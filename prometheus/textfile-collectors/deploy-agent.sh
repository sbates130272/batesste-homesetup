#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
NE_DEFAULTS="/etc/default/prometheus-node-exporter"
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Install the node-exporter textfile collectors on the host this
script is run from. Run it on each GPU machine, and on the backup
host -- the same "copy it to the target machine" model the repo
already uses for prometheus/avahi-services/ and
loki/alloy/deploy-agent.sh.

It installs rocm-version.sh plus its timer everywhere, wsl-wifi.sh
plus its timer on WSL hosts only, where it is the only way to get
a WiFi signal reading at all, and s3-backup-age.sh plus its timer
on whichever host carries batesste-s3-backup.service. And -- on
hosts that do not already have one -- adds
--collector.textfile.directory to the node-exporter ARGS and
restarts the unit. snoc-thinkstation and snoc-strix already carry
that flag; snoc-gaming, amd-laptop and snoc-beelink do not, and
without it node-exporter reads no textfiles at all, so the
collector would write a perfectly good .prom that nothing ever
scrapes.

Note that snoc-beelink gets rocm-version too, where it will report
rocm_version_present 0 forever. That is the collector's documented
"absent" case rather than a malfunction, and gating it on ROCm
being present would defeat the reason it emits that value at all.

Options:
  --dry-run   Show what would be done without changing anything.
  -h, --help  Show this help message.
EOF
    exit 0
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

if [[ ! -f "${NE_DEFAULTS}" ]]; then
    echo "Error: ${NE_DEFAULTS} not found." >&2
    echo "prometheus-node-exporter does not look installed here." >&2
    exit 1
fi

# wsl-wifi is gated on the host actually being WSL. Its units also
# carry ConditionVirtualization=wsl, but that only makes systemd skip
# them silently -- not installing them at all keeps `systemctl
# list-timers` on the Linux boxes honest.
COLLECTORS=(rocm-version)
if [[ "$(systemd-detect-virt 2>/dev/null)" == "wsl" ]]; then
    echo "==> WSL detected; including the Windows WiFi collector."
    COLLECTORS+=(wsl-wifi)
fi

# s3-backup-age is gated on this host actually running the backup,
# which today means snoc-beelink alone. The gate is the presence of
# the backup unit rather than a hostname match, so moving the backup
# to another box brings its monitoring along instead of leaving the
# alert pointed at a machine that no longer backs anything up.
#
# Its unit reads batesste-s3-backup.conf for the bucket, so the config
# has to be installed too -- that file is deployed by hand per
# backup/README.md, and the collector cannot substitute a default for
# it without inventing a bucket name.
BACKUP_UNIT="/etc/systemd/system/batesste-s3-backup.service"
BACKUP_CONF="/usr/local/share/batesste-s3-backup/batesste-s3-backup.conf"
if [[ -f "${BACKUP_UNIT}" ]]; then
    if [[ -f "${BACKUP_CONF}" ]]; then
        echo "==> Backup host detected; including the S3 backup age collector."
        COLLECTORS+=(s3-backup-age)
    else
        echo "    WARNING: ${BACKUP_UNIT} exists but ${BACKUP_CONF} does not;" >&2
        echo "             skipping s3-backup-age. Install the backup config" >&2
        echo "             first (see backup/README.md), then re-run this." >&2
    fi
fi

echo "==> Ensuring ${TEXTFILE_DIR} exists..."
run sudo install -d -m 0755 -o root -g root "${TEXTFILE_DIR}"

for c in "${COLLECTORS[@]}"; do
    echo "==> Installing ${c}..."
    run sudo install -m 0755 -o root -g root \
        "${SCRIPT_DIR}/${c}.sh" "${BIN_DIR}/${c}.sh"
    for u in "${c}.service" "${c}.timer"; do
        echo "    ${u}"
        run sudo install -m 0644 -o root -g root \
            "${SCRIPT_DIR}/${u}" "${UNIT_DIR}/${u}"
    done
done

# The flag is appended to the existing ARGS rather than the line
# being rewritten wholesale: these hosts carry unrelated local
# flags (--collector.wifi everywhere, and more on some), and this
# script has no business deciding what those should be.
echo "==> Checking node-exporter textfile flag..."
NEED_NE_RESTART=false
if sudo grep -q -- '--collector.textfile.directory' "${NE_DEFAULTS}"; then
    echo "    already present"
elif sudo grep -q '^ARGS=' "${NE_DEFAULTS}"; then
    echo "    adding --collector.textfile.directory=${TEXTFILE_DIR}"
    run sudo cp "${NE_DEFAULTS}" "${NE_DEFAULTS}.pre-textfile.bak"
    run sudo sed -i \
        "s|^\(ARGS=\"[^\"]*\)\"|\1 --collector.textfile.directory=${TEXTFILE_DIR}\"|" \
        "${NE_DEFAULTS}"
    NEED_NE_RESTART=true
else
    echo "    no ARGS= line found; adding one"
    run sudo cp "${NE_DEFAULTS}" "${NE_DEFAULTS}.pre-textfile.bak"
    run sudo tee -a "${NE_DEFAULTS}" >/dev/null \
        <<< "ARGS=\"--collector.textfile.directory=${TEXTFILE_DIR}\""
    NEED_NE_RESTART=true
fi

echo "==> Enabling the timers and running each once..."
run sudo systemctl daemon-reload
for c in "${COLLECTORS[@]}"; do
    run sudo systemctl enable --now "${c}.timer"
    run sudo systemctl start "${c}.service"
done

# EnvironmentFile is not re-read on reload, same trap as
# /etc/default/prometheus on the beelink. This must be a restart.
if $NEED_NE_RESTART; then
    echo "==> Restarting node-exporter (ARGS changed)..."
    run sudo systemctl restart prometheus-node-exporter
fi

if $DRY_RUN; then
    echo "==> Dry run complete."
    exit 0
fi

echo "==> Result:"
FAILED=false
for c in "${COLLECTORS[@]}"; do
    if [[ -f "${TEXTFILE_DIR}/${c}.prom" ]]; then
        grep -v '^#' "${TEXTFILE_DIR}/${c}.prom" | sed 's/^/    /'
    else
        echo "    ERROR: ${TEXTFILE_DIR}/${c}.prom was not written" >&2
        FAILED=true
    fi
done
# An `if`, not `$FAILED && exit 1`. The latter is the last command in
# the script, so under `set -e` a clean run exits 1 on the false.
if $FAILED; then
    exit 1
fi

# The grep pattern is not always the collector name with dashes
# swapped for underscores. s3-backup-age publishes batesste_s3_backup_*,
# so the derived pattern would match nothing and the verification step
# would report a healthy install as broken.
metric_prefix() {
    case "$1" in
        s3-backup-age) echo "batesste_s3_backup" ;;
        *)             echo "${1//-/_}" ;;
    esac
}

echo "==> Verify the metrics are actually served:"
for c in "${COLLECTORS[@]}"; do
    echo "    curl -s localhost:9100/metrics | grep $(metric_prefix "$c")"
done
