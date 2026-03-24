#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_DIR="${SCRIPT_DIR}/targets"

usage() {
    cat <<EOF
Usage: $(basename "$0") <job> <host:port> [key=value ...]

Add a scrape target to an existing job's target file.

Arguments:
  job         The job name (must match an existing file
              in targets/, e.g. "node", "emporia").
  host:port   The target address (e.g. "10.0.0.50:9100").
  key=value   Optional labels to attach to this target
              (e.g. "server_name=snoc-newbox").

Options:
  --deploy    Also copy the updated target file to
              /etc/prometheus/targets/ (requires sudo).
  -h, --help  Show this help message.

Examples:
  $(basename "$0") node 10.0.0.50:9100 \\
      server_name=snoc-newbox

  $(basename "$0") --deploy node 10.0.0.50:9100 \\
      server_name=snoc-newbox
EOF
    exit 0
}

DEPLOY=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)   DEPLOY=true; shift ;;
        -h|--help)  usage ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
        *)  POSITIONAL+=("$1"); shift ;;
    esac
done

set -- "${POSITIONAL[@]}"

if [[ $# -lt 2 ]]; then
    echo "Error: job name and target address required." >&2
    usage
fi

JOB="$1"
TARGET="$2"
shift 2

TARGET_FILE="${TARGETS_DIR}/${JOB}.json"

if [[ ! -f "${TARGET_FILE}" ]]; then
    echo "Error: no target file for job '${JOB}'." >&2
    echo "Expected: ${TARGET_FILE}" >&2
    echo "" >&2
    echo "Available jobs:" >&2
    for f in "${TARGETS_DIR}"/*.json; do
        basename "$f" .json >&2
    done
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "Install with: sudo apt install jq" >&2
    exit 1
fi

if jq -e \
    --arg t "${TARGET}" \
    '[.[].targets[] | select(. == $t)] | length > 0' \
    "${TARGET_FILE}" >/dev/null 2>&1; then
    echo "Error: target '${TARGET}' already exists" \
        "in ${JOB}.json." >&2
    exit 1
fi

LABELS="{}"
if [[ $# -gt 0 ]]; then
    LABELS_ARGS=()
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        if [[ "${key}" == "${kv}" ]]; then
            echo "Error: invalid label '${kv}'." >&2
            echo "Labels must be key=value pairs." >&2
            exit 1
        fi
        LABELS_ARGS+=(--arg "${key}" "${val}")
    done

    LABEL_KEYS=()
    for kv in "$@"; do
        LABEL_KEYS+=("${kv%%=*}")
    done

    JQ_EXPR='{'
    first=true
    for k in "${LABEL_KEYS[@]}"; do
        if $first; then
            first=false
        else
            JQ_EXPR+=','
        fi
        JQ_EXPR+="(\"${k}\"): \$${k}"
    done
    JQ_EXPR+='}'

    LABELS=$(jq -n "${LABELS_ARGS[@]}" "${JQ_EXPR}")
fi

NEW_ENTRY=$(jq -n \
    --arg target "${TARGET}" \
    --argjson labels "${LABELS}" \
    '{targets: [$target], labels: $labels}')

if [[ "${LABELS}" == "{}" ]]; then
    NEW_ENTRY=$(jq -n \
        --arg target "${TARGET}" \
        '{targets: [$target]}')
fi

UPDATED=$(jq --argjson entry "${NEW_ENTRY}" \
    '. + [$entry]' "${TARGET_FILE}")

echo "${UPDATED}" | jq '.' > "${TARGET_FILE}"

echo "Added ${TARGET} to ${JOB}.json"

if ! command -v promtool &>/dev/null; then
    echo "Warning: promtool not found; skipping" \
        "validation." >&2
elif promtool check config \
    "${SCRIPT_DIR}/prometheus.yml" >/dev/null 2>&1; then
    echo "Config validation passed."
else
    echo "Warning: config validation reported issues." >&2
    echo "Run: promtool check config" \
        "${SCRIPT_DIR}/prometheus.yml" >&2
fi

if $DEPLOY; then
    PROM_TARGETS="/etc/prometheus/targets"
    echo "Deploying ${JOB}.json to ${PROM_TARGETS}/..."
    sudo cp "${TARGET_FILE}" "${PROM_TARGETS}/${JOB}.json"
    sudo chown prometheus:prometheus \
        "${PROM_TARGETS}/${JOB}.json"
    echo "Deployed. Prometheus will pick up the change"
    echo "automatically."
fi
