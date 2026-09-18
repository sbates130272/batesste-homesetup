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
# integration, entity, area and token. This repo owns
# configuration.yaml, the container definition, and the decision that
# the web UI is reachable from the tailnet and from nowhere else.
#
# One exception to that line, and it is not a happy one: .storage/http.
# Since 2026.9 the bind address lives there and YAML cannot set it, so
# this script writes that one key. See the HTTP config store section.
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
# by virtue of the server_host written into .storage/http below.
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

# ── HTTP config store ────────────────────────────────────────────
#
# The bind address is not configurable from configuration.yaml any
# more. Since 2026.9 an `http:` block is migrated into .storage/http
# once, applied as a five-minute trial, and reverted to the stored
# `stable` slot unless somebody confirms it in the UI -- a slot that
# carries no server_host, and therefore a dual-stack wildcard bind on
# a host-networked container. The first version of this script shipped
# the YAML block and verified the loopback listener inside that trial
# window, which passed and then silently stopped being true.
#
# So the store is what this repo writes. `stable` is what Home
# Assistant uses on every normal start once yaml_migration_done is
# set, and pending is cleared so no trial is ever staged.

http_store="${CONFIG_DIR}/.storage/http"
readonly HTTP_STORE_JQ='
.version = 2
| .minor_version = 2
| .key = "http"
| .data.stable = ((.data.stable // {})
    + { server_port: 8123,
        server_host: ["127.0.0.1"],
        use_x_forwarded_for: true,
        trusted_proxies: ["127.0.0.1/32", "::1/128"],
        error: null,
        error_message: null })
| .data.pending = null
| .data.yaml_migration_done = true
'

echo "==> Checking the HTTP config store..."

store_now='{"data":{}}'
if sudo test -e "${http_store}"; then
    store_now="$(sudo cat "${http_store}")"
fi
store_want="$(jq -S "${HTTP_STORE_JQ}" <<<"${store_now}")"

if [[ "$(jq -S . <<<"${store_now}")" == "${store_want}" ]]; then
    echo "    stable slot: loopback, already correct"
    store_changed=false
else
    store_changed=true
    if $DRY_RUN; then
        echo "[dry-run] would rewrite ${http_store}"
    else
        # Written while the container is stopped: Home Assistant holds
        # this store in memory and rewrites it on shutdown, so an edit
        # under a running instance is undone by the next restart.
        docker stop "${CONTAINER}" >/dev/null 2>&1 || true
        tmp_store="$(mktemp)"
        trap 'rm -f "${tmp_store}"' EXIT
        printf '%s\n' "${store_want}" >"${tmp_store}"
        jq empty <"${tmp_store}" && [[ -s "${tmp_store}" ]] || {
            echo "Error: refusing to install an invalid HTTP config store." >&2
            exit 1
        }
        # Backed up beside the config root rather than inside
        # .storage: Home Assistant archives that directory wholesale,
        # and it is its own namespace, not a dumping ground.
        if sudo test -e "${http_store}"; then
            sudo cp -p "${http_store}" \
                "${CONFIG_DIR}/http-store.$(date +%Y%m%d-%H%M%S).bak"
        fi
        sudo mkdir -p "${CONFIG_DIR}/.storage"
        sudo install -m 644 -o root -g root "${tmp_store}" "${http_store}"
        echo "    stable slot: rewritten (server_host 127.0.0.1, pending cleared)"
    fi
fi

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
        # The redirect belongs to docker, not to `run`: attached to the
        # wrapper it would discard the [dry-run] line for the one
        # mutating action a dry run exists to show.
        if $DRY_RUN; then
            echo "[dry-run] docker restart ${CONTAINER}"
        else
            docker restart "${CONTAINER}" >/dev/null
        fi
    fi
    # The store edit stopped the container above, so `up -d` has
    # already started it with the new slot; nothing more to do here.
else
    echo "==> --no-start given; container not touched."
    if $store_changed && ! $DRY_RUN; then
        echo "    WARNING: the HTTP config store was rewritten, which" >&2
        echo "    stopped the container. It is still stopped." >&2
    fi
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

# Resolved unconditionally: the closing summary prints it whether or
# not --skip-serve was given, and a hardcoded fallback there would be
# a second copy of this box's tailnet name waiting to go stale.
host="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"

if ! $SKIP_SERVE; then
    echo "==> Checking tailscale serve on :${TS_PORT}..."

    serve_json="$(tailscale serve status --json 2>/dev/null || echo '{}')"
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

# The check that matters given network_mode: host. If the stable slot
# is ever lost, this is the difference between a loopback listener and
# an open administrator-account-creation form on the WiFi.
#
# `[::]:8123` is in the pattern because that is how iproute2 renders an
# IPv6 wildcard, and Home Assistant's built-in default binds 0.0.0.0
# *and* :: -- so the v6 half can be the only one visible if something
# else already holds the v4 address.
listeners="$(ss -tln)" || {
    echo "Error: ss failed; cannot prove the bind is not a wildcard." >&2
    exit 1
}
if grep -E "0\.0\.0\.0:${HA_PORT}|\[::\]:${HA_PORT}|\*:${HA_PORT}" \
        <<<"${listeners}" >/dev/null; then
    echo "Error: Home Assistant is bound to a wildcard address." >&2
    echo "       The server_host in the stable slot of" >&2
    echo "       ${CONFIG_DIR}/.storage/http did not take effect, and" >&2
    echo "       the UI is on WiFi without a proxy in front of it." >&2
    echo "       Fix before going further." >&2
    exit 1
fi
echo "    not wildcard-bound: ok"

# A wildcard bind is also what Home Assistant falls back to when it
# decides the running config was a trial nobody confirmed. Nothing
# here should ever stage one, so its presence means the store is being
# written by something other than this script.
if [[ "$(sudo jq -r '.data.pending // "null"' "${http_store}")" != "null" ]]; then
    echo "    WARNING: a pending HTTP config is staged. It reverts to the" >&2
    echo "    stable slot five minutes from now and restarts." >&2
fi

if ! $SKIP_SERVE; then
    # Local check only -- a curl to the tailnet name from this host
    # is accepted and TLS-terminated by tailscaled and then never
    # answered, so it hangs whether or not the deployment works.
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
echo "    UI:   https://${host}:${TS_PORT}/  (tailnet only)"
echo "    Logs: docker logs -f ${CONTAINER}"
echo
echo "    Still manual, and in this order -- see README.md:"
echo "      1. Onboard from ANOTHER tailnet node, not from this box:"
echo "         :${TS_PORT} is bound to loopback and reached through"
echo "         tailscale serve, and the owner token is bound to the"
echo "         origin you onboard from."
echo "         Set the time zone BY HAND. 'Detect' asks"
echo "         services.home-assistant.io, which sees the corporate"
echo "         egress and answers America/Vancouver; the container"
echo "         runs TZ=America/Edmonton. Nothing errors if they"
echo "         disagree -- every timestamp is just an hour out."
echo "      2. Settings > Devices & services > Bluetooth: disable the"
echo "         adapter entry. The /run/dbus mount is gone but the"
echo "         config entry survives onboarding and throws a bleak"
echo "         traceback every ten minutes."
echo "      3. Settings > Voice assistants > Expose, and expose the"
echo "         entities Hermes should be able to see. Nothing else"
echo "         reaches the agent, whatever ../hermes/mcp.yaml says."
echo "         The overflow menu's 'Expose new entities' defaults to"
echo "         ON, so this page is a default and not an allowlist"
echo "         until you turn it off."
echo "      4. Add the 'Model Context Protocol Server' integration --"
echo "         NOT 'Model Context Protocol', which is the opposite"
echo "         direction. POST /api/mcp goes 404 -> 401 once it is in."
echo "      5. Profile > Security > create a long-lived access token."
echo "         Put it in ~/.hermes/.env as HOMEASSISTANT_TOKEN with an"
echo "         editor -- do not echo it, this box is imaged to S3"
echo "         nightly and there is no need for bash history as well."
echo "         Then ../hermes/deploy.sh, which restarts all three"
echo "         hermes units, not just the gateway."
echo "      6. Prove it: hermes mcp test homeassistant"
echo "         'hermes mcp list' reports the config, not a connection."
echo "         Expect a connection with no entity tools until step 7;"
echo "         that is correct, not a failure."
echo "      7. Devices, last, because today it is blocked. The HomeKit"
echo "         Device integration cannot adopt these bridges -- it"
echo "         aborts 'already_paired' before it ever asks for a PIN."
echo "         README.md, 'Getting devices in', has why and what to do"
echo "         instead."
echo
echo "    Re-run this script once after the UI work. Its wildcard-bind"
echo "    check and its pending-config warning are the only things"
echo "    that catch a .storage/http trial staged by Settings >"
echo "    System > Network, and that trial reverts silently."
