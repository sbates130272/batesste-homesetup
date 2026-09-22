#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Deploy the version-controlled parts of the Homebridge setup on
# snoc-beelink.
#
# Homebridge owns its own installation and its own config file: the
# apt package manages /opt/homebridge, and the Config UI rewrites
# /var/lib/homebridge/config.json every time a plugin's settings are
# saved. So this does not template that file. It re-asserts the three
# decisions that belong to this repo and that nothing else on the box
# will keep true:
#
#   1. The Config UI listens on loopback only.
#   2. `tailscale serve` publishes it to the tailnet on :8581, with
#      TLS and tailnet identity in front of it.
#   3. It is served to the tailnet and NOT to the public internet --
#      no Funnel, and this script removes one if it finds it.
#
# Everything here is idempotent, and everything it changes it checks
# first, so a no-op run does not restart Homebridge.
#
# Run it after a Homebridge major upgrade, after anything that touches
# the Config UI's own settings page, and after a `tailscale serve
# reset`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-/var/lib/homebridge/config.json}"

# The Config UI's own listener. Loopback, and on a port that is not
# the one the tailnet uses.
#
# 8581 is Homebridge's documented default and what every piece of its
# documentation tells you to open. Keeping the tailnet on 8581 and
# moving the real listener to 18581 means the port in the URL is still
# the familiar one, while the only socket bound to a routable address
# belongs to tailscaled. Same split as the Prometheus pair in
# nginx/README.md, and for the same reason.
UI_HOST="127.0.0.1"
UI_PORT=18581
TS_PORT=8581

# homebridge-plugin-emporia is installed from a tarball in a sibling
# working copy rather than from npm -- see package.json in
# /var/lib/homebridge. If that directory goes away, the plugin
# survives in node_modules until the next `npm install`, and then
# disappears with no error anyone reads. Checked, not fixed: rebuilding
# it is a `npm pack` in a repo this script does not own.
EMPORIA_TARBALL="${EMPORIA_TARBALL:-$HOME/Projects/homebridge-plugin-emporia/homebridge-plugin-emporia-1.0.0.tgz}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--skip-install] [--skip-serve]
                        [--no-restart]

Re-assert this repo's Homebridge configuration on the local machine:
the loopback bind for the Config UI, the tailnet listener in front of
it, and the absence of a public Funnel.

Options:
  --dry-run       Show what would change without writing anything.
  --skip-install  Do not touch apt; assume Homebridge is present.
  --skip-serve    Leave the tailscale serve configuration alone.
  --no-restart    Deploy the config but do not restart Homebridge.
                  The new bind address does not take effect until it
                  is restarted.
  -h, --help      Show this help message.
EOF
    exit 0
}

DRY_RUN=false
SKIP_INSTALL=false
SKIP_SERVE=false
RESTART=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true;      shift ;;
        --skip-install) SKIP_INSTALL=true; shift ;;
        --skip-serve)   SKIP_SERVE=true;   shift ;;
        --no-restart)   RESTART=false;     shift ;;
        -h|--help)      usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi
}

# ── Preconditions ────────────────────────────────────────────────

echo "==> Checking prerequisites..."

command -v jq >/dev/null || { echo "Error: jq is required." >&2; exit 1; }
command -v tailscale >/dev/null || {
    echo "Error: tailscale is not installed; there is no tailnet to serve on." >&2
    exit 1
}
echo "    jq, tailscale: ok"

if [[ -e "${EMPORIA_TARBALL}" ]]; then
    echo "    emporia tarball: ok"
else
    echo "    WARNING: ${EMPORIA_TARBALL} is missing." >&2
    echo "             homebridge-plugin-emporia is a file: dependency on" >&2
    echo "             that path. It keeps working from node_modules until" >&2
    echo "             the next npm install in /var/lib/homebridge, which" >&2
    echo "             will then drop it. Rebuild it with 'npm pack' in" >&2
    echo "             the plugin's working copy." >&2
fi

# ── Package ──────────────────────────────────────────────────────
#
# The apt repository, not npm. The Homebridge project publishes a
# Debian package that brings its own pinned Node -- /opt/homebridge/bin/node,
# currently v24 -- and this box has no system Node at all. That is not
# an accident to be tidied up: the two dead `command: npx` MCP servers
# described in hermes/mcp.yaml are what a system Node is for, and there
# is still no reason to have one.

