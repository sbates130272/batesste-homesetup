#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Verify that a batesste-s3-backup disk image is structurally sound
# and carries mountable filesystems, without restoring all 238 GiB of
# it.
#
# The trick is that a whole-disk restore is not needed to answer the
# question. Materialise a *sparse* file the size of the original disk,
# stream only the first few GiB of the image into it, and everything
# structural lands in that window: the GPT, the EFI partition, /boot,
# the LVM label and metadata, and the root filesystem's superblock.
# The rest of the file reads as zeros and is never touched. On this
# disk that means a full fsck of two real filesystems for about 4 GiB
# of transfer.
#
# Written because the backups had never been restore-tested. A backup
# nobody has read back is a hypothesis, and this repo had already
# found one fifteen-month outage by looking rather than assuming.
#
# What this does NOT prove: that the bulk of the image -- the other
# 234 GiB, including nearly all of the root filesystem -- is intact.
# The gzip trailer check in --bucket mode catches a truncated archive,
# which is the failure mode the backup script can actually produce
# (see the pipefail note in README.md), but corruption in the middle
# of an otherwise complete archive would pass. Only a full stream
# would catch that.

set -euo pipefail

HEAD_BYTES="${HEAD_BYTES:-$((4 * 1024 * 1024 * 1024))}"
EXPECTED_DISK_BYTES="${EXPECTED_DISK_BYTES:-256060514304}"
WORKDIR="${WORKDIR:-}"
IMAGE=""
BUCKET=""
KEY=""
REGION="${AWS_REGION:-us-west-2}"
KEEP=false

usage() {
    cat <<EOF
Usage: $(basename "$0") --image FILE
       $(basename "$0") --bucket BUCKET --key KEY [--region REGION]

Verify a batesste-s3-backup disk image. In --bucket mode the image is
streamed from S3 and the gzip trailer is checked first; in --image
mode an already-materialised sparse image is inspected in place.

Options:
  --image FILE     Verify a local sparse image (already expanded).
  --bucket BUCKET  S3 bucket holding the .gz image.
  --key KEY        Object key within that bucket.
  --region REGION  AWS region (default: ${REGION}).
  --keep           Leave the work directory behind for inspection.
  -h, --help       Show this help.

Environment:
  HEAD_BYTES            Bytes of the image to materialise
                        (default: ${HEAD_BYTES}).
  EXPECTED_DISK_BYTES   Size of the original disk, used for the sparse
                        file and the gzip trailer check
                        (default: ${EXPECTED_DISK_BYTES}).
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)  IMAGE="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --key)    KEY="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

if [[ -n "${IMAGE}" && -n "${BUCKET}" ]]; then
    echo "Error: --image and --bucket are mutually exclusive." >&2
    exit 2
fi
if [[ -z "${IMAGE}" && ( -z "${BUCKET}" || -z "${KEY}" ) ]]; then
    echo "Error: need either --image, or both --bucket and --key." >&2
    exit 2
fi

# Needed in both modes: --image still writes fsck logs and the parsed
# layout here, so it cannot be created only on the fetch path.
[[ -n "${WORKDIR}" ]] || WORKDIR="$(mktemp -d)"
mkdir -p "${WORKDIR}"

FAILURES=()
NOTES=()
LOOPS=()

fail()  { echo "    FAIL: $*"; FAILURES+=("$*"); }
pass()  { echo "    ok: $*"; }
note()  { echo "    note: $*"; NOTES+=("$*"); }

detach() {
    # `losetup -d` is asynchronous. It flags the device for release and
    # exits 0 even when something still holds it open -- typically a
    # udev probe of the partition devices that -P created, which races
    # with the detach rather than finishing before it. So re-check
    # rather than believing the exit status. On success the first
    # attempt returns immediately and the retries cost nothing.
    local dev="$1" i
    for (( i = 0; i < 40; i++ )); do
        sudo losetup -d "${dev}" 2>/dev/null || true
        sudo losetup -l --noheadings -O NAME 2>/dev/null \
            | grep -qx "${dev}" || return 0
        udevadm settle 2>/dev/null || true
        sleep 0.5
    done
    return 1
}

