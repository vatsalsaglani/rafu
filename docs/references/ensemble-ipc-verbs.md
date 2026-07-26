# Ensemble IPC verbs

- **Applies to:** `rafu ensemble run|status|artifact|await|abort|note|grant|propose-merge`,
  their shared DTOs, app request service, event stream, state projection,
  capability enforcement, and exit codes
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26 (updated
  C8-04: `--plan-gate`, `propose-merge`, `proposes:` artifact schema)

## Rule or observed behavior

Verb version 1 is an observation and capability-scoped mutation surface for
runs in an already-open local Rafu workspace:

```text
rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
rafu ensemble artifact <run> <step> [--json]
rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
rafu ensemble run <workflow> [--role <name>=<cli>[:<model>]] [--prompt <text>]
  [--artifact <path>]... [--base <ref>] [--label <text>] [--plan-gate] [--json]
rafu ensemble abort <run>
rafu ensemble note <run> <text>
rafu ensemble grant [--json]
rafu ensemble propose-merge <run>... [--message <text>] [--json]
rafu ensemble --help | help
```

`LauncherIPCProtocol.ensembleVerbVersion` is `1`, independent of launcher
`wireVersion` and `protocolVersion`, which also remain `1`. Additive optional
DTO fields do not advance the launcher protocol version. A breaking frame,
envelope, or verb-semantics change must advance its corresponding version
deliberately.

The bare first positional `ensemble` is reserved only when no `./ensemble`
filesystem entry exists. A collision exits 64 and names `rafu ./ensemble`;
that explicit path continues through the workspace launcher. Parsing completes
before socket access. The read-only verbs never start an agent, create a
worktree, or write repository state. The five mutating verbs require the live
coordinator capability; no verb approves a gate or merges — `propose-merge`
only re-raises the human merge gate a coordinator's run already reached; a
plan gate (below) is never remotely or programmatically approvable at all,
only through the human's own Approve/Request Changes verbs in Rafu.

### Verb semantics

- `status` returns every run in the matched workspace, or only the supplied
  run IDs. `--tree` orders a coordinator before descendants linked by
  `startedBy`; the wire result still uses one flat `runs` array and reports
  `"tree": true`. `--since N` appends retained events whose cursor is greater
  than `N`.
- `artifact` validates one run ID and zero-based step index and returns the
  absolute handoff artifact path derived from
  `.rafu/runs/<run>/[<evidencePath>/]handoff/<handoffArtifact>`. A missing run
  or step is exit 65.
- `await` subscribes first, receives the subscription acknowledgement, takes a
  one-shot `status` snapshot on the normal two-connection request path, and
  then consumes pushed events. This order closes the snapshot/subscription
  lost-wakeup window. Every named run must enter any requested state unless
  `--any` is present. A snapshot that already satisfies the condition exits
  immediately.

Workspace selection normalizes symlinks and path components, selects the
deepest open workspace containing the CLI working directory, then prefers the
key window and registry order for a tie. No open match is exit 69. Status
combines persisted manifests with the matching session's live workflow
controller state; it never scans repositories or manifests behind a closed
workspace.

### Request DTO and frame examples

Every transport message has the nine-byte RAFU header (`RAFU`, wire byte `1`,
four-byte big-endian body length). This is a real `ensembleStatus` request JSON
body; absent optional fields are omitted:

```json
{
  "ensemble": {
    "any": false,
    "runIDs": ["run-a"],
    "sinceCursor": 41,
    "states": [],
    "tree": true,
    "verb": "status",
    "workingDirectory": "/Users/me/project"
  },
  "kind": "ensembleStatus",
  "protocolVersion": 1,
  "requestID": "5CB66108-6E20-4B88-A620-7C47692B4CD5",
  "wireVersion": 1
}
```

The flat `EnsembleRequestPayload` fields are:

