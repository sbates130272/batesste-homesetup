# oomd — a backstop for memory exhaustion

`systemd-oomd` on `snoc-beelink`, configured so that the node kills
something instead of hanging.

## Why

On 16 September 2026 this node had to be power cycled. The sequence,
reconstructed from `journalctl -b -1` and Prometheus:

| Time (MDT) | State |
| --- | --- |
| Sep 15 09:00 | MemAvailable 4.7 GiB, swap 4.0 GiB free |
| Sep 15 18:00 | swap 31% free — the first honest warning |
| Sep 16 01:29 | the `cua` container comes up, 2 GiB ceiling |
| Sep 16 03:00 | **swap fully consumed**, 0 MiB free |
| Sep 16 03:42 | `hermes_cli.kanban_db` begins deferring workers; 143 warnings follow |
| Sep 16 06:34:54 | `systemd-journald` misses its 3-minute watchdog |
| Sep 16 06:35:56 | **last userspace log line** |
| Sep 16 06:38 → 07:21 | kernel-only PCIe AER lines, gaps widening to six minutes |
| Sep 16 07:25 | power cycle |

The kernel was alive the whole time — it kept logging. Userspace could
not be scheduled for 45 minutes.

The decisive detail is that **`node_vmstat_oom_kill` never moved**. The
kernel OOM killer did not fire once. That is not a bug: with 4 GiB of
swap, `MemAvailable` never reaches the floor that triggers it, so the
kernel reclaims and re-faults forever instead of killing anything.
Swap turns "one process dies" into "the node is lost", and the larger
the swap the wider that window. `systemd-oomd` closes it by acting on
pressure and swap-use signals long before the kernel's last resort.

Hermes' own backpressure worked correctly throughout — it deferred
workers rather than dropping them — but it can only gate *new* work.
Nothing in the system could reclaim from what was already resident.

## What this deploys

```
oomd/
  oomd.conf              -> /etc/systemd/oomd.conf.d/10-batesste.conf
  root-slice.conf        -> /etc/systemd/system/-.slice.d/
  user-service.conf      -> /etc/systemd/system/user@.service.d/
  preference-omit.conf   -> ssh, tailscaled
  preference-avoid.conf  -> prometheus, grafana-server, loki, alloy
                            hermes-gateway, hermes-dashboard (user units)
  deploy.sh              Install the package and assert all of the above
```

```bash
./deploy.sh --dry-run
./deploy.sh
```

Two triggers, both of which have to be opted into explicitly —
**installing the package on its own changes no behaviour at all**,
which is the detail most likely to produce a false sense of safety:

| Trigger | Where | Fires when |
| --- | --- | --- |
| `ManagedOOMSwap=kill` | `-.slice` | system-wide swap use > 90% |
| `ManagedOOMMemoryPressure=kill` | `user@.service` | pressure > 50% for 20s |

Against the incident, the swap trigger would have killed the largest
swap consumer at roughly 01:00 on 16 September — 5.5 hours before
userspace stopped responding.

## What is protected, and why

`ManagedOOMPreference=omit` means never selected.
`avoid` means selected only after every ordinary candidate.

| Preference | Units | Reason |
| --- | --- | --- |
| `omit` | `ssh`, `tailscaled` | The September incident ended in a power cycle *because there was no way in*. An OOM policy that can kill the last remote shell has optimised for the wrong outcome. |
| `avoid` | `prometheus`, `grafana-server`, `loki`, `alloy` | Scrapes stopped at 06:30 and the record of the interesting 45 minutes does not exist. Killing the observability first reproduces that blind spot on purpose, every time. |
| `avoid` | `hermes-gateway`, `hermes-dashboard` | What the node exists to run, and a plausible hog. Transient worker scopes around it get taken first. |

Keep the `omit` list at two. Every unit on it can grow without bound
and shifts the kill onto something else.

### Hermes is a user unit

`hermes-gateway` and `hermes-dashboard` live in
`user@1000.service/app.slice`, not `system.slice`. Their drop-ins go in
`~/.config/systemd/user/`; one placed in `/etc/systemd/system/` parses,
deploys, and does nothing. `deploy.sh` handles the two cases
separately (`USER_AVOID_UNITS`).

This is also why the pressure trigger points at `user@.service`: at the
time of writing `user-1000.slice` holds ~2.8 GiB of the 7.5 GiB total —
the VS Code Remote server and its extension hosts, Claude Code, and
Hermes. On this host, user memory *is* the memory.

That means this rule can kill a Hermes worker scope or a VS Code
session. That is intended. The alternative is the behaviour we already
have evidence for.

## Verifying

`systemctl status` is not a check. A running `systemd-oomd` monitoring
an empty set of cgroups looks identical to a working one:

```bash
oomctl                      # must list non-empty monitored cgroups
journalctl -u systemd-oomd -g 'Killed'
```

`deploy.sh` fails loudly if `oomctl` reports nothing monitored.

## The other half

A backstop that kills things is not the same as knowing the node is in
trouble. Every number in the table above was in Prometheus for the
eighteen hours before the hang, and no alert rule read it.

The `memory` rule group in
[`../grafana/provisioning/alerting/rules.yaml`](../grafana/provisioning/alerting/rules.yaml)
is the other half — `NodeSwapFillingUp` at 50% swap free would have
notified at 18:00 on 15 September, thirteen hours out. Alert early to a
human, kill late as a machine; this directory is only the second part.

## Not deployed to snoc-strix

`snoc-strix` has the same exposure — 12 GiB available of 30 GiB,
2.6 GiB already in swap, three `llama-server` instances, and no OOM
daemon — but tuning an OOM policy against an 8.4 GiB model server is a
different problem to tuning one against editor sessions. Roll it there
once this config has a week of evidence behind it, with `lemonade` and
`llama-server` marked `avoid`.
