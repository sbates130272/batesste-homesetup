#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOY_ETC="/etc/alloy"
ALLOY_DEFAULTS="/etc/default/alloy"
ALLOY_CONFIG="${SCRIPT_DIR}/config.alloy"
LOKI_HOST_LAN="10.0.0.15"
LOKI_HOST_TS="snoc-beelink.fold-leaffish.ts.net"

# Kernel hostname -> homelab name, for the machines where they
# differ. amd-laptop is a corporate build and answers to
# APCAN-MQ60818VV; labelling logs with that would leave it
# unjoinable to every Prometheus metric, which is keyed on
# server_name. Anything not listed keeps its own short hostname.
declare -A HOST_LABELS
HOST_LABELS=(
    ["APCAN-MQ60818VV"]="amd-laptop"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--push-url URL] [--host-label NAME] [--dry-run]

Install the Grafana Alloy log shipper configuration on the host
this script is run from. Run it on each Linux machine in the
fleet -- the same "copy it to the target machine" model the repo
already uses for prometheus/avahi-services/.

The push URL is derived from the hostname:

  snoc-beelink   http://127.0.0.1:3100/...  (Loki is local)
  anything else  http://${LOKI_HOST_LAN}:3100/...

A host on the tailnet can reach Loki from anywhere with
  --push-url http://${LOKI_HOST_TS}:3100/loki/api/v1/push

The host label applied to every log line is the machine's short
hostname, mapped through a small table for the boxes whose kernel
hostname is not their homelab name. It must match the server_name
Prometheus uses, or logs and metrics cannot be joined.

Options:
  --push-url URL    Override the derived Loki push URL.
  --host-label NAME Override the derived host label.
  --dry-run         Show what would be done without changing
                    anything.
  -h, --help        Show this help message.
EOF
    exit 0
}

DRY_RUN=false
PUSH_URL=""
HOST_LABEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push-url)
            [[ $# -ge 2 ]] || { echo "Error: --push-url needs a value" >&2; exit 1; }
            PUSH_URL="$2"; shift 2 ;;
        --host-label)
            [[ $# -ge 2 ]] || { echo "Error: --host-label needs a value" >&2; exit 1; }
            HOST_LABEL="$2"; shift 2 ;;
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

if ! command -v alloy &>/dev/null; then
    cat >&2 <<EOF
Error: alloy not found in PATH.

Install it from the Grafana apt repository:

  sudo apt update && sudo apt install -y alloy

If this host has no Grafana apt source yet, see loki/README.md.
EOF
    exit 1
fi

SHORT_HOST="$(hostname -s)"
if [[ -z "${HOST_LABEL}" ]]; then
    HOST_LABEL="${HOST_LABELS[${SHORT_HOST}]:-${SHORT_HOST}}"
fi

if [[ -z "${PUSH_URL}" ]]; then
    # Keyed on the homelab name, not the kernel hostname, so the
    # mapping above is the only place the two have to be
    # reconciled.
    #
    # Everything but the beelink goes over the LAN. A host that
    # leaves the house wants ${LOKI_HOST_TS} instead, but only if
    # it is actually on the tailnet -- amd-laptop roams and has no
    # Tailscale, so the tailnet name resolves to nothing there and
    # the LAN address is the only one that works. Pass --push-url
    # to override for a host that is genuinely on the tailnet.
    case "${HOST_LABEL}" in
        snoc-beelink) LOKI_ADDR="127.0.0.1:3100" ;;
        *)            LOKI_ADDR="${LOKI_HOST_LAN}:3100" ;;
    esac
    PUSH_URL="http://${LOKI_ADDR}/loki/api/v1/push"
fi

echo "==> Host label: ${HOST_LABEL}"
if [[ "${HOST_LABEL}" != "${SHORT_HOST}" ]]; then
    echo "    (kernel hostname is ${SHORT_HOST})"
fi
echo "==> Push URL:   ${PUSH_URL}"

echo "==> Validating config..."
if alloy validate --help &>/dev/null; then
    alloy validate "${ALLOY_CONFIG}"
else
    # Older Alloy has no validate subcommand; fmt still parses
    # the file and fails on a syntax error.
    alloy fmt "${ALLOY_CONFIG}" >/dev/null
fi
echo "    Config is valid."

echo "==> Deploying config.alloy..."
run sudo mkdir -p "${ALLOY_ETC}"
run sudo cp "${ALLOY_CONFIG}" "${ALLOY_ETC}/config.alloy"
run sudo chown root:alloy "${ALLOY_ETC}/config.alloy"
run sudo chmod 640 "${ALLOY_ETC}/config.alloy"

# CUSTOM_ARGS binds the HTTP server to all interfaces so the
# beelink's Prometheus can scrape this agent's own metrics on
# 12345. The packaged default is loopback-only, which is fine
# for the beelink and useless for every other host.
echo "==> Writing ${ALLOY_DEFAULTS}..."
DEFAULTS_TMP="$(mktemp)"
trap 'rm -f "${DEFAULTS_TMP}"' EXIT
cat >"${DEFAULTS_TMP}" <<EOF
## Managed by batesste-homesetup loki/alloy/deploy-agent.sh.
## Local edits are overwritten on the next deploy.

CONFIG_FILE="${ALLOY_ETC}/config.alloy"
CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345"
RESTART_ON_UPGRADE=true

## Read by sys.env() in config.alloy.
LOKI_PUSH_URL="${PUSH_URL}"
LOKI_HOST_LABEL="${HOST_LABEL}"
EOF
if $DRY_RUN; then
    echo "[dry-run] would write:"
    sed 's/^/    /' "${DEFAULTS_TMP}"
else
    sudo cp "${DEFAULTS_TMP}" "${ALLOY_DEFAULTS}"
    sudo chown root:root "${ALLOY_DEFAULTS}"
    sudo chmod 644 "${ALLOY_DEFAULTS}"
fi

# Without both groups Alloy starts, reports every component
# healthy, and collects nothing at all from the journal. There is
# no error anywhere to find.
echo "==> Adding alloy to the adm and systemd-journal groups..."
run sudo usermod -a -G adm,systemd-journal alloy

echo "==> Enabling and restarting alloy..."
run sudo systemctl enable alloy
run sudo systemctl restart alloy

echo "==> Done. Verify with:"
echo "    systemctl status alloy"
echo "    journalctl -u alloy -n 50"
echo "    curl -s localhost:12345/-/ready"
