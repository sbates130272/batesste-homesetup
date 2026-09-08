# Prometheus Configuration

This directory contains the version-controlled Prometheus
configuration for the batesste homelab. Scrape targets are
managed via `file_sd_configs` so that new targets can be
added without editing `prometheus.yml`. Targets can be added
manually via JSON files or discovered automatically using
Avahi/mDNS.

## Directory Structure

```
prometheus/
  prometheus.yml              Main Prometheus config
  prometheus.defaults         $ARGS -> /etc/default/prometheus
  node-exporter-override.conf systemd drop-in for node-exporter
  deploy.sh                   Deploy config to /etc
  add-target.sh               Add a target manually
  discover-targets.sh         Discover targets via Avahi
  discover-targets.service    systemd oneshot unit
  discover-targets.timer      systemd timer (every 5min)
  avahi-services/
    node-exporter.xml         Template per exporter type
    ...
  targets/
    node.json                 Manual targets per job
    ...
    discovered/
      node.json               Auto-discovered targets
      ...
```

## Quick Start

### Manual targets

Add a target:
```bash
./add-target.sh node 10.0.0.50:9100 server_name=snoc-newbox
```

Deploy to the live system:
```bash
./deploy.sh
```

Deploy only target files (no restart needed):
```bash
./deploy.sh --targets-only
```

Preview without changes:
```bash
./deploy.sh --dry-run
```

`deploy.sh` prunes `/etc/prometheus/targets` down to what
the repo carries. Deploying is a copy, not a mirror, so a
target file deleted from the repo used to linger in `/etc`
forever — harmless while its job was also gone, but
re-adding a job of the same name silently picked the stale
targets back up. Editor backups (`*.json~`) are removed too;
`file_sd` only globs the exact paths named in
`prometheus.yml`, so they were never scraped, but they are
noise in a managed directory.

### Avahi auto-discovery

On each target machine, copy the appropriate Avahi service
XML file to `/etc/avahi/services/`. For example, on a
machine running `prometheus-node-exporter`:
```bash
sudo cp avahi-services/node-exporter.xml \
    /etc/avahi/services/
```

Then on the Prometheus server, run the discovery script:
```bash
./discover-targets.sh --deploy
```
This browses the LAN for each exporter service type,
generates `targets/discovered/<job>.json` files, and
deploys them to `/etc/prometheus/targets/discovered/`.
Prometheus picks up the new targets automatically.

To run discovery continuously, install the systemd timer:
```bash
sudo cp discover-targets.sh /usr/local/bin/
sudo cp discover-targets.service \
    /etc/systemd/system/
sudo cp discover-targets.timer \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now discover-targets.timer
```

### How manual and discovered targets coexist

Each job in `prometheus.yml` watches two files:

| Source                         | Purpose              |
| ------------------------------ | -------------------- |
| `targets/<job>.json`           | Manual/static        |
| `targets/discovered/<job>.json`| Auto-discovered      |

Prometheus merges both into the scrape pool for that job.
Manual targets are never modified by the discovery script.

## Avahi Service Types

Each exporter type uses a distinct DNS-SD service type:

| Service Type                 | Port  | Job                      |
| ---------------------------- | ----- | ------------------------ |
| `_node-exporter._tcp`        | 9100  | node                     |
| `_emporia-exporter._tcp`     | 9947  | emporia                  |
| `_speedtest-exporter._tcp`   | 9469  | speedtest_probe/exporter |
| `_icloud-exporter._tcp`      | 9948  | icloud                   |
| `_amd-gpu-exporter._tcp`     | 5000  | amd-gpu-metrics-exporter |
| `_ais-exporter._tcp`         | 9092  | ais-exporter             |
| `_rdma-exporter._tcp`        | 9879  | rdma-exporter             |
| `_nvme-exporter._tcp`        | 9998  | nvme-exporter            |
| `_hsa-snoop._tcp`            | 9488  | hsa-snoop                |
| `_openai-exporter._tcp`      | 9185  | openai_exporter          |
| `_cursor-exporter._tcp`      | 9788  | cursor-exporter          |
| `_alloy._tcp`                | 12345 | alloy                    |

The `server_name` label is derived automatically from the
Avahi hostname (e.g. `snoc-thinkstation.local` becomes
`server_name=snoc-thinkstation`).

## Scrape Credentials

`snoc-strix` requires a bearer token for its Lemonade
endpoint, so the `lemonade-snoc-strix` job reads one from
`/etc/prometheus/secrets/lemonade-api-key`. That file is
deliberately **not** in this repo; create it on the
Prometheus host before running `deploy.sh`:

```bash
sudo install -d -m 0750 -o prometheus -g prometheus \
    /etc/prometheus/secrets
printf %s "$LEMONADE_API_KEY" \
    | sudo tee /etc/prometheus/secrets/lemonade-api-key \
      >/dev/null
sudo chown prometheus:prometheus \
    /etc/prometheus/secrets/lemonade-api-key
sudo chmod 0400 /etc/prometheus/secrets/lemonade-api-key
```

