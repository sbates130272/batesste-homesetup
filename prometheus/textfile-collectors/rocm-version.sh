#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Publish the host's ROCm/HIP stack version as a node-exporter
# textfile metric, for the ROCm column on the LAN Overview
# dashboard's GPU Inventory table.
#
# This exists as its own collector rather than reusing
# rocm_aic_rocm_version_info, which used to report the same
# number on snoc-thinkstation. That metric came from the
# rocm-aic-exporter timer -- a large bespoke LMCache/NIXL/AIS
# instrumentation package tied to that host's vLLM work, which
# had no business being installed on the other three GPU boxes
# just to read one version string. It ran on snoc-thinkstation
# alone, and has since been removed from there too, so nothing
# emits that series on this fleet any more.

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/rocm-version.prom"

# PATH first, then the ROCm prefixes. systemd's default PATH does
# include /usr/bin, which is where the apt-packaged hipconfig
# lives on all four hosts, so the bare lookup is not the fragile
# one -- /opt/rocm/bin is, since it is on nobody's default PATH.
#
# The order is load-bearing, not cosmetic. amd-laptop has two ROCm
# installs: /usr/bin/hipconfig is 7.15.26333 while /opt/rocm is a
# symlink to /etc/alternatives/rocm pointing at 7.2.53211. Probing
# /opt/rocm first reports the older one, which is not what anything
# on that host actually builds or runs against.
find_hipconfig() {
    local c
    c="$(command -v hipconfig 2>/dev/null)" && { echo "$c"; return 0; }
    for c in /opt/rocm/bin/hipconfig /opt/rocm/hip/bin/hipconfig; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# Report the ROCm prefix separately when it disagrees with PATH.
# Without this, amd-laptop's stale alternatives link is invisible
# -- the column just shows a plausible version and nothing hints
# that /opt/rocm points somewhere else entirely.
alt_version() {
    local alt
    [[ -x /opt/rocm/bin/hipconfig ]] || return 0
    alt="$(/opt/rocm/bin/hipconfig --version 2>/dev/null | tr -d '[:space:]')"
    # The explicit `return 0` is required under `set -e`. Without
    # it the function's exit status is that of the failed test on
    # every host where the two versions agree, which is three of
    # the four, and the whole collector aborts before writing.
    [[ -n "$alt" && "$alt" != "$1" ]] && echo "$alt"
    return 0
}

VERSION=""
if HIPCONFIG="$(find_hipconfig)"; then
    # --version prints the HIP runtime version, e.g.
    # 7.14.60850-0000000. Note this is not always the same as
    # /opt/rocm/.info/version, which is the packaged ROCm release
    # (amd-laptop reports 7.15.26333-0000000 and 7.2.4
    # respectively). The HIP runtime version is the one that
    # matters for "will this kernel build and run here", and it is
    # what rocm_aic_rocm_version_info used to report, so the column
    # kept showing the same value snoc-thinkstation always had.
    VERSION="$("$HIPCONFIG" --version 2>/dev/null | tr -d '[:space:]')" || VERSION=""
fi
ALT="$(alt_version "$VERSION")"

TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

{
    echo '# HELP rocm_version_present 1 if a ROCm/HIP stack was detected on this host.'
    echo '# TYPE rocm_version_present gauge'
    if [[ -n "$VERSION" ]]; then
        echo 'rocm_version_present 1'
        echo '# HELP rocm_version_info ROCm/HIP stack version from hipconfig --version (gauge 1).'
        echo '# TYPE rocm_version_info gauge'
        printf 'rocm_version_info{version="%s"} 1\n' "$VERSION"
        if [[ -n "$ALT" ]]; then
            echo '# HELP rocm_version_prefix_mismatch /opt/rocm resolves to a different HIP version than PATH (gauge 1).'
            echo '# TYPE rocm_version_prefix_mismatch gauge'
            printf 'rocm_version_prefix_mismatch{version="%s"} 1\n' "$ALT"
        fi
    else
        # Emit the "absent" case explicitly. A host with no ROCm
        # and a host whose collector never ran are otherwise
        # indistinguishable in the TSDB, and only one of those is
        # worth chasing.
        echo 'rocm_version_present 0'
    fi
} > "$TMP"

chmod 0644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
