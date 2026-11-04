#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Publish macOS WiFi and link state as node-exporter textfile metrics,
# for the WiFi (dBm) and Link columns on the LAN Overview Node Fleet
# table. The only host this runs on today is snoc-shannon.
#
# node-exporter's --collector.wifi cannot do this: it is built around
# nl80211 and /proc/net/wireless and is not compiled into the darwin
# build at all. Adding the flag there is not a no-op that yields zero
# series, it is an unknown-flag error that stops the binary. The whole
# darwin collector set is 107 metric families against roughly 500 on
# Linux, and neither node_wifi_* nor node_network_info is in it -- so
# both the signal reading *and* the wired/wireless distinction have to
# come from somewhere else.
#
# This is the same shape as wsl-wifi.sh, and for the same reason: the
# number exists on the host, node-exporter just cannot see it.
#
# Written for bash 3.2, which is what /bin/bash is on macOS. No
# associative arrays, no ${var,,}.

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/usr/local/var/node_exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/mac-wifi.prom"

is_darwin() {
    [[ "$(uname -s)" == "Darwin" ]]
}

emit() {
    printf '# HELP %s %s\n# TYPE %s gauge\n' "$1" "$3" "$1" >&3
    printf '%s %s\n' "$1" "$2" >&3
}

# Label values travel into the TSDB verbatim, and a hardware port name
# is free text from the system ("Thunderbolt Ethernet Slot 1"). Escape
# the two characters that would otherwise break the exposition format.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

finish() {
    exec 3>&-
    chmod 0644 "$TMP"
    mv "$TMP" "$OUT"
    trap - EXIT
    exit 0
}

TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
exec 3>"$TMP"

# Emit the "not applicable" case explicitly rather than writing
# nothing, so that a host where this does not apply and a host whose
# collector never ran are distinguishable in the TSDB. Same contract as
# wsl_wifi_present and rocm_version_present.
if ! is_darwin || ! command -v networksetup >/dev/null 2>&1; then
    emit mac_wifi_present 0 'macOS network state is readable on this host.'
    finish
fi
emit mac_wifi_present 1 'macOS network state is readable on this host.'

# networksetup -listallhardwareports prints repeating three-line
# stanzas:
#
#   Hardware Port: Wi-Fi
#   Device: en0
#   Ethernet Address: ...
#
# This is the authoritative port-name-to-device map, it is unprivileged
# and it returns in milliseconds. Matching on interface name instead
# would be guesswork -- on a Mac en0 is the WiFi radio on a laptop and
# the cable on a Mac mini, and Thunderbolt docks hand out en5 and up in
# whatever order they enumerate.
PORTS="$(networksetup -listallhardwareports 2>/dev/null || true)"

WIFI_DEV=""
WIRED_UP=0
WIFI_UP=0

# Per-interface samples are accumulated rather than written as they are
# found. A TYPE line that arrives after a sample of the same metric is
# a parse error, not a cosmetic wart, and node-exporter reports it as
# node_textfile_scrape_error 1 and discards the whole file.
LINK_INFO=""

PORT=""
while IFS= read -r line; do
    case "$line" in
        "Hardware Port: "*) PORT="${line#Hardware Port: }" ;;
        "Device: "*)
            DEV="${line#Device: }"
            [[ -n "$PORT" && -n "$DEV" ]] || continue

            # Kind is decided by the port name, not the device name.
            case "$PORT" in
                Wi-Fi|AirPort) KIND=wifi ;;
                *Ethernet*|*LAN*) KIND=wired ;;
                *) KIND=other ;;
            esac

            # "status: active" is ifconfig's link-layer answer: carrier
            # for a cable, association for a radio. It is not the same
            # as the interface being UP, which a disconnected Mac
            # leaves set, and it needs no privileges.
            if ifconfig "$DEV" 2>/dev/null | grep -q '[[:space:]]status: active'; then
                UP=1
            else
                UP=0
            fi

            if [[ "$KIND" == wifi ]]; then
                WIFI_DEV="$DEV"
                [[ "$UP" == 1 ]] && WIFI_UP=1
            elif [[ "$KIND" == wired ]]; then
                [[ "$UP" == 1 ]] && WIRED_UP=1
            fi

            LINK_INFO="${LINK_INFO}$(printf 'mac_link_info{device="%s",port="%s",kind="%s"} %s' \
                "$(esc "$DEV")" "$(esc "$PORT")" "$KIND" "$UP")
"
            PORT=""
            ;;
    esac
done <<< "$PORTS"

