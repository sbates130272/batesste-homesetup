#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="/usr/local/share/emvue-exporter"
LABELS_SRC="${SCRIPT_DIR}/labels.json"
LABELS_DST="${SHARE_DIR}/labels.json"
UNIT="emvue-exporter.service"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Install labels.json for emvue-exporter and restart it. Run this on
snoc-beelink, where the exporter runs.

The exporter itself lives in its own repository,
https://github.com/sbates130272/emvue-exporter, and is installed from
there. Only labels.json is site configuration -- it names this house's
rooms and machines -- so it is the one piece that lives here. The
exporter reads it once at startup, which is why this restarts the
unit rather than reloading it.

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

# Skipped on a dry run so CI can validate this script and labels.json
# on a runner that has no exporter installed.
if ! $DRY_RUN && ! systemctl cat "${UNIT}" &>/dev/null; then
    echo "Error: ${UNIT} not found on this host." >&2
    echo "Install emvue-exporter first; see its README.md." >&2
    exit 1
fi

# A malformed labels.json does not stop the exporter starting, it stops
# it serving anything at all -- load_plug_labels() runs before
# start_http_server(), so the failure looks like a dead scrape target
# rather than a bad file. Cheaper to catch it here.
echo "==> Validating labels.json..."
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
        "${LABELS_SRC}"; then
    echo "Error: ${LABELS_SRC} is not valid JSON." >&2
    exit 1
fi

echo "==> Installing ${LABELS_DST}..."
run sudo install -d -m 0755 -o root -g root "${SHARE_DIR}"
run sudo install -m 0644 -o root -g root "${LABELS_SRC}" "${LABELS_DST}"

echo "==> Restarting ${UNIT}..."
run sudo systemctl restart "${UNIT}"

if $DRY_RUN; then
    echo "==> Dry run complete."
    exit 0
fi

echo "==> Result:"
PORT="$(systemctl cat "${UNIT}" | sed -n 's/.*--port[= ]\([0-9]*\).*/\1/p')"
PORT="${PORT:-9947}"
# The first scrape of the Emporia cloud happens before the listener
# opens, so there is nothing to curl for a few seconds after a restart.
for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${PORT}/metrics" |
            grep -q '^emvue_plug_power_watts'; then
        curl -s "http://localhost:${PORT}/metrics" |
            grep '^emvue_plug_power_watts' | sed 's/^/    /'
        exit 0
    fi
    sleep 2
done

echo "    ERROR: no emvue_plug_power_watts on port ${PORT} after 60s" >&2
echo "    Check: journalctl -u ${UNIT} -n 50" >&2
exit 1
