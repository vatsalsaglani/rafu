# Ensemble CLI capability matrix — modes, models, effort, sessions

- **Applies to:** every Ensemble adapter. This is the cross-CLI comparison;
  the per-family notes
  ([claude-codex](conductor-adapter-claude-codex.md),
  [opencode-cline-kimi](conductor-adapter-opencode-cline-kimi.md),
  [gemini-cursor](conductor-adapter-gemini-cursor.md))
  stay authoritative for probe transcripts and error taxonomy.
- **Last verified:** 2026-07-26 against the CLIs installed on this Mac.
  Anything marked *unverified* was NOT re-probed and comes from the owning
  phase's recorded shape. Claude Code, Codex, OpenCode, and Cline were all
  probed directly; Kimi, Gemini, and Cursor's runtime behaviour were not.

## Verified versions

| CLI | Version | Where it resolved |
|---|---|---|
| Claude Code | 2.1.220 | `~/.local/bin/claude` |
| Codex | 0.145.0 | `~/.local/bin/codex` — **wins over** the 0.146.0-alpha.3.1 bundled at `/Applications/ChatGPT.app/Contents/Resources/codex`, because discovery runs `which` first and `~/.local/bin` is on the search path. Both are kept as candidates so Codex still resolves for a ChatGPT.app-only install. |
| OpenCode | 1.18.4 | `~/.opencode/bin/opencode` |
| Cline | 3.0.46 | `~/.nvm/versions/node/v22.0.0/bin/cline` (nvm — **not** on a GUI app's `PATH`; see [gui-app-path-and-cli-discovery.md](gui-app-path-and-cli-discovery.md)) |
| Kimi CLI | — | not installed (unverified) |
| Gemini CLI | — | not installed (unverified) |
| Cursor CLI | 2025.09.18 | `~/.local/bin/cursor-agent` (installed, signed out) |

## The matrix

`RW` = what Rafu wires today. `—` = the CLI has no such surface.
**Bold** = the CLI supports it but **Rafu does not use it yet**.

| Capability | Claude Code | Codex | OpenCode | Cline |
|---|---|---|---|---|
| Headless prompt | `-p/--print` `RW` | `exec` `RW` | `run <msg>` `RW` | positional prompt `RW` |
| Read-only / plan | `--permission-mode plan` `RW` | `-s/--sandbox read-only` `RW` | `--agent plan` `RW` | `-p/--plan` + `--auto-approve false` `RW` |
| Write / act | `--permission-mode bypassPermissions` `RW` | `-s/--sandbox workspace-write` `RW` | default agent `RW` | `--auto-approve true` `RW` |
| Working directory | `--add-dir` / cwd `RW` | `-C/--cd <DIR>` `RW` | `--dir` `RW` | `-c/--cwd` `RW` |
| Model | `--model <alias\|full>` `RW` | `--model` `RW` | `-m provider/model` `RW` | `-m <id>` (+ `-P <provider>`) `RW` |
| Machine-readable output | `--output-format stream-json --verbose` `RW` | `--json` (JSONL) `RW` | `--format json` `RW` | `--json` `RW` |
| **Reasoning effort** | **`--effort low\|medium\|high\|xhigh\|max`** | **`-c model_reasoning_effort=<level>`** (config override; no dedicated flag) | — (none in `run`) | **`--thinking none\|low\|medium\|high\|xhigh`** |
| **Continue last session** | **`-c/--continue`** | **`exec resume --last`** | **`-c/--continue`** | — |
| **Resume by session id** | **`-r/--resume <id>`** | **`exec resume <uuid\|thread-name>`** | **`-s/--session <id>`** | **`--id <session-id>`** |
| **Assign a session id** | **`--session-id <uuid>`** | — (Codex mints its own) | — | — |
| **Fork on resume** | **`--fork-session`** | — | **`--fork`** | — |
| List sessions | *unverified* | `exec resume --last` implies a recorded store | *unverified* | `history --json` |
| Model listing | — (curated) | — (curated) | `opencode models` `RW` | — (reads bundled `@cline/llms` catalog) `RW` |
| Auth status, headless | `auth status --json` `RW` | `login status` `RW` | `auth list` `RW` | — (all status commands need a TTY) |

## What this means for the three questions

### 1. "Act mode or plan mode?"

Fully wired, and it is **not** a per-run choice — it is the role's
`autonomy:` field in `.rafu/agents/<name>.md`:

- `autonomy: readOnly` → plan/read-only mapping above.
- `autonomy: worktreeWrite` → act/write mapping, and ADR 0018 confines it to
  a Rafu-created worktree, so "act" never means "loose in your checkout".

An adapter whose CLI has no read-only mode declares `readOnly` unsupported
and **fails closed** rather than silently running with write access.

### 2. "Which model, what reasoning effort?"

**Model: wired.** `model:` in the agent file, overridable per run at launch
(C6), snapshotted into the run manifest so later file edits never rewrite
history.

**Reasoning effort: NOT wired — this is a real gap.** Three of the four
installed CLIs accept it and Rafu passes none of them:

- Claude Code: `--effort low|medium|high|xhigh|max`
- Cline: `--thinking none|low|medium|high|xhigh`
- Codex: no flag, but `-c model_reasoning_effort=<level>` overrides the same
  key Codex reads from `~/.codex/config.toml` (verified: that key is already
  set on this Mac).
- OpenCode: no equivalent in `run`.

`ConductorAgentDefinition` has no field for it, so there is nowhere to put it
today. Closing this needs:

1. an optional `effort:` key in the agent-file frontmatter parser,
2. an `effort` field on `ConductorAgentDefinition` + the manifest binding,
3. per-adapter mapping (`--effort` / `--thinking` / `-c
   model_reasoning_effort=`), with adapters that have no equivalent
   (OpenCode) **ignoring it explicitly** rather than pretending,
4. a Settings/launch affordance.

Note the vocabularies nearly match (`low|medium|high|xhigh` shared; Claude
adds `max`, Cline adds `none`), so a small shared enum with per-adapter
clamping is viable — but clamping must be visible, not silent.

**A CLI's own config is already the default.** Codex reads `model` and
`model_reasoning_effort` from `~/.codex/config.toml`, so a role with an empty
`model:` genuinely means "whatever the user configured for that CLI", not
"whatever Rafu guesses". That is delegated configuration working as intended,
and it is why Rafu must never invent a default it did not read.

### 3. "Continue a previous conversation, or switch model mid-run?"

**Not supported, by design — and worth understanding before changing it.**

Every Ensemble step is a **fresh process**. ADR 0018 chose file-based
handoffs precisely so state lives in `.rafu/runs/<id>/` as inspectable
evidence rather than inside a vendor's session store. Continuity between
steps is the *artifact*, not a conversation.

So today:

- **Continuing a prior conversation:** not wired. All four CLIs can resume
  (`--resume` / `--id` / `--session`), and Rafu records none of their session
  ids, so there is nothing to resume *with*. C7 deliberately scoped this out
  ("adapter-native `--resume` modes stay out of scope").
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
   thread name; OpenCode and Cline emit theirs in `--json` output).
2. Record it in the step's manifest entry — it is metadata, not a credential.
3. Add a "Continue this step" verb that re-invokes with the resume flag.
4. Keep it per-adapter and honest: Cline has no `--continue`, only `--id`;
   Claude and OpenCode have both; Codex spells continue-last as
   `exec resume --last`.

Claude Code's `--session-id` is the strongest lever: Rafu could mint the id
itself, making resume deterministic instead of scrape-dependent.

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

## Re-verification

```bash
claude --help | grep -E '\--effort|--resume|--session-id|--permission-mode'
"/Applications/ChatGPT.app/Contents/Resources/codex" --version
opencode run --help          # -c/--continue, -s/--session, --fork, -m
cline --help | grep -E '\--thinking|--id|--auto-approve|-p, --plan'
cline history --json | head  # session ids, if resume is ever wired
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
