#!/usr/bin/env python3
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

"""Prometheus exporter for GitHub Actions workflow health.

Discovers an owner's repositories from the GitHub API, samples the most
recent Actions runs in each, and exposes the latest default-branch run
per workflow as Prometheus metrics. The question it answers is "which
of my workflows is red right now", not "how much CI do I run".

Metrics are served from an in-memory snapshot refreshed on a background
thread, so a scrape never waits on the GitHub API. The cost of that is
that `up` stays 1 through an API outage -- watch
`github_actions_last_refresh_timestamp_seconds` to tell whether a green
target is serving current data.

Standard library only, deliberately: this runs under systemd on the
homelab server with no virtualenv to maintain.
"""

import argparse
import email.utils
import fnmatch
import json
import logging
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 9612
DEFAULT_LISTEN = "127.0.0.1"
DEFAULT_OWNER = "sbates130272"
DEFAULT_INTERVAL = 300
DEFAULT_DISCOVERY_INTERVAL = 3600
DEFAULT_MAX_REPO_AGE_DAYS = 90
DEFAULT_TOKEN_FILE = "/etc/gh-actions-exporter/token"

API_ROOT = "https://api.github.com"
USER_AGENT = "gh-actions-exporter (+https://github.com/sbates130272/batesste-homesetup)"

# One page of runs per repo per refresh. A workflow whose last run has
# already fallen off this page is not reported: a workflow with a
# hundred runs behind it is not what "fix it today" means.
RUNS_PER_PAGE = 100

# Dependabot's own machinery files its security and graph updates as
# runs with event=dynamic, named things like "pip in /Documentation/sphinx
# for Jinja2 - Update #1394352365". They are not workflows in this
# repository, they fail for reasons nobody here can fix, and each one
# carries a fresh name -- so left in, they would be an ever-growing
# pile of permanently red series that nothing can ever turn green.
# They still count towards the per-repo conclusion tallies, which is
# where "something in this repo is unhappy" belongs.
IGNORED_EVENTS = frozenset({"dynamic"})

logger = logging.getLogger("gh-actions-exporter")


class GitHubError(Exception):
    """An API call failed in a way the caller should count and survive."""


class GitHubClient:
    """Minimal GitHub REST client over urllib.

    Tracks rate-limit headers as a side effect of every call, because
    the only interesting time to know the budget is after spending some
    of it.
    """

    def __init__(self, token, timeout=30):
        self._token = token
        self._timeout = timeout
        self.rate_limit = None
        self.rate_remaining = None
        self.requests = 0

    def get(self, path, params=None):
        url = API_ROOT + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Authorization": f"Bearer {self._token}",
                "User-Agent": USER_AGENT,
            },
        )
        self.requests += 1
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                self._note_rate_limit(resp.headers)
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            self._note_rate_limit(exc.headers)
            # The token is never in the message, but the URL can carry
            # query parameters, so report the path rather than the URL.
            raise GitHubError(f"{path}: HTTP {exc.code} {exc.reason}") from exc
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise GitHubError(f"{path}: {exc}") from exc

    def _note_rate_limit(self, headers):
        for header, attr in (
            ("X-RateLimit-Limit", "rate_limit"),
            ("X-RateLimit-Remaining", "rate_remaining"),
        ):
            value = headers.get(header)
            if value is not None:
                try:
                    setattr(self, attr, int(value))
                except ValueError:
                    pass


