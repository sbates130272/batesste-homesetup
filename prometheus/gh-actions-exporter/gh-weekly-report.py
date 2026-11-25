#!/usr/bin/env python3
"""Weekly GitHub Actions report, sourced from Prometheus on snoc-beelink.

Prints a compact plain-text report of the last 7 days of tracked
workflow activity. Deterministic data collection only — formatting and
commentary are left to whoever (human or agent) consumes the output.

Data sources:
  1. increase(github_actions_workflow_conclusion_events_total[window]) for
     the per-repo, per-conclusion counts. The exporter bumps that counter
     once per previously-unseen completed run id, so each run is counted
     exactly once no matter how the scrapes fall — unlike the
     _last_run_ gauges, which only ever hold a workflow's newest outcome.
  2. github_actions_workflow_last_run_success for the current-state tail
     (which workflows are red right now).

The counter is only as trustworthy as its continuity, so the report
annotates the two ways it can mislead rather than hiding them:

  - resets() > 0 means the counter was zeroed inside the window (an
    exporter deploy that lost its state file), and increase() has
    extrapolated across the gap.
  - a counter younger than the window can only report the slice of the
    window it was alive for; the report says how much that is.

It also warns when up{job="gh-actions-exporter"} is 0, since every number
above is then stale.
"""
import json
import time
import urllib.parse
import urllib.request
from collections import defaultdict

PROM = "http://10.0.0.15:9090/prometheus/api/v1"
WINDOW_HOURS = 168



def query(expr, ts=None):
    params = {"query": expr}
    if ts is not None:
        params["time"] = int(ts)
    url = PROM + "/query?" + urllib.parse.urlencode(params)
    d = json.loads(urllib.request.urlopen(url, timeout=30).read())
    if d.get("status") != "success":
        raise SystemExit(f"prometheus error: {d.get('error')}")
    return d["data"]["result"]


def main():
    now = time.time()

    # Exact per-run counts from the exporter's conclusion event counter.
    window = str(WINDOW_HOURS) + "h"
    born = query(
        "sum by (repo, conclusion) ("
        "increase(github_actions_workflow_conclusion_events_total{repo=~\".+\"}["
        + window + "]))"
    )
    # A counter reset (exporter deploy) would make increase() extrapolate;
    # resets() surfaces how many resets happened in the window so the
    # reader knows the numbers were spliced.
    resets = query(
        "sum(resets(github_actions_workflow_conclusion_events_total[" + window + "]))"
    )
    reset_count = int(float(resets[0]["value"][1])) if resets else 0

    # Honest warming-up note: a counter younger than the window can only
    # report the part of the window it has witnessed.
    # timestamp() alone returns the *evaluation* time, not the series birth,
    # so min(timestamp(m)) is always ~now and the counter looks 0h old. The
    # subquery walks the window and takes the earliest step at which the
    # series actually had a sample. A counter older than the window simply
    # floors at the window start, which reads as "old enough" below.
    first_seen = query(
        "min(min_over_time(timestamp("
        "github_actions_workflow_conclusion_events_total)[" + window + ":1h]))"
    )
    counter_age_h = (now - float(first_seen[0]["value"][1])) / 3600.0 if first_seen else None

    # Currently-failing workflows for the state tail.
    state = {
        s["metric"]["repo"] + "|" + s["metric"].get("workflow", ""): float(s["value"][1])
        for s in query("github_actions_workflow_last_run_success")
    }
    up = query("up{job=\"gh-actions-exporter\"}")
    exporter_up = bool(up) and float(up[0]["value"][1]) == 1

    per_repo = defaultdict(lambda: defaultdict(int))
    for s in born:
        m = s["metric"]
        v = int(round(float(s["value"][1])))
        if v > 0:
            per_repo[m.get("repo", "?")][m.get("conclusion", "?")] += v

    # Cancelled and skipped runs never reached a verdict, so folding them
    # into a "failure rate" would let a burst of cancellations read as a
    # collapse in CI health. Rate is failures over runs that actually
    # decided; the other two are reported alongside, not buried in it.
    def tally(pred):
        return sum(v for d in per_repo.values() for k, v in d.items() if pred(k))

    total = sum(sum(d.values()) for d in per_repo.values())
    cancelled = tally(lambda k: k == "cancelled")
    skipped = tally(lambda k: k == "skipped")
    fails = tally(lambda k: k not in ("success", "skipped", "cancelled"))
    decided = total - cancelled - skipped

    out = []
    out.append(time.strftime("GitHub Actions weekly report — %A %d %b %Y (last 7 days)", time.localtime(now)))
    out.append(f"Runs concluded in window: {total}")
    out.append(f"  failed:    {fails} of {decided} decided"
               + (f" ({100.0*fails/decided:.0f}%)" if decided else ""))
    out.append(f"  cancelled: {cancelled}")
    out.append(f"  skipped:   {skipped}")
    if reset_count:
        out.append(f"NOTE: counter reset(s) in window ({reset_count}) — counts are spliced across them.")
    if counter_age_h is not None and counter_age_h < WINDOW_HOURS:
        out.append(
            f"NOTE: event counter is only {counter_age_h:.0f}h old — counts cover "
            f"that much of the window, not the full {WINDOW_HOURS}h."
        )
    if not exporter_up:
        out.append("WARNING: exporter is DOWN; numbers may be stale.")

    out.append("")
    out.append("Per-repo (conclusions finished in window):")
    for repo in sorted(per_repo, key=lambda r: -sum(per_repo[r].values())):
        d = per_repo[repo]
        line = ", ".join(f"{k}={v}" for k, v in sorted(d.items()))
        out.append(f"  {repo}: {line}")

    out.append("")
    out.append("Currently red (latest run):")
    red = [(k, v) for k, v in state.items() if v == 0 and "|" in k]
    for k, _ in sorted(red):
        repo, wf = k.split("|", 1)
        if repo and wf:
            out.append(f"  {repo} / {wf}")
    if not red:
        out.append("  (none)")

    print("\n".join(out))


if __name__ == "__main__":
    main()
