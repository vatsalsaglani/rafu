# C2 — Adapters: Claude Code + Codex (reference adapters)

- **Branch:** `conductor/c2-adapters-claude-codex` (Wave A, branch after C0)
- **Depends on:** C0 shim on `main`
- **Status:** Planned

## Mission

Replace the C0 stubs for the two flagship adapters. These set the quality
bar every other adapter copies: honest probing, exact autonomy mapping,
model selection with curated + custom entries, and a verified reference
note per CLI. Both CLIs are installed on the user's machine, so these
adapters must merge **verified**, not hypothesized.

## Expected invocation shapes (HYPOTHESES — probe before coding)

Treat this table as a starting point; the installed CLI's `--help` output
wins. Record the verified shapes in
`docs/references/conductor-adapter-claude-codex.md`.

### Claude Code (`claude`)

- Headless: `claude -p "<prompt>" --model <id> --output-format stream-json`
  (capture; the PTY still shows progress) with cwd = working directory.
- Autonomy mapping: `readOnly` → `--permission-mode plan`;
  `worktreeWrite` → the strongest non-interactive write mode available
  (probe: `--permission-mode acceptEdits` vs
  `--dangerously-skip-permissions`; choose the least-dangerous mode that
  completes unattended INSIDE a worktree, record the choice and why).
- Models: curated list (current Fable/Opus/Sonnet/Haiku ids from
  `claude --help` / docs at implementation time) + free-text custom. No
  dynamic listing command expected.
- Auth status: probe for a non-interactive status command or config
  presence (e.g. `claude auth status` if it exists); metadata only, never
  token values. Hint: "run `claude` in a terminal and log in".

### Codex (`codex`)

- Headless: `codex exec "<prompt>" --model <id> --cd <dir>`; probe `--json`
  and sandbox flags.
- Autonomy mapping: `readOnly` → `--sandbox read-only`; `worktreeWrite` →
  `--sandbox workspace-write` (cwd = the run worktree). Never
  `danger-full-access`.
- Models: curated GPT-5.x list verified against `codex --help`/docs at
  implementation time + free-text custom; probe whether a model-list
  command exists.
- Auth status: `codex login status` (or equivalent) exit code / stdout
  classification; presence of `~/.codex/auth.json` may inform `unknown`
  vs `notAuthenticated` but its contents are NEVER read.

## Child-process PATH (C0 contract — applies to every adapter phase)

A Conductor child gets **no inherited `PATH`**: SwiftTerm's PTY environment
omits it, so `RafuConductorEnvironment.curatedPath` supplies a fixed,
auditable list (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`,
`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`). Two consequences are binding on
this phase:

1. `AdapterInvocation.executableURL` must be an **absolute** URL — never a
   bare command name.
2. If your probe finds the CLI outside the curated list (a version-manager
   shim such as nvm/fnm/volta, or any other install root), your adapter
   **must prepend that executable's own directory** to `PATH` in the
   environment it returns. The curated path deliberately does not guess at
   version-manager layouts, and a Node-based CLI that cannot see its own
   interpreter or siblings will fail at its first subprocess. Adding keys on
   top of the C0 defaults is expected — the shared tests assert a superset,
   not an exact key set, precisely so you can do this without editing a
   shared file.

## Scope

- Rewrite `Adapters/ClaudeCodeAdapter.swift` and `Adapters/CodexAdapter.swift`.
- Binary discovery: `which` via argv (no shell), plus the standard install
  locations; result cached per probe call, not per launch.
- Every probe subprocess is bounded (timeout), off-main, and safe to call
  from the Settings surface.
- Tests: argv-construction tests for every (autonomy × model × directory)
  combination; probe-output classification tests over recorded fixture
  transcripts (never live network); registry rows flip from stub to real.
- Reference note `docs/references/conductor-adapter-claude-codex.md`: what
  it applies to, verified CLI versions, exact flags, autonomy mapping
  rationale, auth-probe behavior, failure modes, re-verification commands.

## Owned paths

- `Sources/RafuApp/Conductor/Adapters/ClaudeCodeAdapter.swift`,
  `CodexAdapter.swift`
- `Tests/RafuAppTests/Conductor/ClaudeCodeAdapterTests.swift`,
  `CodexAdapterTests.swift` + fixtures
- `docs/references/conductor-adapter-claude-codex.md`
- This file's status line

Forbidden: everything else — especially `ConductorCore.swift`, the
registry, other adapters, Settings, `Package.swift`.

## Exit criteria

- Both adapters probe the real installed CLIs correctly (record versions in
  the note), classify auth status without reading secrets, build correct
  argv for both autonomy levels, and surface curated models + custom entry.
- All gates green; no shared-file diffs.

## Goal-mode prompt

> /goal Implement phase C2 exactly as scoped in
> docs/plans/phases/conductor/C2-adapters-claude-codex.md. Read that file
> AND docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c2-adapters-claude-codex with a clean tree
> and the C0 shim present — if not, STOP and report. Use the
> advisor→implementor→documentor workflow. The invocation shapes in the
> phase doc are hypotheses: probe the installed `claude` and `codex` CLIs
> (`--help`, subcommand help, status commands) BEFORE coding and record
> verified shapes in the reference note; these two adapters must merge
> verified, not guessed. Obey the README worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths — your two adapter files, your tests, your reference note).
> Never read credential file contents; auth probing is presence/exit-code
> metadata only. Finish with one consolidated report: changes, files, test
> delta, verified CLI versions and flags, deviations from the hypothesized
> shapes, intended doc-index rows, and remaining risks.
