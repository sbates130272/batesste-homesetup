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
    amd-related/              # folder: AMD Related
      cpu-gpu-monitoring.json
      cursor-usage.json
    general/                  # folder: (root)
      lan-overview.json
    home-network-related/     # folder: Home Network Related
      emporia-smartplugs-dashboard.json
      icloud-dashboard.json
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
      general/
        amd-vllm-inference.json
        hsa-snoop.json
        lemonade-built-in-metrics.json
        llamacpp-server-prometheus.json
      home-network-related/
        nvme-exporter-device-metrics.json
        openai-exporter.json
      rocm-aic-related/       # folder: ROCm AIC Related
        rocm-aic-vllm-lmcache.json
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

Two datasources are configured via the provisioning YAML
under `provisioning/datasources/`:

| Name | Type | UID | URL |
|------|------|-----|-----|
| `snoc-beelink-prometheus` | Prometheus | `ae8pyuqoyonpca` | `http://10.0.0.15:9090/prometheus` |
| `firefly-mysql` | MySQL | `P382BE89091B0B8E6` | `127.0.0.1:3306` |

Both UIDs are **pinned deliberately**. Every dashboard
JSON in this repo hardcodes them; if Grafana were left to
generate its own on a rebuild, every panel would lose its
datasource. Don't change them without rewriting the
dashboards to match.

Both are also `editable: false`. Prometheus previously
drifted from this file because the URL had been edited in
the UI — change it here and run `./deploy.sh` instead.

The Firefly III MySQL datasource connects to the
MariaDB container on the Docker bridge network
(`172.20.0.2:3306`) using the `firefly` database
user. The password is stored in the
`FIREFLY_DB_PASSWORD` environment variable in
`grafana-server.defaults` (deployed to
`/etc/default/grafana-server`). See
`firefly-db-init.sql` for the one-time view setup.

## Dashboards (18 total)

`provisioning/dashboards/dashboards.yaml` tells Grafana to
watch `/var/lib/grafana/dashboards/<folder>/` for JSON
files. First-party providers set `allowUiUpdates: true`, so
dashboards can be edited in the UI and pulled back with
`./sync-dashboards.sh --pull`.

Each provider also pins `folderUid`. Provisioning matches
folders by title alone and will create a *second* folder
with the same name rather than adopt an existing one;
pinning the UID prevents that and keeps folder identity
stable across a rebuild.

| Folder | Dashboard | Description |
|--------|-----------|-------------|
| AMD Related | Lemonade: CPU & GPU Monitoring | GPU/CPU/Lemonade AI server metrics |
| AMD Related | Cursor IDE Usage | Cursor API cost, tokens, quotas, and usage |
| General | Home LAN Overview | Fleet, services, power, AI, storage summary |
| Home Network | Emporia SmartPlugs | Home power monitoring via smartplugs |
| Home Network | iCloud | Device location tracking, photos, contacts |
| Home Network | Node Exporter Full | Full node-exporter metrics (upstream 1860) |
| Home Network | Node Exporter Overview | Fleet summary table |
| Home Network | Node Exporter WiFi | WiFi signal/throughput stats |
| Home Network | Speedtest WAN Testing | WAN speed/latency/jitter |
| Personal Finance | Firefly III Overview | Income, spending, investments, category breakdown |
| ROCm XIO Related | rocm-xio dashboard | NVMe/RDMA xio benchmark results |

Adopted third-party dashboards (see below):

| Folder | Dashboard |
|--------|-----------|
| General | AMD vLLM Inference Dashboard |
| General | HSA Snoop |
| General | Lemonade Metrics Dashboard |
| General | llama.cpp server (Prometheus /metrics) |
| Home Network | NVMe Exporter Device Metrics |
| Home Network | OpenAI Exporter |
| ROCm AIC Related | ROCm(tm) AMD Infinity Context Dashboard |

## Third-party dashboards

Several dashboards on the server came from elsewhere and
were tracked nowhere, so a rebuild would have lost them.
They now live under `vendor/`, with provenance recorded in
`vendor/manifest.yaml`: UID, folder, upstream URL (or
`local-import` where the origin is unknown), and the date
the JSON was captured.

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

Five dashboards — four vendor, plus `lan-overview` — were
stored by Grafana in the v2 dashboard schema
(`elements`/`layout` rather than `panels`), which this repo
does not track. They were captured by reading them back
through the v1beta1 API, which renders the classic schema
whatever is stored. Those files are therefore a *rendering*
of what was running, not the stored bytes; deploying them
converts the server's copy to v1 for real. That conversion
is complete and every dashboard on the server is now
file-provisioned.

## Investment Accounts

The Firefly III Overview dashboard includes an
Investments section that tracks CIBC investment
account balances via SimpleFIN. These accounts use
`sync_mode: "balance_only"` in the SimpleFIN sync
script (`~/.openclaw/workspace/simplefin/scripts/`),
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
