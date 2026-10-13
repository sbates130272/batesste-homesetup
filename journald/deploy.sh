#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Cap the systemd journal on snoc-beelink.
#
# Context: on 5 October 2026 the root filesystem hit 88% and the
# journal was 3.9 GiB of it, with no retention limit set at all. The
# stock ceiling is 10% of the filesystem -- 9.8 GiB here -- and the
# journal was simply on its way there. This script sets a real cap and
# verifies that the cap is the one actually in effect.
#
# Everything here is idempotent. Safe to re-run after a systemd
# package upgrade, which is in fact the point: the distro ships its
# own journald drop-in under /usr/lib and this re-asserts ours in
# /etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/systemd/journald.conf.d"

# systemd merges drop-ins by sorting on *filename*, across every
# search directory at once; /etc does not beat /usr/lib unless the two
# files are named the same. That is the trap documented at length in
# ../oomd/root-slice.conf, where a 10- prefix lost to the distro's
# 10-oomd-root-slice-defaults.conf.
#
# The 90- prefix here follows the same convention and sorts after any
# *numerically* prefixed drop-in. It does NOT sort after Ubuntu's
# /usr/lib/systemd/journald.conf.d/syslog.conf, and no numeric prefix
# would: digits sort before letters, so an unprefixed distro filename
# always lands last. Confirm with
#   systemd-analyze cat-config systemd/journald.conf
# which prints files in merge order -- ours appears before syslog.conf.
#
# That is fine, because syslog.conf sets only ForwardToSyslog= and
# shares no key with this repo's config. It is called out because the
# obvious reading of the oomd lesson ("add a 90- prefix and you win")
# is not true here, and the verify step below -- which asserts the
# *effective* merged value rather than the file's presence -- is what
# actually catches an override, from any file, in any position.
DROPIN="90-batesste-journald.conf"

# Cleaned up wherever it is found. The first hand-deployment of this
# config on 5 October 2026 used this name.
OLD_DROPIN="size.conf"

# What SystemMaxUse= in journald.conf is expected to end up as. Kept
# here as well so the verify step can assert the *effective* value
# rather than just trusting that the file landed.
EXPECTED_MAX_USE="1G"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--no-restart] [--vacuum]

Deploy this repo's journald retention policy: a 1 GiB cap on the
journal, 128 MiB file rotation granularity, and a 2 GiB free-space
floor. Verifies that the deployed drop-in is the one systemd actually
honours.

Options:
  --dry-run     Show what would change without writing anything.
  --no-restart  Deploy the file but do not restart systemd-journald.
  --vacuum      Also vacuum the existing journal down to the cap now.
                Without this, journald enforces the cap lazily, on
                rotation -- an oversized journal shrinks over hours,
                not immediately.
  -h, --help    Show this help message.
EOF
    exit 0
}

DRY_RUN=false
NO_RESTART=false
VACUUM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true;    shift ;;
        --no-restart) NO_RESTART=true; shift ;;
        --vacuum)     VACUUM=true;     shift ;;
        -h|--help)    usage ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# `journalctl --disk-usage` prints a full sentence -- "Archived and
# active journals take up 456.6M in the file system." Pull out the
# size by position rather than by pattern: the obvious
# grep -oE '[0-9.]+[KMGT]?' also matches the full stop that ends the
# sentence, and reports the journal size as ".".
journal_size() {
    journalctl --disk-usage 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "in") { print $(i-1); exit } }'
}

# ── Preconditions ────────────────────────────────────────────────
#
# A persistent journal is the thing being capped. If storage is
# volatile the journal lives in /run (a tmpfs, capped by RuntimeMaxUse
# and gone on reboot) and every setting in journald.conf is inert.

echo "==> Checking prerequisites..."

if [[ ! -d /var/log/journal ]]; then
    echo "Error: /var/log/journal does not exist, so this node is not" >&2
    echo "       keeping a persistent journal. SystemMaxUse= applies" >&2
    echo "       only to the persistent journal and would do nothing." >&2
    echo "       Set Storage=persistent first if that is unintended." >&2
    exit 1
