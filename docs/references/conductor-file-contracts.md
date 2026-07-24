# Ensemble `.rafu/` file contracts: layout, parsers, manifest encoding, invocation

- Applies to: `Sources/RafuApp/Conductor/` (`RafuDotDirectory.swift`,
  `ConductorAgentFileParser.swift`, `ConductorWorkflowFileParser.swift`,
  `ConductorRunStore.swift`, `ConductorCore.swift`) and every phase C1–C7
  that reads or writes `.rafu/`
- Last verified: Swift 6.2 / macOS 26 / 2026-07-24 (phase C0)

## Rule or observed behavior

These are the durable, cross-phase decisions C0 baked into the `.rafu/`
contract. They bind C1–C7; changing one is a coordinator decision, not a
phase-local edit.

### `.rafu/` layout and seeding

```
.rafu/
  .gitignore        // gitignores runs/ by default
  agents/
  workflows/
  runs/<id>/
```

`seed()` behavior:

- **Idempotent.** Re-running it changes nothing.
- **Never rewrites an existing `.rafu/.gitignore`** — the user may have
  chosen to commit run evidence.
- **Never touches the repository's top-level `.gitignore`.**
- **Never creates agent or workflow files.** Templates are C6's scope.
- **Throws on wrong-type paths** (e.g. `.rafu/agents` existing as a file).
- **Classifies every path BEFORE creating any of them**, so a bad path
  aborts the whole seed rather than leaving a half-applied tree.

`seed()` is deliberately **not** auto-invoked on workspace open. Rafu must
not write into a user's repository merely because a folder was opened
(AGENTS.md explicit-user-control invariant; ADR 0018's
nothing-without-a-visible-run rule). **C1 must call `seed()` from the
run-start path.**

### Agent file frontmatter (`.rafu/agents/*.md`)

Recognized keys: `name`, `provider`, `model`, `autonomy`,
`handoffArtifact`; the Markdown body after the frontmatter becomes
`promptBody`.

