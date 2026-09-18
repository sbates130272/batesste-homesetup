#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Deploy Home Assistant on snoc-beelink: the config this repo owns, the
# container, and the tailnet listener in front of it.
#
# Same division of labour as ../homebridge/deploy.sh. Home Assistant
# owns its own state -- /var/lib/home-assistant/.storage holds every
# integration, entity, area and token, and nothing here touches it.
# This repo owns configuration.yaml, the container definition, and the
# decision that the web UI is reachable from the tailnet and from
# nowhere else.
#
# Idempotent. A run that finds everything already true restarts
# nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/home-assistant.dc.yml}"
CONTAINER="${CONTAINER:-batesste-home-assistant}"
CONFIG_DIR="${CONFIG_DIR:-/var/lib/home-assistant}"

# Loopback, and the same port inside and out. Unlike the Homebridge
# Config UI there is no port shuffle here: nothing else on this box
# wants 8123, and Home Assistant's own listener is already unroutable
# by virtue of http.server_host in configuration.yaml.
HA_HOST="127.0.0.1"
HA_PORT=8123
TS_PORT=8123

# Created empty if absent. Home Assistant refuses to start when an
# !include target is missing, and the UI editors need somewhere to
# write. They are Home Assistant's to own after that, which is why
# they are created rather than installed.
INCLUDE_FILES=(automations.yaml scripts.yaml scenes.yaml)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--skip-serve] [--no-start] [--pull]

Deploy Home Assistant: configuration.yaml, the container, and the
tailscale serve listener that publishes it to the tailnet.

Options:
  --dry-run     Show what would change without writing anything.
  --skip-serve  Leave the tailscale serve configuration alone.
  --no-start    Deploy the config but do not touch the container.
  --pull        Pull the pinned image before starting. Needed the
                first time and after the image tag moves in
                home-assistant.dc.yml.
  -h, --help    Show this help message.
EOF
    exit 0
}

DRY_RUN=false
SKIP_SERVE=false
START=true
PULL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true;    shift ;;
        --skip-serve) SKIP_SERVE=true; shift ;;
        --no-start)   START=false;     shift ;;
        --pull)       PULL=true;       shift ;;
        -h|--help)    usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi
}

# ── Preconditions ────────────────────────────────────────────────

echo "==> Checking prerequisites..."

command -v docker >/dev/null || { echo "Error: docker is not installed." >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required." >&2; exit 1; }
command -v tailscale >/dev/null || {
    echo "Error: tailscale is not installed; there is no tailnet to serve on." >&2
    exit 1
}
echo "    docker, jq, tailscale: ok"

# Home Assistant's own database, the images, Prometheus and Loki all
# share one 98 GB filesystem that was already at 81% when this was
# written. The image alone is well over a gigabyte.
avail_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [[ "${avail_gb}" -lt 5 ]]; then
    echo "Error: only ${avail_gb}G free on /. Refusing to pull an image." >&2
    exit 1
elif [[ "${avail_gb}" -lt 10 ]]; then
    echo "    WARNING: only ${avail_gb}G free on /." >&2
else
    echo "    disk: ${avail_gb}G free"
fi

# ── Config ───────────────────────────────────────────────────────

echo "==> Deploying configuration..."

run sudo mkdir -p "${CONFIG_DIR}"

if sudo cmp -s "${SCRIPT_DIR}/configuration.yaml" "${CONFIG_DIR}/configuration.yaml" 2>/dev/null; then
    echo "    configuration.yaml (unchanged)"
    config_changed=false
else
    config_changed=true
    # Backed up rather than overwritten in place. On a first run this
    # replaces the default file Home Assistant wrote for itself; on
    # any later run it replaces whatever someone edited by hand, and
    # that edit is worth keeping long enough to port back into the
    # repo copy.
    if sudo test -e "${CONFIG_DIR}/configuration.yaml"; then
        backup="${CONFIG_DIR}/configuration.yaml.$(date +%Y%m%d-%H%M%S).bak"
        run sudo cp -p "${CONFIG_DIR}/configuration.yaml" "${backup}"
        echo "    backup: ${backup}"
    fi
    run sudo install -m 644 -o root -g root \
        "${SCRIPT_DIR}/configuration.yaml" "${CONFIG_DIR}/configuration.yaml"
    echo "    configuration.yaml"
fi

for f in "${INCLUDE_FILES[@]}"; do
    if sudo test -e "${CONFIG_DIR}/${f}"; then
        echo "    ${f} (exists)"
    else
        run sudo touch "${CONFIG_DIR}/${f}"
        run sudo chmod 644 "${CONFIG_DIR}/${f}"
        echo "    ${f} (created empty)"
    fi
done

# ── Container ────────────────────────────────────────────────────

if $PULL; then
    echo "==> Pulling the pinned image..."
    run docker compose -f "${COMPOSE_FILE}" pull
fi

if $START; then
    echo "==> Starting the container..."
    # `up -d` is a no-op when the running container already matches the
    # compose file, and recreates it when it does not -- including when
    # configuration.yaml changed underneath it, which needs a restart
    # rather than a recreate. Hence the explicit restart below.
    run docker compose -f "${COMPOSE_FILE}" up -d

    if $config_changed; then
        echo "==> Restarting (configuration.yaml changed)..."
        run docker restart "${CONTAINER}" >/dev/null
    fi
else
    echo "==> --no-start given; container not touched."
fi

# ── Tailnet listener ─────────────────────────────────────────────
#
# Same reasoning as ../homebridge/deploy.sh: TLS with a real
# certificate, tailnet-only reachability, and a mapping held by
# tailscaled so it survives a reboot without racing anything.
#
# And the same Funnel check, with more at stake. Home Assistant's
# onboarding screen creates the first administrator account for
# whoever reaches it, and its API can unlock doors and watch cameras.

if ! $SKIP_SERVE; then
    echo "==> Checking tailscale serve on :${TS_PORT}..."

    serve_json="$(tailscale serve status --json 2>/dev/null || echo '{}')"
    host="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
    want="http://127.0.0.1:${HA_PORT}"
    have="$(jq -r --arg k "${host}:${TS_PORT}" \
        '.Web[$k].Handlers["/"].Proxy // "none"' <<<"${serve_json}")"

    if [[ "${have}" == "${want}" ]]; then
        echo "    already https://${host}:${TS_PORT} -> ${want}"
    else
        echo "    ${have} -> ${want}"
        run sudo tailscale serve --bg --https "${TS_PORT}" "${want}"
    fi

    funnel="$(jq -r --arg k "${host}:${TS_PORT}" \
        '.AllowFunnel[$k] // false | tostring' <<<"${serve_json}")"
    if [[ "${funnel}" == "true" ]]; then
        echo "    WARNING: Funnel is ON for :${TS_PORT}. Turning it off." >&2
        run sudo tailscale funnel --https "${TS_PORT}" off
    else
        echo "    funnel: off (correct)"
    fi
fi

# ── Verify ───────────────────────────────────────────────────────

if $DRY_RUN; then
    echo "==> [dry-run] would verify the container and the listeners."
    exit 0
fi

if ! $START; then
    exit 0
fi

echo "==> Waiting for Home Assistant..."
code=""
for _ in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        "http://${HA_HOST}:${HA_PORT}/manifest.json" || true)"
    [[ "${code}" == "200" ]] && break
    sleep 2
