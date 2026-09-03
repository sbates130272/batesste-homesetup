#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROM_ETC="/etc/prometheus"
PROM_TARGETS="${PROM_ETC}/targets"
PROM_YML="${SCRIPT_DIR}/prometheus.yml"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--targets-only] [--dry-run]

Deploy Prometheus configuration and target files to
${PROM_ETC}.

Options:
  --targets-only  Only deploy target JSON files (no reload
                  needed; Prometheus watches these via
                  file_sd_configs).
  --dry-run       Show what would be done without changing
                  anything.
  -h, --help      Show this help message.
EOF
    exit 0
}

TARGETS_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets-only) TARGETS_ONLY=true; shift ;;
        --dry-run)      DRY_RUN=true;      shift ;;
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

if ! command -v promtool &>/dev/null; then
    echo "Error: promtool not found in PATH." >&2
    exit 1
fi

# promtool stats every credentials_file, so a missing secret
# fails validation with an opaque message. Check first, via
# sudo: the secrets dir is prometheus-only, so an unprivileged
# invoking user cannot even traverse it.
LEMONADE_KEY_FILE="${PROM_ETC}/secrets/lemonade-api-key"
if ! sudo test -r "${LEMONADE_KEY_FILE}"; then
    cat >&2 <<EOF
Error: ${LEMONADE_KEY_FILE} is missing or unreadable.

The lemonade-snoc-strix job scrapes snoc-strix with a bearer
token. Create the file (contents = LEMONADE_API_KEY, no
trailing newline) with:

  sudo install -d -m 0750 -o prometheus -g prometheus \\
      ${PROM_ETC}/secrets
  printf %s "\$LEMONADE_API_KEY" \\
      | sudo tee ${LEMONADE_KEY_FILE} >/dev/null
  sudo chown prometheus:prometheus ${LEMONADE_KEY_FILE}
  sudo chmod 0400 ${LEMONADE_KEY_FILE}
EOF
    exit 1
fi

# Also under sudo, for the same traversal reason.
echo "==> Validating config with promtool..."
if ! sudo promtool check config "${PROM_YML}"; then
    echo "Error: config validation failed." >&2
    exit 1
fi
echo "    Config is valid."

PROM_DISCOVERED="${PROM_TARGETS}/discovered"

echo "==> Ensuring ${PROM_TARGETS} exists..."
run sudo mkdir -p "${PROM_TARGETS}"
run sudo mkdir -p "${PROM_DISCOVERED}"

echo "==> Deploying manual target files..."
for f in "${SCRIPT_DIR}"/targets/*.json; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    echo "    ${name}"
    run sudo cp "$f" "${PROM_TARGETS}/${name}"
    run sudo chown prometheus:prometheus \
        "${PROM_TARGETS}/${name}"
done

echo "==> Deploying discovered target files..."
for f in "${SCRIPT_DIR}"/targets/discovered/*.json; do
    [[ -f "$f" ]] || { echo "    (none)"; break; }
    name="$(basename "$f")"
    echo "    discovered/${name}"
    run sudo cp "$f" "${PROM_DISCOVERED}/${name}"
    run sudo chown prometheus:prometheus \
        "${PROM_DISCOVERED}/${name}"
done

if $TARGETS_ONLY; then
    echo "==> Targets deployed. Prometheus will pick up"
    echo "    changes automatically (no reload needed)."
    exit 0
fi

echo "==> Backing up current config..."
if [[ -f "${PROM_ETC}/prometheus.yml" ]]; then
    run sudo cp "${PROM_ETC}/prometheus.yml" \
        "${PROM_ETC}/prometheus.yml.pre-file-sd.bak"
fi

echo "==> Deploying prometheus.yml..."
run sudo cp "${PROM_YML}" "${PROM_ETC}/prometheus.yml"
run sudo chown prometheus:prometheus \
    "${PROM_ETC}/prometheus.yml"

echo "==> Reloading Prometheus..."
run sudo systemctl reload prometheus

echo "==> Done. Verify with:"
echo "    systemctl status prometheus"
echo "    curl -s localhost:9090/-/ready"
