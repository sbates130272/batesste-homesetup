#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Name the Emporia plugs in Homebridge from the same labels.json that
# names them in Prometheus, with the room in front.
#
# HomeKit has no way for a bridge to say which room an accessory is in;
# that is set by hand in the Home app. What a name can do is start with
# the room: Home hides a leading room name on the tile once the
# accessory is in that room, so "Entryway Closet snoc-beelink" reads as
# "snoc-beelink" there and as the full name everywhere else. That only
# works if `location` in labels.json is spelled exactly as the room is
# in Home.
#
# labels.json is keyed by Emporia device name and the plugin's
# `devices` overrides by deviceGid, so the two are joined through the
# Homebridge accessory cache, which records both for every plug the
# plugin has discovered. A plug the plugin has never seen cannot be
# named here; run this again after it has been discovered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-/var/lib/homebridge/config.json}"
CACHE_DIR="${CACHE_DIR:-/var/lib/homebridge/accessories}"
LABELS="${LABELS:-${SCRIPT_DIR}/../prometheus/emvue-exporter/labels.json}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--no-restart]

Set the name of each Emporia plug in ${CONFIG}
to "<location> <name>" from labels.json. Existing \`hide\` settings and
overrides for devices not in labels.json are left alone.

Options:
  --dry-run     Show the names that would be set. Writes nothing.
  --no-restart  Write the config but do not restart Homebridge. The
                names do not take effect until it is restarted.
  -h, --help    Show this help message.
EOF
    exit 0
}

DRY_RUN=false
RESTART=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true;  shift ;;
        --no-restart) RESTART=false; shift ;;
        -h|--help)    usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

command -v jq >/dev/null || { echo "Error: jq is required." >&2; exit 1; }
[[ -r "${LABELS}" ]] || { echo "Error: cannot read ${LABELS}." >&2; exit 1; }

# One row per plug in labels.json: its gid if the cache knows it, and
# the name it should carry. The key normalization is the exporter's
# plug_key(), so both sides agree on what a label entry refers to.
wanted="$(sudo find "${CACHE_DIR}" -maxdepth 1 -name 'cachedAccessories.*' \
        -exec cat {} + \
    | jq -s --slurpfile labels "${LABELS}" '
        (add
         | map(select(.plugin == "homebridge-emporia")
               | .context.device
               | select(.locationProperties.deviceName != null)
               | { key: (.locationProperties.deviceName | gsub("-"; "_")),
                   value: .deviceGid })
         | from_entries) as $gid
        | $labels[0] | to_entries
        | map((.value | if type == "string" then {name: .} else . end) as $l
              | ($l.name // .key) as $name
              | ($l.location // "") as $room
              | { plug: .key,
                  deviceGid: $gid[.key | gsub("-"; "_")],
                  name: (if $room == ""
                            or ($name | ascii_downcase
                                | startswith($room | ascii_downcase))
                         then $name
                         else "\($room) \($name)" end) })')"

unknown="$(jq -r '.[] | select(.deviceGid == null) | .plug' <<<"${wanted}")"
if [[ -n "${unknown}" ]]; then
    echo "WARNING: not yet discovered by the plugin, so not named:" >&2
    printf '           %s\n' ${unknown} >&2
fi

MERGE_JQ='
    ($wanted | map(select(.deviceGid != null))) as $w
    | .platforms = [ .platforms[]
        | if .platform == "EmporiaEnergy" then
            .devices = (
              [ (.devices // [])[]
                | . as $d
                | ($w | map(select(.deviceGid == $d.deviceGid)) | first) as $m
                | if $m then .name = $m.name else . end ]
              + [ $w[]
                  | . as $m
                  | select(($cfg | map(.deviceGid) | index($m.deviceGid)) | not)
                  | { deviceGid, name } ]
              | sort_by(.deviceGid))
          else . end ]'

current="$(sudo jq -c '[.platforms[] | select(.platform == "EmporiaEnergy")
                        | (.devices // [])[] | {deviceGid, name}]' "${CONFIG}")"

echo "==> Emporia plug names:"
jq -r --argjson cur "${current}" '
    .[] | select(.deviceGid != null)
    | . as $m
    | ($cur | map(select(.deviceGid == $m.deviceGid)) | first | .name) as $old
    | if $old == .name then "    \(.deviceGid)  \(.name)"
      else "    \(.deviceGid)  \($old // "(none)") -> \(.name)" end' \
    <<<"${wanted}"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
sudo jq --argjson wanted "${wanted}" --argjson cfg "${current}" \
    "${MERGE_JQ}" "${CONFIG}" > "${tmp}"
jq empty "${tmp}" || {
    echo "Error: rewritten config is not valid JSON. Left ${CONFIG} alone." >&2
    exit 1
}

if sudo jq -S . "${CONFIG}" | cmp -s - <(jq -S . "${tmp}"); then
    echo "==> Already up to date."
    exit 0
fi

if $DRY_RUN; then
    echo "==> [dry-run] would rewrite the Emporia devices in ${CONFIG}"
    exit 0
fi

backup="${CONFIG}.$(date +%Y%m%d-%H%M%S).bak"
sudo cp -p "${CONFIG}" "${backup}"
echo "    backup: ${backup}"
sudo install -m "$(sudo stat -c '%a' "${CONFIG}")" -o homebridge -g homebridge \
    "${tmp}" "${CONFIG}"

if $RESTART; then
    echo "==> Restarting Homebridge..."
    sudo systemctl restart homebridge.service
else
    echo "==> --no-restart given; Homebridge still has the old names."
fi

echo "==> Done. Capture the result with sync-config.sh."
