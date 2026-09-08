# Grafana

This directory contains the source-controlled Grafana
configuration for the `snoc-beelink` home server. It
manages dashboard JSON files, datasource provisioning,
and dashboard provider configuration.

## Directory Layout

```
grafana/
  deploy.sh                   # repo -> Grafana
  sync-dashboards.sh          # compare / Grafana -> repo
  firefly-db-init.sql         # Firefly III DB user + views
  provisioning/
    dashboards/
      dashboards.yaml         # dashboard provider config
    datasources/
      datasources.yaml        # Prometheus + MySQL datasources
  dashboards/                 # first-party, one dir per Grafana folder
    general/                  # folder: (root)
      lan-overview.json
    home-network-related/     # folder: Home Network Related
      emporia-smartplugs-dashboard.json
      node-exporter-full.json
      node-exporter-overview.json
      node-exporter-wifi.json
      speedtest-wan-testing.json
    personal-finance/         # folder: Personal Finance
      firefly-overview.json
    rocm-xio-related/         # folder: ROCm XIO Related
      rocm-xio-dashboard.json
  vendor/                     # adopted third-party dashboards
    manifest.yaml             # provenance for each one
    dashboards/
      amd-related/
        hsa-snoop.json
        lemonade-built-in-metrics.json
      home-network-related/
        nvme-exporter-device-metrics.json
    retired/                  # deleted from the server, kept for recovery
      hsa-snoop-v1.json
      rocm-aic-dashboard.json
```

The directory name under `dashboards/` and
`vendor/dashboards/` is the folder slug, and every one must
have a matching provider in
`provisioning/dashboards/dashboards.yaml`. `deploy.sh`
asserts this before it copies anything — adding a
directory without a provider is an error rather than a
silent no-op.

## Datasources

Three datasources are configured via the provisioning YAML
under `provisioning/datasources/`:

| Name | Type | UID | URL |
|------|------|-----|-----|
| `snoc-beelink-prometheus` | Prometheus | `ae8pyuqoyonpca` | `http://10.0.0.15:9090/prometheus` |
| `snoc-beelink-loki` | Loki | `snoc-beelink-loki` | `http://10.0.0.15:3100` |
| `firefly-mysql` | MySQL | `P382BE89091B0B8E6` | `127.0.0.1:3306` |

All three UIDs are **pinned deliberately**. Every dashboard
JSON in this repo hardcodes them; if Grafana were left to
generate its own on a rebuild, every panel would lose its
datasource. Don't change them without rewriting the
dashboards to match.

They are also all `editable: false`. Prometheus previously
drifted from this file because the URL had been edited in
the UI — change it here and run `./deploy.sh` instead.

Loki is the fleet log store. `snoc-beelink`,
`snoc-thinkstation`, `snoc-strix` and `amd-laptop` ship their
journals to it through Grafana Alloy, and it is
unauthenticated on the LAN and the tailnet for the same
reason the LAN Prometheus vhost is. Its config, retention and
agent rollout live in [loki/README.md](../loki/README.md).

The Firefly III MySQL datasource connects to the
MariaDB container on the Docker bridge network
(`172.20.0.2:3306`) using the `firefly` database
user. The password is stored in the
`FIREFLY_DB_PASSWORD` environment variable in
`grafana-server.defaults` (deployed to
`/etc/default/grafana-server`). See
`firefly-db-init.sql` for the one-time view setup.

## Dashboards (11 total)

`provisioning/dashboards/dashboards.yaml` tells Grafana to
watch `/var/lib/grafana/dashboards/<folder>/` for JSON
files. First-party providers set `allowUiUpdates: true`, so
dashboards can be edited in the UI and pulled back with
`./sync-dashboards.sh --pull`.

Most providers also pin `folderUid`. Provisioning matches
folders by title alone and will create a *second* folder
with the same name rather than adopt an existing one;
pinning the UID prevents that and keeps folder identity
stable across a rebuild. The exception is
`vendor-home-network-related`, which cannot pin
`ee8pz914edpfkf` because `home-network-related` already
does and Grafana rejects two providers claiming one UID.
Title matching is safe there only while that provider
survives; `dashboards.yaml` says what to do if it doesn't.

| Folder | Dashboard | Description |
|--------|-----------|-------------|
| General | Home LAN Overview | Fleet, services, power, AI, storage summary |
| Home Network | Emporia SmartPlugs | Home power monitoring via smartplugs |
| Home Network | Node Exporter Full | Full node-exporter metrics (upstream 1860, diverged) |
| Home Network | Node Exporter Overview | Fleet summary table |
| Home Network | Node Exporter WiFi | WiFi signal/throughput stats |
| Home Network | Speedtest WAN Testing | WAN speed/latency/jitter |
| Personal Finance | Firefly III Overview | Income, spending, investments, category breakdown |
| ROCm XIO Related | rocm-xio dashboard | NVMe/RDMA xio benchmark results |

