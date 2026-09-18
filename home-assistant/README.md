# Home Assistant

[Home Assistant][ref-home-assistant] on `snoc-beelink`, running
alongside [Homebridge](../homebridge) and exposing the house to the
[Hermes](../hermes) agent over MCP.

## Overview

| Thing          | Value                                            |
| -------------- | ------------------------------------------------ |
| Install        | Container, `ghcr.io/home-assistant/home-assistant`|
| Container      | `batesste-home-assistant`, `network_mode: host`   |
| Config         | `/var/lib/home-assistant` (bind mount)            |
| Web UI         | `127.0.0.1:8123`                                  |
| On the tailnet | `https://snoc-beelink.fold-leaffish.ts.net:8123`  |
| MCP endpoint   | `http://127.0.0.1:8123/api/mcp`                   |
| Memory ceiling | 1536 MB, no swap                                  |

Deploy with [`deploy.sh`](./deploy.sh). The image tag is pinned in
[`home-assistant.dc.yml`](./home-assistant.dc.yml); moving it is how
upgrades happen.

## What this repo owns, and what it does not

This repo owns [`configuration.yaml`](./configuration.yaml), the
container definition, the tailnet listener, and exactly one key inside
Home Assistant's own state: `.storage/http`.

Home Assistant owns the rest of `/var/lib/home-assistant/.storage`,
which is where everything done through the UI actually lives:
integrations, entities, areas, dashboards, the exposed-entity list,
users and access tokens. None of that is version-controlled and none
of it should be — it holds credentials, and it is not text anybody
wants to review in a diff.