Use `printf` rather than `echo` — a trailing newline becomes
part of the token and the scrape returns 401.

Prometheus re-reads the file on every scrape, so rotating
the key needs no reload. `deploy.sh` refuses to run if the
file is missing, and CI validates against a placeholder.

### The lemonade-snoc-strix job

Lemonade exposes its own metrics endpoint at
`snoc-strix.fold-leaffish.ts.net:13305` over Tailscale, with
TLS and a bearer token. The Tailscale certificate verifies
against the system trust store, so no `tls_config` is
needed.

The job uses `static_configs`, breaking the file_sd
convention used elsewhere, because this is a single known
endpoint rather than a discoverable fleet. It sets
`server_name: snoc-strix` by hand to match the label file_sd
applies to other jobs — the Lemonade dashboard drives its
instance picker from
`label_values(lemonade_server_up, server_name)`, so that
label is load-bearing.

A previous `lemonade-exporter` job scraped `:9091` on both
`snoc-strix` and `snoc-thinkstation` via file_sd and Avahi.
No such exporter ever existed: `max_over_time(up[365d])` was
`0` for both targets across the entire retention window. The
job, its target file, and its Avahi service definition were
removed in favour of Lemonade's built-in endpoint above.

### The amd-gpu-metrics-exporter job

**In the TSDB this job's metric names are always `amd_gpu_*`
and `amd_pcie_*`, never bare `gpu_*` — but that is enforced
here, not upstream.** `MetricsFieldPrefix: "amd_"` is the
exporter's own packaged default, but it only holds if the
host actually uses the packaged config. At the time of
writing `snoc-gaming` is the last host serving bare names,
and not because of its version — it runs the same 1.5.1 as
everyone else, with `/etc/metrics/config.json` hand-trimmed
to `{"ServerPort": 5000}`, which discards the prefix along
with everything else in `CommonConfig`.

The split is not stable either way. `amd-laptop` moved from
bare to prefixed inside a single day after an exporter
upgrade, with no change on this box.

So a `metric_relabel_configs` rule rewrites `__name__` on
ingest, making the prefix an invariant of the TSDB rather
than a property of whatever each host happens to be running.
It is fully anchored, so already-prefixed samples pass
through untouched and the rule is a no-op on hosts that
already agree — which is why it stays even if they all do.
Without it an unprefixed host scrapes green and renders
empty on every panel, because the two vendored AMD
dashboards drive every query off a single `g_metrics_prefix`
variable set to `amd_`; see
[grafana/vendor/manifest.yaml](../grafana/vendor/manifest.yaml).

Fixing `config.json` on a host is worth doing, but it is not
a substitute for the rule: `amd-laptop` is a corporate
laptop, and a fix applied only there is a fix that is not in
this repo. Do both — the rule costs nothing once a host
agrees.

The exporter used to serve `card_model=""` on every host,
and Prometheus drops empty labels, so the label disappeared
entirely and GPU columns rendered blank. **No override
remains** — every host now self-reports:

| Host | card_model |
|---|---|
| `snoc-strix` | `AMD Radeon 8060S Graphics` |
| `amd-laptop` | `AMD Radeon(TM) 8060S Graphics` |
| `snoc-thinkstation` | `AMD Radeon RX 9070 XT` |
| `snoc-gaming` | `AMD Radeon RX 9070 XT` |

Each rule matched on `hostname;card_model` with an *empty*
`card_model`, so an exporter that starts populating the
field wins automatically and the rule becomes dead weight
rather than a wrong override. Keep that shape if a new card
ever turns up blank.

