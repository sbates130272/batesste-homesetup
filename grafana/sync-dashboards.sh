#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Replaces the old export-dashboards.sh, which had three behaviours that
# quietly corrupted this repo:
#
#   * it named output files from the dashboard *title* slug, so 5 of the
#     11 tracked dashboards were written to new paths instead of being
#     updated in place (firefly-overview.json -> firefly-iii-overview.json,
#     lan-overview.json -> home-lan-overview.json, ...), leaving duplicates
#   * it piped through `python3 -m json.tool`, which indents with 4 spaces
#     while every file in this repo uses jq's 2, reformatting the tree on
#     every run
#   * it read /api/dashboards/uid/<uid>, which returns whatever schema
#     the dashboard happens to be stored as. Grafana 13 stores some of
#     ours as v2 (elements/layout instead of panels), producing thousands
#     of lines of phantom diff against the v1 files on disk.
#
# This version keys off the UID, formats with plain jq, and always reads
# through the v1beta1 API so the on-disk schema stays stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_DIR="${SCRIPT_DIR}/dashboards"
VENDOR_DIR="${SCRIPT_DIR}/vendor/dashboards"
MANIFEST="${SCRIPT_DIR}/vendor/manifest.yaml"
SECRETS_FILE="${SCRIPT_DIR}/grafana-api.secrets"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
NS="default"

MODE="check"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--check | --pull | --push] [--url <grafana-url>]

Compare the dashboards running in Grafana against the JSON files in this
repository, and optionally reconcile them.

Modes:
  --check   (default) Report drift and exit non-zero if any is found.
            Writes nothing. Suitable for CI or a pre-commit hook.
  --pull    Live Grafana -> repo. Updates tracked files in place, keyed
            by dashboard UID, and files any dashboard Grafana does not
            provision from disk under vendor/ as an adopted third-party
            dashboard.
  --push    Repo -> live Grafana. Delegates to ./deploy.sh.

Options:
  --url <url>   Grafana base URL (default: ${GRAFANA_URL})
  -h, --help    Show this help message.

The Grafana service account token is read from:
  ${SECRETS_FILE}
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check"; shift ;;
        --pull)  MODE="pull";  shift ;;
        --push)  MODE="push";  shift ;;
        --url)   GRAFANA_URL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

if [[ "${MODE}" == "push" ]]; then
    exec "${SCRIPT_DIR}/deploy.sh"
fi

if [[ ! -f "${SECRETS_FILE}" ]]; then
    echo "Error: secrets file not found:" >&2
    echo "  ${SECRETS_FILE}" >&2
    echo "" >&2
    echo "Create it with your Grafana SA token:" >&2
    echo "  echo 'glsa_...' > ${SECRETS_FILE}" >&2
    exit 1
fi

TOKEN="$(tr -d '[:space:]' < "${SECRETS_FILE}")"
if [[ -z "${TOKEN}" ]]; then
    echo "Error: secrets file is empty." >&2
    exit 1
fi

# curl -sf alone exits non-zero with no output on an HTTP error, which
# under `set -e` kills the script mid-sentence and looks like a hang.
# Capture the status so failures say what actually went wrong.
api() {
    local body code
    body="$(curl -s -w '\n%{http_code}' \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${GRAFANA_URL}$1")" || {
        echo "Error: cannot reach ${GRAFANA_URL}" >&2
        exit 1
    }
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"

    if [[ "${code}" == "401" || "${code}" == "403" ]]; then
        echo "Error: Grafana rejected the service account token (HTTP ${code})." >&2
        echo "  ${SECRETS_FILE}" >&2
        echo "" >&2
        echo "The token is missing, expired, or revoked. Create a new one:" >&2
        echo "  Grafana > Administration > Service Accounts > Add token" >&2
        echo "  echo 'glsa_...' > ${SECRETS_FILE}" >&2
        exit 1
    fi
    if [[ "${code}" != "200" ]]; then
        echo "Error: GET $1 returned HTTP ${code}" >&2
        echo "${body}" | head -c 400 >&2
        echo "" >&2
        exit 1
    fi
    echo "${body}"
}

slugify() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//'
}

