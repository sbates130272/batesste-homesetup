#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Deploy zot, the OCI registry for the home LAN.
#
# Run this on the host that is to BE the registry. It defaults to
# nothing host-specific -- snoc-strix is where it runs today only
# because that is the box with the disk, and moving the registry is a
# matter of running this script somewhere else and repointing the
# clients. The one place a hostname is written down is
# ../prometheus/targets/zot.json, which says who to scrape.
#
# A bare-metal install, deliberately. zot is a single static Go binary
# under systemd: no container runtime in the path of the thing that
# stores the containers, no database, no Redis, nothing to bootstrap
# before the registry can serve its own bootstrap images.
#
# Idempotent. A run that finds the right binary, the right config and
# a healthy service restarts nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned, and verified against checksums.sha256 in this directory
# rather than against anything fetched at run time. Moving this line
# is how upgrades happen -- in a commit, with the digests updated in
# the same diff.
ZOT_VERSION="${ZOT_VERSION:-v2.1.22}"

# Everything below is overridable from the environment, which is what
# makes "put the registry somewhere else" a one-line change.
ZOT_ADDRESS="${ZOT_ADDRESS:-0.0.0.0}"
ZOT_PORT="${ZOT_PORT:-8080}"
ZOT_DATA="${ZOT_DATA:-/var/lib/zot}"
ZOT_ETC="${ZOT_ETC:-/etc/zot}"
ZOT_BIN="${ZOT_BIN:-/usr/local/bin/zot}"
ZLI_BIN="${ZLI_BIN:-/usr/local/bin/zli}"
ZOT_USER="${ZOT_USER:-zot}"

UNIT_PATH="/etc/systemd/system/zot.service"
SECRETS="${SCRIPT_DIR}/zot.secrets"
HTPASSWD="${ZOT_ETC}/htpasswd"
SESSION_KEYS="${ZOT_ETC}/session-keys.json"
CONFIG="${ZOT_ETC}/config.json"
RELEASE_URL="https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}"

# The accounts config.json.in names. Kept here as a list so the
# htpasswd generation and the secrets file cannot drift apart: a user
# added to one and not the other is a 401 nobody can explain.
ZOT_ACCOUNTS=(admin ci metrics)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--with-cve] [--no-start] [--force-download]

Deploy zot ${ZOT_VERSION}: the binary, the system user, the config,
the credentials and the systemd unit.

Run this on the host that is to be the registry. Clients then pull
from http://<this-host>:${ZOT_PORT}/ -- see README.md for the
/etc/docker/daemon.json line they need.

Options:
  --dry-run         Show what would change without writing anything.
  --with-cve        Turn on Trivy vulnerability scanning. Off by
                    default: it downloads a vulnerability database
                    from ghcr.io on start and every 24h after, which
                    is slow behind the corporate egress and needs the
                    memory ceiling in zot.service raised.
  --no-start        Install everything but leave systemd alone.
  --force-download  Re-fetch the binaries even if the installed ones
                    already match the pinned digests.
  -h, --help        Show this help message.

Environment (all optional):
  ZOT_VERSION  Release tag to install.          [${ZOT_VERSION}]
  ZOT_ADDRESS  Address to bind.                 [${ZOT_ADDRESS}]
  ZOT_PORT     Port to bind.                    [${ZOT_PORT}]
  ZOT_DATA     Blob store.                      [${ZOT_DATA}]
EOF
    exit 0
}

DRY_RUN=false
WITH_CVE=false
START=true
FORCE_DOWNLOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true;        shift ;;
        --with-cve)       WITH_CVE=true;       shift ;;
        --no-start)       START=false;         shift ;;
        --force-download) FORCE_DOWNLOAD=true; shift ;;
        -h|--help)        usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi
}

