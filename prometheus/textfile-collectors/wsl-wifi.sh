#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Publish the Windows host's WiFi state as node-exporter textfile
# metrics, for the WiFi (dBm) and Link columns on the LAN Overview
# Node Fleet table.
#
# node-exporter's --collector.wifi cannot do this. It is already
# enabled on both WSL hosts and yields zero series, because there is
# no wireless device inside the VM to read: /proc/net/wireless holds
# only its header, and although both hosts run networkingMode=Mirrored,
# mirrored mode presents the Windows adapters as plain Ethernet with
# no nl80211 behind them. That is also why the Link column called
# them "Wired" -- eth1 is a mirrored adapter, not a cable.
#
# windows_exporter cannot do it either; it ships no wireless collector.
# So the signal has to come from Windows itself, via WSL interop.

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/wsl-wifi.prom"

is_wsl() {
    grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

find_netsh() {
    local c
    c="$(command -v netsh.exe 2>/dev/null)" && { echo "$c"; return 0; }
    for c in /mnt/c/Windows/System32/netsh.exe /mnt/c/Windows/Sysnative/netsh.exe; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# Pull one "Field : value" line out of netsh's output. The field name
# is matched anchored with surrounding whitespace so that "Signal"
# cannot also match "Signal quality", and "Name" cannot match
# "Profile name".
field() {
    sed -nE "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" \
        <<< "$2" | head -1
}

emit() {
    printf '# HELP %s %s\n# TYPE %s gauge\n' "$1" "$3" "$1" >&3
    printf '%s %s\n' "$1" "$2" >&3
}

TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
exec 3>"$TMP"

if ! is_wsl || ! NETSH="$(find_netsh)"; then
    # Emit the "not applicable" case explicitly rather than writing
    # nothing. A host with no WSL interop and a host whose collector
    # never ran are otherwise indistinguishable in the TSDB.
    emit wsl_wifi_present 0 'Windows WiFi state is readable from this host via WSL interop.'
    exec 3>&-
    chmod 0644 "$TMP"; mv "$TMP" "$OUT"; trap - EXIT
    exit 0
fi

# netsh inherits the caller's cwd, and a Linux-only cwd makes the
# Windows loader complain on stderr before doing the right thing
# anyway. Starting from a drive-backed directory keeps it quiet.
cd /mnt/c 2>/dev/null || cd /

# Output is localised; this parses the en-US field names. A host in
# another locale falls through to wsl_wifi_present 0 rather than
# reporting a wrong number.
OUTPUT="$("$NETSH" wlan show interfaces 2>/dev/null | tr -d '\r')" || OUTPUT=""

NAME="$(field 'Name' "$OUTPUT")"
if [[ -z "$NAME" ]]; then
    emit wsl_wifi_present 0 'Windows WiFi state is readable from this host via WSL interop.'
    exec 3>&-
    chmod 0644 "$TMP"; mv "$TMP" "$OUT"; trap - EXIT
    exit 0
fi

emit wsl_wifi_present 1 'Windows WiFi state is readable from this host via WSL interop.'

STATE="$(field 'State' "$OUTPUT")"
if [[ "$STATE" != "connected" ]]; then
    emit wsl_wifi_connected 0 'The Windows WiFi adapter is associated with an access point.'
    exec 3>&-
    chmod 0644 "$TMP"; mv "$TMP" "$OUT"; trap - EXIT
    exit 0
fi
emit wsl_wifi_connected 1 'The Windows WiFi adapter is associated with an access point.'

RSSI="$(field 'Rssi' "$OUTPUT")"
QUALITY="$(field 'Signal' "$OUTPUT" | tr -d '%')"

# Prefer the measured RSSI. Windows only started reporting it in
# recent builds -- both hosts are on 11 build 26200 and do -- but
# where it is missing the only source is the 0-100 quality scale,
# which the WLAN API documents as linear against -100..-50 dBm.
#
# That conversion is a poor substitute and the metric says so, so a
# panel can tell the two apart. Measured against derived on these
# hosts: 85% -> -50 actual vs -57.5 derived, 75% -> -69 vs -62.5.
# Wrong by 6-8 dB, in opposite directions.
if [[ -n "$RSSI" ]]; then
    emit wsl_wifi_signal_dbm "$RSSI" 'WiFi signal strength of the Windows host adapter, in dBm.'
    emit wsl_wifi_signal_dbm_derived 0 '1 if the dBm figure was converted from the quality percentage rather than measured.'
elif [[ -n "$QUALITY" ]]; then
    emit wsl_wifi_signal_dbm "$(( QUALITY / 2 - 100 ))" 'WiFi signal strength of the Windows host adapter, in dBm.'
    emit wsl_wifi_signal_dbm_derived 1 '1 if the dBm figure was converted from the quality percentage rather than measured.'
fi

[[ -n "$QUALITY" ]] && \
    emit wsl_wifi_signal_quality_percent "$QUALITY" "Windows' own 0-100 WiFi signal quality scale."

RX="$(field 'Receive rate \(Mbps\)' "$OUTPUT")"
TX="$(field 'Transmit rate \(Mbps\)' "$OUTPUT")"
[[ -n "$RX" ]] && emit wsl_wifi_receive_rate_mbps "$RX" 'Negotiated WiFi receive rate, in Mbps.'
[[ -n "$TX" ]] && emit wsl_wifi_transmit_rate_mbps "$TX" 'Negotiated WiFi transmit rate, in Mbps.'

# Radio type, band and channel travel as labels on a separate info
# gauge so they can change without churning the numeric series above.
#
# SSID and BSSID are deliberately not exported. They add nothing to
# any panel here, and one of these two hosts is a corporate laptop
# that roams onto networks whose names have no business being written
# into a homelab TSDB with 90-day retention.
RADIO="$(field 'Radio type' "$OUTPUT")"
BAND="$(field 'Band' "$OUTPUT")"
CHANNEL="$(field 'Channel' "$OUTPUT")"
{
    echo '# HELP wsl_wifi_link_info Radio type, band and channel of the Windows WiFi association (gauge 1).'
    echo '# TYPE wsl_wifi_link_info gauge'
    printf 'wsl_wifi_link_info{radio_type="%s",band="%s",channel="%s"} 1\n' \
        "$RADIO" "$BAND" "$CHANNEL"
} >&3

# The WiFi adapter's MAC, which is what lets the dashboard tell the
# Link column the truth about these hosts.
#
# Under networkingMode=Mirrored the Windows adapters appear inside the
# VM as eth*, carrying their real MACs, so the wireless one is
# indistinguishable from a cable by name alone -- which is why Node
# Fleet called both these hosts "Wired". node_network_info exposes the
# MAC in an address label, so joining on it identifies the mirrored
# radio exactly, with no interface-name denylist.
#
# The obvious alternative, asking Windows directly via
# Get-NetAdapter -Physical, is authoritative but takes 32 seconds on
# amd-laptop; see the timer for why that matters.
MAC="$(field 'Physical address' "$OUTPUT")"
if [[ -n "$MAC" ]]; then
    {
        echo '# HELP wsl_wifi_adapter MAC of the Windows WiFi adapter, as mirrored into the VM (gauge 1).'
        echo '# TYPE wsl_wifi_adapter gauge'
        printf 'wsl_wifi_adapter{address="%s"} 1\n' "$MAC"
    } >&3
fi

exec 3>&-
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
