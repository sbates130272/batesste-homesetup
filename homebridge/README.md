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

Two more are installed but carry no platform in `config.json`, so they
load nothing:

| Plugin                                   | State                       |
| ---------------------------------------- | --------------------------- |
| `@homebridge-plugins/homebridge-resideo` | Installed, never configured |
| `homebridge-automation-calendar`         | In `disabledPlugins`        |

`homebridge-automation-calendar` still has two accessory entries in
`config.json`, which is why the disable is explicit rather than the
absence of configuration. Removing the plugin means removing those
too.

Every device platform runs as a child bridge — its own process, its
own HAP identity, its own tile in the Home app — so one plugin
crashing does not take the others with it. The five above are what the
`homebridge: <plugin>` processes under `systemctl status homebridge`
are.

### The Emporia plugin is a local tarball

`homebridge-plugin-emporia` is installed from
`~/Projects/homebridge-plugin-emporia/homebridge-plugin-emporia-1.0.0.tgz`,
not from npm — a `file:` dependency in
`/var/lib/homebridge/package.json`.

If that working copy goes away the plugin keeps running from
`node_modules` and then disappears at the next `npm install` in
`/var/lib/homebridge`, with no error that anyone reads. `deploy.sh`
warns when the tarball is missing but does not rebuild it: that is a
`npm pack` in a repository this one does not own.

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
