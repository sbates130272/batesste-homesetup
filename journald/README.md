# journald — a cap on the log buffer

`systemd-journald` retention on `snoc-beelink`, bounded so the journal
cannot quietly claim 10 GiB of a shared root volume.

## Why

On 5 October 2026 the root filesystem was at 88% — 82 GiB used of 98
GiB, with 12 GiB free. Nothing had failed. Working through what was
actually on the disk:

| Consumer | Size | Bounded by |
| --- | --- | --- |
| `/var/lib/docker` | 20 GiB | nothing |
| **`/var/log/journal`** | **3.9 GiB** | **nothing** |
| `/var/lib/prometheus` | 9.1 GiB | `--storage.tsdb.retention.size=20GB` |
| `/var/lib/snapd` | 5.7 GiB | nothing |
| `~/.hermes` | 6.4 GiB | nothing |
| `~/.vscode-server` | 5.7 GiB | nothing |
| `~/.npm` | 3.8 GiB | nothing |

The journal stood out not because it was the largest but because it
was the one growing on a schedule nobody had chosen. `journald.conf`
had no `SystemMaxUse=` at all, and the documented default is **10% of
the filesystem the journal lives on**. On a 98 GiB root that is a 9.8
GiB ceiling, and the only reason it had not been hit is that the node
had not been up long enough to hit it.

That default is sized for a host where `/var` is its own filesystem.
Here `/`, `/home`, `/var/lib/docker` and the journal all share one LV,
so "10% of the filesystem" is an open-ended claim on space that other
things need more. `/var/lib/loki` already has its own 12 GiB LV for
exactly this reason; the journal never got the same treatment.

A one-off `journalctl --vacuum-size=500M` recovered 3.4 GiB. That is
not a fix — it resets the number without changing the ceiling, and the
journal grows straight back toward 9.8 GiB. This directory is the
ceiling.

## Why 1 GiB is enough

**The local journal is not the system of record on this host.**

Alloy reads it via `loki.source.journal` (see
[`../loki/alloy/config.alloy`](../loki/alloy/config.alloy)) and ships
every entry to Loki, which keeps **90 days** on its own 12 GiB LV — a
separate volume, so log growth there cannot fill `/`. The local
journal is the buffer in front of that pipeline, not the archive
behind it.

So the real question is not "how much history do I want" but "how long
might Alloy be down before I notice", and 1 GiB — roughly three weeks
at this node's rate — is generous against that. Anything older is a
Loki query:

```
{job="systemd-journal"} |= "whatever"
```

Two honest caveats:

- Entries from **before Alloy was deployed**, and any boot where Alloy
  failed to start, exist locally and nowhere else. Vacuuming past them
  loses them permanently. `deploy.sh` warns if `alloy` is not active
  when it runs, but it cannot know about past gaps.
- Loki's 90 days is itself a retention setting
  ([`../loki/loki.yml`](../loki/loki.yml)), not forever. Shortening it
  shortens the window this cap is leaning on.

## What this deploys

```
journald/
  journald.conf  -> /etc/systemd/journald.conf.d/90-batesste-journald.conf
  deploy.sh      Assert the above and verify it is what systemd honours
```

```bash
./deploy.sh --dry-run
./deploy.sh
./deploy.sh --vacuum    # also shrink the existing journal now
```

| Setting | Value | Default | Why |
| --- | --- | --- | --- |
| `SystemMaxUse` | 1 GiB | 10% of volume (9.8 GiB) | The cap. ~3 weeks of history. |
| `SystemMaxFileSize` | 128 MiB | 1/8 of `SystemMaxUse` | journald deletes whole files rather than trimming, so rotation granularity sets how tightly the cap is held. Set explicitly so changing the cap does not silently change rotation. |
| `SystemKeepFree` | 2 GiB | 15% of volume (14.7 GiB) | A real floor. The default is so far above anything a 1 GiB journal could cause that it never binds. |

`--vacuum` is separate because it is the one destructive step.
Deploying the cap governs what journald does from now on; it does not
shrink an already-oversized journal until rotation gets to it, which
is hours, not seconds.

## The filename, and the limit of the oomd lesson

systemd merges drop-ins by sorting on **filename, across every search
directory at once**. `/etc` does not beat `/usr/lib` unless the two
files are named the same. That is the trap documented at length in
[`../oomd/root-slice.conf`](../oomd/root-slice.conf), where a `10-`
prefix sorted before the distro's `10-oomd-root-slice-defaults.conf`
and lost to it silently.

The obvious lesson to carry over is "use a `90-` prefix and you win".
**That is not true here**, and it is worth writing down before someone
relies on it. Ubuntu ships
`/usr/lib/systemd/journald.conf.d/syslog.conf` — no numeric prefix —
and digits sort before letters, so an unprefixed distro filename lands
*last* no matter what number we pick:

```console
$ systemd-analyze cat-config systemd/journald.conf | grep '^# /'
# /etc/systemd/journald.conf
# /etc/systemd/journald.conf.d/90-batesste-journald.conf
# /usr/lib/systemd/journald.conf.d/syslog.conf        <- applied last
```

This is harmless today: `syslog.conf` sets only `ForwardToSyslog=` and
shares no key with this config. Beating it would mean naming our file
`syslog.conf` too — the documented way to mask a `/usr/lib` drop-in
entirely — which would suppress the distro's syslog forwarding as a
side effect. Not worth it for a conflict that does not exist.

The file keeps the `90-` prefix because it is the right convention
against *other* numeric drop-ins. But the thing actually protecting
this config is the verify step in `deploy.sh`, which asserts the
**effective merged value** rather than the file's presence — that
catches an override from any file, in any sort position, including one
a future systemd package has not shipped yet.

`deploy.sh` also removes a stale `size.conf`, the name used by the
hand-deployment that preceded this directory.

## Verifying

`journalctl --disk-usage` is **not** a check. It reads under the cap
on a freshly vacuumed journal whether or not the cap was ever applied
— the same false pass that `oomctl` gives for an unprotected system.
Ask systemd what it actually merged:

```bash
systemd-analyze cat-config systemd/journald.conf | grep -i systemmaxuse
```

The **last** value printed is the effective one. `deploy.sh` asserts
this and fails if the effective value is not 1G, which also catches
the drop-in being out-sorted rather than merely absent.

## The other half

A cap stops the journal from being the thing that fills the disk. It
does nothing about the disk filling.

The root filesystem reached 88% and nothing said so. The alerting in
[`../grafana/provisioning/alerting/rules.yaml`](../grafana/provisioning/alerting/rules.yaml)
has a `backups` group and a `memory` group, and **no disk group at
all** — the 88% was found by going and looking, which is the same
failure the oomd work was supposed to have taught. Every number in
the table at the top of this file was in Prometheus for weeks, and no
rule read any of it.

The `disk` rule group is the other half, added alongside this
directory: `NodeDiskFillingUp` at 15% free, `NodeDiskCritical` at 5%,
and `NodeDiskInodesLow` at 10% of inodes. Backtested against the week
to 5 October, beelink's root bottomed out at 10.5% free — the warning
would have fired with room to spare.

That still only makes the problem visible. Of the seven consumers in
the table above, this directory caps exactly one. The two largest are
bounded by nothing and by a 20 GiB ceiling respectively, on a volume
with 25 GiB free — which is now a thing an alert will tell you about
rather than a thing to notice.
