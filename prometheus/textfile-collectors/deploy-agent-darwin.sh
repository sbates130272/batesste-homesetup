#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# The macOS half of deploy-agent.sh. Separate script rather than a
# branch inside that one, because almost nothing in it survives the
# crossing: no /etc/default, no systemctl, no drop-ins, no
# systemd-detect-virt, and a different privilege model. A --dry-run
# that has to skip nine tenths of its own body is not a deployment,
# it is two scripts sharing a filename.
#
# Written for bash 3.2, which is what /bin/bash is on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
DAEMON_DIR="/Library/LaunchDaemons"
PLIST_LABEL="com.batesste.mac-wifi"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Install the macOS node-exporter textfile collectors on the host this
script is run from -- the same "copy it to the target machine" model
deploy-agent.sh uses on Linux.

Today that is mac-wifi.sh alone. The darwin node-exporter build has no
wifi collector and does not export node_network_info, so this is the
only way the LAN Overview Node Fleet table gets a WiFi (dBm) or Link
reading for snoc-shannon.

rocm-version and s3-backup-age are deliberately not installed here.
Neither applies to a Mac: there is no ROCm for macOS, and the S3
backup runs on snoc-beelink.

This script will not modify how node-exporter itself is launched. If
it cannot find a textfile directory that node-exporter already reads,
it stops and prints what to add, rather than rewriting a plist that
Homebrew owns and will overwrite on the next upgrade.

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

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this is the macOS deploy script; this host is $(uname -s)." >&2
    echo "Use deploy-agent.sh instead." >&2
    exit 1
fi

# Where node-exporter actually reads textfiles from, in the order the
# flag is resolved: the running process, then any plist that launches
# it, then the binary's own compiled-in default.
#
# The running process is checked first and is the only authoritative
# source. Homebrew's node_exporter formula ships a plist with no
# arguments, so a textfile directory on a Mac is nearly always
# something a human added by hand, and the plist that carries it is
# not necessarily the one Homebrew currently manages.
#
# The same trap as the Linux script applies and for the same reason:
# an empty answer makes the caller want to supply a directory of its
# own, which would redirect node-exporter away from one it may already
# be serving. That is why this script refuses rather than guesses.
detect_textfile_dir() {
    local dir pat plist
    pat='s/.*--collector\.textfile\.directory[= ]"\?\([^" ]*\).*/\1/p'

    dir="$(ps -Ao args= 2>/dev/null | grep '[n]ode_exporter' | sed -n "${pat}" | tail -1)"
    [[ -n "${dir}" ]] && { echo "${dir}"; return; }

    for plist in \
        "${DAEMON_DIR}"/*node_exporter*.plist \
        "${HOME}"/Library/LaunchAgents/*node_exporter*.plist \
        /opt/homebrew/opt/node_exporter/*.plist \
        /usr/local/opt/node_exporter/*.plist
    do
        [[ -f "${plist}" ]] || continue
        dir="$(sed -n "${pat}" "${plist}" | tail -1)"
        [[ -n "${dir}" ]] && { echo "${dir}"; return; }
    done

    command -v node_exporter >/dev/null 2>&1 || return 0
    node_exporter --help 2>&1 | sed -n "${pat}" | head -1
}

echo "==> Detecting the node-exporter textfile directory..."
TEXTFILE_DIR="$(detect_textfile_dir)"
if [[ -z "${TEXTFILE_DIR}" ]]; then
    cat >&2 <<EOF
    ERROR: node-exporter on this host reads no textfile directory.

    Installing the collector now would write metrics nobody scrapes,
    which is exactly the failure the Linux hosts had for months with
    rocm-version: the .prom file was correct and the dashboard column
    was empty.

    Add the flag to whatever launches node_exporter here, restart it,
    and re-run this script. For a Homebrew install that is:

      --collector.textfile.directory=/usr/local/var/node_exporter/textfile_collector

    Note that \`brew upgrade node_exporter\` rewrites its own plist and
    will drop the flag again. This script does not edit that plist for
    you precisely because Homebrew owns it.
EOF
    exit 1
fi
echo "    using ${TEXTFILE_DIR} (node-exporter already reads it)"

echo "==> Ensuring ${TEXTFILE_DIR} exists..."
run sudo install -d -m 0755 -o root -g wheel "${TEXTFILE_DIR}"

echo "==> Installing mac-wifi.sh..."
run sudo install -m 0755 -o root -g wheel \
    "${SCRIPT_DIR}/mac-wifi.sh" "${BIN_DIR}/mac-wifi.sh"

# The plist is rendered rather than copied, because launchd has no
# equivalent of a systemd drop-in: there is no way to layer the host's
# textfile directory over a host-agnostic file tracked in git. So the
# file in git carries a placeholder and the substitution happens here.
echo "==> Installing ${PLIST_LABEL}.plist..."
if $DRY_RUN; then
    echo "[dry-run] render ${SCRIPT_DIR}/mac-wifi.plist to" \
         "${DAEMON_DIR}/${PLIST_LABEL}.plist with TEXTFILE_DIR=${TEXTFILE_DIR}"
else
    sed "s|@TEXTFILE_DIR@|${TEXTFILE_DIR}|g" "${SCRIPT_DIR}/mac-wifi.plist" \
        | sudo tee "${DAEMON_DIR}/${PLIST_LABEL}.plist" >/dev/null
    sudo chown root:wheel "${DAEMON_DIR}/${PLIST_LABEL}.plist"
    sudo chmod 0644 "${DAEMON_DIR}/${PLIST_LABEL}.plist"

    # launchd refuses to load a plist it cannot parse and says very
    # little about why, so check it here while the error is still
    # attributable to this script.
    sudo plutil -lint "${DAEMON_DIR}/${PLIST_LABEL}.plist"
fi

# bootout before bootstrap, because bootstrap on an already-loaded
# label fails rather than reloading. The bootout is allowed to fail:
# on a first install there is nothing to unload.
echo "==> Loading the launchd job..."
run sudo launchctl bootout "system/${PLIST_LABEL}" 2>/dev/null || true
run sudo launchctl bootstrap system "${DAEMON_DIR}/${PLIST_LABEL}.plist"
run sudo launchctl kickstart -k "system/${PLIST_LABEL}"

if $DRY_RUN; then
    echo "==> Dry run complete."
    exit 0
fi

echo "==> Result:"
if [[ -f "${TEXTFILE_DIR}/mac-wifi.prom" ]]; then
    grep -v '^#' "${TEXTFILE_DIR}/mac-wifi.prom" | sed 's/^/    /'
else
    echo "    ERROR: ${TEXTFILE_DIR}/mac-wifi.prom was not written" >&2
    echo "           Check /var/log/mac-wifi.err" >&2
    exit 1
fi

echo "==> Verify the metrics are actually served:"
echo "    curl -s localhost:9100/metrics | grep mac_wifi"
echo ""
echo "    If mac_wifi_signal_present is 0, the RSSI was withheld rather"
echo "    than missing: since Sequoia, system_profiler needs Location"
echo "    Services authorisation to report Signal / Noise. Grant it to"
echo "    the process that runs this and the WiFi (dBm) column fills in;"
echo "    the Link column works either way."