| Field | Type | Meaning |
|---|---|---|
| `verb` | string | `status`, `artifact`, or `await` |
| `workingDirectory` | absolute path string | Workspace-selection input |
| `runIDs` | string array | Empty means all runs for `status` |
| `stepIndex` | optional integer | Zero-based; `artifact` only |
| `states` | state array | Requested terminal condition for `await` |
| `any` | boolean | Any-run rather than all-runs matching |
| `sinceCursor` | optional unsigned integer | Exclusive event cursor |
| `token` | optional string | Live coordinator capability; required by every mutating verb and omitted by read-only verbs |
| `tree` | optional boolean | Parent-before-child status ordering |

An `artifact` request payload looks like:

```json
{
  "any": false,
  "runIDs": ["run-a"],
  "states": [],
  "stepIndex": 0,
  "verb": "artifact",
  "workingDirectory": "/Users/me/project"
}
```

An `await` subscription payload looks like:

```json
{
  "any": false,
  "runIDs": ["run-a", "run-b"],
  "states": ["completed", "failed"],
  "verb": "await",
  "workingDirectory": "/Users/me/project"
}
```

It is carried by an envelope whose kind is `ensembleSubscribe`.
`ensembleStatus` and `ensembleArtifact` retain the launcher's handshake
connection followed by a separate one-request/one-response connection.
`ensembleSubscribe` uses one long-lived connection and no preliminary
handshake; the server still applies same-uid, wire, protocol, and known-kind
checks before accepting it.

### Response and event JSON

`EnsembleResponsePayload` has a stable `result` discriminator. Because it is
the associated value of `LauncherIPCResponse.ensemble`, a complete one-shot
response JSON body has the synthesized outer `ensemble._0` wrapper:

```json
{
  "ensemble": {
    "_0": {
      "result": "status",
      "status": {
        "cursor": 42,
        "events": [],
        "runs": [
          {
            "label": "Parser",
            "runID": "run-a",
            "startedBy": "coordinator",
            "state": "running",
            "steps": [
              {
                "agentName": "implementor",
                "artifacts": [
                  "/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1/handoff/report.md"
                ],
                "attempt": 1,
                "evidencePath": "/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1",
                "index": 0,
                "model": "gpt-5.6",
                "provider": "codex",
                "state": "running"
              }
            ],
            "usageLines": [],
            "workflowName": "Implement"
          }
        ],
        "tree": false,
        "verbVersion": 1
      }
    }
  }
}
```

Optional `label`, `startedBy`, `gate`, and step `evidencePath` keys are absent
when nil. A gate is:

```json
{
  "kind": "step",
  "stepIndex": 0
}
```

`prompt` is an optional additive gate-summary field; v1 does not populate it.
Artifact, subscription, and failure inner payloads are:

```json
{"artifact":{"artifacts":["/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1/handoff/report.md"],"runID":"run-a","stepIndex":0},"result":"artifact"}
```

```json
{"cursor":42,"result":"subscribed"}
```

```json
{"code":65,"message":"Ensemble run or step not found","result":"failure"}
```

The subscribed value is wrapped in `ensemble._0` as the acknowledgement frame.
Every subsequent frame body is a bare `EnsembleEvent`, not a launcher response:

```json
{
  "at": 804306000,
  "cursor": 43,
  "kind": "state",
  "label": "Parser",
  "runID": "run-a",
  "startedBy": "coordinator",
  "state": "completed"
}
```

Transport dates use Foundation's default numeric `Date` Codable representation.
Human-facing `--json` output uses ISO-8601 dates. Event `kind` is one of
`state`, `gate`, `note`, `merged`, or `heartbeat`. Optional event fields are
`state`, `stepIndex`, `note`, `label`, and `startedBy`. Heartbeats carry an
empty `runID`, kind `heartbeat`, a cursor, and a date; they never contain
prompt, artifact, diff, output, credential, or token content.

The event center assigns monotonically increasing process-local cursors,
retains 512 events, and buffers the newest 64 values independently per
subscriber. It emits a heartbeat every 15 seconds while subscribed. The
client abandons a connection after 45 seconds without a complete frame and
exits 69. `--timeout` uses a separate monotonic client deadline and exits 75.
The server caps all live connections at 24, streams at 16, and disconnects a
writer blocked for five seconds.

### Run states and projection

