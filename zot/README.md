# zot

A container registry for the home LAN, running bare metal on
`snoc-strix`. Nodes managed by `batesste-ansible` pull from it instead
of reaching out to Docker Hub for every image.

## Why zot and not Harbor

[Harbor][ref-harbor] was the first choice and is not installable here.
It is distributed only as containers — its own `docker compose`
installer or a Helm chart — and there is no package, tarball or binary
release of `harbor-core`, `jobservice`, `registryctl` or the Angular
portal. A bare-metal Harbor means building seven Go services from
source, running PostgreSQL and Redis natively, and hand-maintaining
everything Harbor's `prepare` script generates, then doing it again at
every upgrade.

[zot][ref-zot] is one static Go binary under systemd. No container
runtime in the path of the thing that stores the containers — which
matters the first time the registry is needed to bring a node up — no
database, no cache, nothing to bootstrap. It is OCI-native, it has a
web UI, htpasswd authentication, per-repository access control,
pull-through mirroring of upstream registries, and optional Trivy
vulnerability scanning. That is the Harbor feature set that gets used
here, minus the operational weight.

What is given up relative to Harbor: project quotas, a built-in
Notary/cosign signing workflow, and tag retention policies beyond
zot's garbage collection.

## Directory Layout

| File | Purpose |
| --- | --- |
| `deploy.sh` | Installs the binary, user, config, credentials and unit. Idempotent. |
| `config.json.in` | The zot config, as a valid JSON file. `deploy.sh` overlays the host-specific values with `jq`. |
| `zot.service` | The systemd unit, installed to `/etc/systemd/system/`. |
| `checksums.sha256` | Pinned SHA-256 digests for the release artefacts. |
| `zot.secrets.example` | Template for the untracked `zot.secrets`. |

On the host:

| Path | Contents |
| --- | --- |
| `/usr/local/bin/zot` | The registry. 226 MB — it embeds the UI and Trivy. |
| `/usr/local/bin/zli` | The CLI. `zli images`, `zli cve`, against a running zot. |
| `/etc/zot/config.json` | Rendered config, `root:zot` 0640. |
| `/etc/zot/htpasswd` | Credentials, `root:zot` 0640. Watched and hot-reloaded. |
| `/etc/zot/session-keys.json` | Web UI cookie keys. Generated once, then never touched. |
| `/var/lib/zot` | Blob store. Owned by the `zot` system user. |

Logs go to stdout and therefore to journald, which `../loki/alloy`
already ships to Loki. There is no log file to rotate.

## Moving it

Nothing in `deploy.sh` or `config.json.in` names a host. `snoc-strix`
is where the registry lives because that is the box with 554 GB free,
and moving it is a matter of running `deploy.sh` elsewhere and
repointing the clients. The address, port and blob store are all
environment overrides:

```
ZOT_PORT=5050 ZOT_DATA=/srv/zot ./deploy.sh
```

Two things do name the host, and both need editing if the registry
moves: `../prometheus/targets/zot.json`, which says who to scrape, and
whatever `batesste-ansible` writes into each node's
`/etc/docker/daemon.json`.

## Exposure

Plain HTTP on `0.0.0.0:8080` — reachable from anything on the home LAN
and from anything on the tailnet, with no TLS. The name clients should
use is the tailnet one; see "Pointing clients at it" below for why
that is not a free choice.

That is a deliberate choice and it has a cost worth stating plainly:
the `ci` and `admin` passwords cross the LAN in clear on every
authenticated request, and so does every image layer. On this network
that is the same exposure the rest of the home LAN services already
accept. The alternatives were a tailnet-only listener behind
`tailscale serve` — which gives a real certificate and no client
configuration at all, but excludes any node not on the tailnet — and a
self-signed certificate, which moves the work to every client's
`/etc/docker/certs.d/` and leaves certificate rotation to be
remembered by hand.

The practical consequence is that clients must name the registry as
insecure before they will talk to it. Docker refuses plain HTTP
otherwise, and the error it gives — a TLS handshake failure against a
server that never offered TLS — does not say so.

## Pointing clients at it

### The name

`snoc-strix.fold-leaffish.ts.net:8080` — the tailnet name, not
`snoc-strix.local`.

This matters more than it looks. The registry name is part of every
image reference (`<name>/library/foo:v1`) and it has to match the
client's `insecure-registries` entry character for character, so the
fleet wants exactly one name, not a per-node choice. `.local` is not
that name: mDNS is not uniform here. `snoc-beelink` resolves
`snoc-strix.local` fine; `snoc-thinkstation` — a node that will
certainly pull from this registry — cannot resolve it at all, while it
reaches the tailnet name without trouble.

The cost of choosing a tailnet name is that resolution now depends on
MagicDNS. A node whose `tailscaled` is stopped loses the registry even
though the box is sitting on the same LAN, and the error is a DNS
failure that says nothing about Tailscale. The mitigation is the same
`/etc/hosts` line as below, applied everywhere rather than only where
it is strictly required — it costs nothing and turns a tailnet outage
into a non-event.

