#!/usr/bin/env bash
# Deploy the computer-use sandbox: build the image, start the container,
# install the host shim, and point Hermes at it.
#
# Called by ../deploy.sh, which owns the config.yaml half of the wiring
# (cua/hermes-config.yaml, applied by apply-model-config.py). What is left
# for here is the container, the shim, and the one variable Hermes will
# only read from the environment.
#
# Idempotent throughout. The image is only rebuilt when asked, because a
# rebuild on a box with 2 GB free and a compile-free Dockerfile is several
# minutes of apt for no change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/batesste-cua-driver.dc.yml"
CONTAINER="${CUA_CONTAINER:-batesste-cua-driver}"
SHIM_SRC="${SCRIPT_DIR}/cua-driver-docker"
SHIM_DST="${SHIM_DST:-$HOME/.local/bin/cua-driver-docker}"
HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"
MANIFEST_SRC="${SCRIPT_DIR}/capability-manifest.yaml"
MANIFEST_DST="${MANIFEST_DST:-$HOME/.hermes/cua-capability-manifest.yaml}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--build] [--dry-run] [--no-start]

Build/start the cua-driver desktop container and wire Hermes to it.

Options:
  --build      Rebuild the image before starting (needed after a
               Dockerfile or driver-version change).
  --dry-run    Show what would change without writing anything.
  --no-start   Install the shim and the env var, leave the container alone.
  -h, --help   Show this help message.
EOF
    exit 0
}

BUILD=false
DRY_RUN=false
START=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)    BUILD=true;   shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --no-start) START=false;  shift ;;
        -h|--help)  usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

run() {
    if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi
}

command -v docker >/dev/null || { echo "Error: docker is not installed" >&2; exit 1; }

echo "==> Installing host shim..."
if cmp -s "${SHIM_SRC}" "${SHIM_DST}"; then
    echo "    $(basename "${SHIM_DST}") (unchanged)"
else
    echo "    ${SHIM_DST}"
    run mkdir -p "$(dirname "${SHIM_DST}")"
    run install -m 0755 "${SHIM_SRC}" "${SHIM_DST}"
fi

# Installed even though permission_mode is `standard` and nothing reads it
# today -- see the header of capability-manifest.yaml. Keeping the install
# here means the file is already in place, already correct, on the day the
# driver moves off `docker exec` and the mode can be flipped.
echo "==> Installing the capability manifest..."
if cmp -s "${MANIFEST_SRC}" "${MANIFEST_DST}"; then
    echo "    $(basename "${MANIFEST_DST}") (unchanged)"
else
    echo "    ${MANIFEST_DST}"
    run install -m 0644 "${MANIFEST_SRC}" "${MANIFEST_DST}"
fi

# Hermes resolves the driver from the environment, never from config.yaml,
# so this is the one setting that has to live in .env. Written with the
# same read-modify-write shape sync-lemonade-key.sh uses, and for the same
# reason: .env also holds seventeen credentials' worth of neighbours that a
# clumsy rewrite would take with it.
echo "==> Pointing Hermes at the shim..."
if [[ ! -w "${HERMES_ENV}" ]]; then
    echo "Error: ${HERMES_ENV} not writable -- is Hermes installed?" >&2
    exit 1
fi
if grep -qx "HERMES_CUA_DRIVER_CMD=${SHIM_DST}" "${HERMES_ENV}"; then
    echo "    HERMES_CUA_DRIVER_CMD (unchanged)"
elif $DRY_RUN; then
    echo "[dry-run] set HERMES_CUA_DRIVER_CMD=${SHIM_DST} in ${HERMES_ENV}"
else
    tmp=$(mktemp); chmod 600 "$tmp"
    awk -v v="${SHIM_DST}" \
        'index($0, "HERMES_CUA_DRIVER_CMD=") == 1 { next } { print } \
         END { print "HERMES_CUA_DRIVER_CMD=" v }' "${HERMES_ENV}" > "$tmp"
    cat "$tmp" > "${HERMES_ENV}"
    rm -f "$tmp"
    chmod 600 "${HERMES_ENV}"
    echo "    HERMES_CUA_DRIVER_CMD=${SHIM_DST}"
fi

if $BUILD; then
    echo "==> Building image..."
    run docker compose -f "${COMPOSE_FILE}" build
fi

if $START; then
    echo "==> Starting container..."
    run docker compose -f "${COMPOSE_FILE}" up -d
fi

if $DRY_RUN; then
    echo "==> Dry run complete. Nothing was written."
    exit 0
fi

if ! $START; then
    echo "==> Shim installed; container not touched (--no-start)."
    exit 0
fi

# The container reports healthy well before the desktop is usable: Xvfb,
# the session bus and the AT-SPI bus each have to come up before a capture
# returns anything addressable, and that is the state Hermes cares about.
echo "==> Waiting for the driver..."
for _ in $(seq 1 60); do
    if "${SHIM_DST}" status >/dev/null 2>&1; then break; fi
    sleep 1
done

echo "==> Verifying..."
STATUS=0
"${SHIM_DST}" status | sed 's/^/    /' || STATUS=1
"${SHIM_DST}" --version | sed 's/^/    /' || STATUS=1

if [[ ${STATUS} -ne 0 ]]; then
    echo "==> The driver is not answering. Check:"
    echo "    docker logs ${CONTAINER}"
    exit 1
fi

echo "==> Done. Verify the full path from Hermes with:"
echo "    hermes computer-use doctor"
echo "    hermes -t computer_use -z 'Take a screenshot and tell me what you see'"
echo "    watch it work: http://127.0.0.1:6080/vnc.html"
