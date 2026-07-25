# C8-02 — `rafu ensemble` grammar, streaming IPC, read-only verbs

- **Status:** Implemented on `conductor/c8-02-ipc-streaming`; live
  workspace-session resolution requires the shared-registry handoff recorded
  in the phase-agent report.
  Wave 1 — runs parallel with C8-01 (docs-only; no path overlap).
- **Trust note:** this plan ships ZERO mutating capability. `status`,
  `artifact`, `await` observe; nothing spawns, writes, or merges. That is
  why it may land before the ADR amendment merges.

## Goal

Add the `rafu ensemble` subcommand namespace with strict path-collision
handling, the shared Ensemble DTOs in RafuCore, three read-only verbs
(`status`, `artifact`, `await`), and the **streaming** transport: a
long-lived subscription connection on the existing ADR 0009 socket that
pushes framed events (heartbeat included) from a new app-side event
center. Also add the three additive manifest fields later plans build on
(`startedBy`, `label`, `mergedAt`).

## Read first

`AGENTS.md`; `docs/plans/phases/conductor/README.md` (ground rules,
preflight, gates); `C8-execution-plan.md` (locked decisions 1–3, 5);
`C8-cli-and-skill-spec.md` §1 (grammar, verbs, exit codes);
`docs/references/cli-app-ipc.md` (framing, fd ownership, uid check, the
SIGPIPE-in-tests section — you WILL hit it); `docs/references/launcher-cli.md`
(parse-before-socket rule); `docs/references/nonisolated-extension-isolation-trap.md`;
project skills per `docs/references/skill-routing.md`
(`swift-concurrency-pro` is mandatory for the streaming server work).

## Owned paths

