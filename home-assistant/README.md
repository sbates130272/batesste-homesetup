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
container definition, and the tailnet listener.

Home Assistant owns `/var/lib/home-assistant/.storage`, which is where
everything done through the UI actually lives: integrations, entities,
areas, dashboards, the exposed-entity list, users and access tokens.
None of that is version-controlled and none of it should be — it holds
credentials, and it is not text anybody wants to review in a diff.

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
container's listener *is* the host's listener. So the isolation moves
into `configuration.yaml`:

```yaml
http:
  server_host:
    - 127.0.0.1
```

That is the only thing standing between Home Assistant and a wildcard
bind. Lose it and the UI appears on WiFi and on the tailnet showing
the onboarding screen, which offers to create the first administrator
account for whoever reaches it first.

`deploy.sh` therefore checks the actual bound socket after every
start, not the file it just installed:

```console
$ ss -tln | grep 8123
LISTEN 0 128 127.0.0.1:8123  0.0.0.0:*     # correct
LISTEN 0 128   0.0.0.0:8123  0.0.0.0:*     # deploy.sh fails here
```

## The tailnet listener

`tailscale serve --https 8123 http://127.0.0.1:8123`, for the same
reasons set out in [`../homebridge/README.md`](../homebridge/README.md):
TLS with a real certificate, reachable only from the tailnet, and the
mapping held by `tailscaled` so it comes back on boot without racing
anything.

`use_x_forwarded_for` and `trusted_proxies` in `configuration.yaml`
are the other half of that. `tailscale serve` proxies from loopback,
so without them Home Assistant sees the entire tailnet as a single
client — which means one person fat-fingering a password trips the
login-attempt ban for everybody.

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

**A HomeKit accessory can be paired with exactly one controller.** All
seven Homebridge bridges on this box — the main one and the six child
bridges — are already paired, with two controllers each:

```console
$ cd /var/lib/homebridge/persist
$ for f in AccessoryInfo*.json; do
    echo "$(sudo jq -r '.displayName' "$f") $(sudo jq '.pairedClients|length' "$f")"
  done
Homebridge SNOC 4334 2
SNOC - EufySecurity 5437 2
Govee 3F9B 2
Wemo 681C 2
Emporia Energy A58C 2
homebridge-network-presence 49D9 2
AutomationCalendar 26A7 2
```

So Home Assistant's **HomeKit Device** integration cannot simply pair
with them. It will discover them over mDNS, accept the PIN, and fail.
There are three ways round it, and the trade is real:

1. **Matter multi-admin.** Homebridge 2.x can expose a bridge over
   Matter as well as HAP, and Matter genuinely supports multiple
   controllers commissioning the same bridge. This is the only option
   that leaves the Apple Home setup untouched. Opt in per bridge with
   a `matter` block under `bridge` or a plugin's `_bridge` in
   `config.json`. Uncertified-accessory warnings during commissioning
   are expected.

2. **A dedicated child bridge.** Put the plugins Home Assistant should
   see on child bridges that Apple Home is *not* paired with. Clean,
   but it is all-or-nothing per bridge: pairing a bridge hands over
   every accessory on it.

3. **Unpair from Apple Home.** Works, and destroys the existing setup:
   every room assignment, name and automation in the Home app is lost,
   because an unpaired-and-repaired bridge is a new accessory as far
   as HomeKit is concerned. Do not do this by accident.

Whichever is chosen, the pairing itself happens in the Home Assistant
UI with a PIN typed by hand, so no script here can or should do it.

The alternative direction — native Home Assistant integrations for
Govee, Wemo and Eufy, with Home Assistant's own HomeKit Bridge pushing
them back to Apple Home — is a bigger migration, and it moves the
device credentials out of Homebridge. Worth considering if Homebridge
ever stops being the thing that works.

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
$ hermes -z 'What Home Assistant tools do you have?'
```

The tools are the Assist intents — `HassTurnOn`, `HassLightSet`,
`GetLiveContext` and so on — generated from the exposed entities.
`mcp.yaml` deliberately carries no `include` list for this server, for
that reason: any list written today would silently drop whatever is
exposed tomorrow.

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