`.storage/http` is the exception because Home Assistant took the bind
address away from YAML in 2026.9 and left it nowhere else to live. See
[below](#why-the-bind-address-is-in-storage-of-all-places).

Home Assistant never rewrites `configuration.yaml`, which is what makes
owning it from git possible. `deploy.sh` installs it and backs up
whatever was there first, so a hand-edit made on the box is preserved
long enough to port back here — but it *is* reverted. Edit it in the
repo.

## Why Container rather than Supervised or OS

Supervised wants to own the machine: its own docker daemon policy, its
own network configuration, its own update cadence, and a supported-OS
check that complains about everything else running here. This box
already carries Homebridge, the Firefly III stack, Hermes, the
computer-use sandbox and the Prometheus/Grafana/Loki stack.

Container gives up the add-on store, and nothing else that matters —
every add-on this setup would have wanted (a database, a reverse
proxy, an MCP bridge) is something the box already has, better.

## Host networking, and the one line holding it together

`network_mode: host`, so there is no `ports:` key in the compose file.

Everything Home Assistant is meant to find here, it finds by
multicast: mDNS/zeroconf for the Homebridge bridges, SSDP for the Wemo
outlets, broadcast for Govee LAN control. Multicast does not cross a
docker bridge network. A bridged Home Assistant discovers nothing,
every integration has to be added by IP by hand, and each one then
breaks at the next DHCP lease.

The cost is that `ports:` is no longer isolating anything — the
container's listener *is* the host's listener. So the isolation has to
come from the bind address, and since 2026.9 that no longer lives in
`configuration.yaml`.

### Why the bind address is in `.storage`, of all places

An `http:` block in YAML is now migrated into `.storage/http` **once**,
applied as a five-minute **trial**, and — if nobody confirms it in the
UI — reverted to a stored `stable` slot that has no `server_host` at
all. `yaml_migration_done` is then set and the YAML is ignored for
good.

This is not theory. It happened here on 2026-09-18: the first version
of this deployment shipped the YAML block, verified a correct loopback
listener, and was reverted five minutes later, after the deploy script
had exited reporting success. What saved it was luck — Home Assistant's
default bind is `0.0.0.0` *and* `::`, and the `::` half collided with
`tailscaled`'s own listener on 8123, so the process failed into
recovery mode instead of serving an unauthenticated onboarding form on
WiFi. Free that port and it binds.

So `deploy.sh` writes the `stable` slot directly, with the container
stopped, and clears `pending` so no trial is ever staged:

```json
"stable": { "server_host": ["127.0.0.1"], "use_x_forwarded_for": true,
            "trusted_proxies": ["127.0.0.1/32", "::1/128"] }
```

That slot is the only thing standing between Home Assistant and a
wildcard bind. `deploy.sh` therefore checks the actual bound socket
after every start, not the file it just installed:

```console
$ ss -tln | grep 8123
LISTEN 0 128 127.0.0.1:8123  0.0.0.0:*     # correct
LISTEN 0 128   0.0.0.0:8123  0.0.0.0:*     # deploy.sh fails here
LISTEN 0 128      [::]:8123     [::]:*     # and here
```

A local verification is only meaningful five minutes after the start
it verifies, which is the other reason nothing stages a pending
config.

## The tailnet listener

`tailscale serve --https 8123 http://127.0.0.1:8123`, for the same
reasons set out in [`../homebridge/README.md`](../homebridge/README.md):
TLS with a real certificate, reachable only from the tailnet, and the
mapping held by `tailscaled` so it comes back on boot without racing
anything.

`use_x_forwarded_for` and `trusted_proxies`, in the same stored slot,
are the other half of that. `tailscale serve` proxies from loopback,
so without them Home Assistant sees the entire tailnet as a single
client — which means one person fat-fingering a password trips the
login-attempt ban for everybody.

Two things follow that are easy to get wrong in the other direction.
`tailscale serve` *replaces* a client-supplied `X-Forwarded-For`
rather than appending to it, so a browser behind a header-injecting
corporate proxy is not a problem and these settings need no hardening
for it. But trusting `127.0.0.1` means any local process that can
open `127.0.0.1:8123` can claim to be any address it likes, and Home
Assistant will log and ban on that claim. That is an acceptable trade
only while the bind stays on loopback — a local process already has
better options — and it is the reason to think twice before setting
`login_attempts_threshold` back to a positive number.

`http.forwarded` errors in the log naming an impossible address, such
as `300.1.1.1`, are almost always somebody's own probe rather than
traffic. They render as a plain `400 Bad Request`, never as a
connection failure.

Verify from another tailnet node, never from `snoc-beelink` itself:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    https://snoc-beelink.fold-leaffish.ts.net:8123/
302
```

A 302 is the redirect to onboarding or to the login page — it means
the path works. A `HEAD` request returns 405; Home Assistant does not
serve HEAD on `/`, and that is not a fault.

**No Funnel.** This UI can unlock doors and watch cameras. `deploy.sh`
checks `AllowFunnel` on every run and turns it off rather than
reporting it.

## Getting devices in

This is the part that is not automated, and not because of an
oversight.

HAP is not single-controller — an accessory holds as many pairings as
it is given. What it will not do is hand out the *first* one twice.
Pair-setup is refused outright once any pairing exists (`HAPServer.js`
returns `TLVErrorCode.UNAVAILABLE`), and every pairing after that has
to be added by an already-authenticated controller with the admin bit.
Apple Home has that bit here; Home Assistant has no way to ask for it.

All seven bridges on this box — the main one and the six child bridges
— hold the same two pairings, one admin and one user, which is one
Apple Home household rather than two independent controllers:

```console
$ cd /var/lib/homebridge/persist
$ sudo jq -c '{n: .displayName, perm: .pairedClientsPermission}' AccessoryInfo*.json
{"n":"Homebridge SNOC 4334","perm":{"4A14A531-…":1,"9DB2ED3C-…":0}}
{"n":"SNOC - EufySecurity 5437","perm":{"4A14A531-…":1,"9DB2ED3C-…":0}}
…
```

`1` is admin, `0` is user. The same two UUIDs, with the same public
keys, on all seven.

So Home Assistant's **HomeKit Device** integration never even gets as
far as asking for a PIN. `homekit_controller/config_flow.py` reads the
`sf` flag out of the mDNS advertisement and, for a bridge that is
already paired, returns `async_abort(reason="already_paired")` before
the pairing form is ever built; the same check keeps paired bridges
out of the manual "Add device" picker. There is no PIN field to type
into and no failure to work around — the flow ends first.

That leaves three routes, and none of them is the easy one:

1. **Matter multi-admin.** Homebridge 2.4.0 does ship Matter
   (`@matter/main` 0.17.9, `dist/matter/MatterAPIImpl.js`), and Matter
   genuinely allows several controllers to commission one bridge. But
   a `matter` block under `bridge` or a plugin's `_bridge` only stands
   the Matter server up: accessories appear on it only if the plugin
   itself calls `api.matter`, and **none of the five configured
   plugins does** — grep the installed tree and the only hit is
   `homebridge-resideo`, which has no platform block here. Opting in
   today produces an empty bridge. Home Assistant's side is missing
   too: the `matter` integration talks to a separate
   python-matter-server over `ws://localhost:5580/ws`, and this box
   runs no such container. Revisit only if a plugin gains `api.matter`
   *and* you are willing to run a tenth container.

2. **A separate Homebridge instance.** Not "a dedicated child bridge":
   all five active plugins already sit on their own `_bridge`, so
   moving one means rewriting its `_bridge.username`, and that MAC
   *is* the HAP identity — change it and the Home app treats the
   bridge as brand new and drops its rooms, names and automations.
   Doing this properly means a genuinely second Homebridge with its
   own storage path, fresh MACs and non-colliding ports. Note that
   `hb-service install` is disabled by the APT package, so it would be
   a hand-written systemd unit or a container.

3. **Unpair from Apple Home.** Works, and destroys the existing setup:
   every room assignment, name and automation in the Home app is lost,
   because an unpaired-and-repaired bridge is a new accessory as far
   as HomeKit is concerned. Do not do this by accident.

The alternative direction — native Home Assistant integrations for
Govee, Wemo and Eufy, with Home Assistant's own HomeKit Bridge pushing
them back to Apple Home — is a bigger migration, and it moves the
device credentials out of Homebridge. It is also the only one of these
that can be done incrementally, which makes it the one to start with:

- **`nmap_tracker` or `ping`** replaces `homebridge-network-presence`
  outright. Both are shipped, `nmap` is in the image, and the
  container runs host-networked, so the default ARP scan works.
- **Belkin Wemo** is native and needs no credentials. Blocked today:
  `snoc-wemo-a` is off the network and Homebridge has been logging
  `still not been initially found` for it continuously.
- **Govee, Eufy and Emporia** stay on Homebridge. Their native
  integrations want the same cloud credentials Homebridge already
  holds, and moving them buys nothing until something forces it.

Until one of those lands there is genuinely nothing controllable to
expose, and the MCP chain below will report a connection with no
entity tools. That is the correct result, not a broken deployment.

## MCP, and what Hermes can actually see

The **Model Context Protocol Server** integration publishes Home
Assistant's Assist API at `/api/mcp` over streamable HTTP. The Hermes
side is one entry in [`../hermes/mcp.yaml`](../hermes/mcp.yaml),
pointed at loopback: both processes are on this box, so there is no
reason to go out to `tailscaled` and back for TLS.

Order matters — the integration has nothing to offer until entities
are exposed:

1. **Settings → Voice assistants → Expose.** This list, and nothing
   else, is what the agent can see and control. An entity that is not
   on it does not exist as far as Hermes is concerned, whatever
   `mcp.yaml` says. *This page is the access control.* Think about it
   before adding the locks.

   With one caveat that undoes most of the curation: the overflow
   menu's **Expose new entities** defaults to on, and
   `DEFAULT_EXPOSED_DOMAINS` covers `switch`, `light`, `cover`,
   `climate`, `media_player` and `vacuum`. Left on, every entity a
   future integration creates in those domains reaches the agent
   without anyone revisiting this page. Turn it off to make the list
   an allowlist. `lock` and `alarm_control_panel` are not in that set,
   so doors never auto-expose either way.
2. **Settings → Devices & services → Add integration → Model Context
   Protocol Server.**
3. **Profile → Security → Long-lived access tokens → Create token.**
   Put it in `~/.hermes/.env`:

   ```
   HOMEASSISTANT_TOKEN=<token>
   ```

   That token carries the full privileges of the account that created
   it — an administrator credential in an API token's clothes. It is
   the second reason the Expose page matters.
4. `../hermes/deploy.sh`, which applies `mcp.yaml` into
   `~/.hermes/config.yaml` and restarts the gateway.

Then check it end to end. `hermes mcp list` reports the *config*, not
a connection, so it is not a test:

```console
$ hermes mcp test homeassistant
$ hermes -z 'What Home Assistant tools do you have?'
```

Run those in that order. `mcp test` failing with `Server
'homeassistant' not found in config` means step 4 has not run yet —
`apply-model-config.py` *replaces* the whole `mcp_servers` key from
this file, so `mcp.yaml` is the only place to add a server and
`hermes mcp add` would be overwritten by the next deploy without a
word. If `mcp test` passes but `hermes -z` misbehaves, the difference
is the corporate proxy: the systemd units carry no proxy environment,
an interactive login shell does.

The tools are the Assist intents — `HassTurnOn`, `HassLightSet`,
`GetLiveContext` and so on. `mcp.yaml` deliberately carries no
`include` list for this server: any list written today would silently
drop whatever is exposed tomorrow.

Read the tool list carefully, though. `HassTurnOn` and `HassTurnOff`
are published whether or not anything is exposed — the Assist API
registers them regardless, and they simply have nothing to act on. So
the tool list is not a report of what the agent can reach. The Expose
page is, and `trust: full` in `mcp.yaml` means the moment a real
switch lands on it, the agent can throw it without asking.

## Bluetooth is off, deliberately

The compose file mounts no `/run/dbus`. It did, for Bluetooth, and
Bluetooth does not work here: `bluetooth.service` is inactive on this
host, so BlueZ owns no name on the bus. Home Assistant found the Intel
adapter anyway, tried to drive it, and threw an `AttributeError` out
of `bleak` every few seconds into an unrotated docker log.

Nothing in this house arrives over Bluetooth — the devices come in
over WiFi, mDNS and HomeKit — so the mount is gone rather than papered
over. Enabling it means starting `bluetoothd` on the host *and*
restoring the mount, which is a deliberate change.

One leftover: the config entry Home Assistant created for the adapter
during the first run is still in `.storage`, and still logs on every
start. Disable it once in **Settings → Devices & services →
Bluetooth**; nothing in this repo can do it, because it lives in the
half of `.storage` Home Assistant owns.

Container logs are capped at 3 × 10 MB in the compose file for the
same reason this was worth finding: `/` is at 84% and shared with
Prometheus, Loki, the image store and the Firefly database.

## Memory, and why there is a ceiling

`snoc-beelink` has 8 GB, and in September 2026 it spent 45 minutes in
a swap-thrash livelock that ended in a power cycle — the incident that
produced [`../oomd`](../oomd). With Homebridge, Firefly III, Hermes,
the computer-use sandbox and the monitoring stack resident, there were
about 3.3 GB available before Home Assistant arrived and about 2.7 GB
after.

So the container gets `mem_limit: 1536m` with `memswap_limit` equal to
it. Home Assistant's footprint grows with entity count and recorder
activity; when it goes wrong it dies alone and restarts, rather than
taking the box with it. Equal swap limit means it cannot reach for
swap on the way down, which is the specific mechanism of the September
livelock.

`recorder.purge_keep_days` is 7 rather than the default 10 for the
same kind of reason: `/` was at 81% of 98 GB, shared with Prometheus,
Loki, the docker images and the Firefly database. The history worth
keeping about this network is in Prometheus and Grafana; this database
only needs to be able to draw the graphs in the Home Assistant UI.

Watch both:

```console
$ docker stats --no-stream batesste-home-assistant
$ sudo du -sh /var/lib/home-assistant/home-assistant_v2.db
```

## Upgrades

```console
$ $EDITOR home-assistant.dc.yml      # move the image tag
$ ./deploy.sh --pull
```

Read the release notes first. Home Assistant ships breaking changes
monthly, and the pin exists precisely so that `deploy.sh` on some
unrelated errand cannot perform a major upgrade by surprise.

[ref-home-assistant]: https://www.home-assistant.io/
