# cua — a desktop for Hermes to drive

`snoc-beelink` is headless, so Hermes' built-in `computer_use` toolset has
nothing to act on. This folder builds it one: a container running Xvfb, a
window manager, an accessibility bus, Firefox, and the `cua-driver`
daemon — the same driver the toolset already speaks MCP to, just living in
a container instead of on a logged-in session.

**No agent-side code was needed.** `computer_use` ships with Hermes and
already talks to `cua-driver` over stdio. The whole job is (a) a contained
desktop with the driver in it and (b) a shim that carries stdio across the
container boundary.

| File | What it is |
| --- | --- |
| [`Dockerfile`](./Dockerfile) | The desktop image; pins the driver version |
| [`entrypoint.sh`](./entrypoint.sh) | Brings X, D-Bus, AT-SPI, openbox and Firefox up in order, then execs the daemon |
| [`cua-driver-docker`](./cua-driver-docker) | Host shim: `docker exec -i` as an MCP transport |
| [`batesste-cua-driver.dc.yml`](./batesste-cua-driver.dc.yml) | Compose service, resource ceilings, noVNC port |
| [`hermes-config.yaml`](./hermes-config.yaml) | The `computer_use` block merged into `~/.hermes/config.yaml` |
| [`capability-manifest.yaml`](./capability-manifest.yaml) | The driver-side ceiling — written, installed, and inert while the driver lives in a container (see Permissions) |
| [`openbox-menu.xml`](./openbox-menu.xml) | The desktop's root menu — see *No launch action* below |
| [`deploy.sh`](./deploy.sh) | Builds, starts, installs the shim, sets the env var |

```bash
./deploy.sh --build       # first time, and after a Dockerfile change
./deploy.sh               # re-assert; skips the rebuild
./deploy.sh --dry-run
```

`../deploy.sh` calls this automatically (`--skip-cua` to leave it alone,
and it skips itself on a box without docker).

## How Hermes reaches the driver

```
hermes (host) ──stdio──▶ ~/.local/bin/cua-driver-docker
                             │  docker exec -i
                             ▼
                         cua-driver (container) ──▶ Xvfb :99 + AT-SPI
```

Three things make that work, and each of them is a place the obvious
approach fails:

**`HERMES_CUA_DRIVER_CMD`, not `config.yaml`.** Hermes resolves the driver
binary from the environment only. `deploy.sh` writes it into
`~/.hermes/.env` alongside the credentials, with a read-modify-write that
leaves the neighbours intact.

**`docker exec -i`, never `-t`.** MCP is newline-framed JSON on stdio. A
pty would insert `\r` and corrupt every message; without `-t` the exec is
a transparent pipe.

**The shim rewrites the manifest.** Hermes runs `cua-driver manifest` and,
when the returned `mcp_invocation.command` contains a path separator,
*prefers it* over the path it was configured with
(`cua_backend_driver.py`). The container answers `/opt/cua-driver/...`,
which does not exist on the host, so Hermes would spawn the wrong thing.
The shim intercepts `manifest`, substitutes its own path, and passes
everything else through untouched.

The driver is not on the network at all. The only listener is noVNC on
`127.0.0.1:6080`, and it is **view-only** by default
(`CUA_VNC_VIEW_ONLY=0` to take over the mouse):

```
http://127.0.0.1:6080/vnc.html
```

## Verifying

```bash
hermes computer-use doctor     # both capabilities must say ok
hermes -t computer_use -z 'Take a screenshot and tell me what you see'
```

`doctor` is the check worth trusting. `ax_capability` failing while
`screen_capture_capability` passes is the AT-SPI failure mode: the agent
still gets pixels, so it looks like it is working and is merely bad at
clicking. `service_health.sh` asks the daemon over its own socket for the
same reason — `docker ps` reports `Up` several seconds before the desktop
exists.

## Things that are the way they are for a reason