- NEW `Sources/RafuCore/Ensemble/` (all files below)
- `Sources/RafuCore/Launcher/LauncherInvocation.swift`, `LauncherHelp.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift`
- `Sources/RafuCLI/main.swift`
- NEW `Sources/RafuApp/Conductor/Ensemble/` (event center + request service)
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift` (streaming + log names)
- `Sources/RafuApp/Launcher/LauncherRequestRouter.swift` (one forwarding branch)
- `Sources/RafuApp/Conductor/ConductorCore.swift` (three additive fields ONLY)
- `Sources/RafuApp/Conductor/Run/ConductorRunController.swift` (event hook in
  `publish(_:)` and the two direct saves in `start`)
- `Sources/RafuApp/Models/WorkspaceSession.swift` (ONE line in
  `raiseConductorGateAttention` posting the gate event)
- NEW tests: `Tests/RafuCoreTests/Ensemble*`, `Tests/RafuAppTests/Conductor/Ensemble*`
- `docs/references/{cli-app-ipc.md,launcher-cli.md}` updates + NEW
  `docs/references/ensemble-ipc-verbs.md`; this plan's status line.

**Forbidden:** `Package.swift` (path-based targets pick up new dirs
automatically — verify, do not edit), `LauncherArgumentParser.swift`
(route around it in `main.swift`), adapters, workflow/run engine beyond
the named hooks, all Views, Settings, `RafuAppCommands`, palette.

## Design contract (build exactly this)

### CLI grammar and collision rule

In `Sources/RafuCLI/main.swift`, BEFORE `LauncherArgumentParser.parse`:
if `CommandLine.arguments[1] == "ensemble"`:

- If `FileManager.default.fileExists(atPath: "./ensemble")` → print the
  strict-collision error naming `rafu ./ensemble`, exit 64. (Pure logic in
  `EnsembleSubcommandGate.classify(firstArgument:hasFilesystemEntry:)` so
  it is unit-testable.)
- Else parse the remainder with `EnsembleArgumentParser` and dispatch via
  `EnsembleCommandRunner`. Everything else falls through to the existing
  parser untouched (`rafu ./ensemble` keeps opening a workspace).

Verbs this plan ships (flags per `C8-cli-and-skill-spec.md` §1.3):

```
rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
rafu ensemble artifact <run> <step> [--json]
rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
rafu ensemble --help | help
```

Parse and validate the ENTIRE invocation before any socket use
(`launcher-cli.md` rule; option values must not consume option tokens —
mirror `LauncherArgumentParser`'s guards). Unknown verb → 64. `--state`
takes one of the `EnsembleRunState` raw values below; invalid → 64.

### RafuCore new files (`Sources/RafuCore/Ensemble/`)

1. **`EnsembleExitCode.swift`** — `public enum EnsembleExitCode: Int32`:
   `ok=0, usage=64, dataError=65, unavailable=69, tempFail=75, noPermission=77`
   with a one-line `meaning` string each.
2. **`EnsembleModels.swift`** — all `Codable, Hashable, Sendable`:
   - `EnsembleRunState: String` — `pending, running, awaitingGate,
     awaitingPlanGate, awaitingMergeGate, completed, failed, aborted,
     interrupted, merged`. (Include `awaitingPlanGate`/`merged` now so the
     wire type never changes; C8-03/04 start emitting them.)
   - `EnsembleStepSummary` — `index, agentName, provider (String),
     model, state (String — the RunStepStatus envelope state), attempt,
     evidencePath?, artifacts: [String]` (absolute paths).
   - `EnsembleRunSummary` — `runID, workflowName, label?, state:
     EnsembleRunState, startedBy?, gate: EnsembleGateSummary?
     {kind: String, stepIndex: Int, prompt: String?}, steps:
     [EnsembleStepSummary], usageLines: [String]`.
   - `EnsembleStatusResult` — `runs: [EnsembleRunSummary], cursor: UInt64,
     verbVersion: Int, tree: Bool`.
   - `EnsembleArtifactResult` — `runID, stepIndex, artifacts: [String]`.
   - `EnsembleEvent` — `cursor: UInt64, at: Date, runID: String,
     kind: String` (`state|gate|note|merged|heartbeat`),
     `state: EnsembleRunState?, stepIndex: Int?, note: String?,
     label: String?, startedBy: String?`.
   - `EnsembleRequestPayload` — `verb: String, workingDirectory: String,
     runIDs: [String], stepIndex: Int?, states: [EnsembleRunState],
     any: Bool, sinceCursor: UInt64?, token: String?` (+ optional fields
     later plans add — keep it one flat struct, optionals-with-defaults,
     so adding fields never breaks decoding).
   - `EnsembleResponsePayload` — enum with custom stable Codable
     (envelope `{"result": "...", ...}`): `.status(EnsembleStatusResult)`,
     `.artifact(EnsembleArtifactResult)`, `.subscribed(cursor: UInt64)`,
     `.failure(code: Int32, message: String)`.
3. **`EnsembleArgumentParser.swift`** — pure `[String]` →
   `EnsembleInvocation` (enum: `.status/.artifact/.await/.help`), typed
   errors mirroring `LauncherArgumentError` style; plus
   `EnsembleSubcommandGate`.
4. **`EnsembleCLIClient.swift`** — reuses `LauncherIPCClient` patterns
   (own the fd, `SO_NOSIGPIPE`, timeouts): `performEnsemble(_ payload:)`
   for one-shot verbs (handshake connection, then request connection —
   existing two-connection pattern), and
   `subscribe(payload:onEvent:) throws` — opens ONE connection, sends an
   `ensembleSubscribe` envelope, reads the `.subscribed` response frame,
   then loops decoding one `EnsembleEvent` frame at a time via
   `LauncherIPCFrameDecoder`. Read timeout 45 s (3 missed 15 s
   heartbeats → treat the app as gone, throw → exit 69). `--timeout` is
   enforced client-side around the loop → exit 75.
5. **`EnsembleCommandRunner.swift`** — maps invocation → client calls →
   stdout (human or `--json`) → `EnsembleExitCode`. `await` exits 0 when
   every named run (or any, with `--any`) reaches a requested state; the
   initial `status` snapshot counts (a run already in the state satisfies
   immediately — no lost-wakeup race: subscribe FIRST, then check a
   one-shot status, then consume events).

### Protocol edits (`LauncherIPCProtocol.swift`)

- `LauncherIPCRequestKind`: add `.ensembleStatus, .ensembleArtifact,
  .ensembleSubscribe` (+ Codable switch cases; raw strings
  `"ensembleStatus"` etc.). Add `var isEnsemble: Bool` and
  `var isStreaming: Bool` (true only for `.ensembleSubscribe`).
- `LauncherIPCEnvelope`: add `public var ensemble: EnsembleRequestPayload?
  = nil` (optional-with-default ⇒ no `protocolVersion` bump, per the
  documented forward-compatibility rule).
- `LauncherIPCResponse`: add case
  `.ensemble(EnsembleResponsePayload)`.
- Add `public static let ensembleVerbVersion = 1` on
  `LauncherIPCProtocol`; include it in `EnsembleStatusResult`.

### Server streaming (`LauncherIPCServer.swift`)

Keep the existing rejection ladder exactly (uid before read, wire,
protocol, unknown kind). Then:

- Add a second seam beside `RequestHandler`:
  `typealias SubscriptionHandler = @MainActor @Sendable
  (LauncherIPCEnvelope) async -> AsyncStream<EnsembleEvent>?`
  (nil ⇒ reject). Injected in `init` like `handler`; default forwards to
  `ConductorEnsembleEventCenter.shared`.
- In `processConnection`, when `envelope.kind.isStreaming`: write the
  `.ensemble(.subscribed(cursor:))` response frame, then loop over the
  stream encoding each `EnsembleEvent` as its own RAFU frame
  (`LauncherIPCFrameEncoder`); a heartbeat event arrives from the center
  every 15 s. Exit the loop (and close, single-owner rule unchanged) on:
  stream finish, write error/`EPIPE`, task cancellation from `stop()`.
  Set `SO_SNDTIMEO` 5 s for streams; a blocked writer is disconnected
  (events are re-derivable from `status`; document this).
- Connection accounting: streaming connections register like others;
  raise `defaultMaxConnections` from 8 to **24** and add
  `defaultMaxStreamingConnections = 16` enforced at registration (excess
  streams get a typed `.failure` frame then close). `stopListening()`
  must terminate stream tasks the same way it already cancels + shuts
  down connections — verify with a test.
- `logName(for:)`: add the three kinds (labels only, never payloads).

### Router + app-side service

- `LauncherRequestRouter.handle` — FIRST branch (before the existing
  payload guard): `if envelope.kind.isEnsemble { return
  ConductorEnsembleRequestService.shared.handle(envelope) }`. (Subscribe
  never reaches the router — the server routes it to the
  SubscriptionHandler seam.)
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
  (`@MainActor final class`, `static let shared`, injectable dependencies
  struct like `LauncherRequestRouter.Dependencies`):
  - Resolve the workspace: match `payload.workingDirectory` against
    `WorkspaceWindowRegistry.shared.snapshots()` — deepest containing
    root, key-window-first (mirror `LauncherRequestRouting.matchingRoot`
    semantics; the enum is internal, reuse it directly). No match →
    `.failure(69, "workspace not open in Rafu")`.
  - `status`: for the matched session — merge
    `session.conductorRuns` manifests with live controller states
    (`session.workflowController(forRunID:)`), derive `EnsembleRunState`
    (write the mapping once here: manifest+live → the enum; interrupted >
    failed > aborted > awaiting* > running > pending > completed; a run
    with `mergedAt != nil` reports `merged`). `--tree` groups children
    under `startedBy`. `sinceCursor` appends events newer than the cursor
    from the event center's ring buffer.
  - `artifact`: validate run + step exist; return the step's
    `handoff/` artifact absolute path(s) from the manifest
    (`evidencePath` + `handoffArtifact`); missing → `.failure(65, …)`.
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleEventCenter.swift`
  (`@MainActor final class`, `static let shared`):
  - Monotonic `cursor: UInt64`; ring buffer of the last 512 events;
    `publish(_ event:)`; `subscribe() -> AsyncStream<EnsembleEvent>`
    (bounded `.bufferingNewest(64)`); a 15 s heartbeat task started while
    ≥1 subscriber exists; `eventsSince(_ cursor:)`.
  - Convenience builders: `runChanged(manifest:)` (derives state via the
    same mapping — expose the mapping as a `nonisolated static func` so
    both service and center share it), `gateReady(event:)`.

