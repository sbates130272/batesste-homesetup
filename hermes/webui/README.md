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

## Upstream

Not submitted. The checkout is thousands of commits behind
`nesquena/hermes-webui` and carries no other local change, so the useful
thing to do before proposing this is to update it — and the box works
either way. If that ever happens, the shape above is deliberately
upstreamable: opt-in, default unchanged, one env var alongside the
`HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE` it already has.