**No launch action.** The `computer_use` vocabulary is capture / click /
type / key / drag / scroll / focus_app / list_apps. Nothing in it starts a
program. An agent facing an empty desktop therefore has no first move — so
Firefox autostarts (`CUA_AUTOSTART_BROWSER=0` to stop it) and
`openbox-menu.xml` gives it a right-click menu, which is a move it can
already express.

**A fixed D-Bus address, set in the image.** `docker exec` inherits image
`ENV`, not the entrypoint's shell. A `dbus-launch`-allocated address is
visible to the daemon and invisible to every process Hermes spawns, which
reads as "accessibility bus not reachable" in the doctor while a manual
test works fine. The address is pinned in the Dockerfile so both sides
agree; `DISPLAY` is pinned there for the same reason.

**The driver is installed as a directory, not a binary.** It loads
`libcua_driver_sdk.so` and its cursor theme from beside itself. `/opt`
holds the package, `/usr/local/bin` holds a symlink.

**The version is pinned.** Upstream's `install.sh` resolves *latest* at
build time, which would make the image unreproducible and could move
Hermes onto an untested driver on an unrelated rebuild. Bump
`CUA_DRIVER_VERSION` in the compose file and `./deploy.sh --build`.

**2 GB and 2 CPUs.** The host has ~2 GB free. Firefox is the one thing in
here that can reach that ceiling; the root menu's "Restart Web Browser"
exists so recovery does not need a human on the host.

## Permissions

There are **two** gates here, they are independent, and confusing them
cost this README a wrong answer for a while.

**Hermes' approval gate** is the one that prompts. `handle_computer_use`
calls `_request_approval` for every action its table marks destructive —
click, double_click, right_click, middle_click, drag, scroll, type, key,
set_value, focus_app — *before it constructs a backend at all*. So it
never consults the driver's `permission_mode`, and switching that mode
does nothing to it. Only three things quiet it: a session `--yolo`,
`approvals.mode: off`, and a matching key in `command_allowlist`. The
last is the one used here: [`../approvals.yaml`](../approvals.yaml) names
every `cua:<action>:<background|foreground>` scope and owns that key
wholesale.

**cua-driver's capability manifest** is the one that would enforce — and
it cannot be used here. `permission_mode` stays `standard`, because any
other value makes Hermes take the `_EmbeddedCuaDaemon` path: it spawns
`cua-driver serve --embedded --socket /tmp/hc-<token>.sock` and then
connects to that socket itself. Through this shim the `serve` runs
*inside* the container, so the socket is created in the container's
filesystem and the host connects to a path that does not exist.
`--capability-manifest` has the same split — `cua_backend_daemon.py`
checks `os.path.isfile()` on the host and hands the identical string to a
process that resolves it in the container. Making bounded work would mean
bind-mounting the host's `/tmp` into the sandbox, which is most of the way
to not having a sandbox.

So the enforced ceiling is the container: no host filesystem, no reachable
network but loopback noVNC, 2 GB and 512 pids.
[`capability-manifest.yaml`](./capability-manifest.yaml) is still written
and still installed to `~/.hermes/cua-capability-manifest.yaml` by
`deploy.sh`, because it is correct and because the day the driver runs on
the host is the day it starts applying. It is inert today. Do not read
`permission_mode: standard` as an oversight — see the comment in
[`hermes-config.yaml`](./hermes-config.yaml).

Unattended contexts (cron jobs, the scheduler) still **refuse** actions
rather than auto-approving them, but `command_allowlist` grants are
consulted first — so the desktop actions listed in `approvals.yaml` now
work from a cron job where before they could not.

## Known gaps

- **Nothing persists but the home directory.** `/home/agent` is a named
  volume, so browser profile and downloads survive a restart; anything
  installed with `apt` inside the container does not. Add it to the
  Dockerfile.
- **Firefox starts on a first-run page.** Every session begins with a
  capture of the welcome screen, which costs the agent a turn. A seeded
  profile in the image would remove it.
- **No memory headroom for a second app.** Firefox plus the desktop sits
  close enough to the 2 GB ceiling that opening something substantial
  alongside it risks the OOM killer taking the browser.
