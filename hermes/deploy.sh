#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Deploy the version-controlled parts of the Hermes setup on snoc-beelink.
#
# Hermes owns its own install: ~/.hermes is created by the installer, and
# `hermes update` rewrites config.yaml and regenerates the systemd units.
# So this does not manage the installation, it re-asserts the handful of
# decisions that live in this repo on top of whatever the installer left:
# the model routing, the dashboard bind address, the credential sync, and
# the health scripts.
#
# Everything it does is idempotent. Run it after `hermes update`, after a
# Lemonade key rotation, and after editing models.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
WORKSPACE_SCRIPTS="${WORKSPACE_SCRIPTS:-$HERMES_HOME/workspace/scripts}"
UNITS=(hermes-gateway hermes-dashboard hermes-webui)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--skip-key] [--skip-cua] [--no-restart]

Re-assert this repo's Hermes configuration on the local machine:
model routing from models.yaml, the MCP servers from mcp.yaml, the
dashboard loopback drop-in, the credential sync, the computer-use
sandbox, and the health scripts.

Options:
  --dry-run     Show what would change without writing anything.
  --skip-key    Do not touch ~/.hermes/.env. Use when the dotfiles
                git-crypt is locked and the existing key still works.
  --skip-cua    Do not touch the computer-use container or its shim.
  --no-restart  Leave the units running the old config.
  -h, --help    Show this help message.
EOF
    exit 0
}

DRY_RUN=false
SKIP_KEY=false
SKIP_CUA=false
RESTART=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true;  shift ;;
        --skip-key)   SKIP_KEY=true; shift ;;
        --skip-cua)   SKIP_CUA=true; shift ;;
        --no-restart) RESTART=false; shift ;;
        -h|--help)    usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi
}

if [[ ! -d "${HERMES_HOME}" ]]; then
    echo "Error: ${HERMES_HOME} does not exist -- Hermes is not installed here." >&2
    echo "Install it first (see README.md), then re-run this script." >&2
    exit 1
fi

echo "==> Hermes version"
"${HERMES_HOME}/hermes-agent/venv/bin/python" -m hermes_cli.main --version 2>/dev/null \
    | sed 's/^/    /' || echo "    (could not read version)"

# Two kinds of file live under systemd/user/, and the distinction matters:
#
#   *.conf    drop-ins over a unit the Hermes installer generates. The
#             dashboard's is the example -- the installer regenerates that
#             unit with --host 0.0.0.0, which takes port 9119 on the tailnet
#             address tailscaled needs for TLS, and the drop-in survives the
#             regeneration. See the file itself for the detail.
#
#   *.service whole units nothing else owns. hermes-webui is the only one:
#             it used to be a hand-written system unit in /etc/systemd/system,
#             tracked nowhere, which is how it drifted from the copy left
#             behind in the project checkout.
echo "==> Installing systemd units and drop-ins..."
UNIT_CHANGED=false
while IFS= read -r -d '' src; do
    rel="${src#"${SCRIPT_DIR}"/systemd/user/}"
    dst="${UNIT_DIR}/${rel}"
    if cmp -s "$src" "$dst"; then
        echo "    ${rel} (unchanged)"
        continue
    fi
    echo "    ${rel}"
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
    UNIT_CHANGED=true
done < <(find "${SCRIPT_DIR}/systemd/user" -type f \( -name '*.conf' -o -name '*.service' \) -print0)

if $UNIT_CHANGED; then
    run systemctl --user daemon-reload
fi

# A unit copied in is not a unit that starts at boot. Idempotent, and quiet
# on the units that are already enabled.
for unit in "${UNITS[@]}"; do
    [[ -f "${SCRIPT_DIR}/systemd/user/${unit}.service" ]] || continue
    if [[ "$(systemctl --user is-enabled "${unit}" 2>/dev/null)" == "enabled" ]]; then
        echo "    ${unit} (already enabled)"
    else
        run systemctl --user enable "${unit}"
    fi
done