# One EXIT trap for the whole script, with everything that needs
# removing pushed onto a list. Setting `trap ... EXIT` in two places
# does not add a second handler, it replaces the first -- which is how
# a temp file holding a rendered config quietly stopped being cleaned
# up the moment a second trap was added further down.
CLEANUP_FILES=()
cleanup() { [[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}"; return 0; }
trap cleanup EXIT

# Takes the NAME of the variable to populate rather than printing the
# path, because the obvious `f="$(mktemp_tracked)"` spelling cannot
# work: command substitution runs the function in a subshell, so the
# CLEANUP_FILES entry is appended to a copy that is thrown away the
# moment it returns. Every file was then leaked -- including the curl
# config below, which holds a password in cleartext.
mktemp_tracked() {   # mktemp_tracked <varname>
    local -n _mt_out="$1"
    _mt_out="$(mktemp)"
    chmod 600 "${_mt_out}"
    CLEANUP_FILES+=("${_mt_out}")
}

# ── Preconditions ────────────────────────────────────────────────

echo "==> Checking prerequisites..."

for c in curl jq openssl sha256sum ss systemctl; do
    command -v "$c" >/dev/null || {
        echo "Error: ${c} is required and was not found in PATH." >&2
        exit 1
    }
done
echo "    curl, jq, openssl, sha256sum, ss, systemctl: ok"

# The full zot build is 226 MB on its own and the blob store is the
# whole point of the exercise, so a tight filesystem here is worth
# refusing over rather than discovering during a push.
avail_gb="$(df -BG --output=avail "$(dirname "${ZOT_DATA}")" | tail -1 | tr -dc '0-9')"
if [[ "${avail_gb}" -lt 5 ]]; then
    echo "Error: only ${avail_gb}G free on $(dirname "${ZOT_DATA}")." >&2
    exit 1
elif [[ "${avail_gb}" -lt 20 ]]; then
    echo "    WARNING: only ${avail_gb}G free for the blob store." >&2
else
    echo "    disk: ${avail_gb}G free for ${ZOT_DATA}"
fi

# Checked before anything is installed. A port already held by
# something else means a unit that starts, fails to bind and restarts
# forever, and the failure reads like a zot problem rather than a
# collision with whatever got there first.
#
# Two mistakes were made here and both are worth the comment.
#
# The first: this was `ss -tln | awk ... | grep -q`, which under
# `set -o pipefail` is a guard that fires exactly backwards. `grep -q`
# exits the moment it matches, awk is killed by SIGPIPE, and the
# pipeline's status becomes 141 rather than grep's 0 -- so the `if`
# evaluated FALSE precisely when a listener WAS found. Whether awk had
# finished writing first came down to how many sockets the host had:
# measured dead on snoc-beelink (185 listeners, four of them on the
# port under test, reported "free"), accidentally working on
# snoc-strix (41). Hence the variable: no pipe, no signal, no luck.
#
# The second: the old check asked "is the zot unit active?" and waved
# the port through if it was. That is the wrong question -- a running
# zot on :8080 would wave through a collision on :9090. The question
# is whether the process holding THIS port is ours.
echo "==> Checking the port..."
listeners="$(sudo ss -tlnp 2>/dev/null || true)"
port_line="$(awk -v p=":${ZOT_PORT}\$" 'NR > 1 && $4 ~ p' <<<"${listeners}" || true)"

if [[ -z "${port_line}" ]]; then
    echo "    port ${ZOT_PORT}: free"
elif grep -q '"zot"' <<<"${port_line}"; then
    echo "    port ${ZOT_PORT}: held by zot already"
else
    echo "Error: something is already listening on :${ZOT_PORT}" >&2
    echo "       and it is not zot:" >&2
    sed 's/^/       /' <<<"${port_line}" >&2
    echo "       Set ZOT_PORT to something else, or stop it." >&2
    exit 1
fi

# ── Credentials ──────────────────────────────────────────────────
#
# Generated on a first run, never regenerated, never echoed. The file
# is the only copy: read it with an editor when you need the admin
# password, rather than asking this script to print it into a
# terminal and a shell history.

echo "==> Checking credentials..."

if [[ ! -f "${SECRETS}" ]]; then
    if $DRY_RUN; then
        echo "[dry-run] would generate ${SECRETS} with three passwords"
    else
        # The umask is scoped to the subshell deliberately: set at this
        # level it would leak into every later redirect in the script,
        # which is the kind of action-at-a-distance that makes a file
        # mode somewhere else depend on whether this branch ran.
        (
            umask 077
            {
                echo "# Generated by deploy.sh on $(date -Is)."
                echo "# See zot.secrets.example for what each account is for."
                echo
                for acct in "${ZOT_ACCOUNTS[@]}"; do
                    printf '%s="%s"\n' \
                        "ZOT_${acct^^}_PASSWORD" "$(openssl rand -base64 24)"
                done
            } >"${SECRETS}"
        )
        chmod 600 "${SECRETS}"
        echo "    generated ${SECRETS} (mode 600, untracked, not printed)"
    fi
else
    echo "    ${SECRETS} (exists)"
fi

if ! $DRY_RUN; then
    # shellcheck disable=SC1090
    source "${SECRETS}"
    for acct in "${ZOT_ACCOUNTS[@]}"; do
        var="ZOT_${acct^^}_PASSWORD"
        if [[ -z "${!var:-}" ]]; then
            echo "Error: ${var} is empty in ${SECRETS}." >&2
            echo "       Set it, or delete the file and re-run to" >&2
            echo "       have all three generated." >&2
            exit 1
        fi
    done
    echo "    all ${#ZOT_ACCOUNTS[@]} accounts have passwords"
fi

# ── Binaries ─────────────────────────────────────────────────────
#
# Verified against the digests committed in checksums.sha256, not
# against a checksum file downloaded next to the binary -- that would
# only prove the two came from the same place.

verify() {   # verify <file> <asset-name>
    local file="$1" asset="$2" want have
    want="$(awk -v a="${asset}" '$2 == a { print $1 }' \
        "${SCRIPT_DIR}/checksums.sha256")"
    if [[ -z "${want}" ]]; then
        echo "Error: no digest for ${asset} in checksums.sha256." >&2
        echo "       Did ZOT_VERSION move without the digests?" >&2
        return 1
    fi
    have="$(sha256sum "${file}" | cut -d' ' -f1)"
    [[ "${have}" == "${want}" ]]
}

# Set by install_binary when it replaces something. An upgraded zot
# on disk is still the old zot in memory until the unit is restarted,
# so this feeds the restart decision further down.
binary_changed=false

install_binary() {   # install_binary <asset-name> <dest>
    local asset="$1" dest="$2" tmp

    if ! $FORCE_DOWNLOAD && [[ -x "${dest}" ]] && verify "${dest}" "${asset}"; then
        echo "    ${dest} (already ${ZOT_VERSION})"
        return 0
    fi

    if $DRY_RUN; then
        echo "[dry-run] would download ${asset} and install it to ${dest}"
        return 0
    fi

    # Downloaded next to the destination rather than into /tmp: these
    # are 226 MB, and /tmp here is small enough and shared enough that
    # putting a quarter of a gigabyte in it twice a year is rude. The
    # cleanup is explicit rather than a RETURN trap -- a RETURN trap
    # set inside a function outlives it and then fires on unrelated
    # returns, which is a worse problem than the one it solves.
    tmp="$(mktemp "$(dirname "${dest}")/.$(basename "${dest}").XXXXXX" 2>/dev/null)" ||
        tmp="$(sudo mktemp "$(dirname "${dest}")/.$(basename "${dest}").XXXXXX")"
    sudo chown "$(id -u):$(id -g)" "${tmp}"

    echo "    downloading ${asset}..."
    if ! curl -fsSL --retry 3 -o "${tmp}" "${RELEASE_URL}/${asset}"; then
        sudo rm -f "${tmp}"
        echo "Error: could not download ${asset} from" >&2
        echo "       ${RELEASE_URL}" >&2
        exit 1
    fi

    if ! verify "${tmp}" "${asset}"; then
        sudo rm -f "${tmp}"
        echo "Error: ${asset} does not match the digest in" >&2
        echo "       checksums.sha256. Refusing to install it." >&2
        exit 1
    fi
    echo "    digest: ok"

    # install(1) to the final path: it replaces the inode rather than
    # writing through it, so a running zot keeps the binary it was
    # started with instead of having it rewritten underneath.
    sudo install -m 755 -o root -g root "${tmp}" "${dest}"
    sudo rm -f "${tmp}"
    binary_changed=true
    echo "    ${dest}"
}

echo "==> Installing binaries (${ZOT_VERSION})..."

# checksums.sha256 is keyed by asset name, and the asset names carry
# no version. Without this check, bumping ZOT_VERSION and forgetting
# the digests means the installed old binary still matches, and the
# script cheerfully reports "already <new version>" having installed
# nothing at all.
pinned_version="$(awk '$1 == "version" { print $2 }' \
    "${SCRIPT_DIR}/checksums.sha256")"
if [[ "${pinned_version}" != "${ZOT_VERSION}" ]]; then
    echo "Error: ZOT_VERSION is ${ZOT_VERSION} but checksums.sha256" >&2
    echo "       pins digests for ${pinned_version:-nothing}." >&2
    echo "       Update the digests before moving the version -- the" >&2
    echo "       command to fetch them is in that file's header." >&2
    exit 1
fi
install_binary zot-linux-amd64 "${ZOT_BIN}"
install_binary zli-linux-amd64 "${ZLI_BIN}"

# ── User and directories ─────────────────────────────────────────

echo "==> Checking the service account..."
if id "${ZOT_USER}" &>/dev/null; then
    echo "    user ${ZOT_USER} (exists)"
else
    run sudo useradd --system --no-create-home \
        --home-dir "${ZOT_DATA}" --shell /usr/sbin/nologin "${ZOT_USER}"
    $DRY_RUN || echo "    user ${ZOT_USER} (created)"
fi

run sudo install -d -m 0755 -o "${ZOT_USER}" -g "${ZOT_USER}" "${ZOT_DATA}"
# Config and credentials are root-owned and group-readable by zot:
# the service reads them, and nothing it runs should be able to
# rewrite its own access control.
run sudo install -d -m 0750 -o root -g "${ZOT_USER}" "${ZOT_ETC}"
echo "    ${ZOT_DATA}, ${ZOT_ETC}"

# ── Session keys ─────────────────────────────────────────────────
#
# Without these zot generates a random cookie key at every start and
# says so in one warning line, which means every restart silently logs
# everyone out of the web UI. Rare, confusing, and trivially avoided.
#
# Generated once and then left alone for the same reason: rewriting
# them is exactly the thing being prevented. They are not in
# zot.secrets because nothing human ever needs to read them -- losing
# them costs a re-login, not access.
#
# The lengths are not arbitrary. zot hands these to gorilla's
# securecookie as raw bytes, not decoded base64, and that wants a
# 32- or 64-byte hash key and a 16, 24 or 32-byte block key. `openssl
# rand -base64 48` is 64 characters and `-base64 24` is 32, which is
# also exactly what upstream's examples/sessionKeys.json ships.
#
# This runs before the config is installed: the config names the file,
# and zot refuses to start when a named secret file is missing.

echo "==> Checking session keys..."

if sudo test -s "${SESSION_KEYS}"; then
    echo "    session-keys.json (exists)"
elif $DRY_RUN; then
    echo "[dry-run] would generate ${SESSION_KEYS}"
else
    mktemp_tracked tmp_keys
    jq -n --arg h "$(openssl rand -base64 48 | tr -d '\n')" \
          --arg e "$(openssl rand -base64 24 | tr -d '\n')" \
          '{hashKey: $h, encryptKey: $e}' >"${tmp_keys}"
    sudo install -m 0640 -o root -g "${ZOT_USER}" "${tmp_keys}" "${SESSION_KEYS}"
    rm -f "${tmp_keys}"
    echo "    ${SESSION_KEYS} (generated)"
fi

# ── Config ───────────────────────────────────────────────────────
#
# config.json.in is a valid zot config, not a template full of
# placeholders -- jq overlays the handful of values this script owns.
# That way the committed file can be read, diffed and fed to zot
# directly when something needs debugging.

echo "==> Rendering the config..."

config_jq='
  .http.address = $addr
| .http.port = $port
| .storage.rootDirectory = $root
| .http.auth.htpasswd.path = $htpasswd
| .http.auth.sessionKeysFile = $sessionkeys
'
if $WITH_CVE; then
    config_jq+='| .extensions.search.cve = { updateInterval: "24h" }'
else
    config_jq+='| del(.extensions.search.cve)'
fi

rendered="$(jq -S \
    --arg addr "${ZOT_ADDRESS}" \
    --arg port "${ZOT_PORT}" \
    --arg root "${ZOT_DATA}" \
    --arg htpasswd "${HTPASSWD}" \
    --arg sessionkeys "${SESSION_KEYS}" \
    "${config_jq}" "${SCRIPT_DIR}/config.json.in")"

if sudo test -r "${CONFIG}" &&
   [[ "$(sudo jq -S . "${CONFIG}" 2>/dev/null || true)" == "${rendered}" ]]; then
    echo "    config.json (unchanged)"
    config_changed=false
else
    config_changed=true
    if $DRY_RUN; then
        echo "[dry-run] would install ${CONFIG}"
    else
        mktemp_tracked tmp_cfg
        printf '%s\n' "${rendered}" >"${tmp_cfg}"
        sudo install -m 0640 -o root -g "${ZOT_USER}" "${tmp_cfg}" "${CONFIG}"
        echo "    ${CONFIG}"
    fi
fi

# ── Credentials file ─────────────────────────────────────────────
#
# SHA-512 crypt ($6$) rather than bcrypt, because openssl can produce
# it and apache2-utils is not installed on this host. zot accepts
# bcrypt, $5$ and $6$ and nothing else -- an apr1 ($apr1$) hash, which
# is what `openssl passwd` gives you without -6, is silently rejected
# at login with "unsupported hash type" in the log and a bare 401 at
# the client.
#
# The file is rewritten in full on every run where a password changed.
# zot watches it with inotify and reloads in place, so this does not
# need a restart and does not interrupt a push in flight.
#
# Passwords reach openssl on stdin, never in argv. An argument is
# visible in /proc/<pid>/cmdline to every local account for as long as
# the process lives, which for three hashes on each run is three
# chances to lose the registry's credentials to anyone with a shell on
# the box. `-stdin` produces a byte-identical hash; this was checked.

echo "==> Checking ${HTPASSWD}..."

if $DRY_RUN; then
    echo "[dry-run] would write ${HTPASSWD} for: ${ZOT_ACCOUNTS[*]}"
else
    # Each run would otherwise produce new salts and therefore new
    # hashes for unchanged passwords, which looks like a change and
    # triggers a pointless reload. So: keep an existing line when it
    # still verifies against the password in zot.secrets.
    htpasswd_new=""
    for acct in "${ZOT_ACCOUNTS[@]}"; do
        var="ZOT_${acct^^}_PASSWORD"
        existing="$(sudo awk -F: -v u="${acct}" \
            '$1 == u { print $2 }' "${HTPASSWD}" 2>/dev/null || true)"

        keep=false
        # A $6$ line is $6$[rounds=N$]salt$hash. Taking field 3 blind
        # picks up the rounds= parameter as if it were the salt on a
        # hash written with one, so the comparison never matches and
        # the line is needlessly rewritten.
        if [[ "${existing}" =~ ^\$6\$(rounds=[0-9]+\$)?([^$]+)\$ ]]; then
            salt="${BASH_REMATCH[2]}"
            rounds="${BASH_REMATCH[1]:-}"
            if [[ "$(printf '%s' "${!var}" |
                     openssl passwd -6 -salt "${rounds}${salt}" -stdin)" \
                  == "${existing}" ]]; then
                keep=true
            fi
        fi

        if $keep; then
            htpasswd_new+="${acct}:${existing}"$'\n'
        else
            htpasswd_new+="${acct}:$(printf '%s' "${!var}" |
                openssl passwd -6 -stdin)"$'\n'
        fi
    done

    # printf, not $(sudo cat ...). Command substitution strips every
    # trailing newline from what it captures, and htpasswd_new ends in
    # one by construction -- so the two could never be equal and this
    # branch was dead code that rewrote the file on every single run
    # while printing "unchanged" only in a case that cannot happen.
    # The `; printf x` must be INSIDE the same substitution as the
    # cat: stripping happens once, at the end of the whole thing, so
    # the sentinel is what the newline hides behind.
    htpasswd_now="$(sudo cat "${HTPASSWD}" 2>/dev/null; printf x)"
    if [[ "${htpasswd_now%x}" == "${htpasswd_new}" ]]; then
        echo "    htpasswd (unchanged)"
    else
        mktemp_tracked tmp_ht
        printf '%s' "${htpasswd_new}" >"${tmp_ht}"
        sudo install -m 0640 -o root -g "${ZOT_USER}" "${tmp_ht}" "${HTPASSWD}"
        rm -f "${tmp_ht}"
        echo "    htpasswd: ${#ZOT_ACCOUNTS[@]} accounts written"
    fi
fi

# ── Unit ─────────────────────────────────────────────────────────

echo "==> Checking the systemd unit..."

# ReadWritePaths is the one line in zot.service that has to follow
# ZOT_DATA: ProtectSystem=strict makes everything else read-only, so
# a data directory the unit does not name is a registry that cannot
# write a blob.
unit_rendered="$(sed "s|^ReadWritePaths=.*|ReadWritePaths=${ZOT_DATA}|" \
    "${SCRIPT_DIR}/zot.service")"

if [[ "$(cat "${UNIT_PATH}" 2>/dev/null || true)" == "${unit_rendered}" ]]; then
    echo "    zot.service (unchanged)"
    unit_changed=false
else
    unit_changed=true
    if $DRY_RUN; then
        echo "[dry-run] would install ${UNIT_PATH} and daemon-reload"
    else
        mktemp_tracked tmp_unit
        printf '%s' "${unit_rendered}" >"${tmp_unit}"
        sudo install -m 0644 -o root -g root "${tmp_unit}" "${UNIT_PATH}"
        rm -f "${tmp_unit}"
        sudo systemctl daemon-reload
        echo "    ${UNIT_PATH}"
    fi
fi

# ── Start ────────────────────────────────────────────────────────

if ! $START; then
    echo "==> --no-start given; systemd not touched."
    exit 0
fi

echo "==> Starting zot..."
run sudo systemctl enable zot

if $DRY_RUN; then
    echo "[dry-run] would start or restart zot and verify it"
    exit 0
fi

# Whether the RUNNING process predates the binary on disk, rather than
# whether this particular run was the one that replaced it. Those are
# different questions, and only the first one is the one that matters:
# a run that installed the binary and then stopped -- --no-start, a
# Ctrl-C, a failure between the two -- leaves a new zot on disk and an
# old zot serving, and the next run finds the digest already correct,
# sets binary_changed=false and reports "nothing changed" over the top
# of a registry still running the version it was supposed to leave.
stale_process=false
if systemctl is-active --quiet zot; then
    started="$(systemctl show zot -p ExecMainStartTimestampMonotonic --value)"
    # Monotonic microseconds since boot, compared against the binary's
    # mtime expressed the same way. Wall-clock would be wrong across a
    # clock step and unavailable in the one format both sides share.
    now_mono="$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)"
    bin_age="$(( $(date +%s) - $(stat -c %Y "${ZOT_BIN}") ))"
    bin_mono="$(( now_mono - bin_age * 1000000 ))"
    if [[ -n "${started}" && "${started}" -lt "${bin_mono}" ]]; then
        stale_process=true
    fi
fi

if ! systemctl is-active --quiet zot; then
    sudo systemctl start zot
elif $config_changed || $unit_changed || $binary_changed || $stale_process; then
    # The htpasswd file is deliberately absent from this condition --
    # zot reloads it by itself, and restarting for a credential change
    # would drop pushes for no reason. The binary is not: a replaced
    # file on disk is still the old process until this restart.
    if $stale_process && ! $binary_changed; then
        echo "    restarting (running process predates ${ZOT_BIN})"
    else
        echo "    restarting (binary, config or unit changed)"
    fi
    sudo systemctl restart zot
else
    echo "    already running, nothing changed"
fi

# ── Verify ───────────────────────────────────────────────────────

echo "==> Verifying..."

probe="127.0.0.1"
[[ "${ZOT_ADDRESS}" != "0.0.0.0" ]] && probe="${ZOT_ADDRESS}"

code=""
for _ in $(seq 1 60); do
    # /v2/ rather than /, which the UI extension serves: a 200 from the
    # UI says a web server is up, a 200 from /v2/ says the registry API
    # is. Anonymous read is allowed, so this needs no credentials; if
    # that policy is ever removed this turns into a 401, which is still
    # proof the API is answering.
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        "http://${probe}:${ZOT_PORT}/v2/" || true)"
    [[ "${code}" == "200" || "${code}" == "401" ]] && break
    sleep 1
done

if [[ "${code}" != "200" && "${code}" != "401" ]]; then
    echo "Error: the registry API did not answer on" >&2
    echo "       http://${probe}:${ZOT_PORT}/v2/ (last status: ${code:-none})" >&2
    echo "       Check: journalctl -u zot -n 50" >&2
    exit 1
fi
echo "    registry API on :${ZOT_PORT}: ${code}"

# Credentials go to curl in a mode 600 config file rather than in -u,
# for the same reason the hashes are produced from stdin: an argument
# is readable in /proc/<pid>/cmdline by every local account while the
# process runs.
mktemp_tracked curl_auth

curl_as() {   # curl_as <account> <password> <url...>
    local acct="$1" pass="$2"; shift 2
    printf 'user = "%s:%s"\n' "${acct}" "${pass}" >"${curl_auth}"
    curl -s -o /dev/null -w '%{http_code}' -K "${curl_auth}" "$@" || true
}

# The push account, checked for real. A typo in the htpasswd hash or
# an access-control policy that does not name 'ci' both produce a
# registry that looks perfectly healthy and rejects every build.
ci_code="$(curl_as ci "${ZOT_CI_PASSWORD}" "http://${probe}:${ZOT_PORT}/v2/")"
if [[ "${ci_code}" != "200" ]]; then
    echo "Error: the 'ci' account did not authenticate (${ci_code})." >&2
    echo "       Check: journalctl -u zot | grep htpasswd" >&2
    exit 1
fi
echo "    ci authentication: ok"

# Prometheus on snoc-beelink scrapes this as the 'metrics' user and
# nothing else is allowed to, so both halves are worth proving: that
# the account works, and that the endpoint is not simply open.
m_code="$(curl_as metrics "${ZOT_METRICS_PASSWORD}" \
    "http://${probe}:${ZOT_PORT}/metrics")"
if [[ "${m_code}" != "200" ]]; then
    echo "    WARNING: /metrics returned ${m_code} for the metrics user." >&2
    echo "    The Prometheus job will be down. See ../prometheus/README.md." >&2
else
    anon_code="$(curl -s -o /dev/null -w '%{http_code}' \
        "http://${probe}:${ZOT_PORT}/metrics" || true)"
    if [[ "${anon_code}" == "200" ]]; then
        echo "    WARNING: /metrics is readable anonymously." >&2
    fi
    echo "    /metrics (metrics user only): ok"
fi

host="$(hostname)"

# The canonical name is the tailnet one where there is a tailnet, and
# not the obvious <host>.local. mDNS is not uniformly available on
# this fleet -- snoc-thinkstation, a node that will certainly pull
# from here, cannot resolve a .local name at all -- and the registry
# name is not a detail a client can get wrong: it is baked into every
# image reference and must match the insecure-registries entry
# character for character. One name everywhere is worth more than a
# shorter name somewhere. See README.md, "Pointing clients at it".
canonical="${host}.local"
if command -v tailscale >/dev/null &&
   ts_name="$(tailscale status --json 2>/dev/null |
       jq -r '.Self.DNSName // "" | rtrimstr(".")')" &&
   [[ -n "${ts_name}" ]]; then
    canonical="${ts_name}"
fi

echo
echo "==> Done. zot ${ZOT_VERSION} on ${host}."
echo "    UI:       http://${canonical}:${ZOT_PORT}/"
echo "    Registry: ${canonical}:${ZOT_PORT}"
echo "    Logs:     journalctl -u zot -f"
echo
echo "    Still to do, on the CLIENTS -- this is plain HTTP, so"
echo "    Docker refuses it until it is named explicitly:"
echo
echo "      /etc/docker/daemon.json"
echo "      { \"insecure-registries\": [\"${canonical}:${ZOT_PORT}\"] }"
echo
echo "    then: sudo systemctl reload docker   (reload, not restart --"
echo "    insecure-registries is re-read on SIGHUP, so no container"
echo "    on the client has to be taken down for this)"
echo "    That is the line to put in batesste-ansible. A client with"
echo "    no MagicDNS needs an /etc/hosts entry pointing that same"
echo "    name at this box's LAN address -- the name must match the"
echo "    image tags, so do not substitute a different one. README.md"
echo "    has the podman and containerd equivalents."