def parse_timestamp(value):
    """Parse a GitHub ISO-8601 timestamp into a Unix timestamp."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def discover_repos(client, owner, max_age_days, excludes):
    """List the owner's own, live repositories.

    Forks and archived repos are dropped because their workflow health
    is somebody else's problem or nobody's. The age cut keeps the
    refresh cheap: of ~80 repos on this account, around a sixth have
    been touched this quarter.
    """
    cutoff = time.time() - max_age_days * 86400
    repos = []
    page = 1
    while True:
        batch = client.get(
            "/user/repos",
            {
                "affiliation": "owner",
                "sort": "pushed",
                "direction": "desc",
                "per_page": 100,
                "page": page,
            },
        )
        if not batch:
            break
        for repo in batch:
            name = repo.get("full_name", "")
            if repo.get("fork") or repo.get("archived") or repo.get("disabled"):
                continue
            if owner and not name.startswith(f"{owner}/"):
                continue
            if any(fnmatch.fnmatch(name, pattern) for pattern in excludes):
                continue
            pushed = parse_timestamp(repo.get("pushed_at"))
            if pushed is None or pushed < cutoff:
                continue
            repos.append(
                {
                    "full_name": name,
                    "default_branch": repo.get("default_branch") or "main",
                }
            )
        if len(batch) < 100:
            break
        page += 1
    repos.sort(key=lambda r: r["full_name"])
    return repos


def collect_repo(client, repo):
    """Sample one repo's recent runs.

    Returns the latest *completed* run per workflow on the default
    branch, plus a tally of conclusions across every run on the page.
    The tally spans all branches on purpose: it is a texture of how CI
    is going, where the per-workflow view is the actionable part.
    """
    data = client.get(
        f"/repos/{repo['full_name']}/actions/runs",
        {"per_page": RUNS_PER_PAGE},
    )
    runs = data.get("workflow_runs") or []

    conclusions = {}
    in_progress = 0
    latest = {}
    for run in runs:
        conclusion = run.get("conclusion")
        if conclusion:
            conclusions[conclusion] = conclusions.get(conclusion, 0) + 1
        else:
            in_progress += 1

        if run.get("head_branch") != repo["default_branch"]:
            continue
        if run.get("status") != "completed" or not conclusion:
            continue
        if run.get("event") in IGNORED_EVENTS:
            continue
        workflow = run.get("name") or run.get("path") or "unknown"
        started = parse_timestamp(run.get("run_started_at") or run.get("created_at"))
        finished = parse_timestamp(run.get("updated_at"))
        # The API returns runs newest first, so the first one seen for a
        # workflow is the latest one.
        if workflow in latest:
            continue
        latest[workflow] = {
            "conclusion": conclusion,
            "timestamp": finished,
            "duration": (finished - started) if (finished and started) else None,
            "run_id": run.get("id"),
        }

    return {
        "workflows": latest,
        "conclusions": conclusions,
        "in_progress": in_progress,
    }


# `success` is the only green conclusion worth calling green. `skipped`
# and `neutral` are not failures either, but a workflow that only ever
# skips is not passing, so they are counted as neither: the failing
# count below asks for `failure`-like conclusions explicitly rather
# than for "not success".
FAILED_CONCLUSIONS = frozenset(
    {"failure", "timed_out", "startup_failure", "action_required"}
)


class Collector:
    """Owns the snapshot and the background refresh that renews it."""

    def __init__(self, client, args):
        self.client = client
        self._args = args
        self._lock = threading.Lock()
        self._repos = []
        self._repos_fetched_at = 0.0
        self._state = {
            "repos": {},
            "last_refresh": None,
            "duration": 0.0,
            "errors": 0,
        }

    def snapshot(self):
        with self._lock:
            return dict(self._state, repos=dict(self._state["repos"]))

    def refresh(self):
        started = time.time()
        errors = 0

        if started - self._repos_fetched_at >= self._args.discovery_interval:
            try:
                self._repos = discover_repos(
                    self.client,
                    self._args.owner,
                    self._args.max_repo_age_days,
                    self._args.exclude,
                )
                self._repos_fetched_at = started
                logger.info("Discovered %d repositories", len(self._repos))
            except GitHubError as exc:
                errors += 1
                logger.error("Repository discovery failed: %s", exc)

        repos = {}
        for repo in self._repos:
            try:
                result = collect_repo(self.client, repo)
                result["ok"] = True
            except GitHubError as exc:
                errors += 1
                logger.error("Collecting %s failed: %s", repo["full_name"], exc)
                result = {
                    "workflows": {},
                    "conclusions": {},
                    "in_progress": 0,
                    "ok": False,
                }
            repos[repo["full_name"]] = result

        duration = time.time() - started
        with self._lock:
            # A failed refresh keeps the previous repo data rather than
            # blanking it: "the API is unreachable" is what the
            # freshness metric is for, and empty panels would look like
            # a fleet with no workflows.
            if repos:
                self._state["repos"] = repos
            self._state["last_refresh"] = started
            self._state["duration"] = duration
            self._state["errors"] += errors

        logger.info(
            "Refreshed %d repositories in %.1fs (%d errors, %s API calls remaining)",
            len(repos),
            duration,
            errors,
            self.client.rate_remaining if self.client.rate_remaining is not None else "?",
        )

    def run_forever(self):
        while True:
            try:
                self.refresh()
            except Exception:  # noqa: BLE001 - the thread must not die
                logger.exception("Unhandled error during refresh")
                with self._lock:
                    self._state["errors"] += 1
            time.sleep(self._args.interval)


def escape_label(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def labels(**kwargs):
    inner = ",".join(f'{k}="{escape_label(v)}"' for k, v in kwargs.items())
    return "{" + inner + "}"


def render(state, client):
    """Render a snapshot as the Prometheus text exposition format."""
    out = []

    def family(name, kind, help_text):
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {kind}")

    repos = state["repos"]

    family(
        "github_actions_workflow_last_run_success",
        "gauge",
        "1 if the latest completed default-branch run of this workflow succeeded",
    )
    for repo, data in sorted(repos.items()):
        for workflow, run in sorted(data["workflows"].items()):
            value = 1 if run["conclusion"] == "success" else 0
            out.append(
                "github_actions_workflow_last_run_success"
                + labels(repo=repo, workflow=workflow)
                + f" {value}"
            )

    family(
        "github_actions_workflow_last_run_conclusion",
        "gauge",
        "Conclusion of the latest completed default-branch run, as a label",
    )
    for repo, data in sorted(repos.items()):
        for workflow, run in sorted(data["workflows"].items()):
            out.append(
                "github_actions_workflow_last_run_conclusion"
                + labels(repo=repo, workflow=workflow, conclusion=run["conclusion"])
                + " 1"
            )

    family(
        "github_actions_workflow_last_run_timestamp_seconds",
        "gauge",
        "When the latest completed default-branch run of this workflow finished",
    )
    for repo, data in sorted(repos.items()):
        for workflow, run in sorted(data["workflows"].items()):
            if run["timestamp"] is not None:
                out.append(
                    "github_actions_workflow_last_run_timestamp_seconds"
                    + labels(repo=repo, workflow=workflow)
                    + f" {run['timestamp']:.0f}"
                )

    family(
        "github_actions_workflow_last_run_duration_seconds",
        "gauge",
        "How long the latest completed default-branch run took",
    )
    for repo, data in sorted(repos.items()):
        for workflow, run in sorted(data["workflows"].items()):
            if run["duration"] is not None:
                out.append(
                    "github_actions_workflow_last_run_duration_seconds"
                    + labels(repo=repo, workflow=workflow)
                    + f" {run['duration']:.0f}"
                )

    # A value rather than a label, deliberately: the id changes on every
    # run, so as a label it would churn a fresh series each time. The
    # dashboard reads it as a field to build the run URL.
    family(
        "github_actions_workflow_last_run_id",
        "gauge",
        "Run id of the latest completed default-branch run, for building its URL",
    )
    for repo, data in sorted(repos.items()):
        for workflow, run in sorted(data["workflows"].items()):
            if run["run_id"] is not None:
                out.append(
                    "github_actions_workflow_last_run_id"
                    + labels(repo=repo, workflow=workflow)
                    + f" {run['run_id']}"
                )

    family(
        "github_actions_repo_failing_workflows",
        "gauge",
        "Workflows whose latest default-branch run failed",
    )
    for repo, data in sorted(repos.items()):
        failing = sum(
            1
            for run in data["workflows"].values()
            if run["conclusion"] in FAILED_CONCLUSIONS
        )
        out.append(
            "github_actions_repo_failing_workflows" + labels(repo=repo) + f" {failing}"
        )

    family(
        "github_actions_repo_tracked_workflows",
        "gauge",
        "Workflows with a completed default-branch run in the sampled window",
    )
    for repo, data in sorted(repos.items()):
        out.append(
            "github_actions_repo_tracked_workflows"
            + labels(repo=repo)
            + f" {len(data['workflows'])}"
        )

    family(
        "github_actions_repo_recent_runs",
        "gauge",
        "Runs by conclusion across the sampled window, all branches",
    )
    for repo, data in sorted(repos.items()):
        for conclusion, count in sorted(data["conclusions"].items()):
            out.append(
                "github_actions_repo_recent_runs"
                + labels(repo=repo, conclusion=conclusion)
                + f" {count}"
            )

    family(
        "github_actions_repo_runs_in_progress",
        "gauge",
        "Runs in the sampled window that have not concluded yet",
    )
    for repo, data in sorted(repos.items()):
        out.append(
            "github_actions_repo_runs_in_progress"
            + labels(repo=repo)
            + f" {data['in_progress']}"
        )

    family(
        "github_actions_repo_scrape_success",
        "gauge",
        "1 if this repository's last API call succeeded",
    )
    for repo, data in sorted(repos.items()):
        out.append(
            "github_actions_repo_scrape_success"
            + labels(repo=repo)
            + f" {1 if data['ok'] else 0}"
        )

    family("github_actions_tracked_repos", "gauge", "Repositories being sampled")
    out.append(f"github_actions_tracked_repos {len(repos)}")

    # Metrics are served from cache, so `up` says nothing about whether
    # the GitHub API is answering. This is the metric that does.
    family(
        "github_actions_last_refresh_timestamp_seconds",
        "gauge",
        "When the cached snapshot was last refreshed",
    )
    if state["last_refresh"] is not None:
        out.append(
            f"github_actions_last_refresh_timestamp_seconds {state['last_refresh']:.0f}"
        )

    family(
        "github_actions_refresh_duration_seconds",
        "gauge",
        "How long the last refresh took",
    )
    out.append(f"github_actions_refresh_duration_seconds {state['duration']:.3f}")

    family(
        "github_actions_refresh_errors_total",
        "counter",
        "API calls that failed since the exporter started",
    )
    out.append(f"github_actions_refresh_errors_total {state['errors']}")

    family(
        "github_actions_api_requests_total",
        "counter",
        "GitHub API requests made since the exporter started",
    )
    out.append(f"github_actions_api_requests_total {client.requests}")

    family(
        "github_actions_rate_limit_remaining",
        "gauge",
        "Requests left in the current GitHub API rate-limit window",
    )
    if client.rate_remaining is not None:
        out.append(f"github_actions_rate_limit_remaining {client.rate_remaining}")

    family(
        "github_actions_rate_limit_limit",
        "gauge",
        "Size of the current GitHub API rate-limit window",
    )
    if client.rate_limit is not None:
        out.append(f"github_actions_rate_limit_limit {client.rate_limit}")

    return "\n".join(out) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's spelling
        if self.path.split("?")[0] == "/metrics":
            body = render(
                self.server.collector.snapshot(), self.server.collector.client
            ).encode("utf-8")
            self._respond(200, body, "text/plain; version=0.0.4; charset=utf-8")
        elif self.path == "/health":
            self._respond(200, b"OK\n", "text/plain; charset=utf-8")
        else:
            self._respond(404, b"not found\n", "text/plain; charset=utf-8")

    def _respond(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Date", email.utils.formatdate(usegmt=True))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        logger.debug(fmt, *args)


SELFTEST_STATE = {
    "repos": {
        "sbates130272/batesste-homesetup": {
            "workflows": {
                "batesste-homesetup": {
                    "conclusion": "success",
                    "timestamp": 1760000000,
                    "duration": 95,
                    "run_id": 18000000001,
                },
            },
            "conclusions": {"success": 41, "failure": 2},
            "in_progress": 1,
            "ok": True,
        },
        "sbates130272/hsa-snoop": {
            "workflows": {
                "build and test": {
                    "conclusion": "failure",
                    "timestamp": 1760000600,
                    "duration": 310,
                    "run_id": 18000000002,
                },
            },
            "conclusions": {"failure": 3},
            "in_progress": 0,
            "ok": False,
        },
    },
    "last_refresh": 1760001000,
    "duration": 4.25,
    "errors": 1,
}


def selftest():
    """Render the full metric set from a fixture, with no network.

    CI pipes this into `promtool check metrics`, which is the only
    cheap way to catch a malformed family or a mistyped counter before
    it reaches the TSDB.
    """
    client = GitHubClient("unused")
    client.requests = 12
    client.rate_limit = 5000
    client.rate_remaining = 4988
    sys.stdout.write(render(SELFTEST_STATE, client))


def read_token(args):
    """Resolve the API token.

    The systemd credential comes first so the unit can keep the token
    root-owned and out of the service's own filesystem view. No format
    check: classic and fine-grained PATs have different prefixes and
    asserting one locks out the other.
    """
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    candidates = []
    if creds:
        candidates.append(os.path.join(creds, "token"))
    if args.token_file:
        candidates.append(args.token_file)

    for path in candidates:
        try:
            with open(path) as handle:
                token = handle.read().strip()
        except OSError:
            continue
        if token:
            return token

    return (os.environ.get("GITHUB_TOKEN") or "").strip() or None


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Prometheus exporter for GitHub Actions workflow health"
    )
    parser.add_argument("--listen", default=DEFAULT_LISTEN, help="Listen address")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Listen port")
    parser.add_argument("--owner", default=DEFAULT_OWNER, help="Repository owner")
    parser.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_INTERVAL,
        help="Seconds between workflow-run refreshes",
    )
    parser.add_argument(
        "--discovery-interval",
        type=int,
        default=DEFAULT_DISCOVERY_INTERVAL,
        help="Seconds between re-listing the owner's repositories",
    )
    parser.add_argument(
        "--max-repo-age-days",
        type=int,
        default=DEFAULT_MAX_REPO_AGE_DAYS,
        help="Skip repositories not pushed to within this many days",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="Exclude repositories matching this owner/name glob (repeatable)",
    )
    parser.add_argument(
        "--token-file", default=DEFAULT_TOKEN_FILE, help="File holding the API token"
    )
    parser.add_argument(
        "--log-level", default="INFO", help="Python logging level name"
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Render metrics from a fixture and exit, making no API calls",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(levelname)s %(message)s",
    )

    if args.selftest:
        selftest()
        return 0

    token = read_token(args)
    if not token:
        logger.error(
            "No API token. Expected a systemd credential, %s, or $GITHUB_TOKEN.",
            args.token_file,
        )
        return 1

    client = GitHubClient(token)
    collector = Collector(client, args)

    thread = threading.Thread(target=collector.run_forever, daemon=True)
    thread.start()

    server = ThreadingHTTPServer((args.listen, args.port), MetricsHandler)
    server.collector = collector
    logger.info("Serving metrics on http://%s:%d/metrics", args.listen, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