The stable wire enum is:

```text
pending
running
awaitingGate
awaitingPlanGate
awaitingMergeGate
completed
failed
aborted
interrupted
merged
```

`awaitingPlanGate` was reserved in verb version 1 for a later C8 phase to emit
without changing the wire type. C8-04 is that phase: `run --plan-gate` parks a
fully-validated run at a human plan gate (`ConductorRunManifest.Gate.Kind
.plan`) before anything spawns, and the projection now derives
`awaitingPlanGate` from it. Run projection uses the first matching row:

| Priority | Emitted state | Manifest or live condition |
|---:|---|---|
| 1 | `merged` | `manifest.mergedAt != nil` |
| 2 | `interrupted` | Any step is `interrupted` |
| 3 | `failed` | Any step failed, or live workflow state is failed |
| 4 | `aborted` | Any step aborted, or live workflow state is aborted |
| 5 | `awaitingPlanGate` | Manifest plan gate, or live `.awaitingPlanGate` |
| 6 | `awaitingMergeGate` | Manifest merge gate, or live merge gate |
| 7 | `awaitingGate` | Manifest step gate, awaiting-gate step, or live step gate |
| 8 | `running` | Running step, or live preparing/running/artifact-wait state |
| 9 | `pending` | No steps, a pending step, or live idle |
| 10 | `completed` | None of the higher-priority conditions applies |

A parked plan gate is never simultaneously "running" or "awaiting" a
step/merge gate — nothing has spawned yet — so it sits directly below the
terminal failure/abort rows and above every other in-flight reading. A parked
plan gate also counts as in-flight for `ConductorEnsembleTokenStore`'s
concurrent-run enforcement (it is in `inFlightRunIDs`): a coordinator that
parks `maxConcurrentChildRuns` plan gates self-blocks on its own grant until
it approves or declines one. This is intentional, not a bug — a parked plan
gate is real, counted work the coordinator owns.

Step summaries deliberately expose the persisted `RunStepStatus` envelope
string rather than the run-state enum.

### Exit codes

| Code | Symbol | Meaning |
|---:|---|---|
| 0 | `ok` | Condition or read succeeded |
| 64 | `usage` | Invalid grammar, collision, or malformed request |
| 65 | `dataError` | Run or step is missing/invalid |
| 69 | `unavailable` | App/workspace/stream unavailable, including three missed heartbeats |
| 75 | `tempFail` | User `--timeout` or another temporary failure |
| 77 | `noPermission` | Operation is not permitted |

An app failure preserves its supplied typed code. Unknown/unmapped remote
codes are surfaced as a data error rather than silently treated as success.

### Additive manifest fields

`ConductorRunManifest` now decodes and encodes three optional fields:
`startedBy` (coordinator run ID), `label` (human graph label), and `mergedAt`
(merge completion date). They default to nil, so pre-C8 JSON decodes unchanged.
Coordinator-started workflow runs write `startedBy` and optional `label` at
engine start; read-only status projects them without needing a token.

C8-04 adds two more additive fields, both `var … = nil` for the same
memberwise-init reason documented on `gate` in `ConductorCore.swift`:

- `ConductorRunManifest.Gate.Kind` gains `case plan` alongside `step`/`merge`.
- `ConductorRunManifest.Step.proposals: [String]?` — trimmed, non-empty lines
  parsed from that step's completed handoff artifact's `proposes:`
  frontmatter list, `nil` when the artifact declared none, a scalar one, or
  could not be read. See "The `proposes:` artifact schema" below.

### The `proposes:` artifact schema