fi
echo "    persistent journal: ok"

echo "    current size:       $(journal_size)"

# Capping the journal is only cheap because Alloy ships it to Loki
# first. If that pipeline is not running, this script is throwing away
# the only copy -- worth saying out loud rather than discovering later.
if systemctl is-active --quiet alloy.service 2>/dev/null; then
    echo "    alloy:              active (journal is shipped to Loki)"
else
    echo "    WARNING: alloy is not active, so the journal is NOT being" >&2
    echo "             shipped to Loki. While that is true, the local" >&2
    echo "             journal is the only copy and this cap is the" >&2
    echo "             only thing deciding how much history exists." >&2
fi

# ── Deploy ───────────────────────────────────────────────────────

echo "==> Deploying journald drop-in..."
run sudo mkdir -p "${CONF_DIR}"

if [[ -e "${CONF_DIR}/${OLD_DROPIN}" ]]; then
    run sudo rm -f "${CONF_DIR}/${OLD_DROPIN}"
    echo "    removed stale ${CONF_DIR}/${OLD_DROPIN}"
fi

run sudo install -m 644 -o root -g root \
    "${SCRIPT_DIR}/journald.conf" "${CONF_DIR}/${DROPIN}"
echo "    ${CONF_DIR}/${DROPIN}"

if $NO_RESTART; then
    echo "==> --no-restart given; not restarting systemd-journald."
    exit 0
fi

echo "==> Restarting systemd-journald..."
run sudo systemctl restart systemd-journald.service

# ── Vacuum ───────────────────────────────────────────────────────
#
# Optional because it is the one destructive step here. Deploying the
# cap only governs what journald does from now on; it does not shrink
# an already-oversized journal until rotation gets around to it.

if $VACUUM; then
    echo "==> Vacuuming journal to ${EXPECTED_MAX_USE}..."
    run sudo journalctl --vacuum-size="${EXPECTED_MAX_USE}"
fi

# ── Verify ───────────────────────────────────────────────────────
#
# `journalctl --disk-usage` is not a check. It reads under the cap on
# a freshly vacuumed journal whether or not the cap was ever applied,
# which is exactly the false pass this section exists to avoid. The
# honest question is which SystemMaxUse= systemd ended up with after
# merging every drop-in -- so ask systemd, and take the last value,
# since last-wins is the merge rule that the 90- prefix exists to win.

if $DRY_RUN; then
    echo "==> [dry-run] would verify with: systemd-analyze cat-config"
    exit 0
fi

echo "==> Verifying..."

if ! systemctl is-active --quiet systemd-journald.service; then
    echo "Error: systemd-journald is not active after restart." >&2
    echo "       Check: journalctl -u systemd-journald -n 50" >&2
    exit 1
fi

effective="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
    | grep -E '^\s*SystemMaxUse\s*=' \
    | tail -1 \
    | cut -d= -f2- \
    | tr -d '[:space:]')"

if [[ -z "${effective}" ]]; then
    echo "Error: no SystemMaxUse= is in effect. The drop-in did not" >&2
    echo "       land, or was merged away entirely." >&2
    exit 1
fi

if [[ "${effective}" != "${EXPECTED_MAX_USE}" ]]; then
    echo "Error: effective SystemMaxUse is '${effective}', expected" >&2
    echo "       '${EXPECTED_MAX_USE}'. Another drop-in is sorting" >&2
    echo "       after ${DROPIN} and winning. Check the merge order:" >&2
    echo "         systemd-analyze cat-config systemd/journald.conf" >&2
    exit 1
fi

echo "    effective SystemMaxUse:  ${effective}"
echo "    journal on disk:         $(journal_size)"
echo "    root filesystem:         $(df -h --output=pcent / | tail -1 | tr -d ' ') used"

echo
echo "==> Done. The journal is capped at ${EXPECTED_MAX_USE}."
echo "    Older entries live in Loki for 90 days:"
echo "      {job=\"systemd-journal\"} in Grafana Explore"
