# Homebridge

[Homebridge][ref-homebridge] on `snoc-beelink`. It presents the
non-HomeKit devices in the house — Eufy cameras, Govee lights, Wemo
outlets, Emporia energy monitors, phone presence — to Apple's Home app
as a single HomeKit bridge.

## Overview

| Thing                | Value                                           |
| -------------------- | ----------------------------------------------- |
| Install              | apt, `repo.homebridge.io`, package `homebridge`  |
| Service              | `homebridge.service` (system), user `homebridge` |
| Storage              | `/var/lib/homebridge`                            |
| Node                 | `/opt/homebridge/bin/node` — bundled, not system |
| Config UI listener   | `127.0.0.1:18581`                                |
| Config UI on tailnet | `https://snoc-beelink.fold-leaffish.ts.net:8581` |
| HomeKit bridge       | `:51950`, advertiser `bonjour-hap`, LAN mDNS     |

Deploy with [`deploy.sh`](./deploy.sh). Capture the live config into
this directory with [`sync-config.sh`](./sync-config.sh).

## What this repo owns, and what it does not

Homebridge owns its own installation and its own config file. The apt
package manages `/opt/homebridge`; the Config UI rewrites
`/var/lib/homebridge/config.json` on every settings save, and the
plugins write cached tokens and device lists back into it.

So `deploy.sh` does not template that file. It asserts three things
and leaves everything else exactly as it found it:

1. The Config UI listens on `127.0.0.1:18581` and nowhere else.
2. `tailscale serve` publishes it to the tailnet on `:8581`.
3. Funnel is **off** for that port — and it is turned off if found on.

A run that finds all three already true changes nothing and does not
restart the bridge.

## Why loopback plus `tailscale serve`

The Config UI is not a dashboard. It installs arbitrary npm packages,
edits `config.json`, restarts the bridge, and reads the full log —
which includes the plugins' own chatter about the house. It is a
root-equivalent control plane for every device here, behind one
password.

Binding it to `0.0.0.0` would put that on WiFi, where every guest
device lives. Binding it to the Tailscale address directly would avoid
that but lose TLS and lose the boot ordering — the address does not
exist until `tailscaled` is up.

`tailscale serve` solves all three at once: it terminates TLS with a
real certificate for `snoc-beelink.fold-leaffish.ts.net`, it only
accepts connections from nodes on the tailnet, and the mapping is held
by `tailscaled` itself, so it is re-established on boot without a
race. Homebridge keeps a single loopback socket.

This is the same split as the Prometheus pair described in
[`../nginx/README.md`](../nginx/README.md): the unauthenticated thing
binds somewhere unroutable, and the routable listener belongs to
something that authenticates.

The ports are `18581` inside and `8581` on the tailnet, rather than
the reverse or the same number twice, so that the URL in every piece
of Homebridge documentation — port 8581 — is still the URL that works.

### Not a Funnel

Funnel would publish the Config UI to the public internet. `tailscale
funnel 8581 on` is two words away from the serve command and prints no
warning, so `deploy.sh` checks `AllowFunnel` on every run and turns it
off rather than merely reporting it.

The only Funnel on this host is `:443`, which goes to the nginx mux
and exposes Grafana and Prometheus. See
[`../nginx/README.md`](../nginx/README.md).

## Verifying the tailnet endpoint

From another tailnet node:

```console
$ curl -sI https://snoc-beelink.fold-leaffish.ts.net:8581/ | head -1
HTTP/2 200
```

Not from `snoc-beelink` itself. `tailscaled` accepts that connection
and terminates TLS on it, and then the proxied response never arrives:
the request hangs until it times out whether or not the deployment is
healthy, so the result carries no information. `deploy.sh` stops at
checking that `tailscaled` holds the listening socket, which is as far
as a local check can honestly go.

## Plugins

| Plugin                                   | Devices                     |
| ---------------------------------------- | --------------------------- |
| `homebridge-eufy-security`               | Cameras and doorbell        |
| `@homebridge-plugins/homebridge-govee`   | Lights                      |
| `@homebridge-plugins/homebridge-wemo`    | Outlets                     |
| `homebridge-plugin-emporia`              | Energy monitors, EV charger |
| `homebridge-network-presence`            | Per-person presence sensors |

`homebridge-automation-calendar` (seasons, week and month of the
year, twilight/sunrise/sunset) joined them on 2026-11-02 and is the
sixth child bridge, on `:33242`.

One plugin is still installed but carries no platform in
`config.json`, so it loads nothing:

