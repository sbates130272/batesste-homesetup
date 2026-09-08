#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOKI_ETC="/etc/loki"
LOKI_DATA="/var/lib/loki"
LOKI_YML="${SCRIPT_DIR}/loki.yml"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Deploy the Loki server configuration to ${LOKI_ETC} and make
sure its data directories exist under ${LOKI_DATA} with the
ownership the loki user needs.

Run this on snoc-beelink only -- it configures the log store
itself. To set up a log *shipper* on any host (including this
one), use alloy/deploy-agent.sh.

Options:
  --dry-run   Show what would be done without changing
              anything.
  -h, --help  Show this help message.
EOF
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
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

if ! command -v loki &>/dev/null; then
    cat >&2 <<EOF
Error: loki not found in PATH.

Install it from the Grafana apt repository, which is already
configured on this host (it is where Grafana came from):

  sudo apt update && sudo apt install -y loki
EOF
    exit 1
fi

# Same gate as prometheus/deploy.sh runs with promtool: never
# copy a config into /etc that the server would then refuse to
# start on.
echo "==> Validating config with loki -verify-config..."
if ! loki -config.file="${LOKI_YML}" -verify-config; then
    echo "Error: config validation failed." >&2
    exit 1
fi
echo "    Config is valid."

# The deb creates the loki *user* with nogroup as its primary
# group and no group of its own, which would leave both the data
# directories and the config owned by nogroup. Make a real group
# and add loki to it as a supplementary member -- changing the
# primary group instead would fight the packaging on upgrade.
echo "==> Ensuring the loki group exists..."
run sudo groupadd -f --system loki
run sudo usermod -a -G loki loki

# Ownership mismatches here are the single most common way a
# Loki install fails, and the symptom is unhelpful: pushes
# return a bare 500 and the flush error only shows up in the
# server's own journal.
echo "==> Ensuring data directories exist..."
for d in "${LOKI_DATA}" "${LOKI_DATA}/chunks" "${LOKI_DATA}/rules" \
         "${LOKI_DATA}/compactor"; do
    echo "    ${d}"
    run sudo install -d -o loki -g loki -m 0750 "${d}"
done

# /var/lib/loki is its own logical volume so that a runaway log
# source fills 12G and stops, rather than filling / and taking
# Grafana, Prometheus, Firefly and Time Machine down with it.
# Loki caps retention by time, not size, so the volume boundary
# is the only real size limit there is.
if ! mountpoint -q "${LOKI_DATA}" 2>/dev/null; then
    echo "    WARNING: ${LOKI_DATA} is not a separate mount." >&2
    echo "             Loki is writing to the root filesystem;" >&2
    echo "             see README.md for the LV setup." >&2
fi

echo "==> Deploying loki.yml..."
run sudo mkdir -p "${LOKI_ETC}"
run sudo cp "${LOKI_YML}" "${LOKI_ETC}/config.yml"
run sudo chown root:loki "${LOKI_ETC}/config.yml"
run sudo chmod 640 "${LOKI_ETC}/config.yml"

echo "==> Restarting loki..."
run sudo systemctl restart loki

echo "==> Done. Verify with:"
echo "    systemctl status loki"
echo "    curl -s localhost:3100/ready"
echo "    journalctl -u loki | grep -i retention"
