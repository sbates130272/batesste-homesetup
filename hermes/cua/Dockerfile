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

ENV DEBIAN_FRONTEND=noninteractive

# Add Google's Chrome repo for the latest stable Chrome (need curl+gnupg first)
# then install the X stack, accessibility stack, Chrome, and cua-driver.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
            xvfb x11-utils x11-xserver-utils xauth \
            openbox xterm \
            dbus dbus-x11 \
            at-spi2-core libatk-adaptor libgail-common \
            x11vnc novnc websockify \
            fonts-dejavu fonts-liberation \
            google-chrome-stable \
            xdg-utils procps \
    && rm -rf /var/lib/apt/lists/*

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
