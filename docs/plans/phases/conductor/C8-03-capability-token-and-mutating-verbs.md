# C8-03 — Capability token, grant, coordinator launch, mutating verbs

- **Status:** Implemented and headlessly verified on
  `conductor/c8-03-mutating-verbs` (2026-07-26).
- Wave 2 — runs parallel with C8-06. You must NOT touch
  `ConductorRunsPanelView.swift`, `RafuAppCommands.swift`,
  `CommandPaletteView.swift`, or `EditorCanvasView.swift` (C8-06 owns
  them this wave).

## Goal

Implement the consent machinery the ADR 0018 amendment defines: the
run-scoped capability token and grant store, the headless coordinator
launch API (interactive CLI in a terminal tab with `RAFU_ENSEMBLE_TOKEN`),
and the mutating verbs `run`, `abort`, `note`, plus token-scoped `grant`.
After this plan, a coordinator can actually orchestrate: spawn attributed,
capped child runs; a stray shell gets exit 77.

## Read first

`AGENTS.md`; conductor `README.md` ground rules; `C8-execution-plan.md`
(decisions 3, 4, 7); ADR 0018 **including the new Amendment**;
`C8-cli-and-skill-spec.md` §1.2–1.3; `docs/references/ensemble-ipc-verbs.md`
(C8-02's verb reference — you append to it);
`docs/references/conductor-pty-spawn-and-child-environment.md` (curated
env — the token rides the overlay, never `childEnvironment`);
`docs/references/agent-terminals.md` (AT-01's per-CLI interactive-launch
table — reuse, extend only on gaps);
`Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
and `ConductorEnsembleEventCenter.swift` (C8-02's shapes);
`swift-concurrency-pro` skill for the token store and launch path.

## Owned paths

- `Sources/RafuCore/Ensemble/` — extend parser/models/runner with the new
  verbs (`EnsembleArgumentParser.swift`, `EnsembleModels.swift`,
  `EnsembleCommandRunner.swift`, `EnsembleCLIClient.swift`)
- `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift` — add kinds
  `.ensembleRun, .ensembleAbort, .ensembleNote, .ensembleGrant` (additive)
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleGrant.swift`
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleNoteStore.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
  — handle the four new verbs
- `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` —
  write `startedBy`/`label` into the manifest at run start
- `Sources/RafuApp/Conductor/Run/ConductorRunController.swift` — same for
  single-role runs IF trivial; otherwise skip (workflow runs are the
  coordinator path) and note it
- `Sources/RafuApp/Models/WorkspaceSession.swift` — coordinator-session
  seam ONLY (see anchor below)
- `Sources/RafuApp/Views/ConductorRunDetailCanvas.swift` — a small Notes
  section (C8-06 does not touch this file)
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift` — `logName(for:)`
  rows for the four kinds (labels only)
- NEW tests `Tests/RafuAppTests/Conductor/Ensemble{Grant,Mutating,Coordinator}*`,
  extended `Tests/RafuCoreTests/EnsembleArgumentParserTests.swift`
- `docs/references/ensemble-ipc-verbs.md` (append), NEW
  `docs/references/ensemble-consent-and-token.md`; this plan's status line.

**Forbidden:** `Package.swift`, `script/`, all files C8-06 owns this wave
(listed above), Settings files, adapters, `ConductorCore.swift` (C8-02
already added the fields you need), the worker `childEnvironment`
contract (exactly three keys — a test asserts it; the token is a
coordinator-spec overlay, never a worker key).

## Design contract

### Grant + token (`ConductorEnsembleGrant.swift`)

```swift
nonisolated struct ConductorEnsembleGrant: Sendable {   // primary-decl nonisolated
    var maxConcurrentChildRuns: Int = 3
    var maxTotalChildRuns: Int = 12
    var allowedProviders: [ConductorCLIID]
    var usageCeilingPercentPoints: Double? = nil   // best-effort, C7 honesty
    var deadline: Date? = nil                      // wall-clock backstop
}
```

`@MainActor final class ConductorEnsembleTokenStore` (`static let shared`,
injectable RNG/clock for tests):

- `mint(coordinatorID:grant:) -> String` — 32 random bytes, base64url,
  stored token → `Entry {coordinatorID, grant, startedRunIDs: [String],
  mintedAt}`. **In-memory only. Never persisted, never logged, never in a
  manifest or captured output.** Dies with the app ⇒ re-grant on relaunch
  (the amendment's rule; read-only verbs still work tokenless).
- `validate(_ token: String?) -> Entry?`; `recordChildRun(token:runID:)`;
  `revoke(coordinatorID:)` (called when the coordinator session ends).
- Enforcement helper returning a typed reason: `.noToken` → 77,
  `.providerNotAllowed` → 77, `.concurrentLimit/.totalLimit/.deadline/
  .usageCeiling` → 75. Usage ceiling: sum child steps'
  `usage.providers[].windows[].percentPoints` from manifests; if metering
  resolved nothing, the ceiling simply does not trip (honest, documented).

### Coordinator launch (`ConductorCoordinatorLauncher.swift`)

`nonisolated struct ConductorCoordinatorSession: Identifiable, Sendable`
— `id` (`"co-" + 8-char lowercase suffix`), `provider: ConductorCLIID`,
`model: String?`, `goal: String`, `terminalSessionID: UUID?`,
`startedAt: Date`, `var endedAt: Date?`.

`@MainActor struct ConductorCoordinatorLauncher`:

- `start(provider:model:goal:grant:in session: WorkspaceSession) async throws
  -> ConductorCoordinatorSession`:
  1. Resolve the adapter via `ConductorRoleLaunchService.resolve` (probe;
     unavailable/unauthed → typed error surfaced to the caller — the
     C8-07 sheet disables such CLIs up front).
  2. Mint the token.
  3. Build a `TerminalProcessSpec` DIRECTLY (not the headless
     `invocation()` path — the coordinator is interactive): executable
     from the probe; arguments = the vendor's interactive-with-initial-
     prompt form where the adapter documents one, else launch bare and
     write the goal to the terminal input? **No — never synthesize
     input.** If the CLI has no prompt-argument form, launch bare; the
     goal is shown in the sheet for the user to paste. The per-CLI
     interactive-launch table already exists —
     `docs/references/agent-terminals.md` (AT-01, merged in wave 1).
     REUSE it; probe and extend it only where the coordinator path
     exposes a gap, keeping its verified/hypothesis markers.
     Environment = `RafuConductorEnvironment.curatedPath` PATH +
     `RAFU_ENSEMBLE_TOKEN` (+ nothing else new). cwd = workspace root
     (checkout — amendment decision 4). `roleBadge` "Coordinator",
     `resourceAttribution` "coordinator • <Vendor>". No `outputLogURL`
     in v1 (no run dir — the coordinator is not manifest-backed).
  4. `session.terminal.newSession(spec:)` + reveal, register the session
     in the WorkspaceSession seam, hook exit → `endedAt` + revoke token +
     event (`kind: "state"`, coordinator id, `state: completed`).
- WorkspaceSession anchor: add
  `private(set) var conductorCoordinatorSessions: [ConductorCoordinatorSession]`
  plus `func registerCoordinatorSession(_:)` / `func
  coordinatorSessionDidEnd(_ id: String)` **immediately after
  `canStartConductorWorkflowRun` (~line 314)** — nowhere else in the
  file. C8-06 reads this property for the graph root node (it tolerates
  the property being absent at its build time via its own wave-2
  parallelism note — you two merge serially, coordinator resolves
  trivial adjacency).

### Verbs (server side, in `ConductorEnsembleRequestService`)

All four require `validate(token)` EXCEPT none — all four REQUIRE it
(`grant` too: it reports the caller's own grant). Failure → typed
`.failure(77|75, reason)`; the reason string must not echo the token.

- **`run <workflow> [--role name=cli[:model]] [--prompt <text>]
  [--artifact <path>]... [--base <ref>] [--label <text>] [--json]`**
  1. Enforce grant (provider allow-list checks the RESOLVED bindings
     after `--role` overrides; concurrent = live startedRunIDs ∩
     in-flight; total; deadline; usage ceiling).
  2. Load definitions via `ConductorDefinitionLibrary.load(workspaceRoot:
     userLibraryRoot:)`, resolve the workflow by stem/name, bind roles
     via `ConductorWorkflowBinder`, apply `--role` overrides (reuse
     `ConductorWorkflowLaunchModel`'s snapshot-into-request approach).
     Unknown workflow/agent/provider → `.failure(65, …)`.
  3. Build `ConductorWorkflowRunRequest` with `taskPrompt` from
     `--prompt` (default: the workflow name), `baseReference` from
     `--base` (default HEAD), plus NEW fields you add to the request:
     `startedBy: String?` (the coordinator id) and `label: String?`.
     Seed `--artifact` paths into the first step's prompt by reference
     (absolute paths, never content — `ConductorPromptComposer.step`
     pattern).
  4. `try await session.conductorConcurrentRuns.start(request, launcher:
     WorkspaceConductorRunLauncher(workspaceSession: session))` — the
     window cap still applies (min with grant), typed
     `ConductorConcurrentRunError` maps to `.failure(75, reason)`.
  5. `recordChildRun`; respond `.runStarted(EnsembleRunStartResult)` —
     add this case + struct (runID, workflow, worktree path, branch,
     state, startedBy) to `EnsembleResponsePayload`/models.
- **`abort <run>`** — token's coordinator must equal the run's
  `startedBy` (else 77); resolve `session.workflowController(forRunID:)`
  → `abort()`; unknown run → 65.
- **`note <run> <text>`** — bounded ≤ 1000 characters (reject 64 client-
  side AND server-side); token required; append via
  `ConductorEnsembleNoteStore`.
- **`grant`** — respond `.grant(EnsembleGrantResult)` (add case+struct:
  limits, used counts, deadline, usage consumed/ceiling or `null`s when
  unmetered) so the coordinator can size fan-out (spec: "grant matters
  more than it looks").

### Engine edit (`ConductorWorkflowController.swift`)

`ConductorWorkflowRunRequest` (~line 25): add `var startedBy: String? =
nil`, `var label: String? = nil`. In `start(_:launcher:)` where the v0
manifest is constructed (~line 380–410), copy both onto the manifest.
That is the entire engine diff; `publish` already emits the event.

### Notes (`ConductorEnsembleNoteStore.swift`)

`@concurrent` append of one JSON line `{at, from, text}` to
`.rafu/runs/<id>/notes.jsonl` (atomic append via the write-then-rename
pattern is unnecessary for an append-only log — use `FileHandle`
append with `O_APPEND` semantics; bound the file at 256 KiB, oldest run
wins — refuse with 75 when full). `read(runID:) -> [Note]`. Post a
`kind: "note"` event through the center. Notes may contain repo text ⇒
they live in `.rafu/runs/`, never in Rafu logs (ADR 0018 rule).

### Run detail canvas — Notes section

In `ConductorRunDetailCanvas.swift`, below the step timeline and above
the merge-gate section: a "Notes" subsection listing
`ConductorEnsembleNoteStore.read` results (relative timestamp + text,
plain rows, top-pinned rule respected, empty ⇒ render nothing). Loaded
in `.task(id: manifest.id)`, not in `body`.

### CLI side

Extend `EnsembleArgumentParser`/`EnsembleCommandRunner` with the four
verbs + flags above; token read from `ProcessInfo.processInfo
.environment["RAFU_ENSEMBLE_TOKEN"]` at runner level and placed into
`EnsembleRequestPayload.token`; never printed, never echoed in errors.
`--json` output for `run`/`grant` matches the spec's shapes (§1.3),
with the worktree-path reality (`.rafu-worktrees/<repo>-<id>`,
`rafu/run-<id>`) — the spec doc's `ensemble/…` branch example was
corrected by C8-01.

## Tests

- Parser: four new verbs, flag matrix, note length 64, role-override
  parsing (`name=cli:model`, `name=cli`).
- `EnsembleGrantTests`: mint/validate/revoke; no token → 77; disallowed
  provider → 77; concurrent, total, deadline, ceiling → 75; ceiling
  no-ops when unmetered; token never appears in any error string
  (assert!).
- `EnsembleMutatingVerbTests` (pattern: `ConcurrentRunOwnershipTests` +
  `FakeConductorAdapter` + temp workspace): `run` end-to-end → manifest
  carries `startedBy` + `label`, attributed in status `--tree`;
  window-cap and grant-cap interplay (grant 5, window 3 ⇒ 3); `abort`
  scoping (foreign run → 77); `note` persisted + event emitted + bounded;
  `grant` reports used counts.
- `EnsembleCoordinatorLaunchTests`: session registered, token minted,
  spec env contains token + curated PATH and NOTHING inherited; worker
  `childEnvironment` still exactly three keys (regression alongside
  `RunLifecycleTests:203`); exit → `endedAt` set + token revoked (a
  post-exit `run` gets 77).
- Manifest round-trip for `startedBy`/`label` written by the engine.

## Gates

Standard: `swift build` 0 warnings; `swift test` + `--no-parallel` green;
format `--fix`/`--lint`. HEADLESS ONLY. `rg -n "RAFU_ENSEMBLE_TOKEN"
Sources/RafuApp | rg -v Ensemble` → no leakage into logs/manifest code;
`rg -n "print\(|Logger|os_log" Sources/RafuApp/Conductor/Ensemble` → 0.

## Documentation deliverables

Append `run/abort/note/grant` (+ JSON shapes, 75/77 semantics) to
`docs/references/ensemble-ipc-verbs.md`. NEW
`docs/references/ensemble-consent-and-token.md`: token lifecycle
(mint→inject→validate→revoke; re-grant on relaunch), grant enforcement
table, a pointer to AT-01's per-CLI interactive-launch table in
`agent-terminals.md` (plus any coordinator-path extensions you made to
it), the worker-env invariance proof. Intended index rows go in your
report.

## Handoff report

Delivered behavior; changed paths; test evidence; any extensions made
to AT-01's per-CLI interactive-launch table (verified vs. hypothesis);
remaining risks; docs; branch name; commit messages;
`git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-03-mutating-verbs. Preflight: run `git status
--short --branch` ONCE. On this branch + clean tree → proceed. Detached
HEAD or wrong branch + clean tree → checkout the branch if it exists,
else `git checkout -b conductor/c8-03-mutating-verbs main`, then proceed
and say so. Dirty tree with edits you did not make → STOP. Then verify
prerequisites: Sources/RafuCore/Ensemble/EnsembleModels.swift exists AND
docs/decisions/0018-conductor-external-agent-orchestration.md contains an
"Amendment" section. If either is missing, STOP and report — C8-01/C8-02
have not merged.

GOAL: implement docs/plans/phases/conductor/C8-03-capability-token-and-mutating-verbs.md
— the ConductorEnsembleTokenStore + grant model with typed 75/77
enforcement, the interactive coordinator launch into a terminal tab with
RAFU_ENSEMBLE_TOKEN riding the curated-environment overlay, the mutating
verbs run/abort/note plus token-scoped grant on both CLI and app sides,
startedBy/label written by the workflow engine, the notes store, and the
run-detail Notes section. The plan file is your authoritative design
contract, edit list, and test list — read it FIRST, then AGENTS.md, the
conductor README ground rules, ADR 0018 WITH its Amendment,
docs/references/ensemble-ipc-verbs.md,
docs/references/conductor-pty-spawn-and-child-environment.md, and
docs/references/agent-terminals.md (AT-01's per-CLI interactive-launch
table — reuse it for the coordinator launch; extend only on gaps). Use
the swift-concurrency-pro skill for the token store and launch path.

HARD CONSTRAINTS: the token is in-memory only — never persisted, never
logged, never in a manifest, never in captured output, never echoed in
an error; worker children NEVER receive it and childEnvironment stays
exactly three keys (a test must prove both); every mutating verb without
a live token exits 77 and grant exhaustion exits 75 with the run parked,
never silently continued; argv arrays only; no @unchecked Sendable;
nonisolated on primary declarations only. DO NOT touch
ConductorRunsPanelView.swift, RafuAppCommands.swift,
CommandPaletteView.swift, EditorCanvasView.swift, Package.swift,
ConductorCore.swift, or Settings — C8-06 owns the first four this wave.
HEADLESS ONLY — never run build_and_run.sh or launch Rafu.app.

DEFINITION OF DONE:
1. A token-bearing caller can run/abort/note/grant end to end (proved
   through the request-service tests with FakeConductorAdapter); child
   manifests carry startedBy + label and appear grouped in status
   --tree.
2. A tokenless caller is refused with 77 on every mutating verb; every
   grant limit trips with 75 and a typed reason; the usage ceiling
   no-ops honestly when metering resolves nothing.
3. Coordinator launch registers a session, injects the token, reveals
   the terminal tab, and revokes on exit (post-exit run → 77).
4. All plan tests pass: swift build 0 warnings, swift test AND
   swift test --no-parallel green, format --fix + --lint clean, plus
   the leakage greps in the plan.
5. ensemble-ipc-verbs.md appended and ensemble-consent-and-token.md
   written with probed per-CLI launch evidence; intended index rows in
   the report only.
6. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff,
   after landing everything independent of them.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; any extensions made to AT-01's interactive-launch table
(verified vs hypothesis); remaining risks; docs written; branch name;
every commit message; last commit id from `git rev-parse HEAD`.
```
