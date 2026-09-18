#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Pull the live Homebridge config into this repo, with every secret
# replaced by a placeholder.
#
# Homebridge owns /var/lib/homebridge/config.json: the Config UI
# rewrites it in place every time a plugin's settings are saved, and
# the plugins themselves write back tokens and cached device lists. So
# this repo does not template that file -- deploy.sh asserts the
# handful of keys it cares about and leaves the rest alone, and this
# script captures the result so the shape of the deployment is
# reviewable in git.
#
# What lands in config.redacted.json is therefore documentation and a
# disaster-recovery reference, not something that can be installed. It
# is not a backup: the real backups are Homebridge's own, under
# /var/lib/homebridge/backups, and the credentials live in the Keeper
# vault. Restoring means recreating the structure here and re-entering
# each credential by hand.
#
# Run it after adding a plugin, adding a device, or changing anything
# in the Config UI, then commit the diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_CONFIG="${LIVE_CONFIG:-/var/lib/homebridge/config.json}"
REPO_CONFIG="${REPO_CONFIG:-${SCRIPT_DIR}/config.redacted.json}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--check] [--stdout]

Capture ${LIVE_CONFIG} into
${REPO_CONFIG} with all credentials
and identifying values redacted.

Options:
  --check     Exit non-zero if the repo copy is out of date. Prints
              the diff. Writes nothing. Intended for CI.
  --stdout    Write the redacted config to stdout instead of the file.
  -h, --help  Show this help message.
EOF
    exit 0
}

CHECK=false
STDOUT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK=true;  shift ;;
        --stdout)  STDOUT=true; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

command -v jq >/dev/null || { echo "Error: jq is required." >&2; exit 1; }

if [[ ! -r "${LIVE_CONFIG}" ]] && ! sudo test -r "${LIVE_CONFIG}"; then
    echo "Error: cannot read ${LIVE_CONFIG}." >&2
    exit 1
fi

# What counts as a secret here, and why each one.
#
#   password, code       Plugin account credentials. `code` is Govee's
#                        API key under a name that does not look like
#                        one, which is exactly why this list is by key
#                        name and not by eyeball.
#   pin                  The HomeKit setup code. Possession of it plus
#                        reachability of the bridge is the whole of
#                        HomeKit pairing security.
#   username (platform)  Account emails for Eufy, Govee and Emporia.
#   mac, serialNumber    Device identifiers -- Eufy station and camera
#                        serials, and the phone MACs the presence
#                        plugin pings. Not credentials, but a precise
#                        inventory of the house and who is in it.
#   latitude, longitude  Where the house is.
#
# The presence plugin's per-device `name` is redacted as well, and
# that one is worth spelling out because it is not a secret in any
# usual sense: the values are "<family member>'s iPhone", one row per
# person in the household. This repository is public. A list of who
# lives here, what each of them carries, and a sensor that says when
# each of them is home is not something to publish, whatever the MAC
# addresses next to it are doing.
#
# Deliberately NOT redacted: `bridge.username` and `_bridge.username`.
# Those are MAC-formatted HAP bridge identities, not logins. They are
# also load-bearing -- change one and every paired controller treats
# the bridge as a brand new accessory and drops its rooms, names and
# automations. Keeping them readable is the point of having this file.
readonly REDACT_JQ='
def scrub:
  walk(
    if type == "object" then
      reduce ("password", "code", "pin", "mac", "serialNumber",
              "token", "apiKey", "apiKeys") as $k (.;
        if has($k) and (.[$k] | type) == "string" and .[$k] != ""
        then .[$k] = "REDACTED"
        else . end)
    else . end
  )
  | walk(
      if type == "object" and has("latitude")
      then .latitude = 0 | .longitude = 0
      else . end
    );

scrub
# Platform-level `username` only. The walk above cannot do this: it
# would take `_bridge.username` with it.
| .platforms = [ .platforms[]
    | if has("username") and .username != "" then .username = "REDACTED" else . end
    | if .platform == "NetworkPresence"
      then .devices = [ (.devices // [])[] | .name = "REDACTED" ]
      else . end ]
'

redacted="$(sudo cat "${LIVE_CONFIG}" | jq -S "${REDACT_JQ}")"

# Cheap assertion that the redaction actually fired. A jq filter that
# silently matches nothing produces a perfectly valid file full of
# credentials, and the only thing standing between that and a public
# commit is this check.
if grep -qi '"password"[[:space:]]*:[[:space:]]*"[^"]' <<<"${redacted}" \
   && ! grep -q '"password"[[:space:]]*:[[:space:]]*"REDACTED"' <<<"${redacted}"; then
    echo "Error: redaction did not fire -- a plaintext password survived." >&2
    echo "       Refusing to write. Fix REDACT_JQ in $(basename "$0")." >&2
    exit 1
fi

if $STDOUT; then
    printf '%s\n' "${redacted}"
    exit 0
fi

if $CHECK; then
    if diff -u "${REPO_CONFIG}" <(printf '%s\n' "${redacted}") ; then
        echo "==> ${REPO_CONFIG##*/} is up to date."
        exit 0
    fi
    echo "Error: ${REPO_CONFIG##*/} is stale. Re-run $(basename "$0")." >&2
    exit 1
fi

printf '%s\n' "${redacted}" > "${REPO_CONFIG}"
echo "==> Wrote ${REPO_CONFIG}"

if git -C "${SCRIPT_DIR}" diff --quiet -- "${REPO_CONFIG}" 2>/dev/null; then
    echo "    No change."
else
    echo "    Changed. Review with: git diff -- ${REPO_CONFIG#"${SCRIPT_DIR}"/}"
fi
