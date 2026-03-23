#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVERED_DIR="${SCRIPT_DIR}/targets/discovered"
BROWSE_TIMEOUT=5

usage() {
    cat <<EOF
Usage: $(basename "$0") [--deploy] [--dry-run] [--timeout N]

Discover Prometheus scrape targets on the local network
using Avahi/mDNS service discovery. Each exporter type
is advertised as a distinct DNS-SD service type (e.g.
_node-exporter._tcp). Discovered targets are written to
targets/discovered/<job>.json.

Options:
  --deploy    Also copy discovered target files to
              /etc/prometheus/targets/discovered/.
  --dry-run   Print what would be written without
              changing any files.
  --timeout N Seconds to wait for avahi-browse responses
              (default: ${BROWSE_TIMEOUT}).
  -h, --help  Show this help message.
EOF
    exit 0
}

DEPLOY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)   DEPLOY=true;          shift ;;
        --dry-run)  DRY_RUN=true;         shift ;;
        --timeout)  BROWSE_TIMEOUT="$2";  shift 2 ;;
        -h|--help)  usage ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

if ! command -v avahi-browse &>/dev/null; then
    echo "Error: avahi-browse not found." >&2
    echo "Install with: sudo apt install avahi-utils" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "Install with: sudo apt install jq" >&2
    exit 1
fi

declare -A SERVICE_MAP
SERVICE_MAP=(
    ["_node-exporter._tcp"]="node"
    ["_emporia-exporter._tcp"]="emporia"
    ["_speedtest-exporter._tcp"]="speedtest_probe speedtest_exporter"
    ["_icloud-exporter._tcp"]="icloud"
    ["_amd-gpu-exporter._tcp"]="amd-gpu-metrics-exporter"
    ["_ais-exporter._tcp"]="ais-exporter"
    ["_rdma-exporter._tcp"]="rdma-exporter"
    ["_nvme-exporter._tcp"]="nvme-exporter"
    ["_openai-exporter._tcp"]="openai_exporter"
    ["_cursor-exporter._tcp"]="cursor-exporter"
    ["_lemonade-exporter._tcp"]="lemonade-exporter"
)

browse_service() {
    local svc_type="$1"
    avahi-browse -rpt "${svc_type}" 2>/dev/null &
    local pid=$!
    sleep "${BROWSE_TIMEOUT}"
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

parse_and_generate() {
    local svc_type="$1"
    local raw="$2"

    if [[ -z "${raw}" ]]; then
        return
    fi

    local json_entries="[]"

    declare -A host_targets
    declare -A host_names

    while IFS=';' read -r status iface proto name \
        type domain hostname address port txt; do
        [[ "${status}" == "=" ]] || continue
        [[ "${proto}" == "IPv4" ]] || continue
        [[ -n "${address}" ]] || continue
        [[ -n "${port}" ]] || continue

        local server_name
        server_name="${hostname%.local}"

        local target="${address}:${port}"

        if [[ -n "${host_targets[${server_name}]+x}" ]]; then
            local existing="${host_targets[${server_name}]}"
            if [[ "${existing}" != *"${target}"* ]]; then
                host_targets["${server_name}"]+=" ${target}"
            fi
        else
            host_targets["${server_name}"]="${target}"
        fi
    done <<< "${raw}"

    if [[ ${#host_targets[@]} -eq 0 ]]; then
        return
    fi

    json_entries="["
    local first=true
    for server_name in $(echo "${!host_targets[@]}" \
        | tr ' ' '\n' | sort); do
        local targets_str="${host_targets[${server_name}]}"
        local targets_json="["
        local t_first=true
        for t in ${targets_str}; do
            if $t_first; then
                t_first=false
            else
                targets_json+=","
            fi
            targets_json+="\"${t}\""
        done
        targets_json+="]"

        if $first; then
            first=false
        else
            json_entries+=","
        fi

        json_entries+=$(jq -n \
            --argjson targets "${targets_json}" \
            --arg server_name "${server_name}" \
            '{
                targets: $targets,
                labels: { server_name: $server_name }
            }')
    done
    json_entries+="]"

    local formatted
    formatted=$(echo "${json_entries}" | jq '.')

    local job_names="${SERVICE_MAP[${svc_type}]}"
    for job in ${job_names}; do
        local outfile="${DISCOVERED_DIR}/${job}.json"

        if $DRY_RUN; then
            echo "--- ${job}.json ---"
            echo "${formatted}"
            echo ""
            continue
        fi

        local needs_write=true
        if [[ -f "${outfile}" ]]; then
            local existing
            existing=$(jq '.' "${outfile}" 2>/dev/null || echo "")
            if [[ "${existing}" == "${formatted}" ]]; then
                needs_write=false
            fi
        fi

        if $needs_write; then
            echo "${formatted}" > "${outfile}"
            echo "Updated ${job}.json" \
                "($(echo "${formatted}" \
                    | jq '[.[].targets[]] | length') targets)"
        else
            echo "No changes for ${job}.json"
        fi
    done
}

mkdir -p "${DISCOVERED_DIR}"

total_found=0
for svc_type in $(echo "${!SERVICE_MAP[@]}" \
    | tr ' ' '\n' | sort); do
    echo "==> Browsing ${svc_type}..."
    raw=$(browse_service "${svc_type}")
    parse_and_generate "${svc_type}" "${raw}"
done

if $DEPLOY && ! $DRY_RUN; then
    PROM_DISCOVERED="/etc/prometheus/targets/discovered"
    echo ""
    echo "==> Deploying discovered targets..."
    sudo mkdir -p "${PROM_DISCOVERED}"
    for f in "${DISCOVERED_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f")"
        echo "    ${name}"
        sudo cp "$f" "${PROM_DISCOVERED}/${name}"
        sudo chown prometheus:prometheus \
            "${PROM_DISCOVERED}/${name}"
    done
    echo "    Prometheus will pick up changes" \
        "automatically."
fi