# Both kinds are always emitted, including as 0. The Link column sums a
# wired term worth 2 and a wireless term worth 1, and a PromQL `+`
# drops any series missing from either side -- so a Mac with no cable
# that published only the wifi term would vanish from the join and lose
# every other column in the row with it.
{
    echo '# HELP mac_link_up A link of this kind is carrying a signal (ifconfig status: active).'
    echo '# TYPE mac_link_up gauge'
    printf 'mac_link_up{kind="wired"} %s\n' "$WIRED_UP"
    printf 'mac_link_up{kind="wifi"} %s\n' "$WIFI_UP"
    if [[ -n "$LINK_INFO" ]]; then
        echo '# HELP mac_link_info Per-interface link state, labelled with the hardware port it belongs to.'
        echo '# TYPE mac_link_info gauge'
        printf '%s' "$LINK_INFO"
    fi
} >&3

if [[ -z "$WIFI_DEV" ]]; then
    emit mac_wifi_connected 0 'The WiFi radio is associated with an access point.'
    finish
fi
emit mac_wifi_connected "$WIFI_UP" 'The WiFi radio is associated with an access point.'
[[ "$WIFI_UP" == 1 ]] || finish

# The RSSI has to come from system_profiler, and that is a deliberate
# choice between three bad options:
#
#   * airport -I was the obvious one and is gone. Apple deprecated it
#     in Sonoma 14.4 and removed the private framework binary; on
#     Sequoia it prints a deprecation notice and nothing else.
#   * wdutil info reports RSSI accurately and requires root *and* has
#     no stable output contract.
#   * system_profiler SPAirPortDataType is unprivileged, documented
#     output, and takes 1-3 seconds. Hence the 5-minute interval.
#
# Signal is reported as "Signal / Noise: -56 dBm / -92 dBm" under
# "Current Network Information". Since Sequoia, parts of that block can
# be withheld unless the caller holds Location Services authorisation
# -- which is why mac_wifi_signal_present exists. A withheld reading
# reports 0 rather than a guessed number; there is no quality
# percentage to derive dBm from the way wsl-wifi.sh can, and inventing
# one would be worse than an empty column.
PROFILE="$(system_profiler SPAirPortDataType 2>/dev/null || true)"

SIGNAL="$(sed -nE 's/^[[:space:]]*Signal \/ Noise:[[:space:]]*(-?[0-9]+) dBm.*/\1/p' <<< "$PROFILE" | head -1)"
NOISE="$(sed -nE 's/^[[:space:]]*Signal \/ Noise:[[:space:]]*-?[0-9]+ dBm \/ (-?[0-9]+) dBm.*/\1/p' <<< "$PROFILE" | head -1)"
RATE="$(sed -nE 's/^[[:space:]]*Transmit Rate:[[:space:]]*([0-9]+).*/\1/p' <<< "$PROFILE" | head -1)"
PHY="$(sed -nE 's/^[[:space:]]*PHY Mode:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' <<< "$PROFILE" | head -1)"
CHANNEL="$(sed -nE 's/^[[:space:]]*Channel:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' <<< "$PROFILE" | head -1)"

if [[ -n "$SIGNAL" ]]; then
    emit mac_wifi_signal_present 1 'A measured RSSI was available from this host.'
    emit mac_wifi_signal_dbm "$SIGNAL" 'WiFi signal strength of the Mac radio, in dBm.'
    [[ -n "$NOISE" ]] && emit mac_wifi_noise_dbm "$NOISE" 'WiFi noise floor at the Mac radio, in dBm.'
else
    emit mac_wifi_signal_present 0 'A measured RSSI was available from this host.'
fi

[[ -n "$RATE" ]] && emit mac_wifi_transmit_rate_mbps "$RATE" 'Negotiated WiFi transmit rate, in Mbps.'

# PHY mode and channel travel as labels on a separate info gauge so
# they can change without churning the numeric series above.
#
# SSID and BSSID are deliberately not exported, for the same reason
# wsl-wifi.sh omits them: they feed no panel, and a network name has no
# business being written into a homelab TSDB with 90-day retention.
{
    echo '# HELP mac_wifi_link_info PHY mode and channel of the WiFi association (gauge 1).'
    echo '# TYPE mac_wifi_link_info gauge'
    printf 'mac_wifi_link_info{device="%s",phy_mode="%s",channel="%s"} 1\n' \
        "$(esc "$WIFI_DEV")" "$(esc "$PHY")" "$(esc "$CHANNEL")"
} >&3

finish
