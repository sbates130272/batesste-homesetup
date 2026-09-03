# nginx

The reverse proxy on `snoc-beelink`. It exposes a couple of container
UIs on their own LAN ports and provides the mux that
[Tailscale][ref-tailscale] Funnel points at.

## Overview

nginx serves two distinct audiences, and which address a `listen`
directive binds is what separates them. This is deliberate — do not
"simplify" these into wildcard `listen 80;` directives.

| Listener            | Audience        | Serves                            |
| ------------------- | --------------- | --------------------------------- |
| `10.0.0.15:18789`   | LAN             | proxy to `127.0.0.1:18789`        |
| `10.0.0.15:1080`    | LAN             | proxy to `127.0.0.1:1080`         |
| `10.0.0.15:9090`    | LAN             | Prometheus, **no auth**           |
| `127.0.0.1:9090`    | Tailscale serve | Prometheus, basic auth            |
| `127.0.0.1:9120`    | Tailscale serve | Hermes dashboard Host/Origin shim |
| `127.0.0.1:8080`    | Tailscale Funnel| `/grafana/` and `/prometheus/` mux |

The Prometheus pair is the clearest example: the unauthenticated vhost
is bound to the LAN address only, while the basic-auth vhost is on
loopback and is what `tailscale serve` proxies to. A wildcard bind
would put the no-auth vhost on `tailscale0`.

`tailscale serve` never talks to a LAN address — it always proxies to
`127.0.0.1`. Run `sudo tailscale serve status` to see the mapping.

## The boot race, and why `ip_nonlocal_bind`

nginx used to fail on most reboots:

```
nginx: [emerg] bind() to 10.0.0.15:80 failed
       (99: Cannot assign requested address)
```

`10.0.0.15` lives on `wlp2s0` — WiFi, DHCP. From the boot journal:

```
11:54:17.805  Reached target network.target
11:54:17.805  Reached target network-online.target      <- 0.1 ms later
11:54:18.622  Starting nginx.service...
11:54:19.248  nginx: [emerg] bind() to 10.0.0.15:80 failed
11:54:20.352  wlp2s0: SME: Trying to authenticate with ... SSID='SNOC-Pinewood'
```

nginx tried to bind roughly two seconds before the WiFi card had even
begun to associate, never mind acquired a lease.

`nginx.service` already ships `After=network-online.target`, so why did
that not save it? Because `network-online.target` is meaningless on
this box:

- `NetworkManager-wait-online.service` — `not-found`. NetworkManager is
  not installed; networking is netplan + `systemd-networkd` +
  `wpa_supplicant`.
- `systemd-networkd-wait-online.service` — its netplan drop-in in
  `/run/systemd/system/` is gated behind a
  `ConditionPathIsSymbolicLink=` that does not hold, so the unit never
  runs. `systemctl status` shows it `inactive (dead)`.

With nothing gating it, the target fires immediately after
`network.target`.

The fix is [`sysctl.d/99-nginx-nonlocal-bind.conf`](./sysctl.d/99-nginx-nonlocal-bind.conf),
which sets `net.ipv4.ip_nonlocal_bind=1`. nginx then binds `10.0.0.15`
whether or not the address currently exists, and the socket begins
receiving as soon as WiFi brings the address up. This is the same
mechanism keepalived uses for virtual IPs. It also means nginx rides
out a WiFi drop and reconnect without losing its listeners.

Making `systemd-networkd-wait-online` actually block was rejected: it
would stall every boot behind WiFi association, with a 120 s timeout
when association fails, on a headless machine.

[`systemd/nginx.service.d/override.conf`](./systemd/nginx.service.d/override.conf)
adds `Restart=on-failure` as a safety net for unrelated transient
failures. It is not the fix.

## The `.site` suffix

`nginx.conf` includes `sites-enabled/*.site`, not `sites-enabled/*`.
A symlink without the suffix is silently never loaded, with no warning
from `nginx -t`. `deploy.sh` creates the links with the right name and
removes anything else, so this cannot drift.

`sites-available/hermes` is kept for reference but is **not** enabled:
`tailscale serve` reaches hermes directly on `127.0.0.1:8787` and does
not go through nginx.

Always confirm what is actually loaded with:

```bash
sudo nginx -T | grep -E 'listen|configuration file'
```

## Files not in this repo

These are referenced by the configs but deliberately not versioned:

- `/etc/nginx/.htpasswd` and `/etc/nginx/prometheus.htpasswd` — basic
  auth credentials. Create with `htpasswd -c`.

## Removed: the homelab.raithlin.com vhosts

nginx used to carry a `10.0.0.15:80` redirect and a `10.0.0.15:443`
TLS vhost for `homelab.raithlin.com`, whose only content was a
`/homebridge/` proxy. Both were removed once remote access moved to
Tailscale. At the point of removal they were entirely dead:

- `homelab.raithlin.com` had no public DNS record at all.
- The certificate had expired on 29 Mar 2025. It came from a
  `certbot --manual` DNS-01 challenge, so it never auto-renewed.
- `root /var/www/homelab.raithlin.com/` pointed at a directory that
  did not exist.
- Homebridge was already reachable over the tailnet at
  `snoc-beelink.fold-leaffish.ts.net:8581`, which is where
  `tailscale serve` sends it.

Removing them also cleared a second latent boot failure of the same
family as the one above: nginx refuses to start if an `ssl_certificate`
file is unreadable, so tidying up `/etc/letsencrypt/archive/` would
have taken nginx down on the next reboot.

`/etc/letsencrypt/renewal/homelab.raithlin.com.conf` and the archived
certificate are still on disk but nothing references them.

## Deploying

```bash
cd nginx
./deploy.sh --dry-run    # preview
./deploy.sh
```

The script stages the repo tree into a temporary directory, rewrites
the includes to point at the staging copy and runs `nginx -t` against
it, so a broken config is caught before anything under `/etc/nginx` is
modified. It then installs `nginx.conf`, `conf.d/`, `sites-available/`,
reconciles the `sites-enabled` symlinks, installs the sysctl and
systemd drop-in, and reloads nginx.

Use `--no-boot-fix` to deploy vhost changes only, once the sysctl and
drop-in are already in place.

## Known issues

### The `10.0.0.15` binds assume a stable lease

With `ip_nonlocal_bind` enabled, a changed DHCP lease no longer fails
loudly — nginx binds an address that never materialises and quietly
serves nothing. A DHCP reservation for `snoc-beelink` on the router is
the safeguard.

### The WebSocket path through the dashboard shim is unverified

`sites-available/hermes-dashboard` rewrites `Origin` as well as `Host`
so the dashboard's WebSocket guard accepts a tailnet request. The HTTP
side is confirmed — every path returns the same status through the shim
as it does on loopback — but the WebSocket handshake could not be
tested from the command line, because a tokenless handshake is refused
before the Origin check is reached and the session token is only handed
out to a real browser session. If live updates in the dashboard ever
stall over the tailnet, this shim is the first thing to suspect.

See [the hermes README.md](../hermes/README.md) for the rest of that
story.

[ref-tailscale]: https://tailscale.com/