cleanup() {
    udevadm settle 2>/dev/null || true
    # Reverse order: the root-LV loop is layered on the same backing
    # file as the whole-disk one and must go first.
    for (( i=${#LOOPS[@]}-1 ; i>=0 ; i-- )); do
        detach "${LOOPS[i]}" \
            || echo "Warning: could not detach ${LOOPS[i]}; it still pins ${IMAGE}" >&2
    done
    if [[ -n "${WORKDIR}" && "${KEEP}" == false && -d "${WORKDIR}" ]]; then
        sudo rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

attach() {
    # Sets ATTACHED to the new loop device and records it for cleanup.
    #
    # Deliberately a global rather than an echo the caller captures.
    # `x="$(attach ...)"` runs attach in a subshell, so the LOOPS entry
    # is appended to a copy of the array that dies with it -- leaving
    # the parent's LOOPS permanently empty, cleanup detaching nothing,
    # and every run leaking its loop devices while reporting success.
    # Each leaked device pins its backing file open, so deleting the
    # image does not give the space back either.
    ATTACHED="$(sudo losetup -f --show "$@")"
    LOOPS+=("${ATTACHED}")
}

# ── Fetch ──────────────────────────────────────────────────────────

if [[ -z "${IMAGE}" ]]; then
    IMAGE="${WORKDIR}/disk.raw"

    echo "==> Checking the gzip trailer..."
    # gzip records the uncompressed size in the last four bytes, so a
    # four-byte ranged GET says whether the archive describes a whole
    # disk -- for a fraction of a cent, versus roughly three dollars
    # of egress to stream all 33 GB. This is what catches the
    # `dd | pigz` truncation case: a dd that dies partway leaves a
    # complete, valid, far too small .gz that the unit reports as
    # success.
    #
    # ISIZE is modulo 2^32, so a truncation landing on an exact 4 GiB
    # boundary from the true size would alias and slip through. That
    # is a 1-in-a-billion coincidence rather than a plausible failure,
    # but it is the reason this is a cheap check and not a proof.
    OBJ_SIZE="$(aws s3api head-object --bucket "${BUCKET}" --key "${KEY}" \
        --region "${REGION}" --query 'ContentLength' --output text)"
    TRAILER="${WORKDIR}/trailer.bin"
    aws s3api get-object --bucket "${BUCKET}" --key "${KEY}" \
        --region "${REGION}" \
        --range "bytes=$((OBJ_SIZE - 4))-$((OBJ_SIZE - 1))" \
        "${TRAILER}" >/dev/null
    ISIZE="$(python3 -c "import struct,sys;print(struct.unpack('<I',open(sys.argv[1],'rb').read(4))[0])" "${TRAILER}")"
    WANT=$((EXPECTED_DISK_BYTES % 4294967296))
    if [[ "${ISIZE}" == "${WANT}" ]]; then
        pass "gzip trailer reports ${ISIZE} bytes (mod 2^32), as expected"
    else
        fail "gzip trailer reports ${ISIZE} bytes (mod 2^32), expected ${WANT} -- the archive does not describe a whole ${EXPECTED_DISK_BYTES}-byte disk"
    fi

    echo "==> Materialising the first $((HEAD_BYTES / 1024 / 1024)) MiB into a sparse ${EXPECTED_DISK_BYTES}-byte image..."
    # The sparse full-size file is not a nicety. A plain truncated
    # image has no valid GPT at all: the secondary header lives in the
    # last sectors of the disk, and without it the kernel falls back
    # to the protective MBR and reports one 4 GiB partition of type
    # 0xee. Sizing the file correctly makes the primary GPT
    # self-consistent, and the untouched tail costs nothing on disk.
    truncate -s "${EXPECTED_DISK_BYTES}" "${IMAGE}"

    # No pipefail here, deliberately. head exits as soon as it has
    # what it needs, gunzip and aws then take SIGPIPE, and under
    # pipefail that reads as failure on every successful run.
    set +o pipefail
    aws s3 cp "s3://${BUCKET}/${KEY}" - --region "${REGION}" 2>/dev/null \
        | gunzip -c 2>/dev/null \
        | head -c "${HEAD_BYTES}" \
        | dd of="${IMAGE}" bs=1M conv=notrunc status=none
    set -o pipefail

    # Allocated blocks rather than apparent size: the file is sparse
    # and ${EXPECTED_DISK_BYTES} long from the moment truncate ran, so
    # `stat -c %s` would report success before a single byte arrived.
    GOT="$(find "${IMAGE}" -printf '%b' 2>/dev/null || echo 0)"
    GOT=$((GOT * 512))
    if (( GOT < HEAD_BYTES / 2 )); then
        fail "only ~${GOT} bytes materialised, expected ${HEAD_BYTES} -- the stream ended early or decompression failed"
    else
        pass "decompressed the leading $((HEAD_BYTES / 1024 / 1024)) MiB without error"
    fi
fi

[[ -f "${IMAGE}" ]] || { echo "Error: no such image: ${IMAGE}" >&2; exit 2; }

# ── Partition table ────────────────────────────────────────────────

echo "==> Checking the partition table..."
attach -P -r "${IMAGE}"
DISK_LOOP="${ATTACHED}"
sleep 1

if ! LAYOUT="$(sudo sfdisk -J "${DISK_LOOP}" 2>/dev/null)"; then
    fail "sfdisk could not read a partition table"
    LAYOUT='{"partitiontable":{"label":"none","partitions":[]}}'
fi

LABEL="$(python3 -c "import json,sys;print(json.load(sys.stdin)['partitiontable'].get('label','none'))" <<<"${LAYOUT}")"
if [[ "${LABEL}" == "gpt" ]]; then
    pass "GPT partition table is readable"
else
    fail "expected a GPT partition table, found '${LABEL}'"
fi

LAYOUT_FILE="${WORKDIR:-/tmp}/layout.json"
printf '%s' "${LAYOUT}" >"${LAYOUT_FILE}"
mapfile -t PARTS < <(python3 - "${LAYOUT_FILE}" "${HEAD_BYTES}" <<'PY'
import json, sys
tbl = json.load(open(sys.argv[1]))["partitiontable"]
head = int(sys.argv[2])
for p in tbl.get("partitions", []):
    start = p["start"] * 512
    size = p["size"] * 512
    complete = "full" if start + size <= head else "partial"
    print(f"{p['node']} {start} {size} {complete}")
PY
) || true

if [[ "${#PARTS[@]}" -eq 0 ]]; then
    fail "the partition table contains no partitions"
else
    pass "found ${#PARTS[@]} partitions"
fi

# ── Filesystems ────────────────────────────────────────────────────

CHECKED=0

check_fat() {
    # fsck.fat returns 1 on a perfectly healthy image of a *mounted*
    # FAT volume: the dirty bit is set because the filesystem was
    # never unmounted, and the boot sector and its backup disagree in
    # the byte that records exactly that. Both are expected in a live
    # dd and neither means the data is bad. Treating nonzero as
    # failure here would paint this job permanently red, which is how
    # a check stops being read.
    local dev="$1" log="$2" rc=0
    sudo fsck.fat -n "${dev}" >"${log}" 2>&1 || rc=$?
    if (( rc == 0 )); then
        pass "${dev}: FAT filesystem is clean"
    elif (( rc == 1 )); then
        local unexpected
        # The last alternative is the run summary, anchored to its
        # full shape on purpose: a bare `clusters$` would also swallow
        # any real finding whose message happens to end in that word.
        unexpected="$(grep -vE 'differences between boot sector|mostly harmless|^ +[0-9]+:[0-9]+/[0-9]+|Not automatically fixing|Dirty bit is set|Automatically removing dirty bit|Leaving filesystem unchanged|^fsck\.fat|^$|files, [0-9]+/[0-9]+ clusters$' "${log}" || true)"
        if [[ -z "${unexpected}" ]]; then
            note "${dev}: FAT dirty bit set (expected for a live dd), otherwise clean"
        else
            fail "${dev}: FAT check reported problems beyond the expected dirty bit:"$'\n'"${unexpected}"
        fi
    else
        fail "${dev}: fsck.fat exited ${rc}"$'\n'"$(tail -5 "${log}")"
    fi
}

check_ext4() {
    # Two phases. A read-only check is the strongest signal, but a dd
    # of a mounted ext4 can capture an unreplayed journal, and
    # e2fsck -n refuses to replay and then reports the resulting
    # inconsistencies as errors. So: if the read-only pass is unhappy,
    # replay the journal on a writable attachment -- exactly what a
    # real restore would do -- and check again.
    #
    # The repair step is the dangerous part, and it took two attempts
    # to get right. A plain `-fy` does not merely replay: it repairs,
    # rebuilding from backup metadata and then pronouncing the result
    # clean. Corrupting this image's group descriptors and running the
    # original `-fy` fallback produced "needed a journal replay, clean
    # afterwards" and an overall PASS -- the check laundering real
    # damage into an expected note.
    #
    # `-E journal_only` is the documented "replay and nothing else",
    # but it is silently overridden by `-f`, which forces the full
    # check anyway. Hence `-y` without `-f` here.
    #
    # Even then journal_only still fixes a bitmap or two when the
    # superblock is flagged with errors, so its *exit code* is the
    # real guard: 0 means it only replayed, nonzero means it changed
    # something, and anything it had to change is damage this image
    # should not have had. The follow-up check alone cannot tell the
    # two apart -- it returns 0 in both cases.
    local dev="$1" log="$2" off="$3" size="$4" rc=0
    sudo fsck.ext4 -fn "${dev}" >"${log}" 2>&1 || rc=$?
    if (( rc == 0 )); then
        pass "${dev}: ext4 filesystem is clean"
        return
    fi

    local wdev rc2=0 rc3=0
    attach --offset "${off}" --sizelimit "${size}" "${IMAGE}"
    wdev="${ATTACHED}"
    sudo fsck.ext4 -y -E journal_only "${wdev}" >>"${log}" 2>&1 || rc2=$?
    if (( rc2 != 0 )); then
        fail "${dev}: ext4 replay had to repair the filesystem (rc=${rc2}) -- this is damage, not an unreplayed journal"$'\n'"$(tail -10 "${log}")"
        return
    fi

    sudo fsck.ext4 -fn "${wdev}" >>"${log}" 2>&1 || rc3=$?
    if (( rc3 == 0 )); then
        note "${dev}: ext4 needed a journal replay (expected for a live dd), clean afterwards"
    else
        fail "${dev}: ext4 is inconsistent and a journal replay did not resolve it (rc=${rc3})"$'\n'"$(tail -10 "${log}")"
    fi
}

echo "==> Checking filesystems..."
for entry in "${PARTS[@]}"; do
    read -r node start size complete <<<"${entry}"
    type="$(sudo blkid -s TYPE -o value "${node}" 2>/dev/null || true)"
    [[ -n "${type}" ]] || type="unknown"

    if [[ "${complete}" != "full" ]]; then
        note "${node}: ${type}, extends past the streamed window -- structure only, not fsck'd"
        # An LVM PV is still worth reading even when partial: its
        # label and metadata live in the first megabyte, which is
        # inside the window even though the volumes themselves are
        # not.
        if [[ "${type}" == "LVM2_member" ]]; then
            LVM_NODE="${node}"; LVM_START="${start}"
        fi
        continue
    fi

    case "${type}" in
        vfat|msdos)
            check_fat "${node}" "${WORKDIR:-/tmp}/fsck-$(basename "${node}").log"
            CHECKED=$((CHECKED + 1))
            ;;
        ext2|ext3|ext4)
            check_ext4 "${node}" "${WORKDIR:-/tmp}/fsck-$(basename "${node}").log" \
                "${start}" "${size}"
            CHECKED=$((CHECKED + 1))
            ;;
        LVM2_member)
            LVM_NODE="${node}"; LVM_START="${start}"
            ;;
        *)
            note "${node}: type '${type}', no checker for it"
            ;;
    esac
