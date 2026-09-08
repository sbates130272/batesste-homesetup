# batesste-homesetup

A repository of tools and applications I use to maintain my home IT
infrastructure.

# dyndns

The [dyndns](./dyndns) folder contains a simple bash script that I use
in combination with an [AWS S3][ref-aws-s3] object to track the IP
address of my home router. I can use this to connect to my main home
server while I am travelling. From there I can jump to any other
machine in the system. See [the README.md](./dyndns/README.md) for
more information.

# Homebridge

The [homebridge](./homebridge) folder contains a docker-based setup
for [Homebridge][ref-homebridge] for my house. This allows me to use
[Apple HomeKit][ref-homekit] to communicate with all my home
automation devices. See [the README.md](./homebridge/README.md) for
more information.

# SSL Certificate

Note that this is no longer in use. Remote access to the homelab now
goes through [Tailscale][ref-tailscale], which terminates TLS itself
with a certificate it manages, so there is nothing to renew by hand.
The `homelab.raithlin.com` vhosts have been removed from the nginx
configuration — see [the nginx README.md](./nginx/README.md). The
steps below are kept for reference in case a public hostname is ever
wanted again.

In order to connect to http-based services inside my home setup I want
to deploy [SSL certificates][ref-ssl-certs] that have been
authenticated. There is an easy command line way to do this based on
[this tutorial][ref-ssl-tutorial] that uses
[certbot][ref-certbot]. This tutorial is so good I won't both
repeating the steps here. Just refer to it and you should be good,
though you do want to make sure you run the command for my homelab
domain:
```
$ sudo certbot certonly --manual --preferred-challenges dns -d "*.homelab.raithlin.com"
```

Note that we do need to create a TXT based DNS record on my domain
manager who is currently [GoDaddy][ref-godaddy].

# Grafana and Prometheus

These are used for monitoring my home network and, in time, other
things. Grafana is installed from their apt repository and Prometheus
is installed from the Ubuntu repository.

## Grafana Configuration

The Grafana configuration is version-controlled in the
[grafana](./grafana) folder. Dashboard JSON files and
provisioning YAML are deployed to the live Grafana instance
via a deploy script. Dashboards can also be exported back
from the Grafana UI into the repo for round-trip editing.
See [the README.md](./grafana/README.md) for more
information.

However it is worth noting that on systems with WiFi we do want to
enable the WiFi collector. We can do this by adding the following to
an override file.
```
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter $ARGS --collector.wifi
```
Note that unfortunately this collector is not available for macOS and
so this won't work on Mac-based systems.

Note that in order to gather more data we alter the retention default
policy in Prometheus. In Ubuntu we do this via adding the following to
the ```/etc/default/prometheus``` file and then restart the Prometheus
systemd service.
```
# Set the command-line arguments to pass to the server.
# Due to shell escaping, to pass backslashes for regexes, you need to double
# them (\\d for \d). If running under systemd, you need to double them again
# (\\\\d to mean \d), and escape newlines too.
ARGS="--storage.tsdb.retention.size=10GB"
```

## Prometheus Configuration

The Prometheus configuration is version-controlled in the
[prometheus](./prometheus) folder. Scrape targets are managed via
[file_sd_configs][ref-file-sd] so that adding or removing a target
does not require editing the main `prometheus.yml` file. Prometheus
watches the target JSON files and picks up changes automatically.

### Adding a new target

Use the helper script to add a target to an existing job:
```bash
cd prometheus
./add-target.sh node 10.0.0.50:9100 server_name=snoc-newbox
```
This appends to the appropriate `targets/<job>.json` file. To also
deploy the updated file to the live Prometheus instance add the
`--deploy` flag:
```bash
./add-target.sh --deploy node 10.0.0.50:9100 \
    server_name=snoc-newbox
```

### Deploying configuration changes

To deploy both `prometheus.yml` and all target files:
```bash
cd prometheus
./deploy.sh
```
The script validates the config with `promtool` before copying
anything. Use `--targets-only` to deploy only target files (no
Prometheus reload needed). Use `--dry-run` to preview without
making changes.

### Target files

Each scrape job has a corresponding JSON file in `targets/`:

| File                             | Job                       |
| -------------------------------- | ------------------------- |
| `prometheus.json`                | prometheus                |
| `node.json`                      | node                      |
| `emporia.json`                   | emporia                   |
| `speedtest_probe.json`           | speedtest_probe           |
| `speedtest_exporter.json`        | speedtest_exporter        |
| `icloud.json`                    | icloud                    |
| `amd-gpu-metrics-exporter.json`  | amd-gpu-metrics-exporter  |
| `ais-exporter.json`              | ais-exporter              |
| `rdma-exporter.json`             | rdma-exporter             |
| `nvme-exporter.json`             | nvme-exporter             |
| `openai_exporter.json`           | openai_exporter           |
| `cursor-exporter.json`           | cursor-exporter           |
| `lemonade-exporter.json`         | lemonade-exporter         |
| `loki.json`                      | loki                      |
| `alloy.json`                     | alloy                     |

### Avahi auto-discovery

Targets can also be discovered automatically via
[Avahi][ref-avahi] mDNS. On each target machine, drop the
matching service XML from `prometheus/avahi-services/` into
`/etc/avahi/services/`. Each exporter type uses its own
DNS-SD service type (e.g. `_node-exporter._tcp`). On the
Prometheus server, run:
```bash
cd prometheus
./discover-targets.sh --deploy
```
Or install the systemd timer for continuous discovery
every five minutes. See the
[prometheus README.md](./prometheus/README.md) for full
details.