| Plugin                                   | State                       |
| ---------------------------------------- | --------------------------- |
| `@homebridge-plugins/homebridge-resideo` | Installed, never configured |

It cannot be configured into use here: there is no Resideo or
Honeywell Home device on the LAN and no Resideo account. The reason it
is installed at all is the one in
[`../home-assistant/README.md`](../home-assistant/README.md) — it is
the only plugin in the tree that calls `api.matter`, so it was kept as
the Matter experiment rather than as a device integration. Leave it or
remove it; it costs disk and a line in the plugin list.

### Why automation-calendar was disabled, and what fixed it

It carried **two** `AutomationCalendar` accessory entries with the
same `name` and the same house coordinates to five decimal places —
one with a `_bridge` block, one without. Two accessories with one name
collide in HomeKit, and disabling the plugin was the workaround.

The fix was to delete the entry *without* the `_bridge` — every other
plugin here runs on its own child bridge, so the bridged one is the
one that matches the house — upgrade `0.1.1` to `0.2.1`, and empty
`disabledPlugins`. The plugin is maintained upstream; `0.1.1` had just
sat there for as long as the duplicate did.

Every device platform runs as a child bridge — its own process, its
own HAP identity, its own tile in the Home app — so one plugin
crashing does not take the others with it. The five above are what the
`homebridge: <plugin>` processes under `systemctl status homebridge`
are.

### The Emporia plugin is a local tarball

`homebridge-plugin-emporia` is installed from a `file:` dependency in
`/var/lib/homebridge/package.json`, not from npm.

**That dependency used to point into `~batesste`, and it had broken
every plugin install on this host.** `/home/batesste` is `0750`, so
the `homebridge` user could not traverse it, and `npm install` in
`/var/lib/homebridge` aborted `EACCES` on the tarball before it got as
far as the package anyone was actually asking for:

```text
npm error code EACCES
npm error path /home/batesste/Projects/homebridge-plugin-emporia/...tgz
npm error   requiredBy: '.'
```

A `file:` dependency is resolved on *every* install, so this was not
specific to the Emporia plugin — no plugin could be added or upgraded
at all. It is why `homebridge-automation-calendar` sat on `0.1.1` with
`0.2.1` published.

The tarball now lives at
`/var/lib/homebridge/local-plugins/homebridge-plugin-emporia-1.0.0.tgz`,
owned by `homebridge`, and the dependency is the relative
`file:local-plugins/...`. Nothing under `/home` is on the path any
more.

This whole arrangement is scheduled to go away: see
[the publishing note](#publishing-the-emporia-plugin) below.

## systemd and logging

Two things here are the same kind of bug — a correct fix written into
a file that something else owns and rewrites.

### `KillMode` lives in a drop-in, not in the unit

The apt package ships `KillMode=process`, and that is still true in
`2.0.23`. `hb-service` runs one child bridge per plugin as a separate
process; with `KillMode=process` systemd signals only the supervisor,
the children are orphaned, and they keep their HAP ports bound. The
next start fails `EADDRINUSE` on `8581`, `51950` and `44851` and the
unit crash-loops. That was diagnosed on 2026-06-11.

The fix — `KillMode=mixed` — was correct, but it was edited directly
into `/usr/lib/systemd/system/homebridge.service`, which apt owns.
`dpkg -V homebridge` had been flagging the unit as modified ever
since, and `2.0.23` was already sitting in the repo waiting to revert
it silently.

It is now
`/etc/systemd/system/homebridge.service.d/10-killmode.conf`, the unit
file is back to the packaged original, and `dpkg -V` is clean. Confirm
with:

```console
$ systemctl show homebridge -p KillMode -p DropInPaths
KillMode=mixed
DropInPaths=/etc/systemd/system/homebridge.service.d/10-killmode.conf
```

Stopping the unit still logs `Found left-over process ... Ignoring` for
a child bridge or two. That is cosmetic and not the 2026-06 bug:
systemd `SIGKILL`s every process in the cgroup, and the warning is a
race between that sweep and the restart in the same second. The test
that matters is that no `EADDRINUSE` appears and the new bridges bind
their ports — both true since the change.

### logrotate needs `copytruncate`

`/etc/logrotate.d/homebridge` is hand-written, not packaged, and used
`create`. `hb-service` opens `homebridge.log` once at startup and
never reopens it, so a rotation left the supervisor writing into a
renamed-then-deleted inode:

```console
$ sudo ls -l /proc/<supervisor-pid>/fd | grep log
l-wx------ 21 -> /var/lib/homebridge/homebridge.log.1 (deleted)
```

The log had been 0 bytes since the rotation at 2026-10-29 00:00 — four
days during which the bridge was perfectly healthy and said nothing
anywhere, `journalctl -u homebridge` included. This is the
`rocm-version` failure again: the service works, the record of it goes
nowhere, and nobody notices because nothing errors.

`create` is now `copytruncate`, which truncates in place and keeps the
descriptor valid. Only 64 bytes were trapped, so nothing was lost.

## Credentials, and what is in git

Nothing sensitive from `config.json` is in this repository.

[`config.redacted.json`](./config.redacted.json) is a captured
snapshot with every credential replaced by `REDACTED`:

- `password`, `username`, and Govee's API key (stored under the key
  name `code`)
