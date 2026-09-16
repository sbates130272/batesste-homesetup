#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Whole-box health check for snoc-beelink, run by the Hermes heartbeat cron
# and reachable as a tool from a chat session ("check the services").
#
# Prints HEARTBEAT_OK on the last line when everything passes; the heartbeat
# job greps for that, so do not reword it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMONADE_HEALTH="${LEMONADE_HEALTH:-$SCRIPT_DIR/lemonade_health.sh}"
FAILURES=0

fail() { echo "[FAIL] $*"; FAILURES=$((FAILURES + 1)); }

check_container() {
  local name="$1"
  if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${name} .*Up"; then
    echo "[PASS] container ${name} is Up"
  else
    fail "container ${name} not running"
  fi
}

check_systemd() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    echo "[PASS] systemd $svc: active"
  else
    fail "systemd $svc: $(systemctl is-active "$svc" 2>&1 || true)"
  fi
}

# Hermes runs as user units under a lingering session, not system units, so
# these need --user and will not show up in a `systemctl status` sweep.
check_user_systemd() {
  local svc="$1"
  if systemctl --user is-active --quiet "$svc"; then
    local restarts
    restarts=$(systemctl --user show -p NRestarts --value "$svc" 2>/dev/null || echo 0)
    # A duplicate unit once restart-looped 140,989 times while still
    # reporting "active" on every sample. Active is not the same as healthy.
    if [ "${restarts:-0}" -gt 20 ]; then
      fail "user unit $svc: active but has restarted ${restarts} times"
    else
      echo "[PASS] user unit $svc: active (${restarts} restarts)"
    fi
  else
    fail "user unit $svc: $(systemctl --user is-active "$svc" 2>&1 || true)"
  fi
}

check_disk() {
  local pct
  pct=$(df --output=pcent / | tail -1 | tr -d ' %')
  echo "[INFO] root filesystem: ${pct}% used"
  [ "$pct" -gt 85 ] && fail "root filesystem usage above 85%"
  return 0
}

check_lemonade() {
  if [ -x "$LEMONADE_HEALTH" ]; then
    echo "[INFO] running Lemonade health check"
    if bash "$LEMONADE_HEALTH"; then
      echo "[PASS] Lemonade health checks passed"
    else
      fail "Lemonade health checks failed"
    fi
  else
    echo "[WARN] Lemonade health script not found: $LEMONADE_HEALTH"
  fi
}

check_container "batesste-firefly-iii-core"
check_container "batesste-firefly-iii-db"
check_container "batesste-firefly-iii-importer"

check_systemd "grafana-server"
check_systemd "prometheus"
check_systemd "homebridge"

check_user_systemd "hermes-gateway"
check_user_systemd "hermes-dashboard"

check_disk
check_lemonade

if [ "$FAILURES" -gt 0 ]; then
  echo "Service health: FAIL ($FAILURES issues)"
  exit 1
fi
echo "Service health: OK"
echo "HEARTBEAT_OK"