done

if [[ "${code}" != "200" ]]; then
    echo "Error: Home Assistant did not answer on" >&2
    echo "       http://${HA_HOST}:${HA_PORT}/ (last status: ${code:-none})" >&2
    echo "       Check: docker logs ${CONTAINER}" >&2
    exit 1
fi
echo "    HTTP on ${HA_HOST}:${HA_PORT}: ok"

# The check that matters given network_mode: host. If http.server_host
# is ever lost, this is the difference between a loopback listener and
# an open administrator-account-creation form on the WiFi.
if ss -tln | grep -E "0\.0\.0\.0:${HA_PORT}|\*:${HA_PORT}" >/dev/null; then
    echo "Error: Home Assistant is bound to a wildcard address." >&2
    echo "       http.server_host in configuration.yaml did not take" >&2
    echo "       effect, and the UI is on WiFi and the tailnet without" >&2
    echo "       a proxy in front of it. Fix before going further." >&2
    exit 1
fi
echo "    not wildcard-bound: ok"

if ! $SKIP_SERVE; then
    # Local check only -- tailscaled does not loop its own serve
    # listener back to this host, so curling the tailnet name from here
    # hangs whether or not the deployment works.
    ts_ip="$(tailscale ip -4)"
    if ! ss -tln | grep -q "${ts_ip}:${TS_PORT}"; then
        echo "Error: nothing is listening on ${ts_ip}:${TS_PORT}." >&2
        echo "       Check: sudo tailscale serve status" >&2
        exit 1
    fi
    echo "    tailscaled listening on ${ts_ip}:${TS_PORT}: ok"
fi

echo
echo "==> Done."
echo "    UI:   https://${host:-snoc-beelink.fold-leaffish.ts.net}:${TS_PORT}/  (tailnet only)"
echo "    Logs: docker logs -f ${CONTAINER}"
echo
echo "    Still manual, and in this order -- see README.md:"
echo "      1. Onboard, and create the administrator account."
echo "      2. Decide how devices get in. The HomeKit Device"
echo "         integration CANNOT pair a Homebridge bridge that Apple"
echo "         Home already holds, and all seven here are paired."
echo "         README.md, 'Getting devices in', has the three ways"
echo "         round it -- one of which breaks the Home app."
echo "      3. Settings > Voice assistants > Expose, and expose the"
echo "         entities Hermes should be able to see. Nothing else"
echo "         reaches the agent, whatever ../hermes/mcp.yaml says."
echo "      4. Add the 'Model Context Protocol Server' integration."
echo "      5. Profile > Security > create a long-lived access token,"
echo "         put it in ~/.hermes/.env as HOMEASSISTANT_TOKEN, and run"
echo "         ../hermes/deploy.sh."