# hermes-webui's environment comes from ~/.config/environment.d/50-hermes.conf,
# which the `systemd` package in the dotfiles installs. Without it the WebUI
# starts fine and then refuses every git write, which reads as a WebUI bug
# rather than a missing file -- so say so here instead.
if [[ ! -e "${HOME}/.config/environment.d/50-hermes.conf" ]]; then
    echo "    WARNING: ~/.config/environment.d/50-hermes.conf is missing."
    echo "             hermes-webui will refuse workspace git writes."
    echo "             Fix: cd ~/.batesste-dotfiles && ./install.sh systemd"
fi

# ~/.hermes/.env is the third copy of the Lemonade key, after snoc-strix and
# ~/.secrets.env, and the second copy of the GitHub PAT after the dotfiles.
# Re-syncing on every deploy is what keeps them from drifting apart the way
# the Lemonade key did in September 2026 and the PAT did silently before that.
if $SKIP_KEY; then
    echo "==> Skipping credential sync (--skip-key)"
else
    echo "==> Syncing credentials from the dotfiles..."
    if $DRY_RUN; then
        "${SCRIPT_DIR}/sync-secrets.sh" --dry-run | sed 's/^/    /'
    else
        "${SCRIPT_DIR}/sync-secrets.sh" | sed 's/^/    /'
    fi
fi

echo "==> Applying model routing from models.yaml..."
if $DRY_RUN; then
    "${SCRIPT_DIR}/apply-model-config.py" --dry-run | sed 's/^/    /'
else
    "${SCRIPT_DIR}/apply-model-config.py" | sed 's/^/    /'
fi

# The config half of computer use rides along with apply-model-config.py
# above; this is the container, the host shim and HERMES_CUA_DRIVER_CMD.
# Skipped without docker rather than failed: this script is the one that
# brings Hermes up on a new box, and the desktop sandbox is optional there.
if $SKIP_CUA; then
    echo "==> Skipping computer-use sandbox (--skip-cua)"
elif ! command -v docker >/dev/null; then
    echo "==> Skipping computer-use sandbox (docker not installed)"
else
    echo "==> Deploying the computer-use sandbox..."
    if $DRY_RUN; then
        "${SCRIPT_DIR}/cua/deploy.sh" --dry-run | sed 's/^/    /'
    else
        "${SCRIPT_DIR}/cua/deploy.sh" | sed 's/^/    /'
    fi
fi

# The agent calls these by absolute path from cron jobs and from chat, so
# they have to exist under the workspace regardless of where this repo is
# checked out.
echo "==> Installing workspace health scripts..."
run mkdir -p "${WORKSPACE_SCRIPTS}"
for f in "${SCRIPT_DIR}"/scripts/*.sh; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if cmp -s "$f" "${WORKSPACE_SCRIPTS}/${name}"; then
        echo "    ${name} (unchanged)"
        continue
    fi
    echo "    ${name}"
    run install -m 0755 "$f" "${WORKSPACE_SCRIPTS}/${name}"
done

if $DRY_RUN; then
    echo "==> Dry run complete. Nothing was written."
    exit 0
fi

if $RESTART; then
    echo "==> Restarting units..."
    run systemctl --user restart "${UNITS[@]}"
    sleep 5
fi

echo "==> Verifying..."
STATUS=0
for unit in "${UNITS[@]}"; do
    state=$(systemctl --user is-active "${unit}" || true)
    echo "    ${unit}: ${state}"
    [[ "${state}" == "active" ]] || STATUS=1
done

# The health check is the real verification: a unit can be active while
# every model call it makes comes back 401.
if ! "${SCRIPT_DIR}/scripts/lemonade_health.sh" | sed 's/^/    /'; then
    STATUS=1
fi

if [[ ${STATUS} -ne 0 ]]; then
    echo "==> Deploy finished with failures. Check:"
    echo "    journalctl --user -u hermes-gateway -n 50"
    exit 1
fi

echo "==> Done. Verify a real turn with:"
echo "    hermes -z 'Reply with exactly: ROUTING OK'"
