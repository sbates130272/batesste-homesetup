#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROM_ETC="/etc/prometheus"
PROM_TARGETS="${PROM_ETC}/targets"
PROM_YML="${SCRIPT_DIR}/prometheus.yml"
PROM_DEFAULTS="${SCRIPT_DIR}/prometheus.defaults"
NODE_DROPIN="${SCRIPT_DIR}/node-exporter-override.conf"
NODE_DROPIN_DIR="/etc/systemd/system/prometheus-node-exporter.service.d"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--targets-only] [--dry-run]

Deploy Prometheus configuration and target files to
${PROM_ETC}, plus /etc/default/prometheus and the
prometheus-node-exporter systemd drop-in.

Options:
  --targets-only  Only deploy target JSON files (no reload
                  needed; Prometheus watches these via
                  file_sd_configs). Skips the unit config.
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

# Deploying is a copy, not a mirror, so a target file deleted
# from the repo used to linger in /etc forever. Harmless while
# its job is also gone, but re-adding a job of the same name
# silently picks the stale targets back up. Prune anything in
# /etc that the repo no longer carries. Editor backups (*.json~)
# go too: file_sd only globs the exact paths named in
# prometheus.yml, but they are pure noise in a managed dir.
PRUNED=0

prune_orphans() {
    local dir="$1" src="$2" label="$3"
    local name
    for f in "${dir}"/*.json "${dir}"/*.json~; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        if [[ ! -f "${src}/${name%\~}" || "$f" == *~ ]]; then
            echo "    ${label}${name} (orphan)"
            run sudo rm -f "$f"
            PRUNED=$((PRUNED + 1))
        fi
    done
}

echo "==> Pruning target files no longer in the repo..."
prune_orphans "${PROM_TARGETS}" "${SCRIPT_DIR}/targets" ""
prune_orphans "${PROM_DISCOVERED}" \
    "${SCRIPT_DIR}/targets/discovered" "discovered/"
if [[ "${PRUNED}" -eq 0 ]]; then
    echo "    nothing to prune"
fi

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

# $ARGS carries the flags that have no prometheus.yml equivalent --
# remote-write receive, the size cap, the nginx listener. A reload
# does not re-read EnvironmentFile, so this needs a restart, and only
# when it actually changed: restarting drops the remote-write
# receiver for as long as the TSDB takes to replay.
echo "==> Deploying /etc/default/prometheus..."
NEED_RESTART=false
if ! sudo cmp -s "${PROM_DEFAULTS}" /etc/default/prometheus; then
    run sudo cp "${PROM_DEFAULTS}" /etc/default/prometheus
    run sudo chown root:root /etc/default/prometheus
    run sudo chmod 644 /etc/default/prometheus
    NEED_RESTART=true
    echo "    changed (will restart, not reload)"
else
    echo "    unchanged"
fi

# node-exporter is a separate unit, so it needs its own reload/restart
# and never a prometheus one. Editor backups in the drop-in directory
# are removed rather than left: systemd ignores a *~ suffix, but the
# one found here was a copy missing the `ExecStart=` reset line, which
# fails the unit outright if it is ever renamed into place.
echo "==> Deploying node-exporter drop-in..."
run sudo mkdir -p "${NODE_DROPIN_DIR}"
run sudo rm -f "${NODE_DROPIN_DIR}"/*~
if ! sudo cmp -s "${NODE_DROPIN}" "${NODE_DROPIN_DIR}/override.conf"; then
    run sudo cp "${NODE_DROPIN}" "${NODE_DROPIN_DIR}/override.conf"
    run sudo chown root:root "${NODE_DROPIN_DIR}/override.conf"
    run sudo chmod 644 "${NODE_DROPIN_DIR}/override.conf"
    run sudo systemctl daemon-reload
    run sudo systemctl restart prometheus-node-exporter
    echo "    changed (node-exporter restarted)"
else
    echo "    unchanged"
fi

# Same rationale as the target-file pruning above: /etc is managed
# from here, and a stray prometheus.yml~ is a config that looks
# authoritative and is not.
run sudo rm -f "${PROM_ETC}"/*.yml~

if $NEED_RESTART; then
    echo "==> Restarting Prometheus (\$ARGS changed)..."
    run sudo systemctl restart prometheus
else
    echo "==> Reloading Prometheus..."
    run sudo systemctl reload prometheus
fi

echo "==> Done. Verify with:"
echo "    systemctl status prometheus"
echo "    curl -s localhost:9090/-/ready"
