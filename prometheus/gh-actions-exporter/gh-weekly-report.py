#!/usr/bin/env python3
"""Weekly GitHub Actions report, sourced from Prometheus on snoc-beelink.

Prints a compact plain-text report of the last 7 days of tracked
workflow activity. Deterministic data collection only — formatting and
commentary are left to whoever (human or agent) consumes the output.

Data sources, in order of preference:
  1. github_actions_workflow_last_run_conclusion series "born" inside the
     window (series-born detection: a run's conclusion creates a brand-new
     series, so `unless timestamp(series offset <window>)` isolates runs
     that finished in the window — the gauge itself would otherwise be
     double-counted every scrape).
  2. github_actions_repo_recent_runs / workflow_recent_runs counters
     (exporter's own recent-window view; coarser, used as fallback).
  3. github_actions_workflow_last_run_* for the current-state tail.

Pitfall: right after an exporter restart every conclusion series is new,
so the first report following a deploy over-counts. The script flags the
exporter restart time so the reader can judge.
"""
import json
import sys
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
    first_seen = query(
        "min(timestamp(github_actions_workflow_conclusion_events_total))"
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

    total = sum(sum(d.values()) for d in per_repo.values())
    fails = sum(
        v for d in per_repo.values() for k, v in d.items() if k not in ("success", "skipped")
    )

    out = []
    out.append(time.strftime("GitHub Actions weekly report — %A %d %b %Y (last 7 days)", time.localtime(now)))
    out.append(f"Runs concluded in window: {total} | non-success: {fails}"
               + (f" ({100.0*fails/total:.0f}%)" if total else ""))
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
