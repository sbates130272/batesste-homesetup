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
# flag is resolved: the running process, then Homebrew's args file,
# then any plist that launches it, then the compiled-in default.
#
# The running process is checked first and is the only authoritative
# source. Homebrew's node_exporter formula ships a plist that runs a
# wrapper, not the binary, and the wrapper expands an args file:
#
#   exec .../bin/node_exporter $(</opt/homebrew/etc/node_exporter.args)
#
# so the flag is never in the plist even on a host that has it. That
# file is the supported place to put it, and because it lives under
# etc/ Homebrew preserves it across `brew upgrade` rather than
# rewriting it the way it does the plist.
#
# The pattern is ERE via sed -E, and that is not a style choice. The
# Linux script's BRE uses \? for an optional quote, which is a GNU
# extension; BSD sed does not support it and fails *silently*,
# printing nothing rather than erroring. Lifting that pattern verbatim
# made this function return empty on a host where `ps` plainly showed
# the flag.
#
# The same trap as the Linux script applies and for the same reason:
# an empty answer makes the caller want to supply a directory of its
# own, which would redirect node-exporter away from one it may already
# be serving. That is why this script refuses rather than guesses.
detect_textfile_dir() {
    local dir pat f
    pat='s/.*--collector\.textfile\.directory[= ]"?([^" ]*).*/\1/'

    dir="$(ps -Ao args= 2>/dev/null | grep '[n]ode_exporter' \
        | sed -nE "${pat}p" | tail -1)"
    [[ -n "${dir}" ]] && { echo "${dir}"; return; }

    for f in \
        /opt/homebrew/etc/node_exporter.args \
        /usr/local/etc/node_exporter.args \
        "${DAEMON_DIR}"/*node_exporter*.plist \
        "${HOME}"/Library/LaunchAgents/*node_exporter*.plist
    do
        [[ -f "${f}" ]] || continue
        dir="$(sed -nE "${pat}p" "${f}" | tail -1)"
        [[ -n "${dir}" ]] && { echo "${dir}"; return; }
    done

    command -v node_exporter >/dev/null 2>&1 || return 0
    node_exporter --help 2>&1 | sed -nE "${pat}p" | head -1
}

echo "==> Detecting the node-exporter textfile directory..."
TEXTFILE_DIR="$(detect_textfile_dir)"
if [[ -z "${TEXTFILE_DIR}" ]]; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    cat >&2 <<EOF
    ERROR: node-exporter on this host reads no textfile directory.

    Installing the collector now would write metrics nobody scrapes,
    which is exactly the failure the Linux hosts had for months with
    rocm-version: the .prom file was correct and the dashboard column
    was empty.

    On a Homebrew install the supported place for the flag is the
    args file the service wrapper expands, not the plist:

      D=${BREW_PREFIX}/var/node_exporter/textfile_collector
      mkdir -p "\$D"
      echo "--collector.textfile.directory=\$D" \\
          >> ${BREW_PREFIX}/etc/node_exporter.args
      launchctl kickstart -k gui/\$(id -u)/homebrew.mxcl.node_exporter

    That file lives under etc/, so \`brew upgrade\` preserves it. The
    plist does not, which is why the flag does not belong there.
    Confirm it took with:

      ps -Ao args= | grep '[n]ode_exporter'

    then re-run this script.
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

# launchctl kickstart returns as soon as it has *asked* launchd to
# start the job, not when the job has finished. The collector then
# spends one to three seconds inside system_profiler before it writes
# anything, so checking for the file immediately reports a successful
# install as a failure -- which is exactly what the first real run of
# this script did. Poll instead of sleeping a fixed amount: a loaded
# job that is genuinely broken still fails here, just 30s later.
echo "==> Result:"
PROM="${TEXTFILE_DIR}/mac-wifi.prom"
for _ in $(seq 1 30); do
    [[ -f "${PROM}" ]] && break
    sleep 1
done

if [[ -f "${PROM}" ]]; then
    grep -v '^#' "${PROM}" | sed 's/^/    /'
else
    echo "    ERROR: ${PROM} was not written" >&2
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
