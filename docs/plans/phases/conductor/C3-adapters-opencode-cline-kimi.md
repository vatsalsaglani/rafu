# C3 — Adapters: OpenCode + Cline + Kimi CLI

- **Branch:** `conductor/c3-adapters-opencode-cline-kimi` (Wave A, branch after C0)
- **Depends on:** C0 shim on `main`; C2 is the quality template (read its
  reference note if merged, but do not depend on its code)
- **Status:** Implemented (zero-warning gate blocked outside C3; Kimi unverified locally)

## Mission

Replace the C0 stubs for OpenCode, Cline, and Kimi CLI. These CLIs churn
faster and are less likely to be installed than Claude/Codex, so the honest
`unverified` path matters here: an adapter whose CLI cannot be probed in the
build environment ships against the documented shape, marks itself
unverified, and hands the user exact probe commands.

## Expected invocation shapes (HYPOTHESES — probe before coding)

Record verified shapes in
`docs/references/conductor-adapter-opencode-cline-kimi.md`.

### OpenCode (`opencode`)

- Headless: `opencode run "<prompt>" --model <provider>/<model>` with cwd =
  working directory.
- Models: **dynamic listing expected** — `opencode models` (this is the
  roster's first real `discoverModels` implementation; parse defensively,
  cap output size, fall back to curated on any parse failure).
- Autonomy: probe permission/agent flags (`--agent plan`?); if no
  read-only mode exists, `readOnly` roles must be declared unsupported by
  this adapter rather than faked.
- Auth status: `opencode auth list` classification; metadata only.

### Cline (`cline`)

- The Cline CLI surface is in flux; probe first
  (`cline --help`; expected shapes include `cline task new "<prompt>"` or a
  direct `cline "<prompt>"` with a non-interactive/auto-approve flag).
- Models: Cline routes providers itself; expose curated entries for its
  major routes + free-text; probe for a listing command.
- Autonomy: map to its yolo/auto-approve flag ONLY inside a worktree;
  `readOnly` unsupported unless a plan mode is found.
- Auth: Cline account login vs BYO key are both delegated to the CLI; probe
  a status command.

### Kimi CLI (`kimi`)

- Moonshot's CLI; probe for a non-interactive print/prompt mode and
  `--model` support (kimi-k2 family expected in the curated list).
- If no headless mode exists at implementation time, mark the adapter
  `installedButNoHeadlessMode` with an honest Settings hint — do NOT
  attempt PTY keystroke automation against an interactive UI.

## Child-process PATH (C0 contract)

Read the identical section in
[`C2-adapters-claude-codex.md`](C2-adapters-claude-codex.md) — it is binding
here too. Summary: children get no inherited `PATH`; `executableURL` must be
absolute; if your probe finds the CLI outside
`RafuConductorEnvironment.curatedPath` (notably a version-manager shim), your
adapter must prepend that executable's own directory. Shared tests assert a
superset of the C0 environment keys, so adding keys needs no shared-file edit.

## Scope

- Rewrite `Adapters/OpenCodeAdapter.swift`, `Adapters/ClineAdapter.swift`,
  `Adapters/KimiAdapter.swift`.
- Same probe/bounded-subprocess/no-secret rules as C2.
- Tests: argv construction, probe classification over recorded fixtures,
  `discoverModels` parsing for OpenCode (fixture transcripts, malformed
  input, size cap).
- Reference note with per-CLI verified-or-unverified status and the exact
  user-side verification commands for anything unverified.

## Owned paths

- The three adapter files above
- `Tests/RafuAppTests/Conductor/{OpenCode,Cline,Kimi}AdapterTests.swift` +
  fixtures
- `docs/references/conductor-adapter-opencode-cline-kimi.md`
- This file's status line

Forbidden: everything else, per the README zero-conflict rule.

## Exit criteria

- Three adapters compile, probe honestly (verified where the CLI exists,
  explicit `unverified`/`unsupported` states where it does not), never
  fake capability, all gates green, no shared-file diffs.

## Goal-mode prompt

> /goal Implement phase C3 exactly as scoped in
> docs/plans/phases/conductor/C3-adapters-opencode-cline-kimi.md. Read that
> file AND docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c3-adapters-opencode-cline-kimi with a clean
> tree and the C0 shim present — if not, STOP and report. Use the
> advisor→implementor→documentor workflow. The invocation shapes in the
> phase doc are hypotheses: probe each installed CLI before coding; where a
> CLI is absent or has no headless mode, implement the documented shape,
> mark the adapter unverified/unsupported honestly, and record the exact
> probe commands for the user — never fake capability, never automate an
> interactive TUI. Obey the README worktree ground rules (headless gates
> only, commit on this branch, never push/merge, touch ONLY your owned
> paths — your three adapter files, your tests, your reference note). Never
> read credential file contents. Finish with one consolidated report:
> changes, files, test delta, per-CLI verified/unverified status with
> evidence, intended doc-index rows, and remaining risks.
