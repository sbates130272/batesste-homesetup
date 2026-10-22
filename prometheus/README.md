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
  deploy.sh                   Deploy config to /etc
  add-target.sh               Add a target manually
  textfile-collectors/
    rocm-version.sh           Publishes rocm_version_info,
                              rocm_hip_version_info and
                              amdgpu_dkms_*
    rocm-version.service      systemd oneshot unit
    rocm-version.timer        systemd timer (hourly + on boot)
    wsl-wifi.sh               Publishes wsl_wifi_* (WSL hosts only)
    wsl-wifi.service          systemd oneshot unit
    wsl-wifi.timer            systemd timer (every 5min)
    s3-backup-age.sh          Publishes batesste_s3_backup_* (backup host)
    s3-backup-age.service     systemd oneshot unit
    s3-backup-age.timer       systemd timer (hourly + on boot)
    deploy-agent.sh           Run on each GPU host and the backup host
  emvue-exporter/
    labels.json               Per-plug Prometheus labels
    deploy.sh                 Run on snoc-beelink
  gh-actions-exporter/
    gh-actions-exporter.py    Publishes github_actions_*
    gh-actions-exporter.service  systemd unit
    deploy.sh                 Run on snoc-beelink
  targets/
    node.json                 Targets per job
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

## Exporter Ports

Every target is listed by hand in `targets/<job>.json`. One
port per job, by convention:

| Port  | Job                      |
| ----- | ------------------------ |
| 9100  | node                     |
| 9947  | emporia                  |
| 9469  | speedtest_probe/exporter |
| 9948  | icloud                   |
| 5000  | amd-gpu-metrics-exporter |
| 9879  | rdma-exporter            |
| 9998  | nvme-exporter            |
| 9488  | hsa-snoop                |
| 9185  | openai_exporter          |
| 9788  | cursor-exporter          |
| 9612  | gh-actions-exporter      |
| 12345 | alloy                    |

### Target discovery was retired

Until 6 October 2026 this directory also carried an
Avahi/mDNS discovery path: a `discover-targets.sh` browsing
twelve DNS-SD service types on a 5-minute timer, a set of
`avahi-services/*.xml` for each exporter host to publish, and
a second `targets/discovered/<job>.json` that every job merged
into its scrape pool.

None of it ever ran. The timer and its units were never
installed on `snoc-beelink`, `/usr/local/bin/discover-targets.sh`
did not exist, and `deploy.sh` never installed any of them. Nor
had the publishing half been set up: a dry run browsing all
twelve service types returned nothing, while `avahi-browse -at`
on the same host showed plenty of other services. Browsing
worked; no host was advertising.

The only measurable effect was thirteen `promtool check config`
warnings about `discovered/` paths that did not exist.

Reviving it needs **both** halves — the timer here and an
Avahi service file on every exporter host. Everything is in
git history. The class of bug it was meant to solve is real:
`snoc-shannon` carried two stale IPs for months because
nothing re-resolved it.

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

The `zot` job needs a second one,
`/etc/prometheus/secrets/zot-metrics-password`, created the
same way and subject to the same `printf` warning. The value
is `ZOT_METRICS_PASSWORD` in `zot/zot.secrets` on
`snoc-strix`; that file is the only copy, so read it there
rather than trying to recover it from the hash in
`/etc/zot/htpasswd`. `deploy.sh` refuses to run without this
file too.

### The zot job

The container registry on `snoc-strix` — see
[zot/README.md](../zot/README.md) — serves its own
`/metrics` on the same port as the registry API, so there is
no exporter and no second port to open.

It is the only `basic_auth` job in this config. zot's
`accessControl.metrics` names a single user, `metrics`, as
the only one allowed to read the endpoint; every other
account gets a 403 there, and anonymous gets a 401, while
both can still pull images. So a 401 or 403 on this job means
the password file here and `/etc/zot/htpasswd` on the
registry have drifted — not that the registry is down.

