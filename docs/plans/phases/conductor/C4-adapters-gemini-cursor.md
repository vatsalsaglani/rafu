# C4 — Adapters: Gemini CLI + Cursor CLI (best-effort tier)

- **Branch:** `conductor/c4-adapters-gemini-cursor` (Wave A, branch after C0)
- **Depends on:** C0 shim on `main`
- **Status:** Planned

## Mission

Replace the C0 stubs for Gemini CLI and Cursor CLI. Both are explicitly
best-effort: the user may not hold active access to either, so these
adapters exist to make the roster complete and honest — a fully implemented
invocation path behind a probe that reports plain truth ("not installed",
"not authenticated") rather than a degraded fake.

## Expected invocation shapes (HYPOTHESES — probe before coding)

Record verified shapes in
`docs/references/conductor-adapter-gemini-cursor.md`.

### Gemini CLI (`gemini`)

- Headless: `gemini -p "<prompt>" -m <model>`; probe `--output-format json`.
- Autonomy mapping: `readOnly` → default approval mode (no auto-writes);
  `worktreeWrite` → probe `--approval-mode auto_edit` vs `--yolo` and pick
  the least-dangerous unattended-capable mode; record why.
- Models: curated Gemini ids verified against `--help`/docs at
  implementation time (e.g. current pro/flash tiers) + free-text custom.
- Auth: Google OAuth cached by the CLI (`~/.gemini/`) or
  `GEMINI_API_KEY` — both delegated; probe presence/exit codes only. The
  env-var path, if supported, passes through the user's existing shell
  environment by name only; Rafu never stores the key.

### Cursor CLI (`cursor-agent`)

- Headless: `cursor-agent -p "<prompt>" --model <id>`; probe
  `--output-format` and non-interactive/force flags.
- Autonomy mapping: probe for a plan/read-only mode; if none exists,
  `readOnly` is unsupported for this adapter (state it in Settings).
- Models: probe for a listing command; else curated + free-text.
- Auth: `cursor-agent status` (or equivalent) classification; delegated
  login via `cursor-agent login` hint.

## Child-process PATH (C0 contract)

Read the identical section in
[`C2-adapters-claude-codex.md`](C2-adapters-claude-codex.md) — it is binding
here too. Summary: children get no inherited `PATH`; `executableURL` must be
absolute; if your probe finds the CLI outside
`RafuConductorEnvironment.curatedPath` (notably a version-manager shim), your
adapter must prepend that executable's own directory. Shared tests assert a
superset of the C0 environment keys, so adding keys needs no shared-file edit.

## Scope

- Rewrite `Adapters/GeminiCLIAdapter.swift`, `Adapters/CursorAdapter.swift`
  with the same probe/bounded-subprocess/no-secret rules as C2/C3.
- Tests: argv construction, probe classification over recorded fixtures,
  unsupported-autonomy behavior.
- Reference note with verified-or-unverified status per CLI and user-side
  verification commands.

## Owned paths

- The two adapter files above
- `Tests/RafuAppTests/Conductor/{GeminiCLI,Cursor}AdapterTests.swift` +
  fixtures
- `docs/references/conductor-adapter-gemini-cursor.md`
- This file's status line

Forbidden: everything else, per the README zero-conflict rule.

## Exit criteria

- Both adapters compile, probe honestly, build correct argv for supported
  autonomy levels, declare unsupported levels explicitly, all gates green,
  no shared-file diffs.

## Goal-mode prompt

> /goal Implement phase C4 exactly as scoped in
> docs/plans/phases/conductor/C4-adapters-gemini-cursor.md. Read that file
> AND docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c4-adapters-gemini-cursor with a clean tree
> and the C0 shim present — if not, STOP and report. Use the
> advisor→implementor→documentor workflow. The invocation shapes in the
> phase doc are hypotheses: probe each installed CLI before coding; these
> two are best-effort tier — where a CLI is absent, implement the
> documented shape, mark it unverified, and record the exact probe commands
> for the user; never fake capability. Obey the README worktree ground
> rules (headless gates only, commit on this branch, never push/merge,
> touch ONLY your owned paths — your two adapter files, your tests, your
> reference note). Never read credential file contents; env-var key paths
> pass through by name only and are never stored. Finish with one
> consolidated report: changes, files, test delta, per-CLI
> verified/unverified status with evidence, intended doc-index rows, and
> remaining risks.
