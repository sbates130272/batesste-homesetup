#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="${SCRIPT_DIR}/gh-actions-exporter.py"
BIN_DST="/usr/local/bin/gh-actions-exporter.py"
UNIT="gh-actions-exporter.service"
UNIT_SRC="${SCRIPT_DIR}/${UNIT}"
UNIT_DST="/etc/systemd/system/${UNIT}"
TOKEN_DIR="/etc/gh-actions-exporter"
TOKEN_FILE="${TOKEN_DIR}/token"
PORT=9612

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Install the GitHub Actions exporter and its unit, then restart it. Run
this on snoc-beelink, where Prometheus scrapes it over loopback.

Unlike emvue-exporter, this one lives in this repository rather than
its own: which repositories are worth watching is a fact about this
setup, not a general-purpose exporter.

Needs a GitHub API token at ${TOKEN_FILE}; see below.

Options:
  --dry-run   Show what would be done without changing anything.
  -h, --help  Show this help message.
EOF
    exit 0
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# Same shape as the lemonade-api-key check in ../deploy.sh: the token
# is deliberately not in this repo, and the failure it causes without
# this check is an exporter that starts, logs once and exits 1 on a
# 30-second restart loop. Checked via sudo because the directory is
# root-only, so an unprivileged invoking user cannot even traverse it.
if ! sudo test -r "${TOKEN_FILE}"; then
    cat >&2 <<EOF
Error: ${TOKEN_FILE} is missing or unreadable.

The exporter reads the GitHub Actions API with a personal access
token. A classic PAT needs \`repo\`; a fine-grained one needs read
access to Actions and Metadata on the repositories to watch. Create
the file with:

  sudo install -d -m 0700 -o root -g root ${TOKEN_DIR}
  printf %s "\$GH_TOKEN_SBATES130272" \\
      | sudo tee ${TOKEN_FILE} >/dev/null
  sudo chmod 0400 ${TOKEN_FILE}

Use \`printf\` rather than \`echo\` -- a trailing newline becomes part
of the token and every API call comes back 401.
EOF
    exit 1
fi

# A syntax error here is an exporter that restart-loops rather than one
# that fails to install, so it is worth the second it costs.
echo "==> Checking the exporter compiles..."
python3 -m py_compile "${BIN_SRC}"

# No network, so this is safe on a CI runner, and it is the same render
# path the real /metrics endpoint uses.
echo "==> Checking it renders valid metrics..."
if command -v promtool &>/dev/null; then
    python3 "${BIN_SRC}" --selftest | promtool check metrics
    echo "    promtool is happy."
else
    python3 "${BIN_SRC}" --selftest >/dev/null
    echo "    promtool not found; rendered without checking."
fi

echo "==> Installing ${BIN_DST}..."
run sudo install -m 0755 -o root -g root "${BIN_SRC}" "${BIN_DST}"

echo "==> Installing ${UNIT_DST}..."
run sudo install -m 0644 -o root -g root "${UNIT_SRC}" "${UNIT_DST}"

echo "==> Enabling and restarting ${UNIT}..."
run sudo systemctl daemon-reload
run sudo systemctl enable "${UNIT}"
run sudo systemctl restart "${UNIT}"

if $DRY_RUN; then
    echo "==> Dry run complete."
    exit 0
fi

echo "==> Result:"
# The first refresh walks every tracked repository before the snapshot
# has anything in it, which took 26s the first time it was measured.
# The listener is up well before that, so curl succeeds on an empty
# body long before the metrics arrive -- wait for a real series.
for _ in $(seq 1 45); do
    if curl -sf "http://localhost:${PORT}/metrics" |
            grep -q '^github_actions_tracked_repos [1-9]'; then
        curl -s "http://localhost:${PORT}/metrics" |
            grep -E '^github_actions_(tracked_repos|rate_limit_remaining)' |
            sed 's/^/    /'
        echo "    failing workflows:"
        curl -s "http://localhost:${PORT}/metrics" |
            awk '/^github_actions_workflow_last_run_success/ && / 0$/' |
            sed 's/^/      /'
        exit 0
    fi
    sleep 2
done

echo "    ERROR: no repositories reported on port ${PORT} after 90s" >&2
echo "    Check: journalctl -u ${UNIT} -n 50" >&2
exit 1
