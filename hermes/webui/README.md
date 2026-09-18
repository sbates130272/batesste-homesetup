# webui — the one patch hermes-webui needs

`hermes-webui` is a [separate project](https://github.com/nesquena/hermes-webui),
checked out at `~/Projects/hermes-webui`. Nothing here is a copy of it. This
folder holds the single local change that box depends on, so that a re-clone
does not silently lose it.

| File | What it is |
| --- | --- |
| [`workspace-git-sign.patch`](./workspace-git-sign.patch) | Makes WebUI's hardcoded GPG-signing override opt-out |

The unit that runs it is
[`../systemd/user/hermes-webui.service`](../systemd/user/hermes-webui.service);
its environment comes from the `systemd` package in the dotfiles
(`~/.config/environment.d/50-hermes.conf`).

## Why the patch exists

WebUI gates every mutating Git operation — stage, unstage, discard, commit,
checkout, pull, push — behind `HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE`,
default off. That gate is fine and the dotfiles turn it on.

The problem is what it turns on. `_GIT_DESTRUCTIVE_HARDENED_CONFIG` in
`api/workspace_git.py` passes this on every mutating call:

```
git -c commit.gpgSign=false -c push.gpgSign=false -c gpg.program= ... commit
```

A command-line `-c` beats `.gitconfig`, and there is no environment variable
or config file that overrides it. So enabling the destructive flag as shipped
means **every commit Hermex makes is unsigned**, with no warning and no way
to ask for otherwise — against a standing rule here that commits are signed.

The patch splits those five entries into their own tuple and applies them
only when `HERMES_WEBUI_WORKSPACE_GIT_SIGN` is unset. Default behaviour is
byte-identical to upstream; the rest of the hardening
(`core.alternateRefsCommand`, the `core.hooksPath` redirect to an empty
directory, the `credential.helper`/`askPass` neutralization, the env scrub)
is untouched.

What it re-admits is `gpg.program` resolution — running the configured gpg
binary. That *is* the hardening being traded away, and it matters because a
repo-local `gpg.program` is command execution. Setting the variable is an
assertion that the signing config comes from `~/.gitconfig` and not from a
repository an agent cloned.

## Applying it

The checkout is on branch `local/workspace-git-sign`. If the patch is ever
lost — a re-clone, or a pull that resolves the conflict the wrong way:

```bash
cd ~/Projects/hermes-webui
git switch -c local/workspace-git-sign
git apply ~/Projects/batesste-homesetup/hermes/webui/workspace-git-sign.patch
systemctl --user restart hermes-webui
```

Verify by committing something from Hermex and checking the result on the
host — this is the only test that exercises the whole path:

```bash
git -C ~/.hermes/workspace/kernel-watch log --show-signature -1
```

An unsigned commit means the patch is not applied or the variable is not
reaching the service. A commit that hangs until git's 60 s timeout means
gpg-agent has no cached passphrase: `pinentry-curses` cannot prompt a
service with no terminal. The cache TTLs in the dotfiles' `gpg` package
exist for that, and one interactive sign per boot primes them.

## Updating

Updated 2026-09-17, from 3593 commits behind to `origin/master`. An earlier
version of this section called that gap tolerable because "the box works
either way". It was not: the WebUI reads its Python straight from this
checkout, so being behind is not a cosmetic version number, it is the
running code. The clipboard-paste path Hermex needs shipped upstream during
that gap and was simply absent here.

Update by rebasing the one patch, never by merging:

```bash
sqlite3 ~/.hermes/state.db ".backup '$HOME/.hermes/backups/state-preupgrade-$(date +%F).db'"
git -C ~/Projects/hermes-webui checkout master
git -C ~/Projects/hermes-webui merge --ff-only origin/master
git -C ~/Projects/hermes-webui rebase -S origin/master local/workspace-git-sign
systemctl --user restart hermes-webui
```

Three things that are not optional:

- **`-S` on the rebase.** A plain rebase rewrites the commit and drops its
  GPG signature. Check with `git log --show-signature -1`; it must print `G`.
- **`sqlite3 .backup`, not `cp`.** `~/.hermes/state.db` is 68 MB in WAL mode
  with a live multi-megabyte `-wal`; copying the file alone copies a torn
  database. Session history itself is JSON sidecars under
  `~/.hermes/webui/sessions/` and survives independently.
- **Prime gpg-agent first**, or the signing rebase hangs the same way a
  Hermex commit does, for the same reason.

Do not install this from PyPI. The `hermes-webui` package there is a
different, unrelated project (version 0.1.0, one release, no project URLs);
`pip install hermes-webui` installs an unknown package. pipx is also the
wrong tool even from this source: `bootstrap.py` has to find an interpreter
that can import **both** the WebUI's dependencies and Hermes Agent, and a
pipx-isolated venv has only the former. The service would come up green and
then fail every chat turn with "AIAgent not available". Today bootstrap
re-execs into `~/.hermes/hermes-agent/venv/bin/python`, which has both.

## Upstream

Not submitted. The shape above is deliberately upstreamable: opt-in, default
unchanged, one env var alongside the
`HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE` it already has. Now that the
checkout is current, that is a rebase away from being a real pull request.
