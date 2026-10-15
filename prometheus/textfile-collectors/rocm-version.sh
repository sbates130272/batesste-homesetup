#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Publish the host's ROCm/HIP stack version and its amdgpu DKMS
# module version as node-exporter textfile metrics, for the ROCm
# and DKMS columns on the LAN Overview dashboard's GPU Inventory
# table.
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

# The amdgpu DKMS tree version, scoped to the running kernel.
# Both GPU hosts have amdgpu built for two kernels at once, so an
# unscoped `dkms status` returns several lines and there is no
# single version to report -- -k pins it to the one we booted.
# -m matters too: snoc-strix also carries AMDPowerProfiler and
# xrt trees, which an unfiltered status would interleave.
#
# Two output formats are in the wild. dkms 3.x (3.2.2 on both
# hosts) prints the module and version as one slash-joined field,
# "amdgpu/7.1.9-2407772.26.04, 7.0.0-38-generic, x86_64:
# installed"; dkms 2.x prints them as separate comma-separated
# fields. Trimming at the colon and testing for the slash covers
# both without parsing the status text itself, which is
# translated on some systems.
dkms_amdgpu_version() {
    local line first
    command -v dkms >/dev/null 2>&1 || return 0
    line="$(dkms status -m amdgpu -k "$(uname -r)" 2>/dev/null | head -1)"
    [[ -n "$line" ]] || return 0
    line="${line%%:*}"
    first="${line%%,*}"
    if [[ "$first" == */* ]]; then
        echo "${first#*/}"
    else
        echo "$line" | awk -F', *' '{print $2}'
    fi
    return 0
}

# Fallback for a DKMS-built module on a host without the dkms
# CLI. The filename guard is the whole point: the inbox amdgpu
# also answers `modinfo -F version` on some kernels, and
# reporting that as a DKMS version would be quietly wrong.
# Anything DKMS built lands under /updates/dkms/.
modinfo_dkms_version() {
    local f v
    f="$(modinfo -F filename amdgpu 2>/dev/null)" || return 0
    [[ "$f" == */updates/dkms/* ]] || return 0
    v="$(modinfo -F version amdgpu 2>/dev/null | head -1 | tr -d '[:space:]')"
    [[ -n "$v" ]] && echo "$v"
    return 0
}

# True when DKMS knows about amdgpu for *some* kernel. Only
# consulted once the running-kernel lookup has already come back
# empty, which makes the pair of them a real diagnosis rather
# than a blank column: the rebuild after a kernel upgrade did not
# happen, so the kernel now running has no out-of-tree amdgpu.
dkms_has_amdgpu_tree() {
    command -v dkms >/dev/null 2>&1 || return 1
    dkms status -m amdgpu 2>/dev/null | grep -q .
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

# Trimmed the same way the hipconfig reading is: a stray space
# would not break the exposition format, but it would land in the
# label and show up in the dashboard column.
DKMS_VERSION="$(dkms_amdgpu_version | tr -d '[:space:]')"
[[ -n "$DKMS_VERSION" ]] || DKMS_VERSION="$(modinfo_dkms_version)"

DKMS_MISMATCH=0
if [[ -z "$DKMS_VERSION" ]] && dkms_has_amdgpu_tree; then
    DKMS_MISMATCH=1
fi

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

    # The label is dkms_version rather than the version used
    # above, and that is not a style slip. GPU Inventory joins
    # its targets with a seriesToColumns transform; a second
    # frame carrying a `version` label collides with the ROCm
    # column's and one of the two gets dropped. Naming it apart
    # at the source keeps the dashboard query a plain `max by`.
    echo '# HELP amdgpu_dkms_present 1 if an out-of-tree amdgpu DKMS module is built for the running kernel.'
    echo '# TYPE amdgpu_dkms_present gauge'
    if [[ -n "$DKMS_VERSION" ]]; then
        echo 'amdgpu_dkms_present 1'
        echo '# HELP amdgpu_dkms_version_info amdgpu DKMS tree version for the running kernel (gauge 1).'
        echo '# TYPE amdgpu_dkms_version_info gauge'
        printf 'amdgpu_dkms_version_info{dkms_version="%s"} 1\n' "$DKMS_VERSION"
    else
        # Absent covers three different hosts: the inbox amdgpu
        # driver, no AMD GPU at all, and WSL, where the GPU
        # arrives over /dev/dxg and there is no kernel module to
        # version. None of them is a fault, so none of them gets
        # a mismatch series.
        echo 'amdgpu_dkms_present 0'
        if (( DKMS_MISMATCH )); then
            echo '# HELP amdgpu_dkms_kernel_mismatch amdgpu is built by DKMS but not for the running kernel (gauge 1).'
            echo '# TYPE amdgpu_dkms_kernel_mismatch gauge'
            echo 'amdgpu_dkms_kernel_mismatch 1'
        fi
    fi
} > "$TMP"

chmod 0644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
