# Grafana

This directory contains the source-controlled Grafana
configuration for the `snoc-beelink` home server. It
manages dashboard JSON files, datasource provisioning,
and dashboard provider configuration.

## Directory Layout

```
grafana/
  deploy.sh                   # deploy to system paths
  export-dashboards.sh        # pull dashboards from API
  provisioning/
    dashboards/
      dashboards.yaml         # dashboard provider config
    datasources/
      datasources.yaml        # Prometheus datasource
  dashboards/
    amd-related/              # folder: AMD Related
      cpu-gpu-monitoring.json
      cursor-usage.json
      rocm-xio-dashboard.json
    general/                  # folder: (root)
      lan-overview.json
    home-network-related/     # folder: Home Network Related
      emporia-smartplugs-dashboard.json
      icloud-dashboard.json
      node-exporter-full.json
      node-exporter-overview.json
      node-exporter-wifi.json
      speedtest-wan-testing.json
```

## Datasource

A single Prometheus datasource is configured pointing at
`http://localhost:9090`. This is deployed via the
provisioning YAML under `provisioning/datasources/`. All
dashboards use a `${datasource}` template variable so
they are portable across Grafana instances.

## Dashboards (10 total)

Dashboard JSON files are organized by Grafana folder.
The `provisioning/dashboards/dashboards.yaml` file tells
Grafana to watch `/var/lib/grafana/dashboards/<folder>/`
for JSON files. `allowUiUpdates` is set to `true` so
dashboards can still be edited in the Grafana UI and
then re-exported.

| Folder | Dashboard | Description |
|--------|-----------|-------------|
| AMD Related | CPU & GPU Monitoring | GPU/CPU/Lemonade AI server metrics |
| AMD Related | Cursor IDE Usage | Cursor API cost, tokens, quotas, and usage |
| AMD Related | rocm-xio dashboard | NVMe/RDMA xio benchmark results |
| General | Home LAN Overview | Fleet, services, power, AI, storage summary |
| Home Network | Emporia SmartPlugs | Home power monitoring via smartplugs |
| Home Network | iCloud | Device location tracking, photos, contacts |
| Home Network | Node Exporter Full | Full node-exporter metrics (upstream 1860) |
| Home Network | Node Exporter Overview | Fleet summary table |
| Home Network | Node Exporter WiFi | WiFi signal/throughput stats |
| Home Network | Speedtest WAN Testing | WAN speed/latency/jitter |

## Workflow

### Deploying changes from the repo to Grafana

After editing dashboard JSON files or provisioning YAML
in this repo, deploy them to the live Grafana instance:

```bash
cd grafana
./deploy.sh
```

This copies provisioning configs to
`/etc/grafana/provisioning/`, dashboard JSONs to
`/var/lib/grafana/dashboards/`, sets ownership to
`grafana:grafana`, and restarts the Grafana service. Use
`--dry-run` to preview without making changes.

### Exporting dashboards from Grafana to the repo

After editing a dashboard in the Grafana UI, export the
changes back to the repo:

```bash
cd grafana
./export-dashboards.sh
```

This pulls all dashboards via the Grafana HTTP API, strips
transient fields (`id`, `version`), and writes them to the
correct subdirectory under `dashboards/`. Review the diff
and commit the changes.

### Round-trip editing

The intended workflow is:

1. Edit a dashboard in the Grafana UI.
2. Run `./export-dashboards.sh` to capture the change.
3. Review the diff with `git diff`.
4. Commit and push.

Or the reverse:

1. Edit a dashboard JSON file in the repo.
2. Run `./deploy.sh` to push the change to Grafana.
3. Commit and push.

## Service Account Token

The export script authenticates via a Grafana service
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
