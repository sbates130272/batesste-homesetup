#
# A disposable GUI desktop for the Hermes agent to drive.
#
# snoc-beelink is headless, so there is no desktop for Hermes' built-in
# computer_use toolset to act on. This image supplies one: Xvfb, a window
# manager, an AT-SPI accessibility bus, a browser, and cua-driver's daemon
# -- the same driver the toolset already speaks MCP to, just living in a
# container instead of on a logged-in session.
#
# Hermes reaches it through ./cua-driver-docker, a host shim that forwards
# stdio in with `docker exec`. Nothing about the driver is exposed on the
# network; the only listener is the read-only noVNC view.

FROM debian:12-slim

ARG CUA_DRIVER_VERSION=0.28.2
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000

LABEL org.opencontainers.image.title="batesste-cua-driver" \
      org.opencontainers.image.description="Disposable GUI desktop for Hermes Agent computer_use — Xvfb, Chrome, cua-driver, noVNC" \
      org.opencontainers.image.url="https://github.com/batesste/batesste-homesetup/tree/main/hermes/cua" \
      org.opencontainers.image.source="https://github.com/batesste/batesste-homesetup/tree/main/hermes/cua" \
      org.opencontainers.image.version="${CUA_DRIVER_VERSION}" \
      org.opencontainers.image.vendor="Stephen Bates"

ENV DEBIAN_FRONTEND=noninteractive

# The host environment proxies through 127.0.0.1:8888 (mitmproxy / similar).
# Docker BuildKit injects HTTP_PROXY/HTTPS_PROXY at the daemon level — shell
# env overrides are ignored because they come from a mechanism that survives
# into every RUN layer.  We neutralise this in three places:
#   1. NO_PROXY ENV + /etc/environment — for wget, apt, and shell tools
#   2. /etc/apt/apt.conf.d/99noproxy — apt's own config
#   3. /etc/curlrc + curl --noproxy '*' — curl goes direct

ENV NO_PROXY=localhost,127.0.0.1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,deb.debian.org,security.debian.org,archive.ubuntu.com,security.ubuntu.com,dl.google.com,github.com,objects.githubusercontent.com,release-assets.githubusercontent.com

# /etc/environment is picked up by PAM on login AND by Docker as an env-file
# at build time, so it survives BuildKit's proxy injection.
RUN printf 'NO_PROXY="%s"\n' "${NO_PROXY}" > /etc/environment \
    && printf 'Acquire::http::Proxy "false";\nAcquire::https::Proxy "false";\n' > /etc/apt/apt.conf.d/99noproxy \
    && printf 'all-proxy = disabled\n' > /etc/curlrc

# Add Google's Chrome repo (need curl+gnupg first).  Chrome is installed via
# the apt repo below rather than a downloaded .deb — that way the version
# tracked in the image stays in sync with the repository on rebuilds instead
# of a hard-coded download URL.
#
# Docker BuildKit injects HTTP_PROXY/HTTPS_PROXY from the host.  We use
# `env -u` to strip those from curl's env so it goes direct.
RUN set -xe; \
    apt-get update && apt-get install -y --no-install-recommends \
            ca-certificates curl gnupg && \
    curl -fsSL --noproxy '*' https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends \
            xvfb x11-utils x11-xserver-utils xauth \
            openbox xterm \
            dbus dbus-x11 \
            at-spi2-core libatk-adaptor libgail-common \
            x11vnc novnc websockify \
            fonts-dejavu fonts-liberation \
            google-chrome-stable \
            xdg-utils procps && \
    apt-get purge -y curl gnupg && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Installed by hand rather than through upstream's install.sh: the
# installer resolves "latest" at build time, which would make the image
# unreproducible and silently move Hermes onto an untested driver. The
# tarball is a package, not a lone binary -- the driver loads
# libcua_driver_sdk.so and the cursor theme from beside itself -- so the
# whole directory is kept and only the entry point is linked onto PATH.
RUN set -eux; \
    dir="cua-driver-rs-${CUA_DRIVER_VERSION}-linux-x86_64"; \
    url="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${CUA_DRIVER_VERSION}/${dir}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/cua.tgz; \
    mkdir -p /opt/cua-driver; \
    tar xzf /tmp/cua.tgz -C /tmp; \
    cp -a "/tmp/${dir}/." /opt/cua-driver/; \
    rm -rf /tmp/cua.tgz "/tmp/${dir}"; \
    ln -sf /opt/cua-driver/cua-driver /usr/local/bin/cua-driver; \
    cua-driver --version

RUN groupadd -g "${GID}" "${USERNAME}" \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" \
    && install -d -m 1777 /tmp/.X11-unix

COPY --chown=${UID}:${GID} entrypoint.sh /opt/cua-entrypoint.sh
# /etc rather than ~/.config/openbox: the home directory is a volume, so
# anything written there at build time is shadowed on first start.
COPY openbox-menu.xml /etc/xdg/openbox/menu.xml

USER ${USERNAME}
ENV HOME=/home/${USERNAME}
WORKDIR ${HOME}

# DISPLAY and the accessibility variables are set in the image rather than
# the entrypoint because `docker exec` inherits image ENV but not the
# entrypoint's shell, and Hermes reaches the driver exclusively through
# exec. This is the only place they can be set once for both processes.
#
# DBUS_SESSION_BUS_ADDRESS is pinned to a fixed path rather than left to
# `dbus-launch` to allocate. The address is the only way a process finds
# the accessibility bus, and a `docker exec` inherits image ENV but not the
# entrypoint's shell -- so a randomly-allocated address is reachable by the
# daemon and invisible to every process Hermes spawns, which reads as
# "AT-SPI: accessibility bus not reachable" in the doctor while the agent
# works fine. Fixed address, same answer from both sides.
ENV DISPLAY=:99 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/cua-dbus-session \
    GTK_MODULES=gail:atk-bridge \
    QT_ACCESSIBILITY=1 \
    NO_AT_BRIDGE=0 \
    CUA_DRIVER_RS_TELEMETRY_ENABLED=0 \
    CUA_SCREEN=1920x1080x24

EXPOSE 6080
ENTRYPOINT ["/bin/bash", "/opt/cua-entrypoint.sh"]
