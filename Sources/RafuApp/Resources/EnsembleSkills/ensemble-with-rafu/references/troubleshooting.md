# Ensemble troubleshooting

## Exit-code actions

### 64 — usage

For a read-only verb, the grammar is invalid or the working directory contains
an `ensemble` filesystem entry that collides with the reserved subcommand.
Read `rafu ensemble --help`; use `rafu ./ensemble` only when you meant the
filesystem path. Fix the call, but do not retry it verbatim.

For a mutating verb (`run`, `abort`, `note`, `grant`, or `propose-merge`),
exit 64 means the installed Rafu predates the mutating verb surface. Stop and
tell the user to update Rafu. Do not retry with different arguments.

### 65 — data error

An agent/workflow file is malformed, or a requested run/step does not exist.
Correct the file or identifier. When a plan file changes, open it through
`run --plan-gate` again before anything spawns.

### 69 — unavailable

The app is not running, the matching workspace is not open in Rafu, or an
event stream became unavailable. Stop. Ask the user to run Rafu and open the
repository containing the coordinator terminal. Do not switch to another
workspace silently.

### 75 — temporary failure

The grant is exhausted or `await` reached the user-supplied timeout. Ask the
user to extend the grant or timeout. Never loop.

### 77 — no permission

The coordinator token is missing/dead or the requested CLI is outside the
allowed provider set. Stop and report. Never retry with different arguments.

## Rafu relaunched

`RAFU_ENSEMBLE_TOKEN` is in memory only and dies with the app. After relaunch,
read-only `status`, `artifact`, and `await` still work, so use them to
re-orient. Mutating verbs must not be retried until the user re-grants the
coordinator from the New Ensemble sheet.

## Workspace not open

Verb routing selects the deepest open local Rafu workspace containing the
coordinator's working directory. If none matches, the command exits 69. Ask
the user to open this repository in Rafu; do not `cd` to an unrelated open
workspace to evade the check.

## Version mismatch

This skill targets verb version 2. If `status --json` reports another
`verbVersion`, trust the installed CLI, read its help, and stop using stale
grammar from this skill until the skill pack is updated.