It does take the target down, though: Prometheus treats any
non-2xx scrape as a failure, so `up` goes to 0 and the
target reads exactly like an unreachable registry. The
distinction is in `lastError`, which says
`server returned HTTP status 403 Forbidden` rather than
`connection refused`. Check that before assuming the
registry has fallen over.

The target is the Tailscale name even though zot binds
`0.0.0.0:8080` and `10.0.0.242` would work. Two reasons: it
survives the DHCP lease moving, and the registry speaks
plain HTTP, so the tailnet is what keeps the `basic_auth`
credentials off the wire in clear.

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

### The emporia job

The Emporia smartplugs are scraped from
[emvue-exporter](https://github.com/sbates130272/emvue-exporter)
running on the beelink itself. It
serves two metric families, one series per plug:

```
emvue_plug_power_watts{plug="snoc-pinewood-plug-c",name="Living Room Light",location="Living Room",status="unused"}
emvue_plug_on{plug="snoc-pinewood-plug-c",name="Living Room Light",location="Living Room",status="unused"}
```

Everything past `plug` comes from
`emvue-exporter/labels.json` in this directory. The exporter
is its own repository and generic; the plug names are this
house's, so they live here and `emvue-exporter/deploy.sh`
installs them to `/usr/local/share/emvue-exporter/` and
restarts the unit. The exporter reads the file once at
startup, so a label change needs that restart — a reload
will not do.

The `name` label is load-bearing: the Emporia SmartPlugs
dashboard is three panels driven by one query each with a
legend format of `{{name}}`, so a plug added to the account
shows up without touching any dashboard JSON. A plug missing
from `labels.json` still appears, identified only by `plug`.

`status` is load-bearing too, and every plug carries it —
`active` or `unused`. The dashboard's Status picker defaults
to `active`, so a plug that is unplugged or switched off for
good stays out of the way while its series keeps recording;
pick `unused` or All to see it. Giving the label to every
plug rather than only the idle ones is what makes the picker
offer both choices instead of one. CI enforces that a new
plug has a status, since a plug that lacks one is filtered
out of the default view and looks like it stopped reporting.

This job deliberately has no `metric_relabel_configs`.
Earlier the exporter emitted a separate metric *name* per
plug (`snoc_pinewood_plug_a_power`), which no dashboard
could group over and which pushed eight hardcoded copies of
every panel into the JSON. That was fixed in the exporter
rather than papered over with relabel rules here, because
the `Enum` it used for outlet state named its label after
the metric and no relabel rule can untangle that. Those old
series remain in the TSDB until they age out of retention.

The rename shipped ahead of the dashboards, and only the
SmartPlugs one followed it. LAN Overview and ROCm/XIO kept
querying the old names, and the two failed differently.
Total Home Power summed the eight old names with `or
vector(0)` on each term, so every term fell through to its
default and the panel reported a confident, well-formatted
**0 W** rather than "No data" — the guard that existed to
stop the panel looking empty is what stopped it looking
broken. Power by Plug and the ROCm/XIO wall-power panel had
no such guard and simply went blank. All three now query
`emvue_plug_power_watts`, and the sum has no `or vector(0)`:
if the exporter stops, that panel should say so.

Power by Plug also carried its plug names as eight hardcoded
legends, two of which disagreed with `labels.json` — plug
`a` read "Outside Lights" and `b` "Home Office" against
`snoc-gaming` and `amd-laptop`. Whether the panel or the
physical plugs moved first is not recoverable from the
history, which is the point: `{{name}}` leaves only one
place for a plug's name to be wrong.

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

**The `ais_*` families come from here, not from anything
named "ais".** A separate `ais-exporter` job scraped a
different process on `:9092` until 6 October 2026, when it
was retired having never returned a single successful scrape
in the 90 days Prometheus retains. Nothing was lost with it:
every `ais_*` series on this fleet is served by hsa-snoop on
`:9488`, which is what the HSA Snoop dashboard has always
been reading. The overlapping names made the two look
interchangeable; they never were.

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

### The amd-llm-exporter job

`amd-laptop` runs a small reporter on `:9876` that polls the
AMD internal LLM gateway's usage API and re-exposes the
answer as `amd_llm_*`. It backs the **AMD LLM Metrics**
dashboard and the summary tiles under LAN Overview's AI &
Developer Usage row.

Scraped at 60s, which is about bounding staleness rather
than sampling rate: the numbers only move when the reporter
fetches again, and that is on its own cadence, not ours. Watch
`amd_llm_last_fetch_timestamp_seconds` rather than `up` to
tell whether a green target is serving current data — the
reporter answers every scrape from cache, so `up=1` survives
an upstream API that has been failing for days.

Every `amd_llm_*` series is a **gauge holding a total over a
rolling 30-day window** (`amd_llm_window_days`), not a
counter. `rate()` and `increase()` over them are wrong, not
merely noisy: the window ageing out looks exactly like a
counter reset. The exception is
`amd_llm_fetch_errors_total`, which is a genuine counter.
See [the Grafana README](../grafana/README.md) for how the
dashboards work around this.

**Manual target only, and an IP rather than a name.**
`amd-laptop` does not resolve from `snoc-beelink` — no mDNS,
no `/etc/hosts` entry — which is why `node` and
`amd-gpu-metrics-exporter` also carry `10.0.0.107` literally.
Adding a `/etc/hosts` entry on the beelink would let the
target use a name instead, but nothing else here depends on
resolving it.

### The gh-actions-exporter job

`gh-actions-exporter/` holds a small Python exporter that runs
on `snoc-beelink` and serves `github_actions_*` on
`127.0.0.1:9612`. It backs the **GitHub Actions** dashboard, the
two tiles at the bottom of LAN Overview's Service Health row,
and the `github-actions` alert group.

It lives here rather than in its own repository, unlike
`emvue-exporter`, for the reason `emvue-exporter/labels.json`
does: which repositories are worth watching is a fact about this
setup, not about exporters in general.

```bash
cd prometheus/gh-actions-exporter
./deploy.sh
```

**The repository list is discovered, not configured.** Every
hour the exporter lists the owner's repositories and keeps those
that are not forks, not archived, and pushed to within 90 days —
13 of 80 at the time of writing. A new repository starts being
watched on its own and a repository that goes quiet drops out,
which is the same reasoning behind driving the Emporia panel
legends from `{{name}}`: one less list to disagree with reality. Narrow it
with `--owner`, `--max-repo-age-days` and `--exclude`.

**Only the default branch counts.** The per-workflow metrics
report the latest *completed* run on each repository's default
branch. A red PR branch is how a pull request says it is not
ready yet, and watching those would mean watching work in
progress.

**Dependabot's own runs are excluded** — `event=dynamic`, the
security and graph updates it files against the default branch.
They fail for reasons nothing in the repository can fix, and each
one carries a freshly generated name like `pip in
/Documentation/sphinx for Jinja2 - Update #1394352365`, so left
in they would be an ever-growing pile of permanently red series
that nothing can ever turn green. `linux-p2pmem` is the host of
the example. They still count towards
`github_actions_repo_recent_runs`, which is where "something in
this repository is unhappy" belongs.

**One API call per repository per refresh**, against the first
page of 100 runs. A workflow whose last run has already scrolled
off that page is not reported, which is deliberate: a workflow
with a hundred runs behind it is not what "fix it today" means.
At a 5-minute refresh that is around 200 calls an hour against a
5000 limit, tracked by `github_actions_rate_limit_remaining`.

**Scrapes are served from cache, so `up` proves nothing about
GitHub.** The exporter refreshes on its own thread and answers
every scrape from an in-memory snapshot — the same trap the
`amd-llm-exporter` job has. Watch
`github_actions_last_refresh_timestamp_seconds`;
`GitHubActionsExporterStale` is the alert that does. A refresh
that fails keeps the previous snapshot rather than blanking it,
so stale panels stay populated and the freshness metric is the
only thing that moves.

The run id is published as a metric *value*
(`github_actions_workflow_last_run_id`) rather than as a label,
because it changes on every run and as a label would churn a new
series each time. The dashboard reads it as a table field to
build the link to the run.

#### The token

Not in this repo, like the Lemonade scrape key. The unit hands
it to the exporter as a systemd credential and keeps the file
root-owned, so it is never visible inside the service's own view
of the filesystem. A classic PAT needs `repo`; a fine-grained one
needs read access to Actions and Metadata.

```bash
sudo install -d -m 0700 -o root -g root /etc/gh-actions-exporter
printf %s "$GH_TOKEN_SBATES130272" \
    | sudo tee /etc/gh-actions-exporter/token >/dev/null
sudo chmod 0400 /etc/gh-actions-exporter/token
```

`printf` rather than `echo`, for the same reason as the Lemonade
key: a trailing newline becomes part of the token and every call
comes back 401. `deploy.sh` refuses to run without the file, and
CI validates against a placeholder.

## The S3 backup age textfile collector

`textfile-collectors/s3-backup-age.sh` publishes
`batesste_s3_backup_*` for the host that runs
`batesste-s3-backup.service` — today `snoc-beelink` alone. It
feeds the four backup alert rules in
`grafana/provisioning/alerting/rules.yaml`. `deploy-agent.sh`
installs it wherever it finds the backup unit, so moving the
backup to another box brings its monitoring along instead of
leaving the alert watching a machine that stopped backing
anything up.

| Metric | Meaning |
|---|---|
| `batesste_s3_backup_query_success` | 1 if the bucket listing worked |
| `batesste_s3_backup_objects` | Number of backup objects for this host |
| `batesste_s3_backup_last_object_timestamp_seconds` | `LastModified` of the newest one |
| `batesste_s3_backup_last_object_bytes` | Size of the newest one |

It queries S3 rather than reading the exit status of
`batesste-s3-backup.service`, because the two are not the same
claim and the gap between them is where the outage lived. The
disk backup wrote nothing to `batesste-homelab-backups` between
June 2025 and 8 Sep 2026 — every run rejected with
`InvalidAccessKeyId` — and the Hermes backup still logs
`Uploading to s3://...` without ever reporting whether the
upload landed. A unit that exits 0 having uploaded nothing is
the case worth catching, so the collector asks the bucket.

Size is published for a related reason. `batesste-s3-backup`
runs `dd | pigz > file` without `set -o pipefail`, so only
`pigz`'s status reaches the shell: a `dd` that dies partway
still yields a complete, valid, far too small `.gz` and the
unit exits 0. Age alone would call that healthy.

The unit reads the *same* `batesste-s3-backup.conf` and
`~/.secrets.env` the backup itself reads, deliberately. A
monitor with its own copy of the bucket name or its own key can
pass while the thing it is watching fails. The one difference
is a `-` prefix on the secrets `EnvironmentFile`: the backup
should refuse to start without credentials, whereas this should
still run and publish `query_success 0`, since "there are no
credentials here" is the alert rather than a reason to go
quiet.

## The ROCm version textfile collector

`textfile-collectors/rocm-version.sh` publishes
`rocm_version_info{version=...}` and
`amdgpu_dkms_version_info{dkms_version=...}` via node-exporter's
textfile collector, feeding the ROCm and DKMS columns on the LAN
Overview GPU Inventory table. Run `deploy-agent.sh` on each GPU
host; it is the same "copy it to the target machine" model as
`loki/alloy/deploy-agent.sh`.

The two columns answer different questions, which is why both are
on the table. ROCm is the userspace release; DKMS is the kernel
driver — "did it survive the last kernel upgrade". On
`snoc-thinkstation` and `snoc-strix` today they read `10.1.0` and
`1:7.1.9.31600000-2407772.26.04`.

**Four different version strings are in play here, and three of
them are easy to mistake for the ROCm release.** This collector
originally published `hipconfig --version` as `rocm_version_info`,
so a column headed ROCm showed `7.16.26385-0000000` on hosts
running ROCm 10.1. That is the HIP runtime version, which is
versioned independently of the release and does not track it:

| Series | Source | On the GPU hosts |
| ------ | ------ | ---------------- |
| `rocm_version_info{version}` | `$(hipconfig --path)/.info/version` | `10.1.0` |
| `rocm_hip_version_info{hip_version}` | `hipconfig --version` | `7.16.26385-0000000` |
| `amdgpu_dkms_version_info{dkms_version}` | `amdgpu-dkms-firmware`, first four fields | `31.60.0.0` |
| `amdgpu_dkms_package_info{package_version}` | `dpkg-query amdgpu-dkms` | `1:7.1.9.31600000-2407772.26.04` |
| `amdgpu_dkms_module_info{module_version}` | `dkms status` | `7.1.9-2407772.26.04` |

The release comes from the active core prefix rather than a fixed
path because these hosts have several installed side by side —
`core-7.14` (7.14.1) and `core-10.1` (10.1.0) on both, plus
`core-10.0` on `snoc-strix` — with `/opt/rocm/core` pointing at
whichever `update-alternatives` has selected. `hipconfig --path`
follows that link; a hardcoded `/opt/rocm` would not. Note there
is no `/opt/rocm/.info/version` on these hosts at all, only one
per core.

The column shows AMD's own driver release — `31.60.0.0` — not
the Debian package string. That is the number AMD versions the
driver by: the apt source on these hosts is
`repo.radeon.com/amdgpu/31.60/ubuntu`, and the driver
documentation is published per 31.x line, so it is the value that
can be matched against a release note or a repo path.

`amdgpu-dkms` carries it only packed: its version is
`1:7.1.9.31600000-2407772.26.04`, where `31600000` is `31.60.0.0`
with the dots removed. `amdgpu-dkms-firmware` spells it out as
`1:31.60.0.0.31600000-2407772.26.04`, so the release is read from
there and not unpacked from the digits — `31600000` could be split
several defensible ways, and only the firmware package says which
is right. The first *four* dot-separated fields are taken, because
the packed digits follow the release as a fifth and a greedy split
would swallow them.

The full `dpkg` string is kept as `amdgpu_dkms_package_info` —
it is what `apt policy amdgpu-dkms` compares against, so it is the
one to quote in a support ticket. Both
describe the same driver. The dkms tree version is published as
`amdgpu_dkms_module_info`, because it alone answers "what is
actually built for the running kernel" — dpkg will happily report
a package whose module was never rebuilt.

One collector rather than two: the cadence is identical (both
change only on a package upgrade), the host set is identical, and
both land in the same GPU Inventory row, so a second unit pair on
every host would buy nothing. The script name stays narrower than
its contents as a result — renaming it would strand the old units
on every host already carrying them.

### Reading the DKMS metrics

| Series | Means |
| ------ | ----- |
| `amdgpu_dkms_present 1` + `amdgpu_dkms_version_info` | DKMS module built for the running kernel |
| `amdgpu_dkms_present 0` | inbox `amdgpu`, no AMD GPU, or WSL — not a fault |
| `amdgpu_dkms_kernel_mismatch 1` | DKMS has an `amdgpu` tree, but none for the running kernel |

That last one is the case worth an alert: a kernel upgrade where
the rebuild did not happen, so the kernel now running has no
out-of-tree `amdgpu` at all. It mirrors the existing
`rocm_version_prefix_mismatch`, and exists for the same reason —
a blank column does not say *why* it is blank.

Three details in the DKMS lookup are load-bearing:

**`dkms status` is scoped with both `-m amdgpu` and `-k $(uname
-r)`.** Both GPU hosts have `amdgpu` built for two kernels at
once, so an unscoped query returns several lines with no single
version to report. `-m` matters independently: `snoc-strix` also
carries `AMDPowerProfiler` and `xrt` trees.

**Both `dkms status` output formats are parsed.** dkms 3.x (3.2.2
on both hosts) prints the module and version slash-joined,
`amdgpu/7.1.9-2407772.26.04, 7.0.0-38-generic, x86_64:
installed`; dkms 2.x prints them as separate comma-separated
fields. The script trims at the colon and tests for the slash,
rather than parsing the status text, which is translated on some
systems.

**The `modinfo` fallback is guarded on the module path.** Where
the `dkms` CLI is absent, the version comes from `modinfo -F
version amdgpu` — but only when `modinfo -F filename amdgpu`
resolves under `/updates/dkms/`. The inbox `amdgpu` answers
`modinfo -F version` on some kernels, and reporting that as a
DKMS version would be quietly wrong.

**The label is `dkms_version`, not `version`.** GPU Inventory
joins its targets with a `seriesToColumns` transform on
`server_name`; a second frame carrying a `version` label collides
with the ROCm column's and one of the two is dropped. Naming it
apart at the source keeps the dashboard query a plain `max by`
instead of a `label_replace` that has to strip the original label
again afterwards.

This does not reuse `rocm_aic_rocm_version_info`, which used to
carry the same number on `snoc-thinkstation`. That series came
from the `rocm-aic-exporter` timer — a large bespoke
LMCache/NIXL/AIS package tied to that host's vLLM work, which
had no business being installed on three other machines just to
read one version string. It ran on `snoc-thinkstation` alone;
`snoc-strix` never had it, only a stale series left over from
July. Either way it was a version column that would have gone
blank without anything visibly breaking.

`rocm-aic-exporter` has since been removed from
`snoc-thinkstation` — timer, units, `/opt/rocm-aic-exporter/`,
and the 42-family `rocm_aic_exporter.prom` it left in the
textfile directory, which node-exporter would otherwise have
served forever. Nothing in `grafana/dashboards/` referenced
`rocm_aic_*`; the only consumer was
`grafana/vendor/retired/rocm-aic-dashboard.json`, which is not
provisioned. **Its unit files were headed "Managed by Ansible
(host_setup)", so a future Ansible run on that host may
reinstate them.**

Three things about this are worth keeping:

**The lookup order is load-bearing.** `hipconfig` is resolved
from `PATH` first, and only then from `/opt/rocm/bin`. The
instinct is the reverse — systemd units get a minimal `PATH` —
but that default *does* include `/usr/bin`, which is where the
apt-packaged `hipconfig` lives on all four hosts.
`/opt/rocm/bin` is the one on nobody's `PATH`. Probing it first
reports the wrong version on `amd-laptop`, which has two ROCm
installs:

| Host | `PATH` | `/opt/rocm` |
| ---- | ------ | ----------- |
| `snoc-thinkstation` | 10.1.0 | same |
| `snoc-strix` | 10.1.0 | same |
| `snoc-gaming` | 10.1.0 | same |
| `amd-laptop` | 10.1.0 | same |

All four rows were measured after the switch to release versions.
The figures previously in this table were HIP runtime versions, so
none of the old numbers were carried over — the comparison is now
between ROCm *releases*, and the old values were not merely stale
but the wrong quantity.

**`amd-laptop` no longer has two ROCm installs.** The dual-prefix
case this table was built around is gone: that host now carries
only `core-10.1`, and `/usr/bin/hipconfig` and
`/opt/rocm/bin/hipconfig` both resolve to it, so
`rocm_version_prefix_mismatch` does not fire anywhere on the fleet
today. The metric is kept because the condition it detects is a
property of `update-alternatives`, not of that one host, and
nothing stops a future install from reintroducing it.

Note `snoc-gaming` is a WSL host, so `deploy-agent.sh` installs
`wsl-wifi` alongside `rocm-version` there, and it reports
`amdgpu_dkms_present 0` — the GPU arrives over `/dev/dxg` and
there is no kernel module to version.

`amd-laptop`'s `/opt/rocm` is a symlink to
`/etc/alternatives/rocm` pointing at an older install, so
`rocm_version_prefix_mismatch` is emitted whenever the two
disagree. Without it the column shows a plausible version and
nothing hints that the prefix resolves elsewhere. That metric now
compares release versions too, so it will not fire merely because
two prefixes ship a different HIP runtime version.

**Two hosts needed a node-exporter flag.** `snoc-gaming` and
`amd-laptop` had no `--collector.textfile.directory` at all, so
a collector would have written a perfectly good `.prom` that
nothing ever read. `deploy-agent.sh` appends the flag to the
existing `ARGS` (rather than rewriting the line, which carries
unrelated local flags) and restarts the unit — `EnvironmentFile`
is not re-read on reload, the same trap as `/etc/default/prometheus`.

**A missing flag does not mean a missing directory.** The above
assumed two cases, and there is a third. Debian's
`prometheus-node-exporter` compiles the default to
`/var/lib/prometheus/node-exporter` and ships `apt`, `nvme` and
`smartmon` collectors that write there, so on `snoc-beelink` the
flag was absent *because the directory was already right* — 39
series were being served with `ARGS=""`. Appending our own flag
would have pointed node-exporter at an empty directory and
dropped every one of them, including SMART health for the disk
the backup reads. `deploy-agent.sh` now resolves the directory
the way node-exporter itself does — `ARGS`, then the unit and
its drop-ins, then the binary's compiled-in default — and only
adds the flag when all three come back empty. Since the
collector scripts default `TEXTFILE_DIR` to the fallback path,
it also writes a `<collector>.service.d/textfile-dir.conf`
drop-in pinning the resolved directory; a drop-in rather than an
edit to the unit, so the path stays a property of the host and
the units in git stay host-agnostic.

**A host installed before the drop-in needs `deploy-agent.sh` run
again.** The paragraph above describes the fix; it does not
retroactively apply to hosts installed before it existed.
`snoc-thinkstation` and `snoc-strix` carried a Sep 8 install with
no `rocm-version.service.d/textfile-dir.conf`, so the collector
kept its default of `/var/lib/node_exporter/textfile_collector`
while node-exporter read `/var/lib/prometheus/node-exporter`. Every
symptom pointed away from the cause: the timer was `enabled` and
`active`, the service exited 0, and a current, correct
`rocm-version.prom` sat on disk — but
`curl -s localhost:9100/metrics | grep -c '^rocm_version'` returned
`0`, and the ROCm column was empty on precisely the two hosts that
*had* ROCm. Re-running `deploy-agent.sh` writes the missing drop-in
and leaves `ARGS` alone. The orphaned `.prom` under the old path is
worth deleting by hand afterwards, so a later reader is not misled
by a file that nothing reads.

**And the detection that avoids all this was itself broken.**
`detect_textfile_dir` read the compiled-in default out of
`prometheus-node-exporter --help`, matching only the quoted
rendering `="..."` that older kingpin builds emit. Debian's
node_exporter 1.10.2 prints it bare:

```text
--collector.textfile.directory=/var/lib/prometheus/node-exporter ...
```

so the match failed and the function returned empty — on every host
whose directory comes from the compiled-in default, which is all of
them. Empty is the one wrong answer that does damage: it means
"node-exporter reads nothing", and the caller responds by appending
`--collector.textfile.directory` and restarting. On
`snoc-thinkstation` that would have redirected node-exporter from
`/var/lib/prometheus/node-exporter` — where it was actively serving
3 `smartmon_device_info`, 4 `apt_upgrades_pending` and 3
`node_nvme_info` series — to a directory holding only
`rocm-version.prom`. Fixing the ROCm column would have cost SMART
health for the disk the backup reads, which is precisely the
regression the surrounding comments were written to prevent. The
`--help` branch now reuses the same optional-quote pattern as the
`ARGS` and unit branches, so both renderings resolve and an unset
default still yields empty. A `--dry-run` that reports *"adding
--collector.textfile.directory"* on a host that already serves
textfile metrics is the signal that this has regressed again.

**The dashboard query is scoped to `job="node"`, deliberately.**
A remote-written copy of the older `rocm_aic_rocm_version_info`
arrives from the `rocm-aic-core42-mi300` cluster carrying
`server_name="g04u07"`. GPU Inventory joins its columns on
`server_name`, so an unscoped version query injects a phantom
row for a machine that is not on this LAN.

## The WSL WiFi collector

`wsl-wifi.sh` publishes the *Windows host's* WiFi state on
`amd-laptop` and `snoc-gaming`, feeding the **WiFi (dBm)** and
**Link** columns on Node Fleet. `deploy-agent.sh` installs it
only where `systemd-detect-virt` reports `wsl`, and both units
also carry `ConditionVirtualization=wsl`.

**node-exporter cannot do this, and neither can
windows_exporter.** `--collector.wifi` is already in `ARGS` on
both hosts and yields zero series: there is no wireless device
inside the VM. `/proc/net/wireless` has only its header, and
although both run `networkingMode=Mirrored`, mirrored mode
presents the Windows adapters as plain Ethernet with no nl80211
behind them. windows_exporter has no wireless collector at all
— its `net` collector is perf-counter bytes, packets and
errors. Either way the number has to come from Windows, so it
comes via WSL interop and needs nothing installed on the
Windows side.

**The RSSI is measured, not derived.** Windows historically
exposed only a 0–100 quality percentage, which the WLAN API
documents as linear against −100…−50 dBm. Both hosts are on
Windows 11 build 26200, which reports `Rssi` directly, and the
collector prefers it. The conversion is kept as a fallback but
flagged by `wsl_wifi_signal_dbm_derived`, because it is bad:

| Host | Quality | Derived | Measured |
| ---- | ------- | ------- | -------- |
| `amd-laptop`  | 85% | −57.5 | **−50** |
| `snoc-gaming` | 75% | −62.5 | **−69** |

Wrong by 6–8 dB, in opposite directions. A column mixing the
two silently would be worse than no column.

**Interop is not uniformly cheap, and that shapes the design.**
One `netsh.exe` call, four consecutive runs:

| Host | Per call |
| ---- | -------- |
| `snoc-gaming` | 0.06s |
| `amd-laptop`  | 8–16s |

Same command, same Windows build. `amd-laptop` is
corporate-managed and its security stack inspects every process
launch crossing the interop boundary; the cost is
per-invocation and does not warm up. Hence the five-minute
timer rather than one minute, and hence parsing `netsh` rather
than calling `Get-NetAdapter -Physical` — which is more
authoritative, needs no MAC matching, and takes **32 seconds**
on that host.

**`wsl_wifi_adapter` exists to fix the Link column.** Mirrored
adapters keep their real MACs inside the VM, so a radio is
indistinguishable from a cable by interface name. Publishing
the WiFi adapter's MAC lets the dashboard join it against
`node_network_info`'s `address` label and subtract exactly the
right interface, with no name-based denylist.

**SSID and BSSID are deliberately not exported.** They feed no
panel, and one of these two hosts is a corporate laptop that
roams onto networks whose names have no business being written
into a homelab TSDB with 90-day retention.

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

`deploy.sh` only acts when `$ARGS` actually changes — it needs
a **restart** rather than a reload (EnvironmentFile is not
re-read on reload), and a restart drops remote-write for as
long as TSDB replay takes.

### node-exporter flags belong to ansible

`--collector.wifi` is what LAN Overview's *WiFi (dBm)* column
reads; without it `node_wifi_station_signal_dbm` does not
exist, the scrape stays green, and the empty column looks like
a dashboard bug.

This repo used to add it through a drop-in that overrode
`ExecStart`. It no longer does. `batesste-ansible`'s
`fave_packages` role writes the same flag into `ARGS` in
`/etc/default/prometheus-node-exporter`, and both reached the
same command line: node-exporter exits 1 on a repeated flag
(`flag 'collector.wifi' cannot be repeated`), so on
2026-09-21 the unit failed the moment ansible ran, and stayed
down. The symptom was not an obvious outage — beelink simply
stopped appearing in Node Fleet's *Link* column, because that
expression is built on `node_network_info` and has no
fallback for a host that reports nothing at all.

`ARGS` is now the single owner. It is the mechanism the
packaged unit already expands, and the only one that reaches
the hosts ansible manages but this repo does not.
`deploy.sh` removes the old drop-in if it finds one, rather
than treating its absence as the normal case — a host
deployed before this change still has it on disk.

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