done

if (( CHECKED == 0 )); then
    fail "no filesystem was actually checked -- the image may be empty or unrecognisable"
fi

# ── LVM ────────────────────────────────────────────────────────────

if [[ -n "${LVM_NODE:-}" ]]; then
    echo "==> Checking LVM metadata on ${LVM_NODE}..."
    META="${WORKDIR:-/tmp}/lvm-meta.txt"
    # `tr -d '\0'` rather than `strings`: the metadata is plain ASCII
    # in a mostly-zeroed megabyte, and strings reflows it into
    # printable runs that no longer line up with the original line
    # structure the parser below depends on.
    sudo dd if="${LVM_NODE}" bs=1M count=1 status=none | tr -d '\000' >"${META}"

    if grep -q LABELONE "${META}"; then
        pass "LVM2 PV label present"
    else
        fail "no LVM2 PV label found on ${LVM_NODE}"
    fi

    # The metadata area holds every revision ever written, appended in
    # sequence, so the *last* complete stanza is the current one --
    # taking the first would describe the volume group as it existed
    # at creation, which here means missing loki-lv entirely.
    if MAP="$(python3 - "${META}" <<'PY'
import re, sys

# The LVM text format nests, and every closing brace sits at column
# zero, so a non-greedy regex for "name { ... }" stops at the end of
# the first *inner* block -- for a volume group that is the end of
# pv0, long before logical_volumes is reached. Depth counting is the
# only thing that reads this correctly.
BLOCK = re.compile(r"([A-Za-z0-9_.+-]+)\s*\{")


