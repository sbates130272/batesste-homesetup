#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_ETC="/etc/nginx"
NGINX_AVAIL="${NGINX_ETC}/sites-available"
NGINX_ENABLED="${NGINX_ETC}/sites-enabled"
SYSCTL_CONF="99-nginx-nonlocal-bind.conf"
DROPIN_DIR="/etc/systemd/system/nginx.service.d"

# Sites to symlink into sites-enabled. nginx.conf includes
# "sites-enabled/*.site", so the .site suffix is load-bearing: a link
# without it is silently never loaded. Any link in sites-enabled that
# is not derived from this list is removed -- deployment is a mirror.
#
# "hermes" is intentionally absent. tailscale serve reaches hermes
# directly at 127.0.0.1:8787, bypassing nginx, so the vhost is unused.
# It is kept in sites-available for reference only.
ENABLED_SITES=(funnel-gateway prometheus hermes-dashboard)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--no-boot-fix] [--dry-run]

Deploy the nginx configuration from this repository to
${NGINX_ETC}, and install the boot-race fix that stops nginx
failing to bind 10.0.0.15 before WiFi is up.

The whole tree is staged and validated with "nginx -t" before
anything under ${NGINX_ETC} is touched.

Options:
  --no-boot-fix  Skip the sysctl and systemd drop-in; deploy
                 vhost configuration only.
  --dry-run      Show what would be done without changing
                 anything.
  -h, --help     Show this help message.
EOF
    exit 0
}

BOOT_FIX=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-boot-fix) BOOT_FIX=false; shift ;;
        --dry-run)     DRY_RUN=true;   shift ;;
        -h|--help)     usage ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

if ! command -v nginx &>/dev/null; then
    echo "Error: nginx not found in PATH." >&2
    exit 1
fi

# Validate the repo tree in isolation. The includes in nginx.conf are
# absolute (/etc/nginx/...), so they are rewritten to point at the
# staging directory -- otherwise "nginx -t" would happily validate the
# staged nginx.conf against the *live* vhosts. Paths to things we do
# not version (modules-enabled, the htpasswd files, the letsencrypt
# certificates) are left absolute on purpose.
echo "==> Staging repo tree for validation..."
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/conf.d" "${STAGE}/sites-available" \
    "${STAGE}/sites-enabled"
cp "${SCRIPT_DIR}"/conf.d/*.conf          "${STAGE}/conf.d/"
cp "${SCRIPT_DIR}"/sites-available/*      "${STAGE}/sites-available/"
for site in "${ENABLED_SITES[@]}"; do
    ln -s "${STAGE}/sites-available/${site}" \
        "${STAGE}/sites-enabled/${site}.site"
done
sed -e "s#include ${NGINX_ETC}/conf.d/#include ${STAGE}/conf.d/#" \
    -e "s#include ${NGINX_ETC}/sites-enabled/#include ${STAGE}/sites-enabled/#" \
    "${SCRIPT_DIR}/nginx.conf" > "${STAGE}/nginx.conf"

echo "==> Validating with nginx -t..."
if ! sudo nginx -t -c "${STAGE}/nginx.conf"; then
    echo "Error: config validation failed." >&2
    exit 1
fi
echo "    Config is valid."

echo "==> Backing up current nginx.conf..."
if [[ -f "${NGINX_ETC}/nginx.conf" ]]; then
    run sudo cp "${NGINX_ETC}/nginx.conf" \
        "${NGINX_ETC}/nginx.conf.bak"
fi

echo "==> Deploying nginx.conf..."
run sudo cp "${SCRIPT_DIR}/nginx.conf" "${NGINX_ETC}/nginx.conf"

echo "==> Deploying conf.d..."
for f in "${SCRIPT_DIR}"/conf.d/*.conf; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    echo "    ${name}"
    run sudo cp "$f" "${NGINX_ETC}/conf.d/${name}"
done

echo "==> Deploying sites-available..."
run sudo mkdir -p "${NGINX_AVAIL}" "${NGINX_ENABLED}"
for f in "${SCRIPT_DIR}"/sites-available/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    echo "    ${name}"
    run sudo cp "$f" "${NGINX_AVAIL}/${name}"
done

echo "==> Reconciling sites-enabled..."
for site in "${ENABLED_SITES[@]}"; do
    echo "    ${site}.site -> sites-available/${site}"
    run sudo ln -sfn "${NGINX_AVAIL}/${site}" \
        "${NGINX_ENABLED}/${site}.site"
done
for link in "${NGINX_ENABLED}"/*; do
    [[ -e "$link" || -L "$link" ]] || continue
    name="$(basename "$link")"
    keep=false
    for site in "${ENABLED_SITES[@]}"; do
        [[ "${name}" == "${site}.site" ]] && keep=true && break
    done
    $keep || { echo "    removing stale ${name}"
               run sudo rm -f "$link"; }
done

if $BOOT_FIX; then
    echo "==> Installing ${SYSCTL_CONF}..."
    run sudo cp "${SCRIPT_DIR}/sysctl.d/${SYSCTL_CONF}" \
        "/etc/sysctl.d/${SYSCTL_CONF}"
    run sudo sysctl --system >/dev/null

    echo "==> Installing nginx.service drop-in..."
    run sudo mkdir -p "${DROPIN_DIR}"
    run sudo cp \
        "${SCRIPT_DIR}/systemd/nginx.service.d/override.conf" \
        "${DROPIN_DIR}/override.conf"
    run sudo systemctl daemon-reload
else
    echo "==> Skipping boot fix (--no-boot-fix)."
fi

echo "==> Reloading nginx..."
run sudo systemctl reload nginx

echo "==> Done. Verify with:"
echo "    systemctl status nginx"
echo "    sudo nginx -T | grep -E 'listen|configuration file'"
echo "    sysctl net.ipv4.ip_nonlocal_bind"
