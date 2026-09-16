#!/bin/bash
# Project the credentials Hermes needs from the stow-managed dotfiles into
# ~/.hermes/.env.
#
# ~/.secrets.env is the source of truth for these across the fleet. Hermes
# cannot read it directly: custom_providers[].key_env and the MCP config's
# ${VAR} references only name environment variables, and pointing the units
# at ~/.secrets.env wholesale would hand ANTHROPIC_API_KEY, the AWS pair,
# the other GitHub tokens and HF_TOKEN to an agent that has a local shell
# tool. So this copies exactly the variables Hermes needs and nothing else:
#
#   LEMONADE_API_KEY          -> inference, plus the two STT vars
#   GH_TOKEN_SBATES130272     -> GITHUB_PERSONAL_ACCESS_TOKEN, for the
#                                github MCP server
#
# Only the personal token is projected. GH_TOKEN_STEBATES_AMDENG is AMD's
# and stays out of the agent's reach; sbates130272 is the account Hermes
# should ever act as.
#
# The copy is what rotted in September 2026: the key was rotated on
# snoc-strix and in the dotfiles, ~/.hermes/.env kept the old value, and
# every model call 401'd for twelve days. Run this from deploy.sh after
# any rotation, and let lemonade_health.sh catch it if someone forgets.
#
# The key is never printed. Only a sha256 prefix is, which is enough to
# compare both ends without disclosing anything.

set -euo pipefail

SECRETS="${SECRETS_ENV:-$HOME/.secrets.env}"
HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"
LEMONADE_URL="${LEMONADE_URL:-https://snoc-strix.fold-leaffish.ts.net:13305}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

die() { echo "error: $*" >&2; exit 1; }

[ -r "$SECRETS" ] || die "$SECRETS not readable -- is the dotfiles git-crypt unlocked?"
[ -w "$HERMES_ENV" ] || die "$HERMES_ENV not writable -- is Hermes installed?"

# grep for the assignment rather than sourcing: ~/.secrets.env holds
# credentials this script has no business having in its environment.
read_var() {
  local name="$1" line
  line=$(grep -m1 "^${name}=" "$SECRETS" || true)
  [ -n "$line" ] || die "$name not found in $SECRETS"
  printf '%s' "${line#*=}" | tr -d '"'"'"'\r\n'
}

fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-8; }

KEY=$(read_var LEMONADE_API_KEY)
[ ${#KEY} -ge 16 ] || die "LEMONADE_API_KEY in $SECRETS looks too short (${#KEY} chars)"

echo "dotfiles LEMONADE_API_KEY: ${#KEY} chars, sha256:$(fingerprint "$KEY")"

# Confirm the key the dotfiles hold is the key the server accepts before
# writing it anywhere. A sync that faithfully copies a dead key is worse
# than no sync -- it looks like it worked.
if code=$(curl -sS -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $KEY" "$LEMONADE_URL/api/v1/health" 2>/dev/null); then
  case "$code" in
    200) echo "lemonade $LEMONADE_URL: accepted (HTTP 200)" ;;
    401|403) die "lemonade rejected this key (HTTP $code) -- rotate the dotfiles copy first" ;;
    *) echo "warning: lemonade returned HTTP $code -- syncing anyway" >&2 ;;
  esac
else
  echo "warning: could not reach $LEMONADE_URL -- syncing without verification" >&2
fi

# The github MCP server reads this via a ${GITHUB_PERSONAL_ACCESS_TOKEN}
# reference in mcp.yaml. The copy that used to sit in ~/.hermes/.env was a
# hand-placed classic PAT that had since been revoked, so the server
# authenticated against nothing -- the same drift that killed the Lemonade
# key, and invisible for the same reason. Projecting it from the dotfiles
# is what stops it happening a third time.
GH_TOKEN=$(read_var GH_TOKEN_SBATES130272)
[ ${#GH_TOKEN} -ge 16 ] || die "GH_TOKEN_SBATES130272 looks too short (${#GH_TOKEN} chars)"

echo "dotfiles GH_TOKEN_SBATES130272: ${#GH_TOKEN} chars, sha256:$(fingerprint "$GH_TOKEN")"

if code=$(curl -sS -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user 2>/dev/null); then
  case "$code" in
    200) echo "github api.github.com/user: accepted (HTTP 200)" ;;
    401|403) die "github rejected this token (HTTP $code) -- rotate the dotfiles copy first" ;;
    *) echo "warning: github returned HTTP $code -- syncing anyway" >&2 ;;
  esac
else
  echo "warning: could not reach api.github.com -- syncing without verification" >&2
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "--dry-run: $HERMES_ENV not modified"
  exit 0
fi

# Speech-to-text is routed to Lemonade's Whisper (see models.yaml), and
# Hermes reads those two from the environment rather than from config.
set_var() {
  local name="$1" value="$2" tmp
  tmp=$(mktemp); chmod 600 "$tmp"
  if grep -q "^${name}=" "$HERMES_ENV"; then
    # Written via awk, not sed, so characters special to sed's
    # replacement text cannot corrupt a key.
    awk -v n="$name" -v v="$value" \
      'index($0, n "=") == 1 { print n "=" v; next } { print }' "$HERMES_ENV" > "$tmp"
  else
    cat "$HERMES_ENV" > "$tmp"
    printf '%s=%s\n' "$name" "$value" >> "$tmp"
  fi
  cat "$tmp" > "$HERMES_ENV"
  rm -f "$tmp"
}

# The corporate ZScaler proxy is exported into interactive shells and
# happily intercepts tailnet traffic, answering with a tinyproxy "500
# Unable to connect". The systemd units start clean, but `hermes` run
# from a terminal inherits it, so pin the exemption where both can see it.
NOPROXY='snoc-strix.fold-leaffish.ts.net,.ts.net,localhost,127.0.0.1'

cp -p "$HERMES_ENV" "$HERMES_ENV.bak-$(date +%Y%m%d-%H%M%S)"
set_var LEMONADE_API_KEY "$KEY"
set_var VOICE_TOOLS_OPENAI_KEY "$KEY"
set_var STT_OPENAI_BASE_URL "$LEMONADE_URL/api/v1"
set_var NO_PROXY "$NOPROXY"
set_var no_proxy "$NOPROXY"
set_var GITHUB_PERSONAL_ACCESS_TOKEN "$GH_TOKEN"
chmod 600 "$HERMES_ENV"

echo "synced LEMONADE_API_KEY, VOICE_TOOLS_OPENAI_KEY, STT_OPENAI_BASE_URL, NO_PROXY," \
     "GITHUB_PERSONAL_ACCESS_TOKEN -> $HERMES_ENV"
echo "restart to pick it up: systemctl --user restart hermes-gateway hermes-dashboard"
