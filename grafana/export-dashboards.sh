#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_DIR="${SCRIPT_DIR}/dashboards"
SECRETS_FILE="${SCRIPT_DIR}/grafana-api.secrets"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--url <grafana-url>]

Export all Grafana dashboards to the local dashboards/
directory, organized by folder. Dashboards in the General
folder are placed under dashboards/general/.

The Grafana service account token is read from:
  ${SECRETS_FILE}

Create this file with a single line containing a valid
Grafana service account token. See the README for how to
create one.

Options:
  --url <url>   Grafana base URL (default: ${GRAFANA_URL})
  -h, --help    Show this help message.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)  GRAFANA_URL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

if [[ ! -f "${SECRETS_FILE}" ]]; then
    echo "Error: secrets file not found:" >&2
    echo "  ${SECRETS_FILE}" >&2
    echo "" >&2
    echo "Create it with your Grafana SA token:" >&2
    echo "  echo 'glsa_...' > ${SECRETS_FILE}" >&2
    exit 1
fi

TOKEN="$(cat "${SECRETS_FILE}" | tr -d '[:space:]')"
if [[ -z "${TOKEN}" ]]; then
    echo "Error: secrets file is empty." >&2
    exit 1
fi

api() {
    local endpoint="$1"
    curl -sf \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${GRAFANA_URL}${endpoint}"
}

slugify() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//'
}

echo "==> Fetching dashboard list from ${GRAFANA_URL}..."
SEARCH_RESULT="$(api "/api/search?type=dash-db")"

DASH_COUNT="$(echo "${SEARCH_RESULT}" | jq length)"
if [[ "${DASH_COUNT}" -eq 0 ]]; then
    echo "    No dashboards found."
    exit 0
fi
echo "    Found ${DASH_COUNT} dashboard(s)."

FOLDER_MAP="$(api "/api/search?type=dash-folder")"

echo ""
echo "==> Exporting dashboards..."

echo "${SEARCH_RESULT}" | jq -c '.[]' | while read -r item; do
    uid="$(echo "${item}" | jq -r '.uid')"
    title="$(echo "${item}" | jq -r '.title')"
    folder_uid="$(echo "${item}" | jq -r '.folderUid // empty')"

    if [[ -n "${folder_uid}" ]]; then
        folder_title="$(
            echo "${FOLDER_MAP}" \
                | jq -r \
                    --arg uid "${folder_uid}" \
                    '.[] | select(.uid == $uid) | .title'
        )"
        folder_slug="$(slugify "${folder_title}")"
    else
        folder_slug="general"
    fi

    full_json="$(api "/api/dashboards/uid/${uid}")"
    dash_json="$(
        echo "${full_json}" \
            | jq '.dashboard
                  | del(.id)
                  | del(.version)'
    )"

    slug="$(echo "${item}" | jq -r '.uri' \
        | sed 's|^db/||')"
    if [[ -z "${slug}" || "${slug}" == "null" ]]; then
        slug="$(slugify "${title}")"
    fi

    out_dir="${DASH_DIR}/${folder_slug}"
    mkdir -p "${out_dir}"
    out_file="${out_dir}/${slug}.json"

    echo "${dash_json}" | python3 -m json.tool \
        > "${out_file}"

    echo "    ${folder_slug}/${slug}.json"
done

echo ""
echo "==> Export complete. Files written to:"
echo "    ${DASH_DIR}/"
