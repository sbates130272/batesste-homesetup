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
means **every commit made from the WebUI's Git panel is unsigned**, with no
warning and no way to ask for otherwise — against a standing rule here that
commits are signed.

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

### What it covers, and what it does not

Only the Git panel. Earlier versions of this page, and the unit's own
comments, said the patch was what made "the commits Hermes makes" signed.
It is narrower than that:

- A `git commit` the **agent** runs through its terminal tool never goes
  near `workspace_git.py`. It reads `~/.gitconfig` like any other shell and
  was never affected by the override, with or without the patch.
- The repositories the WebUI works in are under
  `~/.hermes/webui/workspace` (`HERMES_WEBUI_DEFAULT_WORKSPACE`), not
  `~/.hermes/workspace`.
- **Hermex does not come through here at all** once it is pointed at the
  dashboard, and the dashboard's own commit route is unsigned. See
  [Signing](../README.md#signing-and-where-it-does-not-happen).

## Applying it

The checkout is on branch `local/workspace-git-sign`. If the patch is ever
lost — a re-clone, or a pull that resolves the conflict the wrong way:

```bash
cd ~/Projects/hermes-webui
git switch -c local/workspace-git-sign
git apply ~/Projects/batesste-homesetup/hermes/webui/workspace-git-sign.patch
systemctl --user restart hermes-webui
```

Verify by committing something from the WebUI's Git panel and checking the
result on the host — this is the only test that exercises the whole path.
Use whichever repository under the WebUI's workspace the commit went into:

```bash
git -C ~/.hermes/webui/workspace/<repo> log --format='%h %G? %s' -1   # G is signed, N is not
```

An unsigned commit means the patch is not applied or the variable is not
reaching the service. A commit that hangs until git's 60 s timeout means
gpg-agent has no cached passphrase: `pinentry-curses` cannot prompt a
service with no terminal. The cache TTLs in the dotfiles' `gpg` package
exist for that, and one interactive sign per boot primes them.

## Updating

Last updated 2026-11-19, from 5145 commits behind to `origin/master` (one
commit past `exp-v0.52.718`), two months after the previous update on
2026-09-17 had
closed a 3593-commit gap. An earlier version of this section called that
kind of gap tolerable because "the box works either way". It was not: the
WebUI reads its Python straight from this checkout, so being behind is not
a cosmetic version number, it is the running code. The clipboard-paste
path Hermes needs shipped upstream during the first gap and was simply
absent here.

The November rebase was the first to conflict. Upstream moved the Git
environment scrub list out of `api/workspace_git.py` into a shared helper
(`clean_git_env` in `api/subprocess_utils.py`), and the patch's context
still carried the old list. The resolution is to keep upstream's side and
re-add the one line the patch owns there, `WORKSPACE_GIT_SIGN_ENV`. The
saved patch here was regenerated afterwards with
`git format-patch -1 --stdout local/workspace-git-sign`; do that after any
rebase that needed hand-editing, or the file stops applying.

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
- **`sqlite3 .backup`, not `cp`.** `~/.hermes/state.db` is 258 MB in WAL mode
  with a live multi-megabyte `-wal`; copying the file alone copies a torn
  database. Session history itself is JSON sidecars under
  `~/.hermes/webui/sessions/` and survives independently.
- **Prime gpg-agent first**, or the signing rebase hangs the same way a
  Hermes commit does, for the same reason.

Do not install this from PyPI. The `hermes-webui` package there is a
different, unrelated project (version 0.1.0, one release, no project URLs);
`pip install hermes-webui` installs an unknown package. pipx is also the
wrong tool even from this source: `bootstrap.py` has to find an interpreter
that can import **both** the WebUI's dependencies and Hermes Agent, and a
pipx-isolated venv has only the former. The service would come up green and
then fail every chat turn with "AIAgent not available". Before the Hermes
0.21.4 → 0.23.2 update here, bootstrap re-executed into
`~/.hermes/hermes-agent/venv/bin/python`, which had both. It now lands on
Hermes' own managed interpreter, `~/.hermes/tools/python-3.14.x…/`, with
the agent checkout put on
`sys.path` — check with `readlink /proc/$(systemctl --user show
hermes-webui -p MainPID --value)/exe` rather than trusting either sentence.

## Authentication

Upstream ships with no login. Its README calls `tailscale serve` the
preferred remote path on a single-operator tailnet, but its own Serve
recipe (`docs/remote-access.md`) sets a password first, and tells
deployments behind a same-host proxy to set
`HERMES_WEBUI_TRUST_FORWARDED_FOR=1`. Neither was done here, which leaves
one sharp edge. With auth off, the WebUI admits every request and reserves
only the embedded terminal — a PTY shell as the service user — and the
first-run setup routes for callers it considers local, judged by the
socket peer (`_onboarding_request_is_local` in `api/routes.py`). Everything
`tailscale serve` relays arrives from `127.0.0.1`. So every device on the
tailnet is "local", and the gate that was meant to stop a remote shell
does not.

A password closes it. There are two places to put one and only one is
right for this box:

- `HERMES_WEBUI_PASSWORD` is the plaintext, in the environment. Here that
  means `~/.config/environment.d/50-hermes.conf`, which is mode 0664,
  shielded only by the home directory's 0750, and a tracked file in the
  dotfiles. No.
- `password_hash` in `~/.hermes/webui/settings.json` is PBKDF2 and is what
  the Settings panel writes. Use this.

From a browser already on the WebUI: Settings, set a password. It takes
effect at once. From the host:

```bash
cd ~/Projects/hermes-webui
~/.hermes/hermes-agent/venv/bin/python -B -c "import getpass; from api.config import save_settings; save_settings({'_set_password': getpass.getpass('New WebUI password: ')}); print('saved')"
systemctl --user restart hermes-webui    # the running process caches the hash
curl --noproxy '*' -s http://127.0.0.1:8787/api/auth/status   # auth_enabled: true
```

The environment variable outranks the file, so never set both. Every
client has to sign in again afterwards, including a phone holding this
server as a legacy Hermex entry and any installed PWA.

Not done, deliberately: `HERMES_WEBUI_TRUST_FORWARDED_FOR=1`, which would
make the gate judge the forwarded client address instead of the loopback
peer. It narrows the terminal and leaves chat, which can run commands
through the agent, exactly as open as before.

## Upstream

Not submitted. The shape above is deliberately upstreamable: opt-in, default
unchanged, one env var alongside the
`HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE` it already has. Now that the
checkout is current, that is a rebase away from being a real pull request.