if ! $SKIP_INSTALL; then
    if dpkg-query -W -f='${Status}' homebridge 2>/dev/null \
        | grep -q "install ok installed"; then
        echo "==> Homebridge already installed ($(dpkg-query -W -f='${Version}' homebridge))."
    else
        echo "==> Installing Homebridge from repo.homebridge.io..."
        run sudo mkdir -p /usr/share/keyrings
        run bash -c 'curl -fsSL https://repo.homebridge.io/KEY.gpg \
            | sudo gpg --dearmor -o /usr/share/keyrings/homebridge.gpg'
        run bash -c 'echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] \
https://repo.homebridge.io stable main" \
            | sudo tee /etc/apt/sources.list.d/homebridge.list >/dev/null'
        run sudo apt-get update -qq
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y homebridge
    fi
fi

if [[ ! -e "${CONFIG}" ]]; then
    echo "Error: ${CONFIG} does not exist." >&2
    echo "       Start homebridge once to have it generate one." >&2
    exit 1
fi

# ── Config UI bind address ───────────────────────────────────────
#
# Edited in place with jq rather than installed from a repo copy. The
# file holds Eufy, Govee and Emporia credentials and a HomeKit setup
# code; none of that is in git and none of it should be. See
# sync-config.sh for the redacted snapshot that is.
#
# The dance with a temp file and `install` is not ceremony. config.json
# is read continuously by a running Homebridge, and `jq ... > file`
# truncates before it writes -- a crash or a full disk in that window
# leaves an empty config and a bridge that comes back with no
# accessories and no pairing.

echo "==> Checking Config UI bind address..."

current_host="$(sudo jq -r '(.platforms[] | select(.platform=="config") | .host) // "unset"' "${CONFIG}")"
current_port="$(sudo jq -r '(.platforms[] | select(.platform=="config") | .port) // "unset"' "${CONFIG}")"

if [[ "${current_host}" == "${UI_HOST}" && "${current_port}" == "${UI_PORT}" ]]; then
    echo "    already ${UI_HOST}:${UI_PORT}"
    config_changed=false
else
    echo "    ${current_host}:${current_port} -> ${UI_HOST}:${UI_PORT}"
    config_changed=true

    if $DRY_RUN; then
        echo "[dry-run] would rewrite the config platform in ${CONFIG}"
    else
        backup="${CONFIG}.$(date +%Y%m%d-%H%M%S).bak"
        sudo cp -p "${CONFIG}" "${backup}"
        echo "    backup: ${backup}"

        tmp="$(mktemp)"
        sudo jq --arg host "${UI_HOST}" --argjson port "${UI_PORT}" '
            .platforms = [ .platforms[]
                | if .platform == "config"
                  then .host = $host | .port = $port
                  else . end ]
        ' "${CONFIG}" > "${tmp}"

        # A truncated or invalid result must never reach the live path.
        jq empty "${tmp}" || {
            echo "Error: rewritten config is not valid JSON. Left ${CONFIG} alone." >&2
            rm -f "${tmp}"
            exit 1
        }

        sudo install -m 644 -o homebridge -g homebridge "${tmp}" "${CONFIG}"
        rm -f "${tmp}"
    fi
fi

# ── Tailnet listener ─────────────────────────────────────────────
#
# `tailscale serve` terminates TLS with a real certificate for
# snoc-beelink.fold-leaffish.ts.net and will only talk to nodes on the
# tailnet. That is what makes a loopback-only Config UI reachable from
# the phone, from snoc-strix and from anywhere else on the tailnet,
# without putting a single routable socket in front of Homebridge.
#
# Deliberately not a Funnel. The Config UI can install arbitrary npm
# packages, edit config.json, restart the bridge and read the log; it
# is a root-equivalent control plane for every device in the house
# behind one password. Funnel would put that on the public internet.
# The check below is not decoration -- `tailscale funnel 8581 on` is
# two words away from the serve command and does not warn.

# Resolved unconditionally: it is printed in the closing summary,
# which runs whether or not --skip-serve was given, and `set -u` turns
# an unset one into a failure after the deploy has already succeeded.
host="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"

