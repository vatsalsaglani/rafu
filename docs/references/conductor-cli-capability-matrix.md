# Ensemble CLI capability matrix — modes, models, effort, sessions

- **Applies to:** every Ensemble adapter. This is the cross-CLI comparison;
  the per-family notes
  ([claude-codex](conductor-adapter-claude-codex.md),
  [opencode-cline-kimi](conductor-adapter-opencode-cline-kimi.md),
  [gemini-cursor](conductor-adapter-gemini-cursor.md))
  stay authoritative for probe transcripts and error taxonomy.
- **Last verified:** 2026-07-27 against the CLIs installed on this Mac.
  Anything marked *unverified* was NOT re-probed and comes from the owning
  phase's recorded shape. Claude Code, Codex, OpenCode, and Cline were probed
  on 2026-07-26; Cursor's installed, authenticated runtime was probed on
  2026-07-27. Gemini's installed version was confirmed but its Ensemble
  runtime remains unverified; Kimi remains absent and unverified.

## Verified versions

| CLI | Version | Where it resolved |
|---|---|---|
| Claude Code | 2.1.220 | `~/.local/bin/claude` |
| Codex | 0.145.0 | `~/.local/bin/codex` — **wins over** the 0.146.0-alpha.3.1 bundled at `/Applications/ChatGPT.app/Contents/Resources/codex`, because discovery runs `which` first and `~/.local/bin` is on the search path. Both are kept as candidates so Codex still resolves for a ChatGPT.app-only install. |
| OpenCode | 1.18.4 | `~/.opencode/bin/opencode` |
| Cline | 3.0.46 | `~/.nvm/versions/node/v22.0.0/bin/cline` (nvm — **not** on a GUI app's `PATH`; see [gui-app-path-and-cli-discovery.md](gui-app-path-and-cli-discovery.md)) |
| Kimi CLI | — | not installed (unverified) |
| Gemini CLI | 0.52.0 | `~/.nvm/versions/node/v22.0.0/bin/gemini`; version/discovery verified, Ensemble runtime unverified |
| Cursor CLI | 2026.07.23-e383d2b | `~/.local/bin/cursor-agent`; `~/.local/bin/agent` resolves to the same binary. Installed and authenticated. |

## The matrix

`RW` = what Rafu wires today. `—` = the CLI has no such surface.
**Bold** = the CLI supports it but **Rafu does not use it yet**.

| Capability | Claude Code | Codex | OpenCode | Cline | Cursor CLI |
|---|---|---|---|---|---|
| Headless prompt | `-p/--print` `RW` | `exec` `RW` | `run <msg>` `RW` | positional prompt `RW` | `-p/--print` `RW` |
| Read-only / plan | `--permission-mode plan` `RW` | `-s/--sandbox read-only` `RW` | `--agent plan` `RW` | `-p/--plan` + `--auto-approve false` `RW` | **`--mode plan` / `--plan`**; **`--mode ask`** is also read-only. A fresh headless workspace needs **`--trust`**. |
| Write / act | `--permission-mode bypassPermissions` `RW` | `-s/--sandbox workspace-write` `RW` | default agent `RW` | `--auto-approve true` `RW` | `-f/--force` `RW` |
| Working directory | `--add-dir` / cwd `RW` | `-C/--cd <DIR>` `RW` | `--dir` `RW` | `-c/--cwd` `RW` | cwd `RW`; **`--workspace <path-or-name>`** and **`--add-dir`** also exist |
| Model | `--model <alias\|full>` `RW` | `--model` `RW` | `-m provider/model` `RW` | `-m <id>` (+ `-P <provider>`) `RW` | `--model <id>` `RW`; current Rafu defaults are stale, see below |
| Machine-readable output | `--output-format stream-json --verbose` `RW` | `--json` (JSONL) `RW` | `--format json` `RW` | `--json` `RW` | `--output-format json` `RW`; **`stream-json`** is available |
| **Reasoning effort** | **`--effort low\|medium\|high\|xhigh\|max`** | **`-c model_reasoning_effort=<level>`** (config override; no dedicated flag) | — no per-run flag; see note below | **`--thinking none\|low\|medium\|high\|xhigh`** | Effort-bearing model IDs or `--model 'id[effort=<level>]'`; passable today through Rafu's free-text model field, but no portable `effort:` field |
| **Continue last session** | **`-c/--continue`** | **`exec resume --last`** | **`-c/--continue`** | — | **`--continue`** or **`resume`** |
| **Resume by session id** | **`-r/--resume <id>`** | **`exec resume <uuid\|thread-name>`** | **`-s/--session <id>`** | **`--id <session-id>`** | **`--resume <chatId>`** |
| **Assign a session id** | **`--session-id <uuid>`** | — (Codex mints its own) | — | — | **`create-chat`** pre-creates a CLI-minted ID; no arbitrary ID assignment |
| **Fork on resume** | **`--fork-session`** | — | **`--fork`** | — | — |
| List sessions | *unverified* | `exec resume --last` implies a recorded store | `export [sessionID]` (JSON), `stats` | `history --json` | **`ls`** / interactive resume selector |
| Model listing | — (curated) | — (curated) | `opencode models` `RW` | — (reads bundled `@cline/llms` catalog) `RW` | **`models` / `--list-models`**; not used by Rafu |
| Auth status, headless | `auth status --json` `RW` | `login status` `RW` | `auth list` `RW` | — (all status commands need a TTY) | `status` / `whoami` `RW` |

## What this means for the three questions

### 1. "Act mode or plan mode?"

The choice is the role's `autonomy:` field in `.rafu/agents/<name>.md`, not
an ad hoc per-step prompt convention:

- `autonomy: readOnly` → plan/read-only mapping above.
- `autonomy: worktreeWrite` → act/write mapping, and ADR 0018 confines it to
  a Rafu-created worktree, so "act" never means "loose in your checkout".

Claude Code, Codex, OpenCode, and Cline are fully wired. Cursor is now a
documented exception: its current CLI has a genuine read-only plan mode, but
Rafu's adapter predates that surface and still declares `readOnly`
unsupported. It therefore fails closed rather than silently using write
access, but it also leaves a now-supported capability unreachable.

The locally verified Cursor headless mapping is:

```text
-p --output-format json --trust --mode plan --model <model> <prompt>
```

`--trust` acknowledges the selected workspace so the non-interactive process
can start; `--mode plan` remains the read-only enforcement. The existing
write mapping remains syntactically valid:

```text
-p --output-format json --force --model <model> <prompt>
```

### 2. "Which model, what reasoning effort?"

**Model: wired, with a Cursor drift bug.** `model:` in the agent file is
overridable per run at launch (C6) and snapshotted into the run manifest so
later file edits never rewrite history. Cursor 2026.07.23 adds account-backed
`models` / `--list-models`, but `CursorAdapter.supportsModelDiscovery` is
still `false`.

More importantly, the adapter's curated `gpt-5`, `sonnet-4`, and
`sonnet-4-thinking` choices came from the old help examples. On 2026-07-27:

- `models` returned 190 catalog rows, including `auto`, but no exact `gpt-5`;
- the exact Rafu default (`--model gpt-5`) failed before starting the agent;
- a listed named model was also rejected for this account's entitlement; and
- the same write probe with `--model auto` succeeded and created exactly the
  requested three-byte `OK\n` file.

Listing a model therefore does not prove the account may select it. Rafu
needs dynamic discovery plus honest run-time entitlement errors, and an empty
Cursor model must not silently resolve to the stale `gpt-5` default.

**Portable reasoning effort: NOT wired — this is a real gap.** Four of the
five runtime-probed CLIs accept it:

- Claude Code: `--effort low|medium|high|xhigh|max`
- Cline: `--thinking none|low|medium|high|xhigh`
- Codex: no flag, but `-c model_reasoning_effort=<level>` overrides the same
  key Codex reads from `~/.codex/config.toml` (verified: that key is already
  set on this Mac).
- Cursor: no separate effort flag. Its current help exposes effort-bearing
  model IDs and parameterized model strings such as
  `--model 'id[effort=high]'`. Because Rafu passes a custom model string
  verbatim, this can already ride through `model:` for an entitled account,
  but it is not a portable `effort:` setting and was not runtime-verified on
  this account because named models were rejected.
- OpenCode: **no per-invocation mechanism at all.** Verified against its
  published schema (`https://opencode.ai/config.json`, the `$schema` the
  local `~/.config/opencode/opencode.jsonc` points at): `models.<id>.reasoning`
  is a **boolean capability flag** ("this model can reason"), not a level, and
  `models.<id>.options` is an untyped passthrough object. A user can therefore
  put provider-specific options in *their own config file*, but there is no
  argv Rafu could pass per run — and Rafu must not edit a user's config to
  simulate one.

`ConductorAgentDefinition` has no field for it, so there is nowhere to put it
today. Closing this needs:

1. an optional `effort:` key in the agent-file frontmatter parser,
2. an `effort` field on `ConductorAgentDefinition` + the manifest binding,
3. per-adapter mapping (`--effort` / `--thinking` / `-c
   model_reasoning_effort=` / Cursor model parameter), with adapters that
   have no equivalent (OpenCode) **ignoring it explicitly** rather than
   pretending,
4. a Settings/launch affordance.

The vocabularies overlap but do not match. `low|medium|high|xhigh` recur;
Claude and current Cursor models add `max`, while Cline adds `none`.
A small shared enum with per-adapter validation may be viable, but any
rejection or downgrade must be visible, not silently clamped.

**A CLI's own config should be the default when the CLI supports that
contract.** Codex reads `model` and `model_reasoning_effort` from
`~/.codex/config.toml`, so a role with an empty Codex `model:` genuinely means
"whatever the user configured for that CLI". Cursor differs today:
`CursorAdapter` replaces an empty model with its first curated choice
(`gpt-5`), and that choice is now invalid for the authenticated local account.
That is exactly the kind of guessed default delegated configuration is meant
to avoid.

### 3. "Continue a previous conversation, or switch model mid-run?"

**Not supported, by design — and worth understanding before changing it.**

Every Ensemble step is a **fresh process**. ADR 0018 chose file-based
handoffs precisely so state lives in `.rafu/runs/<id>/` as inspectable
evidence rather than inside a vendor's session store. Continuity between
steps is the *artifact*, not a conversation.

So today:

- **Continuing a prior conversation:** not wired. All five runtime-probed
  CLIs can resume (`--resume` / `--id` / `--session`), and Rafu records none
  of their session ids as manifest metadata, so there is nothing to resume
  *with*. C7 deliberately scoped this out ("adapter-native `--resume` modes
  stay out of scope").
- **Retry** is not resume: `retryInterruptedStep` / `retryFailedStep` start a
  **new** attempt from the persisted `prompt.md` into a fresh `-aN` directory.
  Prior evidence is never mutated. That is intentional — a retry you can
  diff against the previous attempt is worth more than an opaque continuation.
- **Switching model mid-conversation:** impossible by construction, because
  there is no live conversation to switch. You change the model *between*
  steps (each step resolves its own binding) or retry a step with a different
  one.

**If we want real resume**, the smallest honest design is:

1. Have each adapter report the session id it created (Claude can be *told*
   one via `--session-id <uuid>`; Codex mints its own and accepts a UUID or a
   thread name; OpenCode and Cline emit theirs in `--json` output; Cursor's
   JSON result contains `session_id`).
2. Record it in the step's manifest entry — it is metadata, not a credential.
3. Add a "Continue this step" verb that re-invokes with the resume flag.
4. Keep it per-adapter and honest: Cline has no `--continue`, only `--id`;
   Claude, OpenCode, and Cursor have continue-last plus explicit-id forms;
   Codex spells continue-last as `exec resume --last`.

Claude Code's `--session-id` is the strongest lever because Rafu could choose
the UUID itself. Cursor offers a different deterministic path:
`create-chat` pre-creates a CLI-minted ID that a later `--resume <chatId>` can
use.

## Cline's TTY split (the one that looks alarming and is not)

Cline is the clearest case of *interactive* and *headless* surfaces
diverging, and it caused a real "is this broken?" moment:

| Surface | TTY? | Used by Rafu |
|---|---|---|
| Prompt mode (`cline --json --cwd … -- "prompt"`) | **No** | **Yes — every run** |
| `--version` | No | Discovery |
| `config`, `mcp`, `-i/--tui` | **Yes** | No |
| `auth` | Interactive; *performs* login | No |

So Cline reports **"sign-in status unknown"** while working perfectly: there
is no headless status command, and reading its `0600`
`~/.cline/data/settings/providers.json` is forbidden (ADR 0018). Auth is
**delegated** — the child reads its own credentials at launch and Rafu passes
none. Verified end to end on 2026-07-26: a real headless Cline run streamed
JSON events with stdin on `/dev/null` and no credentials from Rafu.

Auth status is informational only; it is **not consulted anywhere in the
launch path**, so `unknown` never blocks a run.

## OpenCode: capability flag, not a level

Worth spelling out because the naming invites a wrong assumption. OpenCode's
per-model config keys are `attachment, cost, experimental, family, headers,
id, interleaved, limit, modalities, name, options, provider, reasoning,
release_date, status, temperature, tool_call, variants`.

`reasoning: boolean` answers "does this model reason?", NOT "how hard". The
only extension point is `options: {}` — schema-typed as a bare object, i.e. a
free-form provider passthrough that lives in the user's `opencode.jsonc`.
Nothing about it is reachable from `opencode run`'s argv, which is the only
surface Rafu drives. So OpenCode's cell is an honest `—`, and it would stay
`—` even after effort is wired for the adapters that expose it.

## Cursor: catalog visibility is not model entitlement

Cursor 2026.07.23-e383d2b was tested through the same
`~/.local/bin/cursor-agent` executable Rafu discovers. The installed
`~/.local/bin/agent` is an alias to that binary; `cursor-agent` remains
backward compatible and is still Rafu's discovery name.

The account-backed probes established four separate facts:

1. `status` succeeds under Rafu's minimal `HOME` + curated `PATH`
   environment, so delegated login works without forwarding
   `CURSOR_API_KEY`.
2. `models` and `--list-models` both work headlessly and returned the same
   190-row catalog.
3. That catalog is not an entitlement list: the account rejected a listed
   named model and directed the caller to Auto. The old curated `gpt-5`
   default was absent and failed too.
4. `--model auto` completed the exact Rafu write argv shape. A separate
   `--trust --mode plan --model auto` run completed without changing the
   scratch repository.

Cursor's JSON result includes `session_id`. Resuming that exact id with
`--resume <chatId>` and then using `--continue` both preserved the id and
completed successfully. Rafu deliberately does not parse or persist it today.

These probes used new repositories under `/tmp`; no command was run against
the Rafu checkout, and no credential file or credential value was read.

## Re-verification

```bash
claude --help | grep -E '\--effort|--resume|--session-id|--permission-mode'
"/Applications/ChatGPT.app/Contents/Resources/codex" --version
opencode run --help          # -c/--continue, -s/--session, --fork, -m
cline --help | grep -E '\--thinking|--id|--auto-approve|-p, --plan'
curl -s https://opencode.ai/config.json | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(sorted(d["$defs"]["ProviderConfig"]["properties"]["models"]["additionalProperties"]["properties"]))'
cline history --json | head  # session ids, if resume is ever wired

cursor-agent --version </dev/null
cursor-agent status </dev/null
cursor-agent --help </dev/null | grep -E \
  '\--mode|--plan|--resume|--continue|--model|--list-models|--workspace'
cursor-agent models </dev/null

cursor_probe_dir="$(mktemp -d /tmp/rafu-cursor-matrix.XXXXXX)"
cd "$cursor_probe_dir"
/usr/bin/git init -q
cursor-agent -p --output-format json --force --model auto \
  "Create rafu-cursor-probe.txt containing exactly OK followed by one newline." \
  </dev/null
/bin/test -f "$cursor_probe_dir/rafu-cursor-probe.txt"

cursor_plan_dir="$(mktemp -d /tmp/rafu-cursor-plan.XXXXXX)"
cd "$cursor_plan_dir"
/usr/bin/git init -q
cursor-agent -p --output-format json --trust --mode plan --model auto \
  "Plan how to create should-not-exist.txt. Do not edit files." </dev/null
/bin/test ! -e "$cursor_plan_dir/should-not-exist.txt"
```

Anything a probe cannot confirm must be recorded *unverified* with the exact
command the user should run — never guessed (README ground rules).

## Related

- ADR 0018 (delegated auth; file-based handoffs; fresh process per step)
- [`conductor-pipeline-engine.md`](conductor-pipeline-engine.md) (why retry
  is a fresh attempt, not a continuation)
- [`gui-app-path-and-cli-discovery.md`](gui-app-path-and-cli-discovery.md)
  (why nvm/ChatGPT.app installs need widened discovery)
- `docs/plans/phases/conductor/orchestration-gap-analysis.md` (the larger
  "Rafu executes, it does not decide" gap this sits inside)