# The canonical on-disk form, used for both comparison and writing.
#
# Beyond stripping the per-save fields (uid is deliberately kept: it is
# the identity we key on), this pins down two things Grafana is free to
# vary, which between them accounted for every byte of "drift" the first
# --check run reported across 14 files:
#
#   * key order -- the API returns keys alphabetically, hand-edited
#     files are in insertion order. -S sorts both sides.
#   * panel order -- Grafana emits .panels sorted by grid position, but
#     nothing stops an edit from leaving them in another order. A single
#     panel out of place shifts every panel after it, so a no-op renders
#     as thousands of lines of phantom diff. Layout comes from gridPos,
#     not array index, so sorting is semantically inert.
normalize() {
    jq -S 'del(.id, .version, .__inputs, .__requires)
        | (.panels? // []) |= (
            sort_by(.gridPos.y // 0, .gridPos.x // 0)
            | map(if .panels?
                  then .panels |= sort_by(.gridPos.y // 0, .gridPos.x // 0)
                  else . end))'
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Build uid -> repo path index ────────────────────────────────────
# This is what makes the sync stable: a dashboard that gets renamed in
# the UI updates its existing file rather than spawning a new one.
declare -A UID_PATH
while IFS= read -r f; do
    u="$(jq -r '.uid // empty' "$f" 2>/dev/null || true)"
    if [[ -z "$u" ]]; then
        echo "WARNING: no uid, ignoring: ${f#"${SCRIPT_DIR}"/}" >&2
        continue
    fi
    if [[ -n "${UID_PATH[$u]:-}" ]]; then
        echo "ERROR: uid '${u}' claimed by two files:" >&2
        echo "  ${UID_PATH[$u]#"${SCRIPT_DIR}"/}" >&2
        echo "  ${f#"${SCRIPT_DIR}"/}" >&2
        exit 1
    fi
    UID_PATH[$u]="$f"
done < <(find "${DASH_DIR}" "${VENDOR_DIR}" -name '*.json' 2>/dev/null | sort)

# ── Folder uid -> directory slug ────────────────────────────────────
echo "==> Fetching folders from ${GRAFANA_URL}..."
FOLDERS="$(api "/apis/folder.grafana.app/v1beta1/namespaces/${NS}/folders")"
declare -A FOLDER_SLUG
while IFS=$'\t' read -r fuid ftitle; do
    FOLDER_SLUG[$fuid]="$(slugify "${ftitle}")"
done < <(echo "${FOLDERS}" \
    | jq -r '.items[] | [.metadata.name, .spec.title] | @tsv')
# Dashboards at the root have no folder annotation. Bash rejects an empty
# associative-array subscript, so root gets an explicit sentinel key.
ROOT_KEY="__root__"
FOLDER_SLUG[$ROOT_KEY]="general"

echo "==> Fetching dashboards..."
LIST="$(api "/apis/dashboard.grafana.app/v1beta1/namespaces/${NS}/dashboards")"
COUNT="$(echo "${LIST}" | jq '.items | length')"
echo "    Found ${COUNT} dashboard(s)."

DRIFT=0
NEW=0

while IFS=$'\t' read -r uid title folder_uid managed; do
    # v1beta1 always renders the classic schema, whatever is stored.
    api "/apis/dashboard.grafana.app/v1beta1/namespaces/${NS}/dashboards/${uid}" \
        | jq --arg uid "${uid}" '.spec + {uid: $uid}' \
        | normalize > "${WORK}/live.json"

    [[ -z "${folder_uid}" ]] && folder_uid="${ROOT_KEY}"
    slug="${FOLDER_SLUG[$folder_uid]:-}"
    if [[ -z "${slug}" ]]; then
        echo "    ERROR: ${title} (${uid}) is in unknown folder" >&2
        echo "           uid '${folder_uid}'." >&2
        DRIFT=1
        continue
    fi

    target="${UID_PATH[$uid]:-}"

    if [[ -z "${target}" ]]; then
        # Not tracked yet. File-provisioned dashboards belong in
        # dashboards/, anything else is third-party and goes to vendor/.
        if [[ "${managed}" == "classic-file-provisioning" ]]; then
            target="${DASH_DIR}/${slug}/$(slugify "${title}").json"
        else
            target="${VENDOR_DIR}/${slug}/$(slugify "${title}").json"
        fi
        NEW=$((NEW + 1))
        if [[ "${MODE}" == "check" ]]; then
            echo "    UNTRACKED  ${title}"
            echo "               would create ${target#"${SCRIPT_DIR}"/}"
            DRIFT=1
            continue
        fi
        mkdir -p "$(dirname "${target}")"
    fi

    if [[ -f "${target}" ]] \
        && normalize < "${target}" | diff -q - "${WORK}/live.json" >/dev/null
    then
        continue
    fi

    DRIFT=1
    rel="${target#"${SCRIPT_DIR}"/}"
    if [[ "${MODE}" == "check" ]]; then
        n="$( { normalize < "${target}" 2>/dev/null || true; } \
              | diff - "${WORK}/live.json" | grep -c '^[<>]' || true)"
        echo "    DRIFTED    ${rel}  (${n} lines)"
    else
        cp "${WORK}/live.json" "${target}"
        echo "    UPDATED    ${rel}"
    fi
    # Root dashboards must emit the sentinel, not an empty field: tab is
    # IFS whitespace, so bash collapses "a\t\tb" into two fields and every
    # column after the gap shifts left.
done < <(echo "${LIST}" | jq -r --arg root "__root__" '
    .items[] | [
        .metadata.name,
        .spec.title,
        ((.metadata.annotations["grafana.app/folder"] // "")
         | if . == "" then $root else . end),
        (.metadata.annotations["grafana.app/managedBy"] // "unmanaged")
    ] | @tsv')

# ── Files in the repo with no live counterpart ──────────────────────
LIVE_UIDS="$(echo "${LIST}" | jq -r '.items[].metadata.name' | sort)"
for u in "${!UID_PATH[@]}"; do
    if ! grep -qxF "${u}" <<<"${LIVE_UIDS}"; then
        echo "    ORPHANED   ${UID_PATH[$u]#"${SCRIPT_DIR}"/}"
        echo "               uid '${u}' is not in Grafana; run ./deploy.sh"
        echo "               or delete the file."
        DRIFT=1
    fi
done

echo ""
if [[ "${MODE}" == "check" ]]; then
    if [[ "${DRIFT}" -eq 0 ]]; then
        echo "==> In sync."
        exit 0
    fi
    echo "==> Drift detected. Run --pull to adopt Grafana's state," >&2
    echo "    or --push to overwrite it from the repo." >&2
    exit 1
fi

echo "==> Pull complete."
if [[ "${NEW}" -gt 0 ]]; then
    echo "    ${NEW} new dashboard(s) written. If any landed under"
    echo "    vendor/, add an entry to ${MANIFEST#"${SCRIPT_DIR}"/}"
    echo "    and a provider to provisioning/dashboards/dashboards.yaml."
fi
echo "    Review with: git diff"
