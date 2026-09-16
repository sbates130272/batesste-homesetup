#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Install and configure systemd-oomd on snoc-beelink.
#
# Context: on 16 September 2026 this node spent 45 minutes in a
# swap-thrash livelock and had to be power cycled. The kernel OOM
# killer never fired -- with 4 GiB of swap it never reaches the
# threshold that would make it fire. systemd-oomd kills on pressure
# and swap-use signals instead, well before the kernel's own last
# resort, and this script is what puts it in place.
#
# Everything here is idempotent. Safe to re-run after a systemd
# package upgrade, which is in fact the point: the distro ships its
# own oomd drop-ins under /usr/lib and this re-asserts ours in /etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS_UNIT_DIR="/etc/systemd/system"
USER_UNIT_DIR="${USER_UNIT_DIR:-$HOME/.config/systemd/user}"
OOMD_CONF_DIR="/etc/systemd/oomd.conf.d"

# The 90- prefix is load-bearing, not cosmetic.
#
# systemd merges drop-ins by sorting them on *filename*, across every
# search directory at once -- /etc does not beat /usr/lib unless the
# two files are named the same. Ubuntu ships
# /usr/lib/systemd/system/-.slice.d/10-oomd-root-slice-defaults.conf
# containing `ManagedOOMSwap=auto`, i.e. the root slice trigger
# disabled. A file named 10-batesste-oomd.conf sorts before it
# ("b" < "o"), so the distro's `auto` is applied last and silently
# wins. That is not hypothetical: the first deployment of this script
# used the 10- prefix, `systemctl show` reported ManagedOOMSwap=auto,
# and oomctl listed no swap-monitored cgroups at all.
#
# The same trap applies to user@.service, where Ubuntu's default
# happens to match ours exactly -- so it looks like it worked, while
# the effective policy is actually the distro's and would change out
# from under this repo on a systemd upgrade.
DROPIN="90-batesste-oomd.conf"

# Cleaned up wherever it is found, so re-running this script after the
# fix does not leave the losing file behind to confuse the next reader.
OLD_DROPIN="10-batesste-oomd.conf"

# Never killed. Losing either of these is what turned the September
# incident into a power cycle rather than an inconvenience.
OMIT_UNITS=(ssh tailscaled)

# Killed only after everything else. The monitoring stack, so there is
# still a record of whatever oomd just did.
AVOID_UNITS=(prometheus grafana-server loki alloy)

# Same intent, but these live in the per-user manager under
# user@1000.service, so their drop-ins go somewhere else entirely.
USER_AVOID_UNITS=(hermes-gateway hermes-dashboard)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--skip-install] [--no-restart]

Install systemd-oomd and deploy this repo's OOM policy: the global
tunables from oomd.conf, the swap trigger on the root slice, the
memory-pressure trigger on user@.service, and the omit/avoid
preferences that keep SSH, the tailnet and the monitoring stack off
the kill list.

Options:
  --dry-run       Show what would change without writing anything.
  --skip-install  Do not touch apt; assume systemd-oomd is present.
  --no-restart    Deploy the files but leave systemd-oomd as it is.
  -h, --help      Show this help message.
EOF
    exit 0
}

DRY_RUN=false
SKIP_INSTALL=false
NO_RESTART=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true;      shift ;;
        --skip-install) SKIP_INSTALL=true; shift ;;
        --no-restart)   NO_RESTART=true;   shift ;;
        -h|--help)      usage ;;
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

# Remove a stale 10-prefixed drop-in left by an earlier run of this
# script. Harmless if absent, which is the common case.
drop_stale() {
    local dir="$1" sudo_prefix="${2:-sudo}"
    if [[ -e "${dir}/${OLD_DROPIN}" ]]; then
        if [[ "$sudo_prefix" == "sudo" ]]; then
            run sudo rm -f "${dir}/${OLD_DROPIN}"
        else
            run rm -f "${dir}/${OLD_DROPIN}"
        fi
        echo "    removed stale ${dir}/${OLD_DROPIN}"
    fi
}

