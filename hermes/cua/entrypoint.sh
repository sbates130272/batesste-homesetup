#!/bin/bash
# Bring up the virtual desktop, then hand the container over to the
# cua-driver daemon.
#
# The order matters and each step is waited for rather than slept past:
# cua-driver's Linux backend needs a reachable X display AND a live AT-SPI
# bus, and both failures present identically at the agent -- a capture that
# returns an image with no addressable elements. Failing loudly here is the
# difference between "the container is broken" and "the model is bad at
# clicking".
#
# The daemon runs in the foreground as PID 1's child so that `docker stop`
# takes the desktop down with it, and so a crashed driver restarts the
# container rather than leaving an X server with nothing driving it.

set -euo pipefail

SCREEN="${CUA_SCREEN:-1920x1080x24}"
DISPLAY_NUM="${DISPLAY#:}"
VNC_ENABLED="${CUA_VNC:-1}"

log() { printf '[cua-entrypoint] %s\n' "$*"; }

wait_for() {
    local what="$1" tries="$2"; shift 2
    for ((i = 0; i < tries; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    log "FATAL: ${what} did not come up after $((tries / 2))s"
    return 1
}

# A stale lock survives an unclean stop when /tmp is on a volume, and Xvfb
# refuses to start over it with a message that reads like a port conflict.
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

log "starting Xvfb on ${DISPLAY} at ${SCREEN}"
Xvfb "${DISPLAY}" -screen 0 "${SCREEN}" -nolisten tcp -noreset &
wait_for "Xvfb" 40 xdpyinfo -display "${DISPLAY}"

# One session bus for the whole container, at the fixed address the image
# advertises (see the Dockerfile) so that `docker exec` finds the same bus
# this shell does. at-spi2-core is D-Bus activated, so without a session
# bus the accessibility bus silently never starts and every capture comes
# back with an empty element list.
log "starting D-Bus session bus at ${DBUS_SESSION_BUS_ADDRESS}"
rm -f "${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
dbus-daemon --session --address="${DBUS_SESSION_BUS_ADDRESS}" --nofork --nopidfile &
wait_for "D-Bus session bus" 40 \
    dbus-send --session --dest=org.freedesktop.DBus --print-reply / org.freedesktop.DBus.ListNames

log "starting AT-SPI bus launcher"
/usr/libexec/at-spi-bus-launcher --launch-immediately &
wait_for "AT-SPI bus" 40 \
    dbus-send --session --dest=org.a11y.Bus --print-reply /org/a11y/bus org.a11y.Bus.GetAddress

log "starting openbox"
openbox --sm-disable &

# There is no "launch an app" action in the computer_use vocabulary, so a
# desktop with nothing running gives the agent no first move. A browser is
# open from the start, and the root menu (see openbox-menu.xml) is how it
# opens anything else.
if [[ "${CUA_AUTOSTART_BROWSER:-1}" == "1" ]]; then
    log "starting google-chrome-stable"
    # Chrome needs --force-renderer-accessibility for AT-SPI,
    # --no-sandbox for running inside containers, and --disable-gpu
    # to avoid hardware issues in the virtual X display.
    ACCESSIBILITY_ENABLED=1 google-chrome-stable \
        --no-sandbox \
        --disable-gpu \
        --disable-software-rasterizer \
        --disable-dev-shm-usage \
        --force-renderer-accessibility \
        --start-maximized \
        --user-data-dir=/home/agent/.config/google-chrome \
        --new-window \
        'data:text/html,<h1>Chrome is ready</h1>' \
        >/dev/null 2>&1 &
fi

if [[ "${VNC_ENABLED}" == "1" ]]; then
    # View-only by default: this is a window onto what the agent is doing,
    # not a second pair of hands. Set CUA_VNC_VIEW_ONLY=0 to take over.
    VIEW_ONLY=()
    [[ "${CUA_VNC_VIEW_ONLY:-1}" == "1" ]] && VIEW_ONLY=(-viewonly)
    log "starting x11vnc + noVNC on :6080"
    x11vnc -display "${DISPLAY}" -forever -shared -nopw -localhost -rfbport 5900 \
        -quiet "${VIEW_ONLY[@]}" &
    websockify --web=/usr/share/novnc 0.0.0.0:6080 localhost:5900 >/dev/null 2>&1 &
fi

log "starting cua-driver serve"
# --no-overlay: the agent cursor is a fullscreen always-on-top window that
# wedges X11 input if a session ends uncleanly, and there is nobody sitting
# at this desktop to appreciate it. Hermes disables it on its side too;
# this makes it true even for a session started by hand.
exec cua-driver serve --no-overlay