- Unknown **scalar** keys are ignored.
- Foreign **list-valued** keys (e.g. another tool's `tags:` block) are
  skipped rather than treated as fatal — these files are meant to be
  shared with other tooling.
- `autonomy` defaults to `.readOnly` on **missing OR unparseable** input.
  This is least privilege by construction: a typo can never yield write
  access.

### Workflow file grammar (`.rafu/workflows/*.md`) — binding on C5/C6

```
- <agentName> [<- artifact[, artifact…]] [[gate]]
```

i.e. a list item naming an agent, then an optional `<- artifact, artifact`
input clause, then an optional literal `[gate]` marker.

**Why `[gate]` and not `!gate`:** `!` is YAML's tag indicator, and ADR 0018
commits these files to being readable by other tooling. A bare `!gate`
would either break or be reinterpreted by any YAML-aware reader.

If a `[gate]` token or a `<-` survives inside a parsed agent name, the
parser throws `malformedStep(line:)` rather than producing a bogus agent
name. A bogus name would otherwise fail much later, at run time, with a
far worse diagnostic.

### Pipeline directory layout (`.rafu/runs/<id>/steps/<NN>-<slug>-a<N>/`) — C5 pipelines

When a workflow executes, each step's evidence lives under a directory keyed by step index, sanitized agent name, and attempt number:

```
.rafu/runs/<id>/
  steps/
    00-advisor-a0/
      prompt.md
      handoff/
        ...
      logs/
        ...
    01-implementor-a0/
      prompt.md
      handoff/
        ...
      logs/
        ...
    01-implementor-a1/    # First retry uses -a1
      prompt.md
      handoff/
        ...
      logs/
        ...
```

**Slug sanitizer:** agent names are lowercased and truncated to alphanumeric + hyphens (e.g., `Claude Code` → `claude-code`). Uppercase, special characters, and spaces become hyphens or are stripped. A step's slug is stable across retries in the same run (only the `-a<N>` suffix changes).

**Attempt numbering:** `-a0` for first execution, `-a1` for first retry, `-a2` for second retry, etc. Retry never mutates prior evidence; each attempt gets its own directory.

### Run manifest optional fields (C5 pipelines) — backward-compatible decode

The manifest schema adds three optional fields, all with decode-compatible defaults:

```json
{
  "steps": [
    {
      "index": 0,
      "agent": "advisor",
      "status": {"state": "completed"},
      "attempt": 0,           // NEW: attempt number (default 0)
      "evidencePath": "steps/00-advisor-a0",  // NEW: step directory path relative to run root
      "gate": {               // NEW: if present, indicates a gate after this step
        "kind": "step",       // "step" or "merge"
        "stepIndex": 0        // which step (for "step" kind; omitted for "merge")
      }
    }
  ]
}
```

**Backward compatibility:** pre-C5 manifests omit `attempt`, `evidencePath`, and `gate`. A C5 reader decodes these as missing and infers:
- `attempt = 0` (first execution).
- `evidencePath = "<step-slug>-a0"` (derived from step index and agent name).
- `gate = null` (no gate).

A C5 manifest read by C1 or earlier silently ignores these fields because they are at the optional tail of each step object.

### Run manifest encoding (`.rafu/runs/<id>/manifest.json`)

`RunStepStatus` is persisted through a **hand-written envelope**:

```json
{ "state": "failed", "message": "…" }
```

(`message` present only for `.failed`) — deliberately **not** the
compiler-synthesized associated-value shape
(`{"failed":{"_0":…}}`), because `.rafu/runs/` is a public, committable
contract and the synthesized shape is an implementation detail that would
change under the user's feet.

**Decoding an unrecognized `state` THROWS.** This is deliberately the
opposite of `WorkspaceNavigatorMode`'s tolerant decode. The rationale: a UI
preference should degrade gracefully because guessing costs the user
nothing, but run manifests are the **merge gate's evidence**. A fabricated
or silently-defaulted status is strictly worse than an honest "unreadable
run".

Manifests use ISO-8601 dates and `[.sortedKeys, .prettyPrinted]` so
committed runs produce stable, reviewable diffs.

Run ids are validated as path components against a conservative alphabet.
A leading `.` is rejected because `listRunIDs` skips hidden files — an id
that cannot be listed back is not a valid id.

### The invocation contract

`invocation(...)` takes **both** `runDirectory` (the run root
`.rafu/runs/<id>/`) and `handoffDirectory` (where this step writes).
Neither is derived from the other.

This changed during C0 review. An earlier design derived the run root by
walking to the handoff directory's parent. For a single-role run that
resolves `RAFU_RUN_DIR` to the **shared `.rafu/runs/` root**, which would
let a write-enabled agent clobber every other run's evidence — with no
error, no failing test, and no log line. Passing both explicitly converts
a silent wrong value into a compile-time requirement on every adapter.

**Environment variables passed to the child:**

- `RAFU_RUN_DIR` — always the run root (`.rafu/runs/<id>/`), regardless of whether the step is single-role or multi-step.
- `RAFU_HANDOFF` — the step's own handoff directory (e.g., `.rafu/runs/<id>/steps/00-advisor-a0/handoff/` for a pipeline step, or `.rafu/runs/<id>/handoff/` for a single-role run).

Both are always passed; in C1's single-role context they happen to be the same run root, but the distinction enables C5 pipelines to use a shared worktree while each step reads/writes within its own step directory.

## Why it matters

C1–C7 fan out into isolated worktrees and cannot see the C0 review. Each
rule above has a plausible-looking alternative that is wrong in a way that
only shows up much later: auto-seeding writes into a user repo, tolerant
status decoding fabricates merge-gate evidence, a `!gate` marker breaks
third-party YAML readers, and a derived run root silently widens an
agent's write scope.

## Reproduction or evidence

- C0 gates with these contracts and their tests in place: `swift build`
  exit 0 with no warnings attributable to a C0 file; `swift test` 1362
  tests in 60 suites, exit 0 (baseline before C0 was 1294 ⇒ +68);
  `swift test --no-parallel` 1362 tests, exit 0; `./script/format.sh
  --lint` exit 0.
- Tests live under `Tests/RafuAppTests/Conductor/` (11 files) covering
  frontmatter tolerance, autonomy least-privilege defaulting, workflow
  grammar including `malformedStep`, manifest round-trip and strict status
  decode, and `.rafu/` seeding idempotence.

## Verification

```bash
swift build
swift test
swift test --no-parallel
./script/format.sh --lint

rg -n "@unchecked Sendable" Sources/RafuApp/Conductor   # expect 0 hits
rg -n "print\(|Logger|os_log" Sources/RafuApp/Conductor # expect 0 hits
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/RafuDotDirectory.swift`,
  `ConductorAgentFileParser.swift`, `ConductorWorkflowFileParser.swift`,
  `ConductorRunStore.swift`, `ConductorCore.swift`
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md)
  — the process/environment side of the same invocation contract
- [`../decisions/0018-conductor-external-agent-orchestration.md`](../decisions/0018-conductor-external-agent-orchestration.md)
- [`../plans/phases/conductor/C0-shim.md`](../plans/phases/conductor/C0-shim.md)
