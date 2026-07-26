# Ensemble IPC verbs

- **Applies to:** `rafu ensemble run|status|artifact|await|abort|note|grant`,
  their shared DTOs, app request service, event stream, state projection,
  capability enforcement, and exit codes
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26

## Rule or observed behavior

Verb version 1 is an observation and capability-scoped mutation surface for
runs in an already-open local Rafu workspace:

```text
rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
rafu ensemble artifact <run> <step> [--json]
rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
rafu ensemble run <workflow> [--role <name>=<cli>[:<model>]] [--prompt <text>]
  [--artifact <path>]... [--base <ref>] [--label <text>] [--json]
rafu ensemble abort <run>
rafu ensemble note <run> <text>
rafu ensemble grant [--json]
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
worktree, or write repository state. The four mutating verbs require the live
coordinator capability; no verb approves a gate or merges.

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

`awaitingPlanGate` is reserved in verb version 1 so later C8 phases can emit it
without changing the wire type. C8-02 does not derive it from current
manifests. Run projection uses the first matching row:

| Priority | Emitted state | Manifest or live condition |
|---:|---|---|
| 1 | `merged` | `manifest.mergedAt != nil` |
| 2 | `interrupted` | Any step is `interrupted` |
| 3 | `failed` | Any step failed, or live workflow state is failed |
| 4 | `aborted` | Any step aborted, or live workflow state is aborted |
| 5 | `awaitingMergeGate` | Manifest merge gate, or live merge gate |
| 6 | `awaitingGate` | Manifest step gate, awaiting-gate step, or live step gate |
| 7 | `running` | Running step, or live preparing/running/artifact-wait state |
| 8 | `pending` | No steps, a pending step, or live idle |
| 9 | `completed` | None of the higher-priority conditions applies |

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
routing, snapshot/event delivery, response framing, and listener shutdown.

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
- [`cli-app-ipc.md`](cli-app-ipc.md)
- [`launcher-cli.md`](launcher-cli.md)
- [`conductor-file-contracts.md`](conductor-file-contracts.md)
- [`C8-02-ipc-streaming-and-readonly-verbs.md`](../plans/phases/conductor/C8-02-ipc-streaming-and-readonly-verbs.md)
- [ADR 0009](../decisions/0009-local-cli-app-ipc.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)

## Capability-scoped mutating verbs

The mutating envelope kinds are `ensembleRun`, `ensembleAbort`,
`ensembleNote`, and `ensembleGrant`. They retain the normal launcher handshake
followed by one request/response connection. Every request carries the
process-local capability in `EnsembleRequestPayload.token`. The server
validates it before loading definitions, resolving a run, or writing a note.
The value is never returned in a response or error.

Additional request fields are:

| Field | Type | Verb and meaning |
|---|---|---|
| `workflow` | optional string | `run`; required workflow stem or declared name |
| `roleOverrides` | optional array | `run`; `{name, provider, model?}` bindings |
| `prompt` | optional string | `run`; task prompt, defaulting to workflow name |
| `artifacts` | optional string array | `run`; absolute file references, never file content |
| `baseReference` | optional string | `run`; Git ref, default `HEAD` |
| `label` | optional string | `run`; human graph label |
| `text` | optional string | `note`; nonempty text bounded to 1000 characters |

`run` resolves the file-backed workflow and roles, applies overrides, checks
the token grant against the resolved providers, and starts the workflow
through the window's concurrent-run coordinator. Input artifact paths are
normalized by the CLI and added by reference to the first role prompt.
Worker process environments remain the three-key `PATH`, `RAFU_HANDOFF`,
`RAFU_RUN_DIR` contract; the coordinator capability is never copied into a
worker.

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
