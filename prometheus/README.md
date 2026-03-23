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
| `_openai-exporter._tcp`      | 9185  | openai_exporter          |
| `_cursor-exporter._tcp`      | 9788  | cursor-exporter          |
| `_lemonade-exporter._tcp`    | 9091  | lemonade-exporter        |

The `server_name` label is derived automatically from the
Avahi hostname (e.g. `snoc-thinkstation.local` becomes
`server_name=snoc-thinkstation`).

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