### Engine hooks (smallest possible)

- `ConductorRunController.publish(_:)` (~line 524): after enqueueing the
  write, `ConductorEnsembleEventCenter.shared.runChanged(manifest:)`.
  Also add the same call after the two direct `store.save` writes in
  `start(_:launcher:)` (~647, ~670).
- `WorkspaceSession.raiseConductorGateAttention(_:)` (~line 727): one
  added line posting `ConductorEnsembleEventCenter.shared.gateReady(...)`.

### Manifest fields (`ConductorCore.swift`, additive-only pattern)

On `ConductorRunManifest`: `public var startedBy: String? = nil`,
`public var label: String? = nil`, `public var mergedAt: Date? = nil`.
Follow the `gate`/`recoveryNote` precedent exactly (`var … ? = nil`, so
the memberwise init keeps compiling — see
`docs/references/swift-6-2-memberwise-initializer-default-property.md`).
Nothing in this plan WRITES them; C8-03/04 do.

## Tests (all headless; respect the SIGPIPE rules in `cli-app-ipc.md`)

- `Tests/RafuCoreTests/EnsembleArgumentParserTests.swift` — every verb,
  every flag, value-consumes-option guards, unknown verb/state → typed
  errors; `EnsembleSubcommandGate` collision matrix (reserved+entry →
  collision; reserved+no entry → subcommand; `./ensemble` → path).