# ── Preconditions ────────────────────────────────────────────────
#
# systemd-oomd is built entirely on cgroup v2 and the kernel pressure
# stall information interface. Without either it starts, logs nothing
# obviously wrong, and protects nothing -- so fail loudly here instead.

echo "==> Checking prerequisites..."

if [[ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]]; then
    echo "Error: /sys/fs/cgroup is not a unified (v2) hierarchy." >&2
    echo "       systemd-oomd cannot work without cgroup v2." >&2
    exit 1
fi
echo "    cgroup v2: ok"

if [[ ! -e /proc/pressure/memory ]]; then
    echo "Error: /proc/pressure/memory is missing; this kernel has no PSI." >&2
    echo "       Boot with psi=1 or use a kernel built with CONFIG_PSI." >&2
    exit 1
fi
echo "    PSI:       ok"

# Swap is not a prerequisite, but its absence changes what this policy
# does: with no swap the SwapUsedLimit trigger can never fire and only
# the pressure rule on user@.service remains. Worth saying out loud.
if [[ "$(swapon --noheadings --show=NAME | wc -l)" -eq 0 ]]; then
    echo "    WARNING: no swap is active. The SwapUsedLimit trigger" >&2
    echo "             will never fire; only the user@.service" >&2
    echo "             pressure rule will be in effect." >&2
else
    echo "    swap:      ok ($(swapon --noheadings --show=SIZE | tr -d ' ' | paste -sd+ -))"
fi

# ── Package ──────────────────────────────────────────────────────

if ! $SKIP_INSTALL; then
    if dpkg-query -W -f='${Status}' systemd-oomd 2>/dev/null \
        | grep -q "install ok installed"; then
        echo "==> systemd-oomd already installed."
    else
        echo "==> Installing systemd-oomd..."
        run sudo apt-get update -qq
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-oomd
    fi
fi

# ── Global tunables ──────────────────────────────────────────────

echo "==> Deploying oomd.conf drop-in..."
run sudo mkdir -p "${OOMD_CONF_DIR}"
run sudo install -m 644 -o root -g root \
    "${SCRIPT_DIR}/oomd.conf" "${OOMD_CONF_DIR}/10-batesste.conf"
echo "    ${OOMD_CONF_DIR}/10-batesste.conf"

# ── Triggers ─────────────────────────────────────────────────────
#
# Nothing is monitored until a cgroup opts in. These two files are the
# entire opt-in for this host.

echo "==> Deploying OOM triggers..."
run sudo mkdir -p "${SYS_UNIT_DIR}/-.slice.d"
drop_stale "${SYS_UNIT_DIR}/-.slice.d"
run sudo install -m 644 -o root -g root \
    "${SCRIPT_DIR}/root-slice.conf" "${SYS_UNIT_DIR}/-.slice.d/${DROPIN}"
echo "    -.slice          ManagedOOMSwap=kill"

run sudo mkdir -p "${SYS_UNIT_DIR}/user@.service.d"
drop_stale "${SYS_UNIT_DIR}/user@.service.d"
run sudo install -m 644 -o root -g root \
    "${SCRIPT_DIR}/user-service.conf" "${SYS_UNIT_DIR}/user@.service.d/${DROPIN}"
echo "    user@.service    ManagedOOMMemoryPressure=kill (50%)"

# ── Preferences ──────────────────────────────────────────────────

deploy_pref() {
    local src="$1" unit="$2" label="$3"
    if ! systemctl cat "${unit}.service" &>/dev/null; then
        echo "    SKIP ${unit} (no such unit on this host)"
        return
    fi
    run sudo mkdir -p "${SYS_UNIT_DIR}/${unit}.service.d"
    drop_stale "${SYS_UNIT_DIR}/${unit}.service.d"
    run sudo install -m 644 -o root -g root \
        "${src}" "${SYS_UNIT_DIR}/${unit}.service.d/${DROPIN}"
    echo "    ${label} ${unit}"
}

echo "==> Deploying kill preferences..."
for unit in "${OMIT_UNITS[@]}"; do
    deploy_pref "${SCRIPT_DIR}/preference-omit.conf" "${unit}" "omit "