Adopted third-party dashboards (see below):

| Folder | Dashboard | Upstream |
|--------|-----------|----------|
| AMD Related | AMD GPU (device-metrics-exporter) | [ROCm/device-metrics-exporter v1.5.1](https://github.com/ROCm/device-metrics-exporter/blob/v1.5.1/grafana/dashboard_gpu.json) |
| AMD Related | AMD GPU Fleet Overview | [ROCm/device-metrics-exporter v1.5.1](https://github.com/ROCm/device-metrics-exporter/blob/v1.5.1/grafana/dashboard_overview.json) |
| AMD Related | HSA Snoop | [sbates130272/hsa-snoop](https://github.com/sbates130272/hsa-snoop) |
| AMD Related | Lemonade Metrics Dashboard | [grafana.com 25422](https://grafana.com/grafana/dashboards/25422-lemonade-built-in-metrics/) |
| Home Network | NVMe Exporter Device Metrics | [grafana.com 12736](https://grafana.com/grafana/dashboards/12736-nvme-exporter/) |

## Third-party dashboards

Several dashboards on the server came from elsewhere and
were tracked nowhere, so a rebuild would have lost them.
They now live under `vendor/`, with provenance recorded in
`vendor/manifest.yaml`: UID, folder, upstream URL, and the
date the JSON was captured.

All five surviving vendor dashboards have a real upstream,
so refreshing one is fetch → diff → commit rather than
"export whatever is running". Note that each has *diverged*
from its upstream deliberately, and the manifest says how —
a blind overwrite would undo local fixes. Do not read a
missing `gnetId` as proof a dashboard was hand-built; it is
recorded only on import *by ID*, and pasting the same JSON
leaves no trace of its origin. The surviving signal is a
`DS_*` datasource variable, which grafana.com requires of
published dashboards.

`vendor-*` providers set `allowUiUpdates: false` on
purpose. Making these read-only on the server is what keeps
"sync" meaningful — to change one, edit the JSON here (or
re-fetch it from its recorded upstream) and run
`./deploy.sh`.

`vendor/retired/` holds dashboards deleted from the server,
kept so they can be restored by hand. It sits outside
`vendor/dashboards/` deliberately, so no provider picks
them up and re-creates them.

### Recovered from v2 storage

Five dashboards were stored by Grafana in the v2 dashboard
schema — `elements`/`layout` rather than `panels` — which
this repo does not track. Two survive today,
`lemonade-built-in-metrics` and `lan-overview`; the other
three were removed on 2026-09-03 as out of date.

They were captured by reading them back through the v1beta1
API, which renders the classic schema whatever is stored.
Those files are therefore a *rendering* of what was running,
not the stored bytes; deploying them converts the server's
copy to v1 for real. That conversion is complete and every
dashboard on the server is now file-provisioned.

## The 2026-09-03 scrub

Every dashboard except Firefly III Overview was audited
against live Prometheus, each exporter's own `/metrics`,
and exporter source where a metric was absent from both.
That last step matters, because three different things
present identically as an empty panel and want opposite
responses:

| Cause | Example | Response |
|---|---|---|
| Metric renamed or mistyped | `speedtest_jitter_seconds` → `speedtest_jittter_seconds` | Fix the query |
| Exporter alive, family never materialised | `hsa_errors_total` | **Leave alone** |
| Exporter alive, collector not enabled | `node_processes_pids` | Enable the collector |
| Feed gone | all `icloud_*`, all `cursor_usage_events_*` | Retire |
| Hardware does not have the sensor | `amd_gpu_hbm_temperature` | **Leave alone** |

The second row is the trap. prometheus-cpp does not
materialise a metric family until a labelled child exists,
so hsa-snoop's `hsa_errors_total` and `ais_tx_errors_total`
are declared upstream and simply have not fired yet. Four
working panels would have been "fixed" without that check.

The third row is the one that looks like a dashboard bug and
is not. Node Exporter Full's entire *System Processes* row —
PIDs Number and Limit, Threads Number and Limit, Processes
State — queries `node_processes_*`, which node-exporter emits
only under `--collector.processes`. That flag is off by
default and off on every host here, so the row is blank
fleet-wide while the scrape stays green. Same shape as
`--collector.wifi`, which
[prometheus/node-exporter-override.conf](../prometheus/node-exporter-override.conf)
already carries for exactly this reason.

The last row covers the two vendor AMD panels that read
`amd_gpu_hbm_temperature`. Navi 48 and Strix Halo use GDDR6
and unified LPDDR5X respectively; neither has HBM, so the
sensor does not exist and never will on this fleet.

Two dashboards were retired: **Cursor IDE Usage** (24 of 28
panels dead) and **iCloud** (6 of 6). Both were exporter
failures, not query bugs — the iCloud job refuses
connections, and cursor-exporter answers scrapes while
emitting only its `cursor_subscription_*` gauges because
its Cursor API calls fail. LAN Overview's *OpenAI Daily
Cost* went the same way: `openai_api_daily_cost` has never
existed in this TSDB and the exporter serves only Go
runtime metrics. The `up{}` health tiles for all three
stay, because the jobs are still in the scrape config and
the tiles correctly report the outage.

### Node Exporter Full has diverged from 1860

It came from [grafana.com
1860](https://grafana.com/grafana/dashboards/1860-node-exporter-full/)
(`gnetId: 1860`, not recorded in the JSON — it was pasted
rather than imported by ID). All 116 panels now carry
descriptions, several units were corrected, and four dead
panels were repointed at metrics this fleet actually
collects:

- *Interrupts Detail* → `node_intr_total`, since
  `--collector.interrupts` is off and the per-IRQ
  breakdown is unavailable.
- *TCP Stat* → `node_sockstat_TCP_*`, since
  `--collector.tcpstat` is off.
- *TCP Connections* — dropped `node_netstat_Tcp_MaxConn`,
  which node-exporter does not export.
- *Processes Memory* — dropped `irate()` from two gauges,
  dropped a duplicate target, and dropped
  `process_virtual_memory_max_bytes`, which reads 1.8e19
  here because `RLIMIT_AS` is unlimited.

The panels still marked "Enable with `--collector.processes`"
were left alone: they document their own absence, and there
is no aggregate substitute.

**A refresh from 1860 is now a manual merge, not a
review.** That is the cost of the pass, accepted
deliberately.

### GPU detection is spined on hwmon

LAN Overview's *GPU Inventory* used to enumerate cards from
`amd-gpu-metrics-exporter`, which meant a GPU became
invisible the moment its exporter broke — the failure mode
looked identical to having no GPU at all. On
`snoc-thinkstation` that hid a Radeon RX 9070 XT for weeks:
`/etc/modprobe.d/amdgpu-blacklist.conf` kept the driver
unbound, `gpuagent` failed `rsmi_init` and core-dumped 6,198
times, and the exporter answered scrapes with an empty
registry.

The panel is now spined on
`node_hwmon_chip_names{chip_name="amdgpu"}`, which
node-exporter emits whenever the kernel driver is bound —
independent of any AMD userspace. Temperature and a power
fallback come from the same hwmon chip. The vendor exporter
still supplies `card_model` and `gpu_gfx_activity`, and its
`up` value is its own column, so the two detectors can
disagree visibly:

| PCIe | Exporter | Meaning |
|---|---|---|
| set | UP | healthy |
| set | DOWN | exporter fault; card is fine |
| blank | UP | driver never bound — check `/etc/modprobe.d` |

The old *GPU Exporter Health* table was folded into this
panel; the `up{job="amd-gpu-metrics-exporter"}` stat tile
under *Service Health* is unchanged.

The **PCIe** column is `label_replace`d out of the hwmon
`chip` label rather than shown raw. hwmon reports the whole
device path with the dots mangled to underscores —
`0000:0f:00_0_0000:10:00_0` — of which only the trailing
component is the card's own BDF. The column shows
`0000:10:00.0`. The regex is anchored on the last two groups
for that reason; matching the first would name the bridge,
not the GPU.

The column is blank on `snoc-gaming` and `amd-laptop` and
will stay that way: both run under WSL2, which exposes no
hwmon amdgpu chip. That is the same reason their Temp column
is empty, and it is not the "driver never bound" case in the
table above.

The **GPU** column spines on `amd_gpu_health`, not on
`amd_gpu_average_package_power`. It used to use the latter,
which silently cost the column on both WSL hosts: neither
exposes package power, so `card_model` came back on no series
and the two cards showed as nameless rows despite their
exporters being up and self-reporting the model correctly.
`amd_gpu_health` is emitted by all four. Any column that only
needs a *label* should spine on the metric with the widest
coverage, not on whichever one happened to be nearby.

The **ROCm** column reads `rocm_version_info`, published by
the textfile collector in
[prometheus/textfile-collectors/](../prometheus/textfile-collectors/)
on all four GPU hosts. The query is scoped to `job="node"`
because a remote-written series from the
`rocm-aic-core42-mi300` cluster carries
`server_name="g04u07"`, and this panel joins on
`server_name` — unscoped, it grows a phantom row.

There is deliberately no exporter-version column. The AMD
device-metrics-exporter serves 151 `amd_*` families and no
build-info metric of any kind; `driver_version` reads `"N/A"`
and `vbios_version` is the card's firmware, not the exporter.

The exporter's metric names are `amd_gpu_*`, not bare
`gpu_*` — `MetricsFieldPrefix: "amd_"` is its packaged
default. The three GPU Inventory targets that read from this
job (Power, Busy, GPU) use the prefixed names accordingly;
the two that spine on hwmon do not.

`card_model` used to arrive empty from the exporter, and
Prometheus drops empty labels, so `prometheus.yml` hardcoded
it per host via `metric_relabel_configs`. No host needs that
any more — all four self-report since `snoc-thinkstation` was
upgraded off 1.5.0, and the last override has been removed.
See [prometheus/README.md](../prometheus/README.md).

### Node Fleet reports the link, not just the WiFi signal

`snoc-thinkstation` has both wired and wireless interfaces
(`eno1`, `eno2`, `wlp17s0`). With only a **WiFi (dBm)**
column, a dual-homed host reads as being on WiFi whenever
the radio is associated, whether or not any traffic uses it
— and reads identically to a host that has no ethernet at
all.

The **Link** column resolves that. It encodes the up
interfaces as a number the field mappings render as text:

| Value | Renders | Meaning |
|---|---|---|
| 0 | down | no physical interface up |
| 1 | WiFi | wireless only |
| 2 | Wired | ethernet only |
| 3 | Wired+WiFi | both |

The query is arithmetic rather than a label, on purpose. The
table joins every column on `instance`, so a query returning
one row per *interface* would duplicate the host's entire row
the moment a second link came up — which is precisely the
case this column exists to show. Summing a wired term worth 2
and a wireless term worth 1 keeps it at exactly one row per
host regardless of how many interfaces are up.

Each term is `or`-ed with a zeroed copy of the whole metric so
that a host with no matching interface still contributes a row
at 0, instead of dropping out of the `+` join and losing every
other column with it.

`tailscale0` is excluded by the `operstate="up"` filter — it
reports `unknown`, not `up`. The WSL hosts (`snoc-gaming`,
`amd-laptop`) show **Wired** for their `eth*` virtual NICs,
which is the honest answer for how the traffic leaves the VM
even though the physical link underneath may be wireless.

## Investment Accounts

The Firefly III Overview dashboard includes an
Investments section that tracks CIBC investment
account balances via SimpleFIN. These accounts use
`sync_mode: "balance_only"` in the SimpleFIN sync
script (`~/.hermes/workspace/simplefin/scripts/`),
which compares the SimpleFIN-reported balance to
Firefly III and creates adjustment transactions
categorised as "Investment - Valuation". The
`analysis_txs` SQL view tags this category as
`Transfer` so investment valuation changes do not
inflate income or expense totals in the cash flow
panels.

| Firefly Name              | Account | Type |
|---------------------------|---------|------|
| CIBC - Kids' RESP         | 2422    | RESP |
| CIBC - Stephen's LIRA     | 2397    | LIRA |
| CIBC - Stephen's TFSA     | 4254    | TFSA |
| CIBC - Stephen's RRSP     | 8774    | RRSP |
| CIBC - Stephen's FHSA     | 9439    | FHSA |

The dashboard panels query the Firefly database
directly using a `REGEXP` filter on account names
matching `RESP|LIRA|TFSA|RRSP|FHSA`.

## Data freshness

The Summary row leads with a **Days Since Last
Transaction** banner: green under a week, red past a
month. It is the most prominent thing on the
dashboard on purpose.

On 2026-05-07 the SimpleFIN bridge's connection to
CIBC started returning `Auth required`, and nothing
noticed until 2026-09-03 — four months and roughly
600 transactions later. Two failures compounded:

- **The sync stopped being scheduled.** Logs end at
  `simplefin-sync-2026-07-02_0801.log`; no timer or
  cron entry survives. There is still no schedule —
  the sync is run by hand.
- **When it did run, it reported success.** SimpleFIN
  signals a broken bank link in an `errors` array in
  an otherwise-200 response, still serving each
  account's last-known balance. The script ignored
  that field, so it compared frozen balances against
  the frozen values it had already imported and
  logged `BALANCE OK` for every account.

The sync script now reads the `errors` array, treats
a `balance-date` older than `--max-age` (default 8
days) as stale, refuses to call a stale match `OK`,
and exits non-zero in either case. A match against a
feed that has stopped refreshing is not agreement,
it is the same stale number on both sides.

Because SimpleFIN caps history at 90 days, the
2026-05-08 → 2026-06-05 window was already beyond
recovery by the time the outage was found. That gap
is being backfilled from a CIBC CSV export.

## Workflow

### Checking whether repo and server agree

```bash
cd grafana
./sync-dashboards.sh --check
```

Reports drift and exits non-zero if any is found; writes
nothing. It flags dashboards that differ, dashboards
running in Grafana that no repo file claims
(`UNTRACKED`), and repo files with no live counterpart
(`ORPHANED`).

It also scans the Grafana journal for dashboards
provisioning is refusing to write (`REJECTED`). That is a
separate failure from drift, and the comparison cannot see
it: a dashboard whose content already matches compares as
in-sync while silently discarding every subsequent edit.
This is not hypothetical — `amd-vllm-inference` and
`node-exporter-full` were once issued the same internal ID,
so Grafana rejected both writes for hours while `--check`
reported everything fine.

Neither `--pull` nor `--push` is the right response to
`REJECTED`: one would adopt a copy the server cannot
update, the other would send changes it will discard. Fix
the underlying rejection first.

The scan only runs against a local Grafana managed by
systemd, since the journal says nothing about a remote
`--url`. Where it cannot run it says so rather than imply a
clean bill of health. Override the unit name with
`GF_UNIT` if yours differs from `grafana-server`.

### Deploying changes from the repo to Grafana

```bash
cd grafana
./deploy.sh          # --dry-run to preview
```

Copies provisioning configs to `/etc/grafana/provisioning/`
and dashboard JSONs to `/var/lib/grafana/dashboards/`, sets
ownership to `grafana:grafana`, and restarts Grafana.

Deployment is a **mirror**: files removed from the repo are
removed from `/var/lib/grafana/dashboards/` too. That
matters when a dashboard moves between folders — without
pruning, the stale copy stays behind and two providers end
up fighting over the same UID.

### Exporting dashboards from Grafana to the repo

```bash
cd grafana
./sync-dashboards.sh --pull
```

Pulls dashboards via the Grafana API, strips transient
fields (`id`, `version`, `__inputs`), and updates files
**keyed by UID** so a dashboard renamed in the UI updates
its existing file rather than spawning a second one.
Anything Grafana doesn't provision from disk is filed under
`vendor/` for adoption. Review the diff and commit.

Files are written in a canonical form — keys sorted, and
`panels` sorted by grid position — and `--check` compares
in that same form. Both orderings are cosmetic (Grafana
lays panels out from `gridPos`, not array index), but
Grafana is free to vary them, and a single panel out of
position shifts every panel after it. Before canonicalising,
that made no-op diffs read as thousands of changed lines and
hid real edits inside them.

Reads are done through
`/apis/dashboard.grafana.app/v1beta1/...` rather than
`/api/dashboards/uid/...`, because the latter returns
whatever schema a dashboard happens to be stored as — and
Grafana 13 stores some of ours as v2, which would produce
thousands of lines of phantom diff against the v1 files on
disk.

### Round-trip editing

1. Edit a dashboard in the Grafana UI.
2. `./sync-dashboards.sh --pull`
3. `git diff`, then commit.

Or the reverse:

1. Edit a dashboard JSON file in the repo.
2. `./deploy.sh`
3. Commit.

### Moving a dashboard between folders

Provisioning honours `folderUid` when it *creates* a
dashboard, but will not relocate one that already exists.
To move a provisioned dashboard, remove its JSON from
`/var/lib/grafana/dashboards/`, restart Grafana so the
dashboard is deleted, then restore the file in its new
directory and restart again.

## Service Account Token

`sync-dashboards.sh` authenticates via a Grafana service
account token stored in `grafana-api.secrets` (gitignored
by the `*.secrets` pattern). To create one:

1. Log in to Grafana as an admin.
2. Go to **Administration > Service Accounts**.
3. Click **Add service account**.
4. Name it (e.g. `dashboard-exporter`), set role to
   **Viewer**.
5. Click **Add service account token** and copy the token.
6. Save it:

```bash
echo 'glsa_...' > grafana/grafana-api.secrets
```

The existing `openclaw` service account can also be used
if it has a valid token with at least Viewer permissions.
