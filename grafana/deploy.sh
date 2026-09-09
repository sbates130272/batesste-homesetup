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

echo "==> Deploying alerting provisioning..."
run sudo mkdir -p "${GF_PROV}/alerting"
for f in contact-points notification-policies rules; do
    echo "    ${f}.yaml"
    run sudo cp \
        "${SCRIPT_DIR}/provisioning/alerting/${f}.yaml" \
        "${GF_PROV}/alerting/${f}.yaml"
    run sudo chown root:grafana "${GF_PROV}/alerting/${f}.yaml"
    run sudo chmod 640 "${GF_PROV}/alerting/${f}.yaml"
done

# contact-points.yaml expands $NTFY_TOPIC_URL from the grafana-server
# environment. Grafana substitutes an unset variable with the empty
# string rather than refusing to start, so the failure is a contact
# point that resolves to no URL and drops every notification silently
# -- the same class of quiet failure the backup alerts exist to catch,
# and it would take out the alerting instead of the backup.
if ! grep -q '^NTFY_TOPIC_URL=' "${SCRIPT_DIR}/grafana-server.defaults"; then
    echo "    ERROR: NTFY_TOPIC_URL is not set in grafana-server.defaults." >&2
    exit 1
fi
if grep -q '^NTFY_TOPIC_URL=thishastochange$' "${SCRIPT_DIR}/grafana-server.defaults"; then
    echo "    WARNING: NTFY_TOPIC_URL is still the placeholder; alerts" >&2
    echo "             will be delivered nowhere. Set a real topic URL." >&2
fi

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

# rsync mirrors *within* each directory it is given, so deleting a whole
# folder from the repo removes nothing: the loop above simply never
# visits it and the server keeps serving its dashboards. That is worse
# than untidy. Retiring a folder normally means retiring its provider in
# the same commit, and a dashboard whose provider is gone becomes
# unmanaged rather than deleted -- it cannot then be removed through the
# API ("provisioned dashboard cannot be deleted") and it keeps its
# internal ID, which is how two dashboards ended up sharing one and
# deadlocking provisioning for hours.
#
# The existing preflight cannot catch this: it warns when a provider
# outlives its directory, but here the provider and the directory are
# removed together, so there is nothing left to compare.
echo "==> Pruning dashboard directories no longer in the repo..."
mapfile -t KEEP_DIRS < <(discover_dirs | cut -d' ' -f2)
PRUNED=0
for existing in "${GF_DASH}"/*/ "${GF_DASH}"/vendor/*/; do
    [[ -d "${existing}" ]] || continue
    existing="${existing%/}"
    # vendor/ is a container for the vendor-* dirs, not a dashboard dir.
    [[ "${existing}" == "${GF_DASH}/vendor" ]] && continue
    for keep in "${KEEP_DIRS[@]}"; do
        [[ "${existing}" == "${keep}" ]] && continue 2
    done
    echo "    removing ${existing}"
    sudo find "${existing}" -maxdepth 1 -name '*.json' -printf '        %f\n'
    run sudo rm -rf "${existing}"
    PRUNED=1
done
[[ "${PRUNED}" -eq 0 ]] && echo "    nothing to prune"

echo "==> Restarting grafana-server..."
run sudo systemctl restart grafana-server

echo "==> Done. Verify with:"
echo "    systemctl status grafana-server"
echo "    ./sync-dashboards.sh --check"