def blocks(s):
    """Yield (name, body) for each block at the top level of s."""
    out, i = [], 0
    while (m := BLOCK.search(s, i)):
        depth, j = 1, m.end()
        while j < len(s) and depth:
            if s[j] == "{":
                depth += 1
            elif s[j] == "}":
                depth -= 1
            j += 1
        if depth:
            break            # unterminated: truncated metadata
        out.append((m.group(1), s[m.end():j - 1]))
        i = j
    return out


def num(pattern, s):
    m = re.search(pattern, s)
    return int(m.group(1)) if m else None


text = open(sys.argv[1], errors="replace").read()

# The metadata area is append-only and keeps every revision ever
# written, so the current volume group is the stanza with the highest
# seqno. Taking the first would describe the VG as it was at creation
# -- here, missing loki-lv entirely.
best = None
for name, body in blocks(text):
    if "logical_volumes" not in body:
        continue
    seq = num(r"seqno = (\d+)", body)
    if seq is not None and (best is None or seq > best[0]):
        best = (seq, name, body)

if not best:
    sys.exit(1)

_, vg, body = best
ext = num(r"extent_size = (\d+)", body)
inner = dict(blocks(body))
pe = num(r"pe_start = (\d+)", inner.get("physical_volumes", ""))
if ext is None or pe is None:
    sys.exit(1)
