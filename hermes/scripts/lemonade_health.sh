#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Lemonade server health check -- reachability, an inference probe, and a
# GPU/resource check over SSH to snoc-strix.
#
# The list of models it expects is read out of ~/.hermes/config.yaml rather
# than hardcoded. The previous version of this script carried its own list,
# which went stale the moment the routing changed and then cheerfully
# reported FAIL for a model nothing used any more. Whatever Hermes is
# configured to call is exactly what needs to be resident.
#
# Exit 0 = all checks pass, exit 1 = at least one failure.

set -euo pipefail

LEMONADE_URL="${LEMONADE_URL:-https://snoc-strix.fold-leaffish.ts.net:13305}/v1"
SSH_HOST="${SSH_HOST:-snoc-strix}"
ENV_FILE="${HERMES_ENV:-$HOME/.hermes/.env}"
CONFIG_FILE="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"
CURL_TIMEOUT=10
# A cold model load on a busy GPU runs past 30s, at which point curl gives
# up and reports HTTP 000. Keep this above worst-case cold start.
INFERENCE_MAX_TIME="${INFERENCE_MAX_TIME:-180}"
SSH_TIMEOUT=10

# The tailnet must not go through the corporate proxy; see
# sync-secrets.sh. Appended rather than defaulted, because the
# inherited NO_PROXY is usually already set to something short like
# "localhost,127.0.0.1" -- a `${NO_PROXY:-...}` default would keep that
# and every request would come back HTTP 000 through tinyproxy.
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}.ts.net,localhost,127.0.0.1"
export no_proxy="$NO_PROXY"

PASS=0
FAIL=0
RESULTS=()

record() {
  local tier="$1" status="$2" detail="$3"
  if [ "$status" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  RESULTS+=("[$status] $tier: $detail")
}

for dep in curl jq python3; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done

# --- What this deployment actually needs ------------------------------------

EXPECTED_MODELS=()
PROBE_MODEL=""

load_expected_models() {
  if [ ! -r "$CONFIG_FILE" ]; then
    record "Setup" "FAIL" "$CONFIG_FILE not readable"
    return 1
  fi
  # Every distinct model named anywhere in the routing table: the default,
  # the fallbacks, delegation, and each auxiliary task.
  local models
  models=$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
seen, out = set(), []
def add(m):
    if m and m not in seen:
        seen.add(m); out.append(m)
add((cfg.get("model") or {}).get("default"))
for fb in cfg.get("fallback_providers") or []:
    add((fb or {}).get("model"))
add((cfg.get("delegation") or {}).get("model"))
for task in (cfg.get("auxiliary") or {}).values():
    if isinstance(task, dict):
        add(task.get("model"))
stt = ((cfg.get("stt") or {}).get("openai") or {})
if (cfg.get("stt") or {}).get("enabled") and (cfg.get("stt") or {}).get("provider") == "openai":
    add(stt.get("model"))
print("\n".join(out))
PY
)
  if [ -z "$models" ]; then
    record "Setup" "FAIL" "no models found in $CONFIG_FILE"
    return 1
  fi
  mapfile -t EXPECTED_MODELS <<<"$models"
  PROBE_MODEL="${EXPECTED_MODELS[0]}"
}

load_api_key() {
  [ -r "$ENV_FILE" ] || { record "Setup" "FAIL" "$ENV_FILE not found"; return 1; }
  LEMONADE_API_KEY=$(grep -m1 '^LEMONADE_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"'"'"'')
  [ -n "${LEMONADE_API_KEY:-}" ] || {
    record "Setup" "FAIL" "LEMONADE_API_KEY not set in $ENV_FILE"
    return 1
  }
  export LEMONADE_API_KEY
}

# --- Tier 1: reachability ---------------------------------------------------