After a step's handoff artifact is confirmed present, `ConductorWorkflow
Controller.stepDidComplete(_:)` re-reads it (bounded to the same 1 MiB cap
as every other Conductor file read) and scans its frontmatter — the same
tiny, dependency-free grammar `ConductorFrontmatter` already uses for
`.rafu/agents|workflows/*.md` — for a LIST-valued `proposes:` key:

```markdown
---
proposes:
  - Add a retry policy to the upload step
  - Document the new --dry-run flag
---
Report body an agent CLI wrote as its handoff artifact.
```

Rules, all enforced by `ConductorStepProposalsParser` and never thrown:

- No frontmatter at all, no `proposes:` key, or a SCALAR `proposes: value`
  (not the list shape) ⇒ `nil`.
- Each entry is trimmed and unquoted; blank entries are dropped.
- Each entry is bounded to 200 characters.
- The list is capped at 16 entries; an over-cap list keeps the first 15 and
  appends a 16th literal entry, `"… (truncated)"`.
- A malformed, oversize, or non-UTF-8 artifact parses to `nil` and NEVER
  fails the step — proposals are advisory, not evidence.

`ConductorGraphModel` renders each entry in `Step.proposals` as one ghost
node (`ConductorGraphNode.Kind.proposedGhost`, edged from its producing
step, `EnsembleGraphState.pending`, no verbs in v1 — admission is the
coordinator's own subsequent `run` decision, not something clicked here).

## Why it matters

Coordinators need a deterministic, scriptable observation boundary without
embedding an agent or granting mutation authority. Subscribe-before-snapshot
prevents a run transition from disappearing between polling calls. Bounded
ring, subscriber, connection, and socket-write limits keep one abandoned CLI
from growing app memory or blocking other work. A versioned DTO and explicit
state precedence let later graph/plan phases add behavior without changing the
meaning of existing responses.

## Reproduction or evidence

`EnsembleArgumentParserTests` exercises the full grammar and strict path
collision. `EnsembleFramingTests` round-trips every request, response, and
event shape and proves additive unknown-field tolerance. Socketpair-backed
`EnsembleClientStreamTests` proves the subscribe/ack/snapshot/event ordering,
heartbeats, missed-heartbeat exit 69, user-timeout exit 75, and that a peer
cannot extend liveness by trickling an incomplete frame.

App tests use real `WorkspaceSession` and manifest fixtures to prove every
state-precedence row, root routing, tree ordering, event replay, and artifact
resolution. Event-center tests prove the 512/64 bounds without fixed sleeps.
Server tests prove uid-before-read, separate framed events, typed stream-cap
failure, and stream shutdown. Additive manifest tests decode a pre-C8 fixture
and round-trip all three fields.
`EnsembleEndToEndTests` starts the real server on a temporary Unix socket and
drives all three verbs from `EnsembleCommandRunner` through authentication,
routing, snapshot/event delivery, response framing, and listener shutdown; a
C8-04 case adds `propose-merge` to that same real socket/server/service path.

`PlanGateTests` proves the plan-gate FSM headlessly with `WorkflowFakeLauncher`:
zero-launch parking (plus the worktree path not existing on disk), approve-time
re-parse honoring a hand-edit made between park and approve, a parse failure
keeping the park and setting `planGateIssue`, decline aborting with a bounded
note, `approveGate()` forwarding, and a real `WorkspaceSession`/
`TerminalAttentionCenter` proving a plan gate is structurally unreachable
through the remote-approval path. `ProposeMergeTests` proves the token/
ownership/state matrix, that an accepted call posts a note and re-raises the
gate event without ever applying anything, and that `applyToWorkspace()`
stamps `mergedAt` and streams a `merged` event for BOTH controllers — including
through a live `AsyncStream` subscriber, the same mechanism `await --state
merged` depends on. `ConductorStepProposalsParserTests` and
`ConductorStepCompletionProposalsTests` cover the `proposes:` grammar and its
malformed-artifact-never-fails-the-step guarantee; `GraphModelTests` covers
ghost-node rendering and the 16-entry cap.

## Verification

```bash
swift build
swift test --filter RafuCoreTests.Ensemble
swift test --filter RafuAppTests.Ensemble
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
rg -n "@unchecked Sendable" Sources/
rg -n "print\\(|Logger|os_log" Sources/RafuApp/Conductor/Ensemble
rg -n "print\\(|Logger|os_log" Sources/RafuApp/Conductor/ConductorStepProposalsParser.swift
```

## Related code, ADRs, and phases

- `Sources/RafuCore/Ensemble/`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift`
- `Sources/RafuCLI/main.swift`
- `Sources/RafuApp/Conductor/Ensemble/`
- `Sources/RafuApp/Conductor/ConductorCore.swift`
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift`
- `Tests/RafuCoreTests/Ensemble*`
- `Tests/RafuAppTests/Conductor/Ensemble*`
- `Tests/RafuAppTests/Conductor/PlanGateTests.swift`
- `Tests/RafuAppTests/Conductor/ProposeMergeTests.swift`
- `Tests/RafuAppTests/Conductor/ConductorStepProposalsParserTests.swift`
- `Sources/RafuApp/Conductor/ConductorStepProposalsParser.swift`
- [`cli-app-ipc.md`](cli-app-ipc.md)
- [`launcher-cli.md`](launcher-cli.md)
- [`conductor-file-contracts.md`](conductor-file-contracts.md)
- [`conductor-pipeline-engine.md`](conductor-pipeline-engine.md) — plan-gate FSM
- [`C8-02-ipc-streaming-and-readonly-verbs.md`](../plans/phases/conductor/C8-02-ipc-streaming-and-readonly-verbs.md)
- [`C8-04-plan-gate-and-propose-merge.md`](../plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md)
- [ADR 0009](../decisions/0009-local-cli-app-ipc.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md) and its amendment

## Capability-scoped mutating verbs

The mutating envelope kinds are `ensembleRun`, `ensembleAbort`,
`ensembleNote`, `ensembleGrant`, and `ensembleProposeMerge`. They retain the
normal launcher handshake followed by one request/response connection. Every
request carries the process-local capability in `EnsembleRequestPayload
.token`. The server validates it before loading definitions, resolving a
run, or writing a note. The value is never returned in a response or error.

Additional request fields are:

| Field | Type | Verb and meaning |
|---|---|---|
| `workflow` | optional string | `run`; required workflow stem or declared name |
| `roleOverrides` | optional array | `run`; `{name, provider, model?}` bindings |
| `prompt` | optional string | `run`; task prompt, defaulting to workflow name |
| `artifacts` | optional string array | `run`; absolute file references, never file content |
| `baseReference` | optional string | `run`; Git ref, default `HEAD` |
| `label` | optional string | `run`; human graph label |
| `planGate` | optional boolean | `run`; park at a human plan gate instead of launching step 0 |
| `text` | optional string | `note`; nonempty text bounded to 1000 characters. Also reused by `propose-merge` for its optional `--message` |

`run` resolves the file-backed workflow and roles, applies overrides, checks
the token grant against the resolved providers, and starts the workflow
through the window's concurrent-run coordinator. Input artifact paths are
normalized by the CLI and added by reference to the first role prompt.
Worker process environments remain the three-key `PATH`, `RAFU_HANDOFF`,
`RAFU_RUN_DIR` contract; the coordinator capability is never copied into a
worker.

`run --plan-gate` (`planGate: true`) skips materializing a worktree and
launching step 0: the request service resolves and validates the whole
request exactly as a normal `run` would (including every adapter-version
probe), publishes the manifest with `gate: {kind: "plan", stepIndex: 0}` and
every step `.pending`, and returns `EnsembleRunStartResult` with `state:
"awaitingPlanGate"`. Nothing runs behind a plan gate: no worktree, no agent
process, no evidence directory. The human approves it in Rafu — which
RE-READS and re-parses the workflow/agent files at that moment, so a
hand-edit made at the gate wins over the parked parse; a parse failure at
that point keeps the run parked and surfaces the issue, never a silent
fallback to the stale parse — or declines it with a note, which aborts the
run without starting anything. Both verbs are exclusively reachable through
the human's own UI actions; no CLI verb approves or declines a plan gate, and
it is never remotely approvable the way a `[gate:remote]` step gate can be.

Successful `run --json` output is the `EnsembleRunStartResult` itself:

```json
{
  "branch": "rafu/run-run-a",
  "runID": "run-a",
  "startedBy": "co-a1b2c3d4",
  "state": "running",
  "workflow": "Ship",
  "worktree": "/Users/me/.rafu-worktrees/project-run-a"
}
```

The framed response wraps the same object as:

```json
{"result":"runStarted","runStarted":{"branch":"rafu/run-run-a","runID":"run-a","startedBy":"co-a1b2c3d4","state":"running","workflow":"Ship","worktree":"/Users/me/.rafu-worktrees/project-run-a"}}
```

`abort` and `note` require the token coordinator to match the target
manifest's `startedBy`. `abort` parks the live workflow without deleting its
evidence or worktree. `note` appends `{at,from,text}` as one bounded JSON line
under `.rafu/runs/<id>/notes.jsonl` and publishes a `note` event. Their
success envelope uses `result: "mutation"`:

```json
{"mutation":{"runID":"run-a","state":"aborted","verb":"aborted"},"result":"mutation"}
```

`grant` reports only the caller's own counts and limits. Its JSON result shape
is:

```json
{
  "activeChildRuns": 1,
  "allowedProviders": ["codex"],
  "maxConcurrentChildRuns": 3,
  "maxTotalChildRuns": 12,
  "startedChildRuns": 2,
  "usageCeilingPercentPoints": 10,
  "usageConsumedPercentPoints": 4.5
}
```

`deadline`, `usageCeilingPercentPoints`, and
`usageConsumedPercentPoints` are omitted by Codable when nil. An unresolved
meter is represented by absent usage consumed data and never guessed as zero.

Authorization failures are exit 77: missing/revoked token, provider outside
the allow-list, or a coordinator attempting to abort/note another
coordinator's run. Capacity failures are exit 75: grant concurrent/total
limit, deadline, metered usage ceiling, the tighter per-window run cap, or a
full 256 KiB notes file. A 75 response is returned before another child
continues; the coordinator must park and request a new grant rather than
retrying silently. Usage grammar remains 64 and invalid definitions or run
identity remain 65.

### `propose-merge`

`propose-merge <run>... [--message <text>] [--json]` is token-scoped and
**never applies, commits, or merges anything** — applying stays the human's
`applyToWorkspace()` verb in Rafu's own UI. It re-raises the human merge gate
for one or more runs a coordinator started, so the human notices a diff that
has been sitting parked, and optionally attaches a note.

The server validates EVERY named run before mutating or raising attention for
ANY of them (all-or-nothing):

1. The token must be valid (77 `noPermission` otherwise).
2. `runIDs` must be non-empty (64 `usage` otherwise).
3. `--message`, if present, must be at most 1000 characters (64 `usage`
   otherwise — the same bound `note` enforces).
4. Every run ID must exist (65 `dataError` otherwise, "Ensemble run not
   found").
5. Every run's `startedBy` must equal the token's coordinator (77
   `noPermission` otherwise, "This coordinator does not own that run" — an
   unowned or user-started run is refused identically).
6. Every run's PROJECTED state must be `awaitingMergeGate` (65 `dataError`
   otherwise, naming the actual state: `"<run> is <state>, not awaiting a
   merge gate"`).

Only once every named run passes all six checks does the server act, for
each: append the optional message as a note (skipped when absent or empty,
identical persistence/event path to `note`) and re-raise gate attention
through `WorkspaceSession.raiseConductorGateAttention` — the SAME seam a live
pipeline reaching its merge gate uses, so HUD/notification arbitration (ADR
0016) and the "never remotely approvable" rule apply identically; a
`propose-merge`-raised merge gate offers exactly the same UI verbs
(Open Diff / Apply / Discard) a freshly-reached one does, never an
auto-approve.

A successful response is:

```json
{"proposeMerge":{"accepted":["run-a"],"state":"awaiting_human"},"result":"proposeMerge"}
```

`state` is a LITERAL `"awaiting_human"` string — it matches the shipped
coordinator skill's text (`ensemble-with-rafu/references/verbs.md`)
verbatim and is deliberately NOT a member of `EnsembleRunState`: it is a verb
acknowledgement, not a run state. The run's own projected state is unchanged
by `propose-merge` and stays `awaitingMergeGate` (or whatever it already was)
in every subsequent `status`/event.
