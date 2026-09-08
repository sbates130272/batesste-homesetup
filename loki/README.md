# Loki

Centralised logs for the homelab. Loki runs on `snoc-beelink`
and every Linux host in the fleet ships its systemd journal
there with [Grafana Alloy][ref-alloy]. Queried from Grafana
through the `snoc-beelink-loki` datasource.

This is the other half of the monitoring setup. Prometheus
answers "the exporter is down"; until now nothing answered
"why", and finding out meant `ssh` plus `journalctl` on
whichever box was suspect.

## Directory Layout

```
loki/
  deploy.sh                     # repo -> Loki server (beelink only)
  loki.yml                      # server config -> /etc/loki/config.yml
  alloy/
    deploy-agent.sh             # repo -> Alloy agent (run per host)
    config.alloy                # agent config -> /etc/alloy/config.alloy
    avahi-services/
      alloy.xml                 # _alloy._tcp, for Prometheus discovery
```

## Packages

Both come from `apt.grafana.com`, which is already configured
on the beelink — it is where Grafana itself came from. No new
package source, no Docker, no hand-managed binaries.

```bash
sudo apt update
sudo apt install -y loki      # server, beelink only
sudo apt install -y alloy     # agent, every host
```

Alloy rather than Promtail. Nearly all Loki documentation still
shows Promtail; it reached end of life and is no longer
published to the Grafana apt repository at all.

## Storage

`/var/lib/loki` is its own 12G logical volume:

```bash
sudo lvcreate -L 12G -n loki-lv ubuntu-vg
sudo mkfs.ext4 /dev/ubuntu-vg/loki-lv
sudo mkdir -p /var/lib/loki
echo '/dev/ubuntu-vg/loki-lv /var/lib/loki ext4 defaults 0 2' \
    | sudo tee -a /etc/fstab
sudo mount /var/lib/loki
```

This is not tidiness. **Loki caps retention by time, not
size** — there is no size setting to configure — so the volume
boundary is the only hard limit that exists. `/` is at 72% and
carries Grafana, Prometheus, Firefly, Time Machine and 4GB of
journals; without the separate volume, one host in a log loop
fills the root filesystem and takes all of them down together.
`ubuntu-vg` had 135GB unallocated, so the space costs `/`
nothing.

`deploy.sh` warns if `/var/lib/loki` is not a separate mount
rather than assuming it.

## Retention

90 days, set by `limits_config.retention_period: 2160h`.

Two settings in `loki.yml` make that real, and both fail
quietly if dropped:

| Setting | If missing |
|---|---|
| `compactor.retention_enabled: true` | Compaction still runs, nothing is ever deleted, `retention_period` is ignored |
| `compactor.delete_request_store` | Loki refuses to start with retention enabled |

Retention changes are **not retroactive** — shortening the
window does not delete what has already been ingested under the
old one.

`schema_config.configs[0].from` must never be edited once data
exists. Every chunk written under that entry becomes unreadable
if it changes. To move to a new schema, *append* an entry with a
future date.

## Exposure

Loki binds `0.0.0.0:3100` directly. There is no nginx vhost in
front of it, so anything that can route to the beelink — LAN or
tailnet — can read logs, push logs, and issue delete requests
without authentication. That is the same trade already made for
the LAN Prometheus vhost, and it is what lets the fleet agents
push without managing credentials on four machines.

If that needs tightening later, the two-vhost pattern in
[nginx/sites-available/prometheus](../nginx/sites-available/prometheus)
is the drop-in answer: LAN unauthenticated, loopback with basic
auth for Tailscale Funnel. Retrofitting means changing the
Grafana datasource URL *and* `LOKI_PUSH_URL` on every host.

gRPC is bound to loopback, and `common.instance_addr` is pinned
to `127.0.0.1` to match. **Those two settings have to agree.**
Even as a single binary, Loki's components find each other over
gRPC through the ring rather than in-process, and by default they
register the outbound interface address — `10.0.0.15` here.
Loopback gRPC plus a `10.0.0.15` ring entry means every query
hangs while the journal fills with `connection refused` dialling
`10.0.0.15:9096`, and `/ready` still reports ready throughout.

## The agents

One `config.alloy` for the whole fleet. The only per-host
variable is where to push, which `deploy-agent.sh` derives from
the hostname and writes to `/etc/default/alloy`:

| Host | Push URL |
|---|---|
| `snoc-beelink` | `http://127.0.0.1:3100/...` |
| `snoc-thinkstation` (10.0.0.131) | `http://10.0.0.15:3100/...` |
| `snoc-strix` (10.0.0.70) | `http://10.0.0.15:3100/...` |
| `amd-laptop` (10.0.0.107) | `http://10.0.0.15:3100/...` |