- `Tests/RafuCoreTests/EnsembleFramingTests.swift` — payload/response/
  event round-trips; unknown-field tolerance; `.failure` carries code.
- `Tests/RafuCoreTests/EnsembleClientStreamTests.swift` — socketpair fake
  server (copy the `LauncherIPCClientTests` helpers): subscribe →
  subscribed frame → N event frames → condition met exits 0; heartbeat
  keeps the loop alive; missed heartbeats → unavailable; client timeout →
  tempFail; subscribe-then-snapshot ordering has no lost-wakeup.
- `Tests/RafuAppTests/Conductor/EnsembleEventCenterTests.swift` — cursor
  monotonicity, ring-buffer eviction at 512, `eventsSince`, bounded
  subscriber buffer drops oldest… (buffering-newest), heartbeat emission.
- `Tests/RafuAppTests/Conductor/EnsembleRequestServiceTests.swift` — real
  `WorkspaceSession` + temp workspace fixtures (pattern:
  `ConcurrentRunOwnershipTests`): status maps manifests + live state to
  `EnsembleRunState` correctly (one test per precedence rule), tree
  grouping by `startedBy`, artifact path resolution + 65 on missing,
  69 on unmatched workspace.
- `Tests/RafuAppTests/Conductor/EnsembleServerStreamTests.swift` — via
  `serveConnectionForTesting`: uid check precedes read (reuse existing
  pattern), streaming cap enforced, `stopListening` ends live streams.
- Manifest decode test in `ConductorCoreTests.swift` style: pre-C8
  manifest (no new fields) decodes; new fields round-trip.