The exception that definitely needs it is a node that does not run
Tailscale. `amd-laptop` is one: Tailscale is installed there but
stopped, because running it breaks ZScaler, which is why
`../prometheus/prometheus.yml` scrapes that host by IP. Such a node
keeps the same registry name and gets it resolved locally instead:

```
# /etc/hosts
10.0.0.242  snoc-strix.fold-leaffish.ts.net
```

That is the wired address. Do not substitute a different registry name
for those hosts — an image tagged `10.0.0.242:8080/foo` and an image
tagged `snoc-strix.fold-leaffish.ts.net:8080/foo` are different images
as far as every client is concerned, and the cache hit you wanted
becomes a second pull.

**On a WSL2 node, that line does not survive a reboot.** WSL
regenerates `/etc/hosts` at every start unless told not to, and
`amd-laptop` — the one node this exception exists for — has an
`/etc/wsl.conf` containing nothing but `[boot] systemd=true`. Write
the stanza first, restart the distro from Windows with
`wsl --shutdown`, and only then add the hosts entry:

```
# /etc/wsl.conf
[network]
generateHosts = false
```

Without it the sequence is: configure, works, reboot, silently stops
working, with no change to any file under configuration management.

### Docker

`/etc/docker/daemon.json`, then `sudo systemctl reload docker`:

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"]
}
```

Reload, not restart. `insecure-registries` is one of the options
Docker re-reads on SIGHUP, so adding the registry costs nothing — this
was measured on `snoc-strix` with 35 containers running, all of which
survived. A restart would have taken every one of them down for no
reason.

The asymmetry is worth knowing: adding an entry applies on reload,
*removing* one does not. Delete the file, reload, and the daemon keeps
serving the old list until it is genuinely restarted.

### Podman

`/etc/containers/registries.conf`:

```
[[registry]]
location = "snoc-strix.fold-leaffish.ts.net:8080"
insecure = true
```

No restart; podman is not a daemon.

### containerd

Only relevant to a node using containerd directly — Kubernetes, nerdctl
— not to one that reaches containerd through Docker. Docker does not
consult containerd's registry configuration.

Every containerd in this fleet is 2.x (`snoc-thinkstation` 2.3.6,
`snoc-strix` 2.2.2), and the plugin was renamed at 2.0. Use the 2.x
name; the 1.x `io.containerd.grpc.v1.cri` table is silently ignored
here, which is a configuration that looks right and does nothing.

`/etc/containerd/config.toml`:

```
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

then
`/etc/containerd/certs.d/snoc-strix.fold-leaffish.ts.net:8080/hosts.toml`:

```
server = "http://snoc-strix.fold-leaffish.ts.net:8080"

[host."http://snoc-strix.fold-leaffish.ts.net:8080"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
```

The `certs.d` form is the one to use. The older inline
`registry.mirrors` and `registry.configs` tables are ignored once
`config_path` is set, which makes a half-migrated node look configured
and behave as if it is not.

### buildx and BuildKit

The trap on any node that builds images, which here means `snoc-strix`
— it has a `docker-container` buildx builder, and that driver runs
BuildKit in its own container that **does not read
`/etc/docker/daemon.json`**. Registering the daemon is not enough; a
`FROM` or a `--push` against this registry fails inside the builder
while a plain `docker pull` on the same host works.

BuildKit needs its own config, and the key is `http`, not `insecure`.
`insecure = true` means "HTTPS, but do not verify the certificate",
which is the wrong fix for a registry that speaks no HTTPS at all.

```
# buildkitd.toml
[registry."snoc-strix.fold-leaffish.ts.net:8080"]
  http = true
```

That is supplied when the builder is created, and an existing builder
has to be recreated to pick it up:

```
docker buildx create --name local --driver docker-container \
    --config buildkitd.toml --use
```

The `docker` driver — the default builder, no container — uses the
daemon's own configuration and needs nothing extra.

## Accounts

Three, defined in `config.json.in` and created by `deploy.sh` with
generated passwords on its first run:

| Account | Rights |
| --- | --- |
| `admin` | Everything including delete. The web UI login. Nothing automated should use it. |
| `ci` | `read`, `create`, `update` on every repository — the push account. Cannot delete. |
| `metrics` | Read only, and the only account allowed to `GET /metrics`. |

Anonymous pulls are allowed on every repository. A node that only
consumes images needs no credentials, which is what keeps the ansible
side of this to one file. Pushing always needs `ci` or `admin`.

Passwords live in `zot.secrets`, untracked by the repo's existing
`*.secrets` rule. `deploy.sh` writes that file and never prints a
password; read it with an editor on the host when you need one.
Changing a value there and re-running the script rewrites
`/etc/zot/htpasswd`, which zot reloads by itself — no restart, no
interrupted push.

