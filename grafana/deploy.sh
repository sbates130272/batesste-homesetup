#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GF_ETC="/etc/grafana"
GF_PROV="${GF_ETC}/provisioning"
GF_DASH="/var/lib/grafana/dashboards"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Deploy Grafana provisioning configuration and dashboard
JSON files from this repository to the system paths under
${GF_ETC} and ${GF_DASH}.

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

echo "==> Deploying grafana-server defaults..."
run sudo cp \
    "${SCRIPT_DIR}/grafana-server.defaults" \
    /etc/default/grafana-server
run sudo chown root:root /etc/default/grafana-server
run sudo chmod 644 /etc/default/grafana-server

echo "==> Deploying datasource provisioning..."
run sudo cp \
    "${SCRIPT_DIR}/provisioning/datasources/datasources.yaml" \
    "${GF_PROV}/datasources/datasources.yaml"
run sudo chown root:grafana \
    "${GF_PROV}/datasources/datasources.yaml"
run sudo chmod 640 \
    "${GF_PROV}/datasources/datasources.yaml"

echo "==> Deploying dashboard provisioning..."
run sudo cp \
    "${SCRIPT_DIR}/provisioning/dashboards/dashboards.yaml" \
    "${GF_PROV}/dashboards/dashboards.yaml"
run sudo chown root:grafana \
    "${GF_PROV}/dashboards/dashboards.yaml"
run sudo chmod 640 \
    "${GF_PROV}/dashboards/dashboards.yaml"

echo "==> Ensuring dashboard directories exist..."
for folder in home-network-related general amd-related personal-finance; do
    run sudo mkdir -p "${GF_DASH}/${folder}"
    run sudo chown grafana:grafana "${GF_DASH}/${folder}"
done

echo "==> Deploying dashboard JSON files..."
for folder in home-network-related general amd-related personal-finance; do
    src_dir="${SCRIPT_DIR}/dashboards/${folder}"
    [[ -d "${src_dir}" ]] || continue
    for f in "${src_dir}"/*.json; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f")"
        echo "    ${folder}/${name}"
        run sudo cp "$f" "${GF_DASH}/${folder}/${name}"
        run sudo chown grafana:grafana \
            "${GF_DASH}/${folder}/${name}"
    done
done

echo "==> Restarting grafana-server..."
run sudo systemctl restart grafana-server

echo "==> Done. Verify with:"
echo "    systemctl status grafana-server"
echo "    curl -s http://localhost:3000/api/health"