# Loki

Prometheus and Grafana cover metrics; [Loki](./loki) covers
logs. It runs on the home server and every Linux box in the fleet
ships its systemd journal there with [Grafana Alloy][ref-alloy], so
"why did that exporter die" is a Grafana query rather than an ssh
session on whichever machine is suspect.

Both packages come from the Grafana apt repository that Grafana
itself already uses. Retention is 90 days, and `/var/lib/loki` is
its own logical volume because Loki caps retention by time and has
no size limit — the volume boundary is the only thing standing
between a runaway log source and a full root filesystem. See [the
README.md](./loki/README.md) for the config, the agent rollout, and
the handful of ways Alloy fails without saying anything.

# nginx

The [nginx](./nginx) folder holds the reverse proxy configuration for
the home server. nginx publishes a few container UIs on their own LAN
ports and provides the loopback mux that [Tailscale][ref-tailscale]
Funnel points at. Configuration is deployed with a script that
validates the whole tree with `nginx -t` before touching `/etc/nginx`.

Which address a `listen` directive binds is what separates LAN traffic
from Tailscale traffic — the unauthenticated Prometheus vhost is bound
to the LAN address only, while the basic-auth one sits on loopback for
`tailscale serve` to proxy to. These must not be collapsed into
wildcard binds.

That does mean nginx binds an address belonging to the WiFi interface,
which is not present that early in boot, so nginx used to lose the race
and die with `bind() to 10.0.0.15:80 failed (99: Cannot assign
requested address)`. `network-online.target` does not help here because
nothing on this machine gates it. The fix is
`net.ipv4.ip_nonlocal_bind=1`. See [the README.md](./nginx/README.md)
for the full analysis and the deploy instructions.

# Hermes

The [hermes](./hermes) folder covers the Hermes agent running on the
home server. It runs as a pair of *user* systemd units rather than
system ones, which matters because `Linger` has to be enabled for the
account or nothing starts at boot.

The folder holds a drop-in that binds the dashboard to loopback
instead of all interfaces. The old bind was taking port 9119 on every
address, including the one tailscaled needs for its own `serve` entry,
which left tailscaled retrying in a loop forever — and left the
dashboard reachable from the LAN with no authentication in front of
it. Reaching it over the tailnet now goes through an nginx shim. See
[the README.md](./hermes/README.md) for the details and for the
duplicate system unit that was disabled alongside it.

# Firefly III

I use [Firefly III][ref-firefly] for personal finance tracking. I have
a [GitHub repo][ref-batesste-ff] dedicated to this. Best refer to that
repo for more information.

# Home Internet Speedtest

In order to ensure my WAN connection is stable I run a speedtest using
[this container][ref-speedtest] and then integrate the metrics into my
Prometheus and Grafana servers. Using something like this:
```
docker run -d --restart=always \
  -p 9469:9469 \
  billimek/prometheus-speedtest-exporter:latest
```
See the referenced project for an example of the Prometheus scrape
config and the Grafana dashboard.

# Backups

We enable backups of homelab data to AWS S3 buckets. See the
[backup README.md](./backup/README.md) for details:

- **Disk images** — [mountpoint-s3][ref-mountpoint] and a system
  systemd timer (`batesste-s3-backup`, daily).
- **Hermes agent** — `hermes backup` plus AWS CLI upload
  (`batesste-hermes-s3-backup`, weekly user timer).
- **Docker volumes** — [offen/docker-volume-backup][ref-dvb] for
  Firefly III and Time Machine (see project compose files).

# Time Machine

In order to backup my MacBook we use [this timemachine
repo][ref-time-machine] on the home server. In order to get this
started and in order to provide AWS S3 backup of the volume that
contains the time machine data use the [docker
compose](./time-machine/batesste-time-machine.yml) file.

Place a ```.aws.creds.env``` file in the ```time-machine``` folder of
the form:
```bash
AWS_ACCESS_KEY_ID="<my AWS id>"
AWS_SECRET_ACCESS_KEY="<my AWS secret>
```
Then install using something like (only once ever):
```bash
cd time-machine
docker volume create batesste-time-machine
docker compose -f batesste-time-machine.dc.yml -d up
```
Note that since we are not broadcasting you will need to establish a
link to the server via the instructions in main repo.

[ref-aws-s3]: https://aws.amazon.com/s3/
[ref-homebridge]: https://homebridge.io/
[ref-ssl-certs]: https://www.kaspersky.com/resource-center/definitions/what-is-a-ssl-certificate
[ref-ssl-tutorial]: https://ongkhaiwei.medium.com/generate-lets-encrypt-certificate-with-dns-challenge-and-namecheap-e5999a040708
[ref-certbot]: https://eff-certbot.readthedocs.io/en/latest/index.html
[ref-godaddy]: https://godaddy.com/
[ref-firefly]: https://docs.firefly-iii.org/
[ref-batesste-ff]:https://github.com/sbates130272/batesste-firefly-iii
[ref-speedtest]:https://github.com/billimek/prometheus-speedtest-exporter
[ref-mountpoint]: https://github.com/awslabs/mountpoint-s3
[ref-dvb]: https://github.com/offen/docker-volume-backup
[ref-time-machine]: https://github.com/mbentley/docker-timemachine
[ref-file-sd]: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config
[ref-homekit]: https://www.apple.com/home-app/
[ref-avahi]: https://avahi.org/
[ref-alloy]: https://grafana.com/docs/alloy/latest/
[ref-tailscale]: https://tailscale.com/