check_reachability() {
  local resp http_code body missing=()

  resp=$(curl -sk -w "\n%{http_code}" \
    --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" \
    -H "Authorization: Bearer $LEMONADE_API_KEY" \
    "$LEMONADE_URL/models" 2>&1) || true
  http_code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')

  if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
    # Naming the fix here because this is the failure that took the agent
    # down for twelve days: the key rotated and ~/.hermes/.env kept a copy.
    record "Reachability" "FAIL" \
      "/v1/models returned HTTP $http_code -- run hermes/sync-secrets.sh"
    return
  fi
  if [ "$http_code" != "200" ]; then
    record "Reachability" "FAIL" "/v1/models returned HTTP $http_code (expected 200)"
    return
  fi

  for model in "${EXPECTED_MODELS[@]}"; do
    echo "$body" | jq -e --arg m "$model" \
      '[.data[]?.id] | index($m) != null' >/dev/null 2>&1 || missing+=("$model")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    record "Reachability" "FAIL" "HTTP 200 but not served: ${missing[*]}"
  else
    record "Reachability" "PASS" \
      "HTTP 200, all ${#EXPECTED_MODELS[@]} configured model(s) served"
  fi
}

# --- Tier 2: inference probe ------------------------------------------------

# Best-effort assistant text from an OpenAI-style response: models here
# variously answer with a string, a content-part array, or reasoning fields.
extract_content() {
  jq -r '
    def as_text($x):
      if   $x == null            then ""
      elif ($x | type) == "string" then $x
      elif ($x | type) == "array"  then
        $x | map(if type == "object" then ((.text // "") | tostring) else "" end) | join("")
      else "" end;
    (.choices // [])[0] as $c
    | if $c == null then "" else
        as_text($c.message.content) + as_text($c.message.reasoning_content) + ($c.text // "")
      end' 2>/dev/null | tr -d '\r'
}

probe_model() {
  local model="$1" body_file http_code content
  body_file=$(mktemp)
  http_code=$(curl -sk -o "$body_file" -w "%{http_code}" \
    --connect-timeout "$CURL_TIMEOUT" --max-time "$INFERENCE_MAX_TIME" \
    -H "Authorization: Bearer $LEMONADE_API_KEY" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg m "$model" \
      '{model:$m, messages:[{role:"user",content:"Say OK"}], max_tokens:8, temperature:0}')" \
    "$LEMONADE_URL/chat/completions" | tr -d '\r\n') || true
  content=$(extract_content <"$body_file")
  rm -f "$body_file"
  PROBE_CODE="$http_code"
  PROBE_CHARS="${#content}"
  [ "$http_code" = "200" ] && [ -n "$content" ]
}

check_inference() {
  # Only the default model is probed. Probing all three would force
  # Lemonade to cycle every slot on every health check, which is a load
  # test dressed up as a health check.
  if probe_model "$PROBE_MODEL"; then
    record "Inference" "PASS" "$PROBE_MODEL responded ($PROBE_CHARS chars)"
    return
  fi
  local first_code="$PROBE_CODE" first_chars="$PROBE_CHARS"

  local alt="${EXPECTED_MODELS[1]:-}"
  if [ -n "$alt" ] && probe_model "$alt"; then
    record "Inference" "FAIL" \
      "$PROBE_MODEL failed (HTTP $first_code, $first_chars chars) but fallback $alt is healthy"
    return
  fi
  record "Inference" "FAIL" \
    "chat/completions: $PROBE_MODEL HTTP ${first_code:-?}, ${alt:-no fallback} HTTP ${PROBE_CODE:-?}"
}

# --- Tier 3: the server host ------------------------------------------------

check_resources() {
  local ssh_cmd="ssh -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes $SSH_HOST"

  local vram total used pct
  vram=$($ssh_cmd "rocm-smi --showmeminfo vram 2>/dev/null" 2>&1) || true
  if echo "$vram" | grep -q "VRAM Total Memory"; then
    total=$(echo "$vram" | grep "VRAM Total Memory" | awk '{print $NF}')
    used=$(echo "$vram" | grep "VRAM Total Used" | awk '{print $NF}')
    if [ -n "$total" ] && [ -n "$used" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      pct=$(( used * 100 / total ))
      # Not a failure on its own: three resident models are *meant* to fill
      # VRAM. Only a near-full card, which evicts on the next load, is.
      if [ "$pct" -gt 95 ]; then
        record "GPU-VRAM" "FAIL" "${pct}% used -- next model load will evict"
      else
        record "GPU-VRAM" "PASS" "${pct}% used"
      fi
    else
      record "GPU-VRAM" "FAIL" "could not parse rocm-smi VRAM values"
    fi
  else
    record "GPU-VRAM" "FAIL" "rocm-smi unreachable or no output"
  fi

  local lemond_status
  lemond_status=$($ssh_cmd "systemctl is-active lemond.service 2>/dev/null" 2>&1) || true
  if [ "$lemond_status" = "active" ]; then
    record "Service-lemond" "PASS" "active"
  else
    record "Service-lemond" "FAIL" "${lemond_status:-unreachable}"
  fi

  local llama_count
  llama_count=$($ssh_cmd "pgrep -c llama-server 2>/dev/null" 2>&1) || true
  if [ -n "$llama_count" ] && [ "$llama_count" -ge 1 ] 2>/dev/null; then
    record "LlamaProcesses" "PASS" "$llama_count llama-server process(es)"
  else
    record "LlamaProcesses" "FAIL" "no llama-server processes"
  fi

  local disk_pct
  disk_pct=$($ssh_cmd "df / --output=pcent | tail -1 | tr -d ' %'" 2>&1) || true
  if [ -n "$disk_pct" ] && [ "$disk_pct" -ge 0 ] 2>/dev/null; then
    if [ "$disk_pct" -gt 85 ]; then
      record "Disk" "FAIL" "${disk_pct}% used (threshold 85%)"
    else
      record "Disk" "PASS" "${disk_pct}% used"
    fi
  else
    record "Disk" "FAIL" "could not read disk usage"
  fi
}

# --- Main -------------------------------------------------------------------

if load_expected_models && load_api_key; then
  check_reachability
  check_inference
fi
check_resources

echo "=== Lemonade Health Check ==="
[ ${#EXPECTED_MODELS[@]} -gt 0 ] && echo "  models from $CONFIG_FILE: ${EXPECTED_MODELS[*]}"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "=== Summary: $PASS passed, $FAIL failed ==="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