- `pin` — the HomeKit setup code
- `mac` and `serialNumber` — phone MACs and Eufy device serials
- `latitude` / `longitude` — where the house is
- the presence plugin's per-device `name`, which is one family
  member per row. This repository is public; a roster of who lives
  here and a sensor for when each of them is home does not belong in
  it.

Left readable on purpose: `bridge.username` and `_bridge.username`.
Those are MAC-formatted HAP identities rather than logins, and they
are load-bearing — change one and every paired controller treats the
bridge as a new accessory, losing its room, its name and every
automation that referenced it.

The snapshot is **documentation, not a backup**. It cannot be
installed. Real recovery means Homebridge's own backups under
`/var/lib/homebridge/backups` plus the credentials from the Keeper
vault.

Re-capture it after any change made through the Config UI:

```console
$ ./sync-config.sh
$ git diff -- homebridge/config.redacted.json
```

## Publishing the Emporia plugin

The plugin is being published to npm as **`homebridge-emporia`**,
which retires the `file:` dependency, the staged tarball, the
`EMPORIA_TARBALL` check in `deploy.sh` and the section above. Source
is at [`sbates130272/homebridge-emporia`][ref-emporia-repo].

It is worth publishing rather than keeping local. Two Emporia plugins
exist on npm — `homebridge-emporia-vue-log` and
`homebridge-emporia-vue-plugin` — and both are read-only virtual
switches that borrow an unrelated service, one reporting watts as
*lux* on a light sensor. Neither exposes an Emporia smart outlet as a
HomeKit `Outlet`, and neither can switch one. None of the 707
Homebridge-verified plugins is an Emporia plugin.

**The rename is a migration, not a version bump.** Cached accessories
record the plugin that created them:

```console
$ sudo jq -r '.[0].plugin' \
    /var/lib/homebridge/accessories/cachedAccessories.0E4494DB4E91
homebridge-plugin-emporia
```

Installing under the new name orphans all eight of them. The platform
alias is unchanged (`EmporiaEnergy`), so `config.json` needs no edit,
but the cutover wants doing once — after the npm publish, not before —
and the Home app should be checked for renamed or duplicated tiles
afterwards. This host therefore stays on
`homebridge-plugin-emporia@1.0.0` until then.

[ref-emporia-repo]: https://github.com/sbates130272/homebridge-emporia

## Home Assistant

[`../home-assistant`](../home-assistant) runs alongside this and does
*not* import these accessories over HomeKit — the bridges are already
paired to Apple Home, so that flow aborts before it asks for a PIN.
Nor does it pick them up natively: of the five plugins here, only Wemo
has a Home Assistant equivalent, and that outlet is off the network.
Homebridge stays the single place these devices exist at all, and the
single place their credentials live.

## Plugin setup notes

### Eufy Security

Use the [Eufy plugin][ref-eufy-plugin] with a [dedicated admin
account][ref-eufy-instruct], not the main Eufy account. Both sets of
credentials are in the Keeper vault.

### Samsung Smart TV

The [Samsung Tizen plugin][ref-samsung-tizen], configured per [these
instructions][ref-samsung-instruct]. The TV must accept the API access
prompt on screen the first time. Not currently installed.

[ref-homebridge]: https://homebridge.io/
[ref-eufy-plugin]: https://github.com/homebridge-eufy-security/plugin
[ref-eufy-instruct]: https://github.com/homebridge-eufy-security/plugin/wiki/Create-a-dedicated-admin-account-for-Homebridge-Eufy-Security-Plugin
[ref-samsung-tizen]: https://github.com/tavicu/homebridge-samsung-tizen
[ref-samsung-instruct]: https://tavicu.github.io/homebridge-samsung-tizen/