done
for unit in "${AVOID_UNITS[@]}"; do
    deploy_pref "${SCRIPT_DIR}/preference-avoid.conf" "${unit}" "avoid"
done

# The user units are not reachable from the system manager, and a
# drop-in placed in /etc/systemd/system for them would be silently
# inert -- it parses, it deploys, it does nothing. They go in the
# user manager's own unit directory instead.
echo "==> Deploying kill preferences (user manager)..."
for unit in "${USER_AVOID_UNITS[@]}"; do
    if ! systemctl --user cat "${unit}.service" &>/dev/null; then
        echo "    SKIP ${unit} (no such user unit)"
        continue
    fi
    run mkdir -p "${USER_UNIT_DIR}/${unit}.service.d"
    drop_stale "${USER_UNIT_DIR}/${unit}.service.d" nosudo
    run install -m 644 \
        "${SCRIPT_DIR}/preference-avoid.conf" \
        "${USER_UNIT_DIR}/${unit}.service.d/${DROPIN}"
    echo "    avoid ${unit} (user)"
done

# ── Activate ─────────────────────────────────────────────────────

if $NO_RESTART; then
    echo "==> --no-restart given; not reloading or starting systemd-oomd."
    exit 0
fi

echo "==> Reloading systemd..."
run sudo systemctl daemon-reload
run systemctl --user daemon-reload

echo "==> Enabling systemd-oomd..."
run sudo systemctl enable --now systemd-oomd.service
run sudo systemctl restart systemd-oomd.service

# ── Verify ───────────────────────────────────────────────────────
#
# oomctl is the only honest check. A running systemd-oomd that is
# monitoring an empty set of cgroups looks identical to a working one
# from `systemctl status`, and that is exactly the false sense of
# safety this whole exercise exists to remove.

if $DRY_RUN; then
    echo "==> [dry-run] would verify with: oomctl"
    exit 0
fi

echo "==> Verifying..."
if ! systemctl is-active --quiet systemd-oomd.service; then
    echo "Error: systemd-oomd is not active after start." >&2
    echo "       Check: journalctl -u systemd-oomd -n 50" >&2
    exit 1
fi

# Count the cgroups actually listed under each heading. Grepping for
# the heading itself is not a test: oomctl prints "Swap Monitored
# CGroups:" whether or not anything follows it, so the obvious check
# passes on a completely unprotected system. It did, on the first run
# of this script, and reported success while monitoring nothing.
count_monitored() {
    local heading="$1"
    oomctl | awk -v h="${heading}" '
        $0 ~ "^" h ":" { inside = 1; next }
        /^[^[:space:]]/ { inside = 0 }
        inside && /Path:/ { n++ }
        END { print n + 0 }'
}

swap_n="$(count_monitored 'Swap Monitored CGroups')"
pressure_n="$(count_monitored 'Memory Pressure Monitored CGroups')"

if [[ "${swap_n}" -lt 1 ]]; then
    echo "Error: oomd lists no swap-monitored cgroups, so the swap" >&2
    echo "       trigger is inert. Check that ${DROPIN} sorts after" >&2
    echo "       Ubuntu's 10-oomd-root-slice-defaults.conf:" >&2
    echo "         systemctl show -p ManagedOOMSwap -- -.slice" >&2
    echo "       should print 'kill', not 'auto'." >&2
    exit 1
fi

if [[ "${pressure_n}" -lt 1 ]]; then
    echo "Error: oomd lists no pressure-monitored cgroups. The" >&2
    echo "       user@.service drop-in did not take effect." >&2
    exit 1
fi

echo "    swap-monitored cgroups:     ${swap_n}"
echo "    pressure-monitored cgroups: ${pressure_n}"

echo
oomctl
echo
echo "==> Done. systemd-oomd is active and monitoring."
echo "    Kills are logged by the service itself:"
echo "      journalctl -u systemd-oomd -g 'Killed'"
echo "    and alerted on via the 'memory' rule group in"
echo "    grafana/provisioning/alerting/rules.yaml."
