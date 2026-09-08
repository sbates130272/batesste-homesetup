#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Publish the age and size of the newest batesste-s3-backup artifact
# in S3 as node-exporter textfile metrics, for the backup alert rules
# in grafana/provisioning/alerting/rules.yaml.
#
# This deliberately measures the *object in the bucket* rather than
# the exit status of batesste-s3-backup.service. The two are not the
# same thing, and the gap between them is where fifteen months of
# missing backups hid: the disk backup wrote nothing to
# batesste-homelab-backups between June 2025 and September 2026, and
# the Hermes backup logs "Uploading to s3://..." and then never
# reports whether the upload landed. A unit that exits 0 having
# uploaded nothing is the failure mode worth catching, so the check
# asks S3 what is actually there.
#
# Settings come from the same batesste-s3-backup.conf the backup unit
# reads, and credentials from the same ~/.secrets.env, so there is one
# bucket name and one key in play rather than a second copy that can
# drift out of step with the thing it claims to be watching.

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/s3-backup-age.prom"

AWS_BUCKET="${AWS_BUCKET:-batesste-homelab-backups}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BLK_DEVICE="${BLK_DEVICE:-/dev/sda}"

# Match the naming batesste-s3-backup builds its filenames from:
# hostname + block device with slashes turned into dashes. Scoping the
# query to this prefix keeps the metric about *this host's* backup.
# The bucket is shared, and a fresh object from some other machine
# should not make a dead backup here look healthy.
PREFIX="$(uname -n)${BLK_DEVICE//"/"/"-"}"

QUERY_OK=1
LAST_MODIFIED=""
LAST_SIZE=""
OBJECT_COUNT=""

# One list call, three values out of it. The CLI paginates internally
# and applies --query to the aggregated result, so this does not miss
# objects once the bucket grows past a page.
#
# `|| QUERY_OK=0` rather than letting set -e kill the script: a
# rejected key must still produce a .prom file saying so. If the
# script simply died, node-exporter would keep serving the last good
# file it wrote and the bucket would look fine while nobody could
# reach it -- which is the exact shape of the outage this is here to
# report.
#
# The `|| ` + "[]"` null-coalescing is load-bearing. A prefix matching
# nothing omits Contents entirely rather than returning an empty list,
# and length(None) is a hard error that exits 255 -- indistinguishable
# from a rejected key. Without this, "every backup has been deleted"
# would be reported as "cannot reach S3": still an alert, but pointing
# at the wrong thing while the bucket sits empty.
RAW="$(aws s3api list-objects-v2 \
    --bucket "${AWS_BUCKET}" \
    --region "${AWS_REGION}" \
    --prefix "${PREFIX}" \
    --output text \
    --query '[length(Contents || `[]`), sort_by(Contents || `[]`, &LastModified)[-1].LastModified, sort_by(Contents || `[]`, &LastModified)[-1].Size]' \
    2>/dev/null)" || QUERY_OK=0

if [[ "${QUERY_OK}" -eq 1 ]]; then
    read -r OBJECT_COUNT LAST_MODIFIED LAST_SIZE <<<"${RAW}"
    # An empty bucket answers "None None None" rather than failing.
    # That is a successful query with zero backups in it -- a real and
    # distinct state from "the query did not work", so it keeps
    # query_success 1 and simply reports a count of zero.
    if [[ "${OBJECT_COUNT}" == "None" || -z "${OBJECT_COUNT}" ]]; then
        OBJECT_COUNT=0
        LAST_MODIFIED=""
        LAST_SIZE=""
    fi
fi

TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

{
    echo '# HELP batesste_s3_backup_query_success 1 if the S3 bucket listing succeeded (gauge).'
    echo '# TYPE batesste_s3_backup_query_success gauge'
    printf 'batesste_s3_backup_query_success{bucket="%s",prefix="%s"} %d\n' \
        "${AWS_BUCKET}" "${PREFIX}" "${QUERY_OK}"

    if [[ "${QUERY_OK}" -eq 1 ]]; then
        echo '# HELP batesste_s3_backup_objects Number of backup objects in the bucket for this host (gauge).'
        echo '# TYPE batesste_s3_backup_objects gauge'
        printf 'batesste_s3_backup_objects{bucket="%s",prefix="%s"} %d\n' \
            "${AWS_BUCKET}" "${PREFIX}" "${OBJECT_COUNT}"

        if [[ -n "${LAST_MODIFIED}" && "${LAST_MODIFIED}" != "None" ]]; then
            EPOCH="$(date -d "${LAST_MODIFIED}" +%s)"
            echo '# HELP batesste_s3_backup_last_object_timestamp_seconds LastModified of the newest backup object, in epoch seconds (gauge).'
            echo '# TYPE batesste_s3_backup_last_object_timestamp_seconds gauge'
            printf 'batesste_s3_backup_last_object_timestamp_seconds{bucket="%s",prefix="%s"} %d\n' \
                "${AWS_BUCKET}" "${PREFIX}" "${EPOCH}"

            # Size is here because "the object exists" is a weaker
            # claim than it looks. batesste-s3-backup pipes dd into
            # pigz without pipefail, so a dd that dies partway still
            # leaves a valid, complete, far too small .gz behind and
            # the unit exits 0. Age alone would call that a healthy
            # backup.
            echo '# HELP batesste_s3_backup_last_object_bytes Size of the newest backup object in bytes (gauge).'
            echo '# TYPE batesste_s3_backup_last_object_bytes gauge'
            printf 'batesste_s3_backup_last_object_bytes{bucket="%s",prefix="%s"} %d\n' \
                "${AWS_BUCKET}" "${PREFIX}" "${LAST_SIZE}"
        fi
    fi
} > "$TMP"

chmod 0644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