print(f"vg {vg} {ext} {pe}")

for lv, lvbody in blocks(inner.get("logical_volumes", "")):
    first, total = None, 0
    for seg, segbody in blocks(lvbody):
        if not seg.startswith("segment"):
            continue
        cnt = num(r"extent_count = (\d+)", segbody)
        if cnt is None:
            continue
        # Size is the sum over every segment, but the offset comes
        # only from the one starting at logical extent 0 -- that is
        # where the superblock lives. A grown volume's later segments
        # can sit anywhere on the PV, so using the wrong one would
        # point the check at the middle of the filesystem.
        total += cnt
        if num(r"start_extent = (\d+)", segbody) == 0:
            stripe = re.search(r'stripes = \[\s*"[^"]+",\s*(\d+)', segbody, re.S)
            if stripe:
                first = stripe.group(1)
    if first is not None and total:
        print(f"lv {lv} {first} {total}")
PY
    )"; then
        EXTENT_SECT=0; PE_START_SECT=0
        while read -r kind a b c; do
            case "${kind}" in
                vg) pass "volume group '${a}' metadata parsed"
                    EXTENT_SECT="${b}"; PE_START_SECT="${c}" ;;
                lv)
                    LV_OFF=$(( LVM_START + PE_START_SECT * 512 + b * EXTENT_SECT * 512 ))
                    LV_SIZE=$(( c * EXTENT_SECT * 512 ))
                    if (( LV_OFF + 4096 > HEAD_BYTES )); then
                        note "LV '${a}': starts past the streamed window, superblock not read"
                        continue
                    fi
                    attach -r --offset "${LV_OFF}" --sizelimit "${LV_SIZE}" "${IMAGE}"
                    SB="${ATTACHED}"
                    # dumpe2fs exits 1 here on a healthy image: the
                    # journal lives deeper into the volume than the
                    # streamed window reaches, so its superblock reads
                    # as zeros. The primary superblock is what matters
                    # and it is at offset 1024, well inside.
                    DUMP="$(sudo dumpe2fs -h "${SB}" 2>/dev/null || true)"
                    if grep -q '^Filesystem magic number: *0xEF53' <<<"${DUMP}"; then
                        BC="$(sed -n 's/^Block count: *//p' <<<"${DUMP}")"
                        BS="$(sed -n 's/^Block size: *//p' <<<"${DUMP}")"
                        MNT="$(sed -n 's/^Last mounted on: *//p' <<<"${DUMP}")"
                        pass "LV '${a}': ext4 superblock valid, last mounted on '${MNT}'"
                        # Cross-check: the filesystem's own idea of its
                        # size against what the LVM metadata allocated.
                        # These are two independent records, and a
                        # mismatch means one of them is wrong.
                        if [[ -n "${BC}" && -n "${BS}" ]] && (( BC * BS == LV_SIZE )); then
                            pass "LV '${a}': ext4 size $((BC * BS)) matches its LVM allocation"
                        else
                            fail "LV '${a}': ext4 reports $((BC * BS)) bytes but LVM allocated ${LV_SIZE}"
                        fi
                    else
                        fail "LV '${a}': no valid ext4 superblock at offset ${LV_OFF}"
                    fi
                    ;;
            esac
        done <<<"${MAP}"
    else
        fail "could not parse LVM volume group metadata"
    fi
fi

# ── Verdict ────────────────────────────────────────────────────────

echo
if [[ "${#NOTES[@]}" -gt 0 ]]; then
    echo "Notes (expected for an image of a live, mounted disk):"
    printf '  - %s\n' "${NOTES[@]}"
    echo
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "RESULT: FAILED (${#FAILURES[@]} problem(s))"
    printf '  - %s\n' "${FAILURES[@]}"
    exit 1
fi

echo "RESULT: PASSED -- ${CHECKED} filesystem(s) checked, structure intact."