Everything but the beelink pushes over the LAN. A host on the
tailnet could push from anywhere with
`--push-url http://snoc-beelink.fold-leaffish.ts.net:3100/loki/api/v1/push`,
but none currently needs it: `amd-laptop` is the one machine that
leaves the house and it is **not on the tailnet at all**, so it
ships logs only while it is home.

`snoc-shannon` (macOS) and `snoc-gaming` (Windows) are not
covered.

### The host label is not always the hostname

`amd-laptop` answers to the kernel hostname `APCAN-MQ60818VV`.
Labelling its logs with that would leave them unjoinable to
every Prometheus metric, which is keyed on `server_name` —
Prometheus already fights the same problem, which is why
`prometheus.yml` rewrites hsa-snoop's `host` label.

`deploy-agent.sh` therefore maps kernel hostname to homelab name
through a small table and passes the result to Alloy as
`LOKI_HOST_LABEL`. Anything not in the table keeps its own short
hostname. Override with `--host-label`.

### amd-laptop's metrics are not scraped

It ships logs correctly, but the beelink cannot reach its Alloy
metrics port. Alloy listens on `*:12345` and the INPUT policy is
ACCEPT with no rules, yet 12345 and 12346 both time out.

That is an allowlist below iptables, not a blanket block: 9100
(node-exporter) and 5000 (the GPU exporter) both answer from the
same source. So this is fixable — it needs an explicit inbound
rule for 12345 on that machine, the same shape as the
node_exporter rules in [snoc-gaming.md](../snoc-gaming.md).

Until that rule exists it stays out of
`prometheus/targets/alloy.json`, because a target that can never
come up trains you to ignore a red light. The cost is that a
silent failure of *its* agent will not show up in Prometheus;
the signal there is the absence of recent logs under
`{host="amd-laptop"}`.

### Things that fail silently

Every one of these leaves Alloy running, every component
reporting healthy, and no logs arriving.

- **Group membership.** The `alloy` user must be in `adm` and
  `systemd-journal` to read the journal at all.
  `deploy-agent.sh` does this; it is the first thing to check
  when a host goes quiet.
- **`__journal__systemd_unit` has two underscores** after
  `__journal`, because journald's own field is `_SYSTEMD_UNIT`.
  Alloy drops every `__journal_*` label before forwarding unless
  a relabel rule renames it, so a typo here ships logs that
  nobody can filter by unit.
- **`sys.env("LOKI_PUSH_URL")` reads the process
  environment**, not a login shell's. It has to be in
  `/etc/default/alloy`, which the unit pulls in via
  `EnvironmentFile`. Exporting it from a profile does nothing,
  and `sys.env` returns an empty string for a variable it
  cannot see rather than failing. The same applies to
  `LOKI_HOST_LABEL`.
- **`loki.source.journal` overwrites `job`.** Setting
  `job = "systemd-journal"` in its `labels` argument silently
  yields `job = "loki.source.journal.read"` instead — the
  component ID. The `loki.relabel "journal_job"` stage between
  the source and the writer is what makes it stick, and it is
  there for that reason alone.

`max_age = "12h"` on the journal source is also deliberate.
`/var/log/journal` is persistent here and holds 4GB on the
beelink alone; without it a fresh agent replays the entire
history on first start.

## Prometheus integration

Both components are scraped, via `loki.json` and `alloy.json` in
[prometheus/targets/](../prometheus/targets/). Loki serves
`/metrics` on 3100, Alloy on 12345.

The agents bind their HTTP server to `0.0.0.0:12345` (the
packaged default is loopback) so the beelink can scrape them.
`avahi-services/alloy.xml` registers `_alloy._tcp` for
auto-discovery, matching how node-exporter is found — though
only the beelink has Avahi installed today, so the static target
file is what actually finds the fleet.

## Workflow

### Deploying the server (beelink)

```bash
cd loki
./deploy.sh          # --dry-run to preview
```

Validates with `loki -verify-config` before touching `/etc`,
the same gate `prometheus/deploy.sh` applies with `promtool`,
then creates the data directories `loki:loki` and restarts the
service. Ownership mismatches under `/var/lib/loki` are the
most common Loki failure and surface only as bare 500s on push,
with the real error in the server's own journal.

### Deploying an agent (any host)

```bash
cd loki/alloy
./deploy-agent.sh    # --dry-run to preview
```

Run it on the machine itself, the same way
`prometheus/avahi-services/` files are installed.

### Checking it works

```bash
systemctl status loki
curl -s localhost:3100/ready
journalctl -u loki | grep -i retention        # compactor started?
curl -s localhost:3100/loki/api/v1/label/host/values
```

The last one should list every host with a running agent.

[ref-alloy]: https://grafana.com/docs/alloy/latest/
