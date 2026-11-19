# hermes

The [Hermes Agent](https://github.com/NousResearch/hermes-agent) running on
`snoc-beelink`, wired to the Lemonade server on `snoc-strix` for all
inference. Nothing in this agent's hot path leaves the tailnet.

Hermes owns its own installation — the installer creates `~/.hermes`,
`hermes update` rewrites `config.yaml`, and it generates its own systemd
units. So this folder is not a copy of the install. It holds the handful
of decisions that would otherwise be lost on the next update:

| File | What it pins |
| --- | --- |
| [`models.yaml`](./models.yaml) | Which models serve which role, and why |
| [`mcp.yaml`](./mcp.yaml) | The whole set of MCP servers, and their credential references |
| [`approvals.yaml`](./approvals.yaml) | The whole permanent approval allowlist |
| [`voice.yaml`](./voice.yaml) | Which STT and TTS providers, and why not the obvious one |
| [`apply-model-config.py`](./apply-model-config.py) | Merges those into `~/.hermes/config.yaml` and any profiles |
| [`sync-secrets.sh`](./sync-secrets.sh) | Projects `LEMONADE_API_KEY` and the GitHub PAT from the dotfiles into `~/.hermes/.env` |
| [`cua/`](./cua/) | The containerised desktop the agent drives, and its config block |
| [`webui/`](./webui/) | The one local patch `~/Projects/hermes-webui` carries |
| [`systemd/user/`](./systemd/user/) | The dashboard's loopback bind, and the WebUI unit |
| [`scripts/`](./scripts/) | The health checks the agent runs on a schedule |
| [`deploy.sh`](./deploy.sh) | Re-asserts all of the above, idempotently |

```bash
./deploy.sh --dry-run   # show what would change
./deploy.sh             # apply, restart, verify
```

Run it after `hermes update`, after a Lemonade key rotation, and after
editing `models.yaml` or `mcp.yaml`.

## MCP servers

`mcp.yaml` is the source of truth for the entire `mcp_servers:` map, and
`apply-model-config.py` **replaces** that key rather than merging into it.
That asymmetry is deliberate: a merge can only ever add a server, which is
why two servers that had never once started survived every apply until
September 2026. Deleting a server here deletes it there.

| Server | Transport | Tools |
| --- | --- | --- |
| `github` | GitHub's hosted endpoint over HTTPS | 8: search, file reads, issue and PR read/write |
| `firefly` | local script, its own venv | 8: Firefly reads, Google Drive, Apple Calendar |
| `lemonade` | Lemonade on snoc-strix, over the tailnet | all of them, no include list |

Credentials are `${VAR}` references resolved from `~/.hermes/.env` at load
time, never inline. An unset variable keeps the literal placeholder and
fails as an auth error, which is louder than running unauthenticated.

`firefly` runs out of its own venv under `~/.hermes/workspace/mcp/`, not
the Hermes venv it used to share. A `hermes update` that moved `mcp` to
2.0 broke it at import — sharing a venv with Hermes makes Hermes'
dependency churn this server's problem. `create_calendar_event` is its
only write, and it is refused without an explicit confirmation argument
— the same rule the `apple-calendar` skill states, so it is guarded in
two places.

**No MCP server here may depend on Node.** The old reason for this rule
— there is no Node on this box — stopped being true on 2026-09-21, when
the WhatsApp bridge forced an install (see [The WhatsApp
bridge](#the-whatsapp-bridge)). The rule stays anyway, on the evidence
that produced it: both retired servers were `command: npx`, and Hermes
parked them at every startup for months without ever failing loudly —
`hermes mcp list` reported them `✓ enabled` throughout, because that
column reflects the config, not a connection. `hermes mcp test <name>` is
the one that actually connects.

Node's arrival makes that failure mode *harder* to spot, not easier: an
`npx` server will now get far enough to look alive. Nothing here has been
reintroduced on that basis.

Note that testing from an interactive shell fails on TLS
(`CERTIFICATE_VERIFY_FAILED`) for any non-tailnet endpoint, because
ZScaler is exported there and intercepts. The systemd units start clean,
so this is a terminal-only artifact — clear the proxy variables to
reproduce what the gateway actually does:

```bash
HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= hermes mcp test github
```

## Approvals

`approvals.yaml` owns `command_allowlist` the same way `mcp.yaml` owns
`mcp_servers` — it is a list, `deep_merge` replaces lists, so the file is
the whole key and deleting an entry here deletes it there.

**An "always" answered at a prompt is now temporary.** It writes the key
into `~/.hermes/config.yaml`, and the next `./deploy.sh` overwrites it.
Add it here as well, or it goes away.

That asymmetry is deliberate and it is the same lesson as the two dead
`npx` MCP servers: `command_allowlist` lives in a file `hermes update`
rewrites, so a grant that only lives there is a grant with an expiry date
nobody wrote down. `cua:click:background` was already in exactly that
state when this file was written.

The bulk of the list is the `computer_use` desktop actions. Hermes gates
every click, keystroke and drag through the same approval path as a
dangerous shell command, and — contrary to what this repo claimed until
September 2026 — cua-driver's `permission_mode` has nothing to do with
it. See [`cua/README.md`](./cua/README.md#permissions) for the two gates
and which one does what.

## Processes and ports

Hermes runs as **user** units under a lingering session (`Linger=yes` for
`batesste`), not system units. They will not show up in a `systemctl
status` sweep and need `--user` on every command.

| Unit | Scope | Listens on | Reached via |
| --- | --- | --- | --- |
| `hermes-gateway.service` | user | `0.0.0.0:8642` | LAN, bearer key |
| `hermes-dashboard.service` | user | `127.0.0.1:9119` | `tailscale serve :9119` → nginx `:9120`, then the dashboard's own login |
| `hermes-webui.service` | user | `127.0.0.1:8787` | `tailscale serve :8787`, direct — no nginx, and no login until a password is set |
| `batesste-cua-driver` (container) | docker | `127.0.0.1:6080` | noVNC, view-only; the driver itself is `docker exec` only |
| WhatsApp bridge (child of the gateway) | none — spawned process | `127.0.0.1:3020` | the gateway only |

The gateway unit does the messaging-platform work (WhatsApp is the only
platform configured) and also hosts Hermes's own OpenAI-compatible API
server on 8642, enabled by `API_SERVER_*` in `~/.hermes/.env`.

**Telegram was disabled on 2026-09-21** and is no longer in use. There is
no `TELEGRAM_ENABLED` flag — the platform activates purely on a valid
`TELEGRAM_BOT_TOKEN` in `~/.hermes/.env`, so disabling it means
commenting that line out. It is commented rather than deleted, so
re-enabling is removing one `#` and restarting the gateway.
`TELEGRAM_ALLOWED_USERS` was left in place for the same reason.

What `ExecStart` names is not what runs. The dashboard unit names
`~/.hermes/hermes-agent/venv/bin/python` and the WebUI `/usr/bin/python3`;
both re-execute under Hermes' own managed interpreter,
`~/.hermes/tools/python-3.14.x…/`. The gateway unit names a launcher,
`~/.hermes/hermes-agent/.hermes/bin/hermes`, that starts on that
interpreter directly, and `~/.local/bin/hermes` — the command line — goes
through the same launcher. Upstream has worked this way since 0.22; it
arrived here with the 0.21.4 → 0.23.2 update. The venv is still there,
still Python 3.11, and now useful for one thing: a one-off script that
imports Hermes modules has to be run with `venv/bin/python` from the
checkout directory, because the managed interpreter invoked by hand does
not have the dependencies on its path.

`hermes-webui` is a **separate project** (`~/Projects/hermes-webui`), not
part of the agent. It imports the agent in-process, which is why it follows
the agent onto the same interpreter. Its unit is the one in
[`systemd/user/`](./systemd/user/) that is a whole unit rather than a
drop-in, because nothing else generates it — it used to be a hand-written
system unit tracked nowhere, and had already drifted from the stray copy
in the project checkout.

It is user-scoped for two reasons that are not tidiness: only a user unit
can reach the login session's gpg-agent, which its Git panel needs to sign
a commit; and only a user unit reads `~/.config/environment.d/`, which is
where its environment lives. That file belongs to the `systemd` package in
the dotfiles, not to this repo — see [`webui/`](./webui/) for the whole
picture, including the one local patch that checkout carries, what that
patch does and does not cover, and the password.

The dashboard's path through nginx is not incidental — see
[Appendix: why nginx is in the path](#appendix-a--the-dashboard-and-port-9119).

## Front ends: which one does what

There are three ways to talk to this agent from a browser or a phone, and
they are not interchangeable. Sessions by origin in `~/.hermes/state.db`
on 2026-11-19: 339 cron, 63 WebUI, 45 CLI, five between kanban, one-shot
and WhatsApp, and two `tui` from June — the label the dashboard's chat
shares with `hermes --tui` in a terminal, so at most two from the
dashboard. None from Hermex.

| | Dashboard (`:9119`) | WebUI (`:8787`) | Hermex on the dashboard |
| --- | --- | --- | --- |
| Chat | the Hermes TUI in a browser terminal | a real chat UI | native iOS |
| Git panel | none | yes | yes |
| A commit made from the UI is signed | — | yes, with the patch | **no** |
| File editor | none | yes | — |
| Login | `dashboard.basic_auth` | its own password | `dashboard.basic_auth` |

The dashboard in a browser is an admin console with a terminal in it. The
richer workspace Hermes ships — Git review, a file tree, a host terminal —
belongs to the Desktop app and to "Webapp" mode, which serves that same
workspace from the gateway. Webapp is not enabled here, its bundle is not
built, and its default port is `127.0.0.1:9120`, **which the nginx shim
already holds**. Move one of them before setting `webapp.enabled`.

So the WebUI stays, for now, for two reasons: it is the only interactive
front end anyone actually uses, and its Git panel is the only commit
button on this box that produces a signed commit.

### Signing, and where it does not happen

Three different code paths make commits, and they do not agree:

- **The agent runs `git commit` itself**, through its terminal tool, from
  any front end. Nothing overrides Git's configuration on that path, both
  units have the session's `HOME` and `XDG_RUNTIME_DIR`, and so
  `~/.gitconfig` signing applies. This does not depend on the WebUI.
- **The WebUI's Git panel**, which signs only because of the
  [local patch](./webui/).
- **The dashboard's commit route**, `POST /api/git/review/commit`, used by
  Hermex's Git screen and by the Desktop and Webapp review panes. It runs
  Git with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` pointed at
  `/dev/null` (`hermes_cli/_subprocess_compat.py`), so the signing
  configuration is never read and the commit comes out unsigned. Confirmed
  on 0.23.2 by calling the function against a scratch repository.

The practical rule: **from Hermex, ask the agent to commit in chat; do not
use the Git screen's commit button.**

Signing is also not as airtight as the patch makes it sound. Five unsigned
commits carrying this user's identity landed in repositories under
`~/.hermes/webui/workspace` between 2026-09-18 and 2026-11-07, after the
patch went in. Which path made them has not been established.

## Connecting Hermex

[Hermex](https://github.com/uzairansaruzi/hermex) is a third-party iOS
client. From 2.0 it talks to the Hermes dashboard directly and treats
hermes-webui as a legacy server type. It does not use the gateway API on
8642 and `API_SERVER_KEY` plays no part.

Everything the server side needs is already in `~/.hermes/config.yaml`:

| Key | What it is |
| --- | --- |
| `dashboard.public_url` | `https://snoc-beelink.fold-leaffish.ts.net:9119` — the exact address the phone uses |
| `dashboard.basic_auth.username` | compared exactly, case-sensitively |
| `dashboard.basic_auth.password_hash` | scrypt; the password itself is stored nowhere |
| `dashboard.basic_auth.secret` | signs sessions; leave it alone |

Setting `public_url` is what turns the login on for a loopback bind, and
it is also what lets the dashboard accept the tailnet hostname
(Appendix A).

In the app, add a server with the `public_url` value exactly: `https`, the
`:9119`, no path. Not the bare hostname — 443 on this host is the Funnel
gateway, a different service, and answers `/api/status` with 404 — and
not `:8787`, which
would add the WebUI as a legacy server. Type the credentials rather than
accepting autofill: several unrelated logins live on this hostname at
other ports.

A failed attempt is recorded in `~/.hermes/logs/dashboard-auth.log` as
`login_failure` with `invalid_credentials`, which does not say which half
was wrong. Ten attempts a minute per client, then `429`.

### Resetting the dashboard password

There is no command for it, and the interactive prompt Hermes offers on
first run never fires under systemd. Generate a hash:

```bash
cd ~/.hermes/hermes-agent
venv/bin/python -B -c "import getpass; from plugins.dashboard_auth.basic import hash_password; print(hash_password(getpass.getpass('New dashboard password: ')))"
```

Put the result in `dashboard.basic_auth.password_hash` with
`hermes config edit`. It needs no quoting in YAML; the `$` signs in it
only matter if it is passed through a double-quoted shell string. Leave
`password` empty. Then:

```bash
systemctl --user restart hermes-dashboard
curl --noproxy '*' -s http://127.0.0.1:9119/api/status   # auth_required: true, auth_providers: ["basic"]
```

The new hash ends every existing dashboard session once the restart loads
it: session keys are derived from it. A restart on its own signs nobody
out while `secret` is set.

## The WhatsApp bridge

WhatsApp runs in **self-chat** mode: there is no second phone number, so
messaging yourself is the interface. Hermes talks to it through a Node
process (`scripts/whatsapp-bridge/bridge.js`, Baileys) that the gateway
spawns as a child. It is not a systemd unit and should not become one —
the adapter already spawns it, health-checks it, adopts an
already-running one, and reclaims its port by sending SIGTERM to any
node process listening on it.
A second supervisor would fight all four. Verified by `kill -9` on the
bridge: the gateway rebuilt it within 45 s unattended.

### It needs Node, and the install has a trap

This is why Node 22 exists on the box at all. Install it from NodeSource,
which is already configured in `/etc/apt/sources.list.d/nodesource.list`:

```bash
sudo apt install -y nodejs     # NOT `apt install npm`
```

**Never `apt install npm` here.** Ubuntu's `npm` (9.2.0, noble/universe)
declares `Conflicts: npm` against the NodeSource package and would drag
in Ubuntu's older `nodejs` alongside it. The NodeSource package already
`Provides: npm`, so the one install covers both.

### Port 3020, because Grafana owns 3000

`bridge.js` defaults to port 3000. **Grafana is already on 3000** — its
own default, serving the dashboards for the whole Prometheus and Loki
stack. The bridge therefore died with `EADDRINUSE` on every single start,
and WhatsApp never once connected, while the QR pairing itself succeeded
and looked fine. The visible symptom was only `✗ whatsapp failed to
connect` plus a bridge that vanished.

The port is moved on the bridge, never on Grafana:

```yaml
platforms:
  whatsapp:
    enabled: true
    extra:
      bridge_port: 3020
```

Any unknown key at the platform level is folded into `extra` by
`PlatformConfig.from_dict`, so `bridge_port:` one level up works too — an
explicit `extra:` wins on a clash.

Grafana was never actually at risk from the bridge's port reclaim:
`_kill_port_process` only signals a process that
`_pid_looks_like_node_bridge` confirms is `node`, and Grafana is a Go
binary. It logs `Not killing PID … process is not a node bridge` and
moves on. That guard is the only
reason a port collision here was merely broken rather than destructive.

### The home channel is not derived

`hermes whatsapp` does not set one, and nothing infers it from the
self-chat number, so `hermes send --to whatsapp` fails with *"No home
channel set"* until it is set by hand. In self-chat mode it is your own
number as a JID:

```bash
hermes config set WHATSAPP_HOME_CHANNEL <number>@s.whatsapp.net
```

Cron delivery reads the same variable (`scheduler_delivery.py`), so a
scheduled job set to `deliver: origin` with no recorded origin lands here.

### Voice notes transcribe locally, on purpose

Everything else here routes to Lemonade on `snoc-strix`, so STT was pointed
there too — `stt.provider: openai` with `STT_OPENAI_BASE_URL` overridden to
`https://snoc-strix.fold-leaffish.ts.net:13305/api/v1`. It never once
worked. The route exists (it answers 500, not 404) but the backend cannot
decode what Hermes uploads:

```
Retrying openai STT after transcoding aud_14a8908b6b9d.ogg to m4a
Voice transcription failed: 500 - {'error': 'failed to read audio data'}
```

WhatsApp voice notes are Opus-in-Ogg. Hermes gets exactly one retry, and
`_transcode_audio_for_stt()` hardcodes its target to 16 kHz mono AAC/m4a —
written for OpenAI's hosted models, which reject Ogg. There is no config
key for the container, so **that retry can never succeed against this
endpoint**, and no amount of tuning `stt.openai` would have helped.

The failure is quiet in the worst way. Transcription failing does not fail
the message: the gateway substitutes

```
[voice message could not be transcribed automatically; the audio is available at ...]
```

and the model answers *that*. You get a reply, it is fluent, and it is
about the existence of an audio file rather than a word you said.

`voice.yaml` therefore pins `stt.provider: local`. faster-whisper decodes
Opus natively, which removes the container negotiation instead of losing
it, and `base` on a 20-second clip is not work the beelink notices. It is
installed lazily on first use, so nothing is resident until a voice note
arrives.

TTS stays on `edge` — no API key, no local model, nothing to rotate. It is
not automatic: replies are text unless the model calls `text_to_speech`, or
the chat is switched with `/voice`, whose modes are `off`, `voice_only` and
`all`. `voice.auto_tts` is the fleet-wide default behind them and is left
`false`.

## Model routing

One Lemonade server (`snoc-strix`, 96 GB VRAM, ROCm llama.cpp) serves
everything. Its binding constraint is `max_loaded_models: 3` — three LLMs
resident at a time, per model category. Naming a fourth model anywhere in
the routing table does not fail; it silently evicts a resident one and
pays a ~40 s cold load on the next call to it. **The entire routing table
is therefore built around naming exactly three LLMs and never a fourth.**

| Role | Model | Why |
| --- | --- | --- |
| Main agent, vision, curator, monitor | `Qwen3.6-35B-A3B-MTP-GGUF` | Fastest measured *and* newest and largest |
| Fallback and delegation | `Qwen3-Coder-30B-A3B-Instruct-GGUF` | Coding-tuned, different lineage from the main model |
| All short side-calls | `Qwen3.5-4B-MTP-GGUF` | Small and vision-capable; keeps titles and triage off the main model's queue |
| Speech-to-text | `Whisper-Large-v3-Turbo` | Transcription is a separate Lemonade slot category, so it costs none of the three |
| Text-to-speech | Edge (not Lemonade) | `kokoro-v1` fails to load server-side |

### The evidence

Six candidates, each measured cold-loaded on `snoc-strix`: a tool-calling
prompt against a two-argument function schema, then a 400-token
generation. All six emitted a well-formed tool call with correct
arguments, so correctness did not separate them and throughput did.

| Model | tok/s | Tool call | Load |
| --- | --- | --- | --- |
| `Qwen3.6-35B-A3B-MTP-GGUF` | **74.4** | ✓ | 9.8 s |
| `Qwen3-Coder-30B-A3B-Instruct-GGUF` | 72.3 | ✓ | 5.9 s |
| `gpt-oss-20b-mxfp4-GGUF` | 67.7 | ✓ | 6.9 s |
| `Qwen3.5-4B-MTP-GGUF` | 85.5 | ✓ | 4.6 s |
| `Qwen3.5-4B-GGUF` (no MTP) | 56.9 | ✓ | 5.0 s |
| `Qwen3.6-35B-A3B-GGUF` (no MTP) | 51.6 | ✓ | 41.5 s |
| `Qwen3.6-27B-MTP-GGUF` | 23.1 | ✓ | 6.8 s |

The headline is MTP, twice. The 35B pair and the 4B pair are each the
same weights with and without multi-token speculative decoding, and it
is worth +44 % and +50 % respectively. That is what makes the largest
model also the fastest one, and it is why the previous default
(`gpt-oss-20b`) is no longer worth the tradeoff. The 27B is a dense
model rather than A3B MoE — 27 B active parameters against 3 B — which
is the whole of its 3× disadvantage.

### Reasoning is off for the short side-calls

Every Qwen3 model here is a reasoning model and will think before
answering, including when the question is "write a six-word title for
this conversation". Measured on `Qwen3.5-4B-MTP-GGUF` with a real
title-generation prompt:

| Request | Time | Tokens | Answer |
| --- | --- | --- | --- |
| default | 2.84 s | 300 (capped) | *empty — still thinking* |
| `chat_template_kwargs: {enable_thinking: false}` | 0.27 s | 7 | "Restarting Failed Systemd Unit" |
| `reasoning_effort: "none"` | 0.20 s | 7 | "Restarting Failed Systemd Unit" |
| `/no_think` in the prompt | 2.98 s | 300 | *empty — the suffix does nothing* |

So the default is not merely slow, it returns nothing at all: the model
is still mid-thought when the token cap hits. `models.yaml` sets
`auxiliary.<task>.extra_body.chat_template_kwargs.enable_thinking:
false` on the tasks that are lookups or formatting (titles, approvals,
MCP, skills hub, TTS tags, profile describer, session search) and leaves
it on for the ones that are judgement (compression, triage, kanban
decomposition, vision, curator, monitor).

Two wire forms work and one does not. Hermes has its own
`auxiliary.<task>.reasoning_effort` key which folds into
`extra_body.reasoning = {"enabled": false}` — an OpenAI-shaped field
that Lemonade's llama.cpp backend accepts and ignores. The form that
actually reaches the chat template is `chat_template_kwargs`, and
`extra_body` is forwarded verbatim, so that is what is configured here.

### Why not an OMNI model

Lemonade serves `LMX-Omni-52B-Halo` and `LMX-Omni-5.5B-Lite`, and
neither is a distinct model. Both are *composites*: a bundle id whose
`components` list names other served models, loaded eagerly and
all-or-nothing.

| Bundle | Components |
| --- | --- |
| `LMX-Omni-52B-Halo` | `Qwen3.6-35B-A3B-MTP-GGUF`, `Flux-2-Klein-9B-GGUF`, `Whisper-Large-v3-Turbo`, `kokoro-v1` |
| `LMX-Omni-5.5B-Lite` | `Qwen3.5-4B-MTP-GGUF`, `SD-Turbo`, `Whisper-Tiny`, `kokoro-v1` |

The LLM inside the large bundle is *exactly* the model already routed
to, and its STT component is *exactly* the STT already routed to — so
the bundle offers no better inference, only image generation on the
side. And neither bundle loads: both fail with `koko failed to start or
become ready`, because `kokoro-v1` is the broken model and the load is
all-or-nothing. A bundle also advertises only the `chat` label, where
the components carry `chat`, `vision`, `tool-calling` and `mtp`.

The one capability a bundle would genuinely add is image generation, and
that is reachable without one: Lemonade exposes
`POST /api/v1/images/generations`, images are their own slot category
(so they cost none of the three LLM slots), and Hermes' `deepinfra`
image-gen plugin is the one whose `base_url` and model id are both
user-configurable. Not enabled — nothing here asks for image
generation — but it is a config edit, not a bundle.

### Things deliberately left unset

- **`model.context_length`.** Lemonade reports context on `/v1/models`;
  hardcoding it creates a second value to keep in sync with the server's
  `ctx_size` and Hermes rejects a provider whose advertised context is
  below `agent.minimum_context_length`.
- **`model.base_url` / `model.api_key`.** The named custom provider
  (`custom:lemonade`) supplies both. `apply-model-config.py` actively
  deletes these if an older config left them behind — a stale second copy
  of an endpoint or a key is exactly the failure mode below.

### Profiles — there is only `default`

Profiles under `~/.hermes/profiles/` are separate agents with their own
`config.yaml`, inheriting **nothing** from the main config. This
deployment has none: `assistant`, `finance`, `ops`, `orchestrator` and
`research` were created in June 2026 and deleted on 2026-09-15, because
none had ever been used — zero sessions and zero messages in every
`state.db`, empty `cron/` directories, and `memories/` holding
byte-identical copies of the same two seed files. The ~8 MB each
occupied was the bundled skills cache, not user data.

What they did cost was real: five *"shares its telegram credential with
default"* warnings on every `hermes profile list`, and a fourth model.
Left alone each one pinned `DeepSeek-Qwen3-8B-GGUF`, so every profile
invocation evicted one of the three resident models and paid a ~40 s
cold load. `profile_overrides` in `models.yaml` is what held them to the
same three, and it is kept (empty) rather than deleted — it is the thing
that stops a *new* profile from silently becoming that fourth model.

Two config keys name a profile, and both fail soft in ways worth
knowing, which is why `models.yaml` sets each to `default` explicitly
rather than trusting the fallback:

| Key | If it names a missing profile |
| --- | --- |
| `kanban.orchestrator_profile` | Silently falls back to the active profile |
| `kanban.default_assignee` | Resolves to `None`; tasks are left unassigned |

A *task* assigned to a missing profile is worse than either: it lands in
`skipped_nonspawnable` and is never dispatched, with no error raised
anywhere. One task (`t_1f0802de`, a June smoke test) was assigned to
`ops`; it was reassigned to `default` before the deletion, and completed
on its next run.

To add a profile back: `hermes profile create <name>`, then add it to
`profile_overrides` in `models.yaml` naming one of the three resident
models, and re-run `./deploy.sh`. Note that `hermes profile delete` is
an unrecoverable `rm -rf` — it makes no backup — though it does clean up
the `~/.local/bin/<name>` alias and any per-profile systemd unit. The
`default` profile is special-cased and cannot be deleted.

## Credentials

`LEMONADE_API_KEY` exists in three places, and all three must agree:

```
snoc-strix (lemond)  →  ~/.secrets.env (git-crypt, stow)  →  ~/.hermes/.env
     issuer                source of truth                    what Hermes reads
```

`sync-secrets.sh` copies **only** that variable (plus the two STT
variables derived from it and a `NO_PROXY` exemption) and
`GH_TOKEN_SBATES130272`, which lands as `GITHUB_PERSONAL_ACCESS_TOKEN`
for the `github` MCP server. The units deliberately do **not** get
`EnvironmentFile=-%h/.secrets.env`: that file holds seventeen
credentials, and Hermes has a local shell tool.

Only the personal GitHub token is projected. `GH_TOKEN_STEBATES_AMDENG`
is AMD's and stays out of the agent's reach — `sbates130272` is the only
account Hermes should ever act as.

The script verifies both credentials against their servers *before*
writing either, and prints only a length and a SHA-256 prefix — never a
key. A sync that faithfully copies a dead credential is worse than no
sync, because it looks like it worked.

> **Rotation runbook.** Rotate on `snoc-strix` (or on GitHub), update
> `~/.secrets.env`, commit the dotfiles, then run `./deploy.sh` here.
> Skipping the last step is what caused a twelve-day outage in September
> 2026: every model call returned `HTTP 401` and every scheduled job
> failed silently into Telegram. The GitHub PAT failed the same way and
> was never noticed at all, because nothing on that path had a health
> check — it was a hand-placed copy that had been revoked.

### The corporate proxy

`ZScaler` is exported into interactive shells and intercepts tailnet
traffic, answering with `500 Unable to connect` from `tinyproxy`. The
systemd units start clean, but anything run from a terminal needs an
exemption; the sync script writes one into `~/.hermes/.env`, which
`hermes` reads. Ad-hoc commands need `curl --noproxy '*'` or
`NO_PROXY='*'`.

## Health checks

[`scripts/lemonade_health.sh`](./scripts/lemonade_health.sh) checks
reachability, one inference probe, and the GPU host over SSH. It reads
the list of models it expects out of `~/.hermes/config.yaml` rather than
carrying its own copy, so it cannot drift from the routing table.

[`scripts/service_health.sh`](./scripts/service_health.sh) wraps that
with the containers, the system units, the Hermes user units, and the
computer-use driver. It treats a high restart count as a failure, because
a restart-looping unit reports `active` on every sample (Appendix B).

```bash
./scripts/service_health.sh        # prints HEARTBEAT_OK on success
systemctl --user status hermes-gateway
journalctl --user -u hermes-gateway -n 50
hermes doctor                      # Hermes's own diagnostics
hermes -z 'Reply with exactly: ROUTING OK'   # end-to-end, one turn
```

`deploy.sh` installs both scripts into `~/.hermes/workspace/scripts/`,
where the agent and its cron jobs call them by absolute path.

## Computer use

Hermes' built-in `computer_use` toolset drives a real GUI — screenshots,
mouse, keyboard, and an accessibility tree it can read elements out of.
This box is headless, so [`cua/`](./cua/) supplies the desktop as a
container and a host shim carries MCP stdio into it with `docker exec`.
No agent-side code was needed; the toolset already speaks to `cua-driver`.

```bash
hermes computer-use doctor                  # both capabilities must say ok
hermes -t computer_use -z 'Take a screenshot and tell me what you see'
http://127.0.0.1:6080/vnc.html              # watch it, view-only
```

Actions are approved individually (`permission_mode: standard`), and
unattended contexts refuse them outright rather than auto-approving — a
computer-use cron job will not work without a deliberate change. See
[`cua/README.md`](./cua/README.md) for the transport, the manifest
rewrite, and the accessibility-bus failure mode that looks like a
merely-incompetent agent.

## Scheduled jobs

Three jobs run out of Hermes's own scheduler (`hermes cron list`), not
crontab: a daily Homelan check, a weekly memory-hygiene pass, and a
monthly Firefly III report. This README claimed ten until 2026-09-21;
the other seven are gone.

All three are `deliver: origin` with **no origin recorded**, so they fall
through to the platform home channel. That used to be a Telegram group.
Disabling Telegram did not break them — none was bound to a Telegram
chat, and `last_delivery_error` was null on all three — but it does mean
they now land in WhatsApp self-chat, which is why
`WHATSAPP_HOME_CHANNEL` has to be set.

After changing the default model, run `hermes cron resnap --all` so
unpinned jobs adopt it. Two jobs are pinned explicitly; both are pinned
to a model in the resident three.

## Backups

`hermes backup --output <file>.zip` writes a full agent backup (sessions,
state DBs, config, workspace). It was ~180 MB in September 2026 and 908 MB
on 2026-11-19, and it reports a couple of dozen files it "could not add":
Chrome cache under `workspace/cron/chrome-profile/` with timestamps before
1980, which ZIP cannot represent. Nothing of value. The weekly off-site copy is
[`../backup/batesste-hermes-s3-backup.*`](../backup), a user timer that
is **currently disabled** — its last run failed with
`InvalidAccessKeyId`, so the AWS credentials in `~/.secrets.env` need
attention before it is re-enabled.

Take one before any `hermes update`:

```bash
hermes backup --output /var/tmp/hermes-pre-upgrade-$(date +%F).zip
```

## Updating

Last done 2026-11-19, v0.21.4 → v0.23.2, config format v45 → v54. In order:

```bash
hermes backup --output /var/tmp/hermes-pre-upgrade-$(date +%F).zip
hermes update --plan      # read-only: what is running and how it restarts
hermes update --yes
./deploy.sh --dry-run     # what the update undid, if anything
```

Three things the last one taught:

- **`deploy.sh --dry-run` is the audit, not a formality.** That update
  left the model routing, the units and the credentials alone. The only
  thing the dry run offered to change was `command_allowlist` — nine
  approvals answered "always" since the previous capture, which a real
  run would have deleted. They are in [`approvals.yaml`](./approvals.yaml)
  now. Read the diff before applying it.
- **The uncommitted local change in the checkout survives.** `hermes
  update` stashes it and re-applies it on top (`agent/prompt_builder.py`
  at the time of writing). It says so in a few lines of the update
  output, kept in `~/.hermes/logs/update.log`, and nowhere else.
- **The gateway takes about half a minute to listen again.** The unit is
  `active` well before 8642 and the WhatsApp bridge on 3020 come back, so
  a port check straight after the restart reads as a failure.

The WebUI is updated separately — see [`webui/`](./webui/#updating).

## Known gaps

- **`hermes-webui` has no login until a password is set.** With auth off
  it admits every request and keeps only the embedded terminal — a shell
  as this user — and first-run setup for local callers. Every request
  `tailscale serve` relays
  arrives from loopback, so every tailnet peer counts as local. See
  [`webui/`](./webui/#authentication) for the one command that closes it.
  Delete this entry once `/api/auth/status` reports `auth_enabled: true`.
- **A commit made from Hermex's Git screen is unsigned**, as is one from
  the Desktop or Webapp review pane. See
  [Signing](#signing-and-where-it-does-not-happen). Untested alternative
  to avoiding the button: `commit.gpgsign` and `user.signingkey` in each
  repository's own `.git/config`, which that route does still read.
- **Hermex has never completed a login here.** The path is checked as far
  as it can be without credentials — status, the login page and the
  WebSocket handshake all answer through the shim — but the token
  exchange and chat over WebSocket have not been exercised.
- **`hermes-gateway` binds `0.0.0.0:8642`.** The API server is
  key-authenticated, but it is the same exposure shape as Appendix A and
  it is not behind `tailscale serve`. Fix is `API_SERVER_HOST=127.0.0.1`
  plus a serve entry — deferred because the LAN consumers are unknown.
- **The GitHub PAT is a classic token, not a fine-grained one.**
  `GH_TOKEN_SBATES130272` carries `admin:org`, `delete_repo`, `workflow`
  and more, and Hermes now holds it. `mcp.yaml` limits the *tools* to
  eight, but the token itself would permit far more if reached another
  way — and Hermes has a local shell tool. A fine-grained PAT scoped to
  the reads and issue writes actually listed would be the tighter answer;
  it expires 2027-09-02, which is the natural moment to swap it.
- **No health check covers the MCP servers.** `service_health.sh` checks
  units, containers and Lemonade, so all three MCP servers could sit
  broken for months without anything saying so — and all three did.
  `hermes mcp list` is no help: it reports the config, not a connection.
  A `hermes mcp test` sweep belongs in the six-hourly check.
- **TTS is not local.** Nothing on the Hermes side blocks it: Lemonade
  serves `POST /api/v1/audio/speech`, and Hermes' built-in `openai` TTS
  provider takes a configurable `tts.openai.base_url` on both the batch
  and streaming paths. The blocker is that Lemonade's only TTS model is
  `kokoro-v1` and loading it fails with `koko failed to start or become
  ready`. Revisit server-side; the change here is two lines in
  `models.yaml`.
- **Audio never reaches a model as audio.** Hermes builds no
  `input_audio` content parts anywhere; every voice path runs STT first
  and injects a plain-text transcript. So a model's native audio-in
  unlocks nothing Hermes can currently drive.

---

## Appendix A — the dashboard and port 9119

The stock unit passes `--host 0.0.0.0`, which claimed 9119 on the LAN
address and the tailnet address as well as loopback. tailscaled needs
`100.118.22.104:9119` for its own `serve :9119` entry, lost the race on
every boot, and retried roughly every 20 s, forever:

```
tailscaled: localListener failed to listen on 100.118.22.104:9119,
            backing off: bind: address already in use
```

It did manage to claim the IPv6 tailnet address, so the serve entry
half-worked and the breakage was easy to miss. The `0.0.0.0` bind was
also a real exposure: no auth provider was configured at the time, so
the dashboard was reachable **unauthenticated** from any LAN host. (One
is now — `dashboard.basic_auth`, see
[Connecting Hermex](#connecting-hermex) — and current Hermes refuses a
non-loopback bind without one; the `--insecure` still on the unit's
command line is accepted and ignored.)

[`systemd/user/hermes-dashboard.service.d/override.conf`](./systemd/user/hermes-dashboard.service.d/override.conf)
moves it to `--host 127.0.0.1`, which is also what upstream recommends.
It is a drop-in rather than an edit so that a reinstall cannot silently
undo it.

Moving to loopback tripped a second guard. The dashboard enforces a
DNS-rebinding defence (GHSA-ppp5-vxwm-4cf7, `_is_accepted_host`, now in
`hermes_cli/web_server_boundary.py`): on a loopback bind it accepted only
loopback `Host` values, and the WebSocket handshake applies the same test
to `Origin`. A `0.0.0.0` bind disables the guard entirely, which is the
only reason the tailnet path used to work. `tailscale serve` forwards the
tailnet hostname verbatim, so pointing it straight at 9119 was refused.

There was no allowed-hosts setting then, so an nginx vhost on
`127.0.0.1:9120` normalises both headers back to loopback and serve
points at that:

```bash
tailscale serve --bg --https 9119 http://127.0.0.1:9120
```

See [nginx/sites-available/hermes-dashboard](../nginx/sites-available/hermes-dashboard).
This does re-permit what the guard blocks. The trade is deliberate:
the guard exists to stop a malicious website rebinding DNS in a victim's
browser, whereas everything reaching that listener has already passed
Tailscale's TLS and tailnet ACLs. The dashboard's login sits behind it,
so tailnet membership is the outer gate rather than the only one — but
**the shim must stay bound to loopback** regardless.

### What the update to 0.23.2 changed

There is an allowed-hosts setting now, in effect: the guard also accepts
the hostname of `dashboard.public_url`. Upstream has had that since
0.21.6; it reached this box with the 0.21.4 → 0.23.2 update. With that
set, 9119 answers the
tailnet `Host` directly, with or without the port, and refuses anything
else:

```
{"detail":"Invalid Host header. Dashboard requests must use the bound
  hostname or the configured public hostname."}
```

So the `Host` and `Origin` rewrite is no longer what makes the path work,
and serve could point straight at 9119. The shim is kept for a different
job. The dashboard hardens its cookies only when it believes the request
arrived over HTTPS — `__Host-` names with `Secure`, against bare names
without — and it believes whatever `X-Forwarded-Proto` a loopback proxy
tells it. The vhost used to pass `$scheme`, which on a plain-HTTP
listener is `http`, so sessions that were TLS end to end from the
browser's side got the weak cookies. It now sends `https` outright.
Removing the shim would hand that decision to whatever `tailscale serve`
forwards, which nobody has captured.

Changing the header renames the cookies, so it signs every browser out
once.

## Appendix B — a duplicate system unit that restarted 140,989 times

`/etc/systemd/system/hermes.service` ran `hermes gateway` as a *system*
unit, duplicating the user-level `hermes-gateway.service`. The user unit
always won the race, so the system one exited immediately every time:

```
❌ Gateway already running (PID 1469).
```

With `Restart=always` and `RestartSec=10` it had looped **140,989**
times, continuously since the 16 Aug boot, without ever serving traffic.
It was disabled rather than deleted:

```bash
sudo systemctl disable --now hermes.service
```

It should not be re-enabled while the user units are in place; `Linger=yes`
already covers starting Hermes at boot. `service_health.sh` now fails on
a high restart count so that this shape of problem is visible.