if ! $SKIP_SERVE; then
    echo "==> Checking tailscale serve on :${TS_PORT}..."

    serve_json="$(tailscale serve status --json 2>/dev/null || echo '{}')"
    want="http://127.0.0.1:${UI_PORT}"
    have="$(jq -r --arg k "${host}:${TS_PORT}" \
        '.Web[$k].Handlers["/"].Proxy // "none"' <<<"${serve_json}")"

    if [[ "${have}" == "${want}" ]]; then
        echo "    already https://${host}:${TS_PORT} -> ${want}"
    else
        echo "    ${have} -> ${want}"
        run sudo tailscale serve --bg --https "${TS_PORT}" "${want}"
    fi

    # AllowFunnel is keyed by "host:port" and is absent, not false,
    # when Funnel is off -- so this compares against the string "true"
    # rather than trusting a bare truthiness test on null.
    funnel="$(jq -r --arg k "${host}:${TS_PORT}" \
        '.AllowFunnel[$k] // false | tostring' <<<"${serve_json}")"
    if [[ "${funnel}" == "true" ]]; then
        echo "    WARNING: Funnel is ON for :${TS_PORT}. Turning it off." >&2
        run sudo tailscale funnel --https "${TS_PORT}" off
    else
        echo "    funnel: off (correct)"
    fi
fi

# ── Activate ─────────────────────────────────────────────────────

run sudo systemctl enable --quiet homebridge.service

if ! $RESTART; then
    echo "==> --no-restart given; Homebridge still has the old config."
    exit 0
fi

if $config_changed; then
    echo "==> Restarting Homebridge (config changed)..."
    run sudo systemctl restart homebridge.service
else
    echo "==> Config unchanged; not restarting."
    run sudo systemctl start homebridge.service
fi

# ── Verify ───────────────────────────────────────────────────────
#
# `systemctl is-active` is not a test of anything useful here: the
# supervisor stays up and keeps restarting a child that cannot bind,
# so the unit reports active while the UI answers nothing.

if $DRY_RUN; then
    echo "==> [dry-run] would verify the UI and the tailnet listener."
    exit 0
fi

echo "==> Verifying..."

if ! systemctl is-active --quiet homebridge.service; then
    echo "Error: homebridge.service is not active." >&2
    echo "       Check: journalctl -u homebridge -n 50" >&2
    exit 1
fi

# The UI takes a few seconds to come up after a restart, and longer
# on a cold start while the plugins load.
for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        "http://${UI_HOST}:${UI_PORT}/" || true)"
    [[ "${code}" == "200" ]] && break
    sleep 2
done

if [[ "${code}" != "200" ]]; then
    echo "Error: the Config UI did not answer on http://${UI_HOST}:${UI_PORT}/" >&2
    echo "       (last status: ${code:-none})" >&2
    echo "       Check: journalctl -u homebridge -n 50" >&2
    exit 1
fi
echo "    UI on ${UI_HOST}:${UI_PORT}: ok"

# The local check stops at "tailscaled is listening on the tailnet
# address for this port". It cannot go further, and the obvious
# stronger test is a trap: curl to https://<this node>:8581 from this
# node hangs until it times out -- tailscaled accepts it and
# terminates TLS, and the proxied response never comes back -- so that
# failure says nothing about the tailnet at all. The first version
# of this script treated it as an error and reported a working
# deployment as broken.
if ! $SKIP_SERVE; then
    ts_ip="$(tailscale ip -4)"
    if ! ss -tln | grep -q "${ts_ip}:${TS_PORT}"; then
        echo "Error: nothing is listening on ${ts_ip}:${TS_PORT}." >&2
        echo "       tailscale serve accepted the config but did not bind." >&2
        echo "       Check: sudo tailscale serve status" >&2
        exit 1
    fi
    echo "    tailscaled listening on ${ts_ip}:${TS_PORT}: ok"
    echo "    end-to-end check, from another tailnet node:"
    echo "      curl -sI https://${host}:${TS_PORT}/"
fi

echo
echo "==> Done."
echo "    UI:      https://${host}:${TS_PORT}/  (tailnet only)"
echo "    Logs:    journalctl -u homebridge -f"
echo "    Capture: ${SCRIPT_DIR##*/}/sync-config.sh, then commit the diff."