That is not a hypothetical, it is how all three overrides
died. Rules for `snoc-strix` and `amd-laptop` forced
`Radeon 8060S (Strix Halo)` while amdsmi had no gfx1151
support ([ROCm#6035](https://github.com/ROCm/ROCm/issues/6035));
`amdgpu-exporter` 1.5.1 reports the part natively and
disabled both. `snoc-gaming` self-reports and never needed
one. `snoc-thinkstation` held out longest because it was
pinned on 1.5.0 from a loose `.deb` with no repo behind it —
upgrading it on 2026-09-08 retired the last rule.

### Upgrading a host to 1.5.1

`snoc-thinkstation` was the worked example. Its
`/etc/apt/sources.list.d/rocm.list` had the ROCm repo but
not the exporter one, so `apt-cache policy` showed no
candidate beyond what was already installed:

```bash
# the second line is what snoc-strix already had
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/device-metrics-exporter/apt/1.5.1 noble main' \
  | sudo tee -a /etc/apt/sources.list.d/rocm.list
sudo apt-get update
sudo apt-get install -y --only-upgrade \
  -o Dpkg::Options::="--force-confnew" amdgpu-exporter
sudo systemctl enable --now amd-metrics-exporter
```

`--force-confnew` is deliberate: the whole point is to take
the packaged `config.json` back, since the local one had
been trimmed to `{"ServerPort": 5000}`. Back it up first if
it holds anything you want.

**The last line is not optional.** The upgrade removes the
`multi-user.target.wants` symlink and does not restore it,
so the exporter comes back *disabled and stopped* while
`apt` reports success and `needrestart` says no services
need restarting. Check `systemctl is-enabled` afterwards.

Cost of taking the packaged config on that host was one
metric family, `gpu_vram_max_bandwidth` (103 → 102), which
no dashboard queries.

GPU *presence* is deliberately not detected from this job —
see [the Grafana README](../grafana/README.md) for why LAN
Overview spines its inventory on
`node_hwmon_chip_names{chip_name="amdgpu"}` instead.

### The hsa-snoop job

[hsa-snoop](https://github.com/sbates130272/hsa-snoop)
serves `hsa_*` and `ais_*` families from its own endpoint
when built with `-DHSA_SNOOP_PROMETHEUS=ON` and run as
`sudo hsa-snoop --all --prometheus` (default port 9488).
The `ais_*` families additionally require `--ais-snoop`.

It is a separate job from `ais-exporter`, despite the
overlapping metric names — `ais-exporter` is a different
process on `:9092`.

The job carries a `metric_relabel_configs` rule copying
`server_name` into `host`. hsa-snoop already stamps every
metric with a constant `host` label from `gethostname()`,
so the rule is a normalisation rather than a fix: it keeps
the HSA Snoop dashboard's picker
(`label_values(hsa_snoop_up, host)`) agreeing with the
`server_name` every other dashboard uses, even if the box's
kernel hostname drifts from its homelab name. Drop the rule
if you would rather see the self-reported hostname.

Note that `hsa_errors_total` and `ais_tx_errors_total` are
declared upstream but only materialise once a labelled child
exists, so those panels read empty on a healthy exporter.

## Things prometheus.yml cannot express

Two files here configure the *processes* rather than the
scrape config. Neither has any representation in
`prometheus.yml`, which is exactly why they are easy to lose:
a server rebuilt without them comes up healthy, with a
config that diffs clean against this repo, and is quietly
missing all of it.

`prometheus.defaults` → `/etc/default/prometheus` supplies
`$ARGS`, which the unit expands into `ExecStart`:

| Flag | Lost without it |
|---|---|
| `--web.enable-remote-write-receiver` | Every series pushed in from external clusters — the bulk of the TSDB |
| `--storage.tsdb.retention.size=20GB` | The only size cap; `retention` in the YAML bounds time, not disk |
| `--web.listen-address=127.0.0.1:9092` | nginx owns 9090 and fronts this listener |
| `--web.route-prefix=/` | A bare `/metrics`, which the `prometheus` job scrapes |
| `--web.external-url=...` | Usable links in the UI and in alerts |

`node-exporter-override.conf` →
`/etc/systemd/system/prometheus-node-exporter.service.d/override.conf`
adds `--collector.wifi`, which LAN Overview's *WiFi (dBm)*
column depends on. Its empty `ExecStart=` line is load-bearing:
systemd treats `ExecStart` as a list, so a drop-in that
appends without first clearing the packaged entry fails the
unit at `daemon-reload`.

`deploy.sh` handles both, and only acts when they actually
change — `$ARGS` needs a **restart** rather than a reload
(EnvironmentFile is not re-read on reload), and a restart
drops remote-write for as long as TSDB replay takes.

## Retired jobs

Removed on 2026-09-08, recorded here for the same reason
[grafana/vendor/manifest.yaml](../grafana/vendor/manifest.yaml)
records retired dashboards — so a future reader finds an
answer rather than an absence:

| Job | Was | Why |
|---|---|---|
| `amd-sysfs-gpu-exporter` | `:9401`, a local Python exporter reading amdgpu sysfs | Superseded by `amd-gpu-metrics-exporter`; not running on any host |
| `vllm-exporter` | `:8000` on thinkstation and strix | Inference stack no longer resident |
| `lmcache-exporter` | `:6990`/`:6991` on thinkstation and strix | Ditto; panels lived on the retired `rocm-aic-dashboard` |
| `llama-cpp-exporter` | `:8081` on amd-laptop | Ditto |

None had a `targets/` file or an Avahi service — they were
`static_configs` that predated the `file_sd` migration and
were dropped by it, surviving only in an editor backup under
`/etc`. `deploy.sh` now prunes `*.yml~` from `/etc/prometheus`
so no stray copy outlives the repo again.

## First-Time Migration

When migrating from a `static_configs` based setup to
`file_sd_configs` for the first time:

1. Run `./deploy.sh --dry-run` to preview the changes.
2. Run `./deploy.sh` to deploy. The script backs up the
   existing `prometheus.yml` before overwriting it.
3. Verify Prometheus is healthy:
   ```bash
   systemctl status prometheus
   curl -s localhost:9090/-/ready
   ```

Existing TSDB data is not affected by this migration. The
`job` and `instance` labels remain identical so Grafana
dashboards continue to work.