## Gates

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel`
green; `./script/format.sh --fix` then `--lint` clean. HEADLESS ONLY.
`rg -n "@unchecked Sendable" Sources/` → 0 new hits; `rg -n
"print\(|Logger|os_log" Sources/RafuApp/Conductor/Ensemble` → 0 hits
(CLI-side printing lives in RafuCore/RafuCLI only). No token strings, no
payload logging in the server (labels only).

## Documentation deliverables (same change)

- `docs/references/cli-app-ipc.md`: new "Streaming subscriptions" section
  (frame sequence, heartbeat/timeout numbers, connection caps, slow-
  consumer disconnect, stop semantics).
- `docs/references/launcher-cli.md`: subcommand grammar, strict collision
  rule, new exit codes.
- NEW `docs/references/ensemble-ipc-verbs.md`: the complete verb
  reference — grammar, JSON shapes (real examples), exit codes, state
  enum, event schema, verb version. **C8-03/04 append to it; C8-05's
  skill mirrors it.** Follow the reference-note template (applies-to,
  verified toolchain, rule, evidence, verification, related).
- Intended `docs/references/README.md` index row goes in your report
  (you do not edit shared indexes).

## Handoff report

Delivered behavior; changed paths; verification evidence (test names +
counts); the exact `EnsembleRunState` mapping table you implemented;
remaining risks; docs updated + intended index rows; branch name; every
commit message; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-02-ipc-streaming. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → `git checkout conductor/c8-02-ipc-streaming`
if it exists, else `git checkout -b conductor/c8-02-ipc-streaming main`,
then proceed and say so in your report. Dirty tree with edits you did not
make → STOP and report.

GOAL: implement docs/plans/phases/conductor/C8-02-ipc-streaming-and-readonly-verbs.md
— the `rafu ensemble` subcommand (strict path-collision rule), the shared
Ensemble DTOs and exit codes in Sources/RafuCore/Ensemble/, the read-only
verbs status/artifact/await, the STREAMING subscription transport on the
existing uid-authenticated socket (heartbeats, bounded buffers, framed
events), the app-side event center + request service, the engine event
hooks, and the three additive manifest fields (startedBy, label,
mergedAt). The plan file is your authoritative edit list, design
contract, and test list — read it FIRST, then AGENTS.md, the conductor
README ground rules, docs/references/cli-app-ipc.md,
docs/references/launcher-cli.md, and C8-execution-plan.md. Use the
swift-concurrency-pro skill for the server streaming work.

HARD CONSTRAINTS: read-only surface only (nothing this plan ships may
spawn, write repo state, or merge); one-frame-per-connection preserved
for request/response kinds; uid check before first read, unchanged; no
payloads or tokens in logs; no @unchecked Sendable; nonisolated only on
primary type declarations; never touch Package.swift,
LauncherArgumentParser.swift, Views, Settings, or engine files beyond
the exact hooks the plan names. HEADLESS ONLY — never run
build_and_run.sh or launch Rafu.app.

DEFINITION OF DONE:
1. `rafu ensemble status|artifact|await` work end to end against a
   running app (verified headlessly through the socketpair/server test
   seams the plan lists — real-app verification happens on main).
2. `await` is push-based: subscribe first, snapshot second, no lost
   wakeup; heartbeat 15 s; client gives up after 3 missed heartbeats
   (exit 69); --timeout exits 75. All numbers as specified.
3. Strict collision: `rafu ensemble` with a local `ensemble` entry exits
   64 naming `rafu ./ensemble`; without one it is the subcommand;
   `rafu ./ensemble` still opens the workspace.
4. Every test in the plan's test list exists and passes: swift build 0
   warnings, swift test AND swift test --no-parallel green,
   format --fix + --lint clean.
5. Reference docs updated + new ensemble-ipc-verbs.md written; intended
   README.md index row in your report (never edit shared indexes).
6. Work committed locally in verified stages. Never push, never merge,
   never rebase, never checkout main. A shared-file need you discover is
   a HANDOFF (do independent work first, then report the exact file,
   line, and proposed diff) — never a silent halt with zero commits.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence (names + counts, including the no-parallel run); the
EnsembleRunState mapping table; remaining risks; docs written; branch
name; every commit message; last commit id from `git rev-parse HEAD`.
```
