#!/usr/bin/env python3
"""Merge this repo's Hermes config overlays into ~/.hermes/config.yaml.

Two files, each owning one decision: models.yaml the model routing and
mcp.yaml the MCP servers.

The Hermes installer owns config.yaml: it rewrites it on every update and
adds keys as the schema version moves. So this does not template the file,
it merges into it -- only the keys models.yaml actually names are touched,
and everything else is left exactly as the installer left it.

Deletion is explicit. `model.base_url`, `model.api_key` and
`model.context_length` are removed when models.yaml omits them, because
leaving a stale copy of a key or a URL behind is the failure this whole
folder exists to prevent.

`mcp_servers` is the one key that is replaced rather than merged, for the
same reason stated the other way round: a merge can only ever add servers.
Two dead `command: npx` entries survived months of applies because nothing
in this repo was able to remove them. mcp.yaml names the whole set.

Usage:
    ./apply-model-config.py [--dry-run] [--config PATH] [--models PATH]
                            [--mcp PATH]
"""

import argparse
import copy
import difflib
import os
import pathlib
import shutil
import sys
import time

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

# Keys under model: that the named custom provider supplies instead.
# Present in older configs; removed on apply.
MODEL_KEYS_TO_DROP = ("base_url", "api_key", "context_length")

# Pushed down into every profile so they route through the same endpoint
# and the same three resident models as the main agent.
PROFILE_SHARED_KEYS = ("providers", "custom_providers", "agent")

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_CONFIG = pathlib.Path.home() / ".hermes" / "config.yaml"
DEFAULT_PROFILES = pathlib.Path.home() / ".hermes" / "profiles"
DEFAULT_MODELS = HERE / "models.yaml"
DEFAULT_MCP = HERE / "mcp.yaml"


def deep_merge(base, overlay):
    """Recursively merge overlay into base. Lists are replaced, not appended."""
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = copy.deepcopy(value)
    return base


def strip_anchor_helpers(node):
    """Drop the ``_default`` scratch keys that models.yaml uses for YAML anchors."""
    if isinstance(node, dict):
        node.pop("_default", None)
        for value in node.values():
            strip_anchor_helpers(value)
    elif isinstance(node, list):
        for item in node:
            strip_anchor_helpers(item)
    return node


def print_diff(before, after, label):
    diff = difflib.unified_diff(
        yaml.safe_dump(before, sort_keys=False, allow_unicode=True).splitlines(),
        yaml.safe_dump(after, sort_keys=False, allow_unicode=True).splitlines(),
        fromfile=f"{label} (live)", tofile=f"{label} (merged)", lineterm="")
    # Never echo a secret into a terminal or a CI log. config.yaml carries
    # MCP server credentials inline, and they show up in these diffs as
    # soon as a neighbouring line changes.
    for line in diff:
        if any(s in line.lower() for s in ("api_key:", "password", "token:", "secret",
                                           "authorization:", "bearer ")):
            line = line.split(":")[0] + ": <redacted>"
        print(line)


def write_yaml(path, data):
    backup = path.with_suffix(f".yaml.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, backup)
    tmp = path.with_suffix(".yaml.tmp")
    tmp.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False,
                                  width=100, allow_unicode=True))
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    return backup


def apply_to(path, overlay, label, dry_run, replace_keys=()):
    """Merge overlay into the YAML at path. Returns True if anything changed.

    Keys named in replace_keys are emptied in the live config first, so the
    overlay's version of them lands whole instead of being merged key-by-key.
    That is what lets a server deleted from mcp.yaml actually disappear.
    Emptied rather than popped: assigning to an existing key keeps its
    position in the file, and a key that jumps to the end rewrites every
    line after it in the diff this prints.
    """
    config = yaml.safe_load(path.read_text()) or {}
    before = copy.deepcopy(config)
    for key in replace_keys:
        if key in overlay and isinstance(config.get(key), dict):
            config[key] = {}
    deep_merge(config, overlay)

    # The named provider owns the endpoint and credentials now.
    for key in MODEL_KEYS_TO_DROP:
        config.get("model", {}).pop(key, None)

    if config == before:
        print(f"{label} already matches models.yaml -- nothing to do")
        return False

    print_diff(before, config, label)
    if dry_run:
        return True

    backup = write_yaml(path, config)
    print(f"\nwrote {path} (previous version at {backup.name})")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true",
                        help="show the diff and exit without writing")
    parser.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    parser.add_argument("--profiles", type=pathlib.Path, default=DEFAULT_PROFILES)
    parser.add_argument("--models", type=pathlib.Path, default=DEFAULT_MODELS)
    parser.add_argument("--mcp", type=pathlib.Path, default=DEFAULT_MCP,
                        help="MCP server definitions; skipped if the file is absent")
    args = parser.parse_args()

    if not args.config.exists():
        sys.exit(f"no Hermes config at {args.config} -- is Hermes installed?")

    desired = strip_anchor_helpers(yaml.safe_load(args.models.read_text()) or {})
    profile_overrides = desired.pop("profile_overrides", {}) or {}

    # Profiles never get this: PROFILE_SHARED_KEYS decides what is pushed
    # down, and an MCP server started once per profile is a second process
    # holding the same credential.
    if args.mcp.exists():
        desired["mcp_servers"] = yaml.safe_load(args.mcp.read_text()) or {}

    changed = apply_to(args.config, desired, "config.yaml", args.dry_run,
                       replace_keys=("mcp_servers",))

    for name, model in profile_overrides.items():
        path = args.profiles / name / "config.yaml"
        if not path.exists():
            print(f"profiles/{name}: no config.yaml -- skipped")
            continue
        overlay = {k: copy.deepcopy(desired[k]) for k in PROFILE_SHARED_KEYS if k in desired}
        # supports_vision follows the model the profile actually uses, not
        # the main agent's: claiming vision on a text-only model makes
        # Hermes send image_url parts the endpoint will reject.
        served = (desired.get("custom_providers") or [{}])[0].get("models") or {}
        overlay["model"] = {
            "default": model,
            "provider": desired.get("model", {}).get("provider", "custom:lemonade"),
            "supports_vision": bool((served.get(model) or {}).get("supports_vision")),
        }
        changed |= apply_to(path, overlay, f"profiles/{name}/config.yaml", args.dry_run)

    if args.dry_run:
        print("\n--dry-run: no changes written")
    elif changed:
        print("restart to pick it up: systemctl --user restart hermes-gateway hermes-dashboard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
