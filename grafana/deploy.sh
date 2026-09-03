#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GF_ETC="/etc/grafana"
GF_PROV="${GF_ETC}/provisioning"
GF_DASH="/var/lib/grafana/dashboards"
PROVIDERS_YAML="${SCRIPT_DIR}/provisioning/dashboards/dashboards.yaml"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Deploy Grafana provisioning configuration and dashboard
JSON files from this repository to the system paths under
${GF_ETC} and ${GF_DASH}.

Dashboard directories are discovered from the repository tree
(dashboards/*/ and vendor/dashboards/*/) rather than hardcoded, and
each one must have a matching provider in
provisioning/dashboards/dashboards.yaml. Deployment is a mirror:
files removed from the repo are removed from ${GF_DASH} too, so a
dashboard that moves between folders does not end up provisioned
twice under the same UID.

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

# Emit "<src-dir> <dest-dir>" for every dashboard directory in the repo.
# First-party dirs map to ${GF_DASH}/<name>, adopted third-party dirs to
# ${GF_DASH}/vendor/<name>.
discover_dirs() {
    local d
    for d in "${SCRIPT_DIR}"/dashboards/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        echo "${d} ${GF_DASH}/$(basename "${d}")"
    done
    for d in "${SCRIPT_DIR}"/vendor/dashboards/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        echo "${d} ${GF_DASH}/vendor/$(basename "${d}")"
    done
}

# A directory with no provider is provisioned nowhere -- Grafana would
# silently ignore it. Fail loudly instead.
echo "==> Checking every dashboard directory has a provider..."
PROVIDER_PATHS="$(sed -n 's/^[[:space:]]*path:[[:space:]]*//p' "${PROVIDERS_YAML}")"
MISSING=0
while read -r src dest; do
    if ! grep -qxF "${dest}" <<<"${PROVIDER_PATHS}"; then
        echo "    ERROR: ${src#"${SCRIPT_DIR}"/} has no provider with" >&2
        echo "           path: ${dest}" >&2
        echo "           Add one to ${PROVIDERS_YAML#"${SCRIPT_DIR}"/}." >&2
        MISSING=1
    fi
done < <(discover_dirs)
if [[ "${MISSING}" -ne 0 ]]; then
    exit 1
fi
echo "    OK"

# The reverse case is only a warning: a provider pointing at a directory
# we do not ship is harmless (Grafana just finds nothing there), but it
# usually means a dashboard was deleted without cleaning up the config.
while read -r p; do
    [[ "${p}" == "${GF_DASH}"* ]] || continue
    found=0
    while read -r _ dest; do
        [[ "${dest}" == "${p}" ]] && found=1
    done < <(discover_dirs)
    if [[ "${found}" -eq 0 ]]; then
        echo "    WARNING: provider path has no source directory: ${p}" >&2
    fi
done <<<"${PROVIDER_PATHS}"

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
    "${PROVIDERS_YAML}" \
    "${GF_PROV}/dashboards/dashboards.yaml"
run sudo chown root:grafana \
    "${GF_PROV}/dashboards/dashboards.yaml"
run sudo chmod 640 \
    "${GF_PROV}/dashboards/dashboards.yaml"

echo "==> Deploying dashboard JSON files..."
RSYNC_OPTS=(-r --delete --checksum --chown=grafana:grafana
            --chmod=F644,D755 --include='*/' --include='*.json'
            --exclude='*' --itemize-changes)
$DRY_RUN && RSYNC_OPTS+=(--dry-run)
while read -r src dest; do
    echo "    $(basename "${dest}") <- ${src#"${SCRIPT_DIR}"/}"
    run sudo mkdir -p "${dest}"
    # rsync --dry-run needs the destination to exist; on a first deploy
    # it will not, and every file is trivially new anyway.
    if $DRY_RUN && [[ ! -d "${dest}" ]]; then
        echo "        (new directory, all files would be created)"
        continue
    fi
    sudo rsync "${RSYNC_OPTS[@]}" "${src}/" "${dest}/" \
        | sed 's/^/        /'
done < <(discover_dirs)

echo "==> Restarting grafana-server..."
run sudo systemctl restart grafana-server

echo "==> Done. Verify with:"
echo "    systemctl status grafana-server"
echo "    ./sync-dashboards.sh --check"