Tightening this is a `config.json.in` edit: drop `anonymousPolicy` to
require credentials for pulls, or narrow the `ci` policy from `**` to
the repository prefixes that actually get pushed to.

## Vulnerability scanning

Off by default. `./deploy.sh --with-cve` turns it on, which enables
Trivy inside zot and makes it download a vulnerability database from
`ghcr.io` on start and every 24 hours after.

Two reasons it is not the default. The database download is slow and
unreliable from behind the corporate egress, and it happens *before*
zot signals readiness — so a failed fetch is a unit that sits in
`activating` until `TimeoutStartSec` and then gets restarted. And
Trivy wants well over a gigabyte of its own, which the `MemoryMax=4G`
in `zot.service` does not leave room for alongside the blob store
index. Raise both ceilings in the same change.

## Pull-through mirroring

Not configured, but it is the reason `extensions.sync` exists and the
obvious next thing to want from a registry on a corporate network.
Adding a `sync` block with `onDemand: true` against `docker.io` makes
zot fetch and cache upstream images the first time anything asks for
them, so the second node to need a base image gets it over the LAN.
See upstream's `examples/config-sync.json`.

## Prometheus integration

zot serves its own `/metrics` on the registry port, so there is no
exporter and no second port. The `zot` job in
`../prometheus/prometheus.yml` scrapes it over the tailnet, and
`../prometheus/targets/zot.json` is the target file.

It is the only authenticated-with-basic_auth job in that config.
zot's `accessControl.metrics` names `metrics` as the sole account
allowed to read the endpoint, so Prometheus needs the password in
`/etc/prometheus/secrets/zot-metrics-password` on `snoc-beelink`.
`../prometheus/deploy.sh` refuses to run without it and prints the
exact commands to create it.

A 401 or 403 on that job means the password file and
`/etc/zot/htpasswd` have drifted, not that the registry is down — but
it takes the target down all the same, because Prometheus counts any
non-2xx scrape as a failure. `up` goes to 0 and it reads like an
unreachable host. The tell is `lastError`:
`server returned HTTP status 403 Forbidden`, not `connection refused`.

The codes themselves, measured: anonymous gets 401 on `/metrics`, an
authenticated non-`metrics` account gets 403. Both can still pull.

## Workflow

### Deploying (on the registry host)

```
./deploy.sh --dry-run
./deploy.sh
```

A first run generates `zot.secrets`, creates the `zot` user, downloads
and verifies the binaries, writes the config and credentials, installs
the unit and starts it. Later runs restart the service only if the
binary, the config or the unit actually changed.

### Upgrading

Move `ZOT_VERSION` in `deploy.sh`, replace both lines in
`checksums.sha256` with the digests for the new tag — the command to
get them is in the comment at the top of that file — and re-run. The
new binary is verified before it is installed and the service is
restarted because the binary changed.

### Checking it works

```
curl -s http://snoc-strix.fold-leaffish.ts.net:8080/v2/_catalog | jq
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
docker tag alpine:latest snoc-strix.fold-leaffish.ts.net:8080/library/alpine:latest
docker push snoc-strix.fold-leaffish.ts.net:8080/library/alpine:latest
zli images list --config local
journalctl -u zot -f
```

The web UI is at `http://snoc-strix.fold-leaffish.ts.net:8080/`, the
registry API at
`/v2/` on the same port.

## Things that fail silently

**An `apr1` password hash.** zot accepts bcrypt, `$5$` and `$6$` and
nothing else. `openssl passwd` without `-6` produces `$apr1$`, which
zot rejects at login with one line in its log and a bare 401 at the
client that looks exactly like a wrong password. `deploy.sh` always
uses `-6`.

**A trailing newline in the Prometheus password file.** Sent verbatim,
and a 401 that reads as a wrong password.

**Missing session keys.** Without
`http.auth.sessionKeysFile`, zot generates a random cookie key at every
start and mentions it in one `warn` line, which means every restart
logs everyone out of the web UI with no explanation. `deploy.sh`
generates `/etc/zot/session-keys.json` once and then leaves it alone —
rewriting it would cause the very thing it prevents. The key lengths
matter: zot passes these to `securecookie` as raw bytes, not decoded
base64, so the hash key must be 32 or 64 bytes and the encryption key
16, 24 or 32.

**A client that was never told the registry is insecure.** The TLS
handshake error names a certificate problem, not a missing
`insecure-registries` entry.

**`ProtectSystem=strict` and a moved blob store.** The unit's
`ReadWritePaths` is the only writable path zot has. `deploy.sh`
rewrites that line to match `ZOT_DATA`, so changing the data directory
by editing `config.json` alone gives a registry that starts, serves
reads and fails every push with a permission error from inside a
namespace nothing on the host can see.

[ref-harbor]: https://goharbor.io/
[ref-zot]: https://zotregistry.dev/
