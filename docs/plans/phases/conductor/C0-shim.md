# C0 — Ensemble shared shim and contracts

- **Runs:** serial, on `main` (integration-owner work; blocks every other
  conductor phase)
- **Depends on:** ADR 0018 accepted; clean tree
- **Status:** Implemented on `main` (headless gates green); staged-app GUI
  pass still outstanding — see "Exit criteria"

## Mission

Create every shared Ensemble file so C1–C7 can fan out with zero merge
conflicts. C0 ships compiling contracts, stubs, and placeholder UI — no real
adapter logic, no run execution. The contract names and file layout below are
binding on later phases; changing them after C0 merges requires a
coordinator decision, not a phase-local edit.

## Contracts (binding)

### Core types — `Sources/RafuApp/Conductor/ConductorCore.swift`

- `ConductorCLIID: String, CaseIterable, Codable, Sendable` —
  `claudeCode, codex, openCode, cline, kimi, geminiCLI, cursor`.
- `ConductorAutonomy: String, Codable, Sendable` — `readOnly`,
  `worktreeWrite`. (No "full access to the main checkout" level exists.)
- `ConductorModelChoice: Sendable, Codable` — `id: String`,
  `displayName: String`, `source: ModelSource { curated, discovered, custom }`.
- `ConductorAgentDefinition: Sendable` — parsed from `.rafu/agents/*.md`
  frontmatter: `name`, `provider: ConductorCLIID`, `model: String`,
  `autonomy: ConductorAutonomy`, `handoffArtifact: String` (relative
  filename, e.g. `brief.md`), plus `promptBody: String`.
- `ConductorWorkflowDefinition: Sendable` — parsed from
  `.rafu/workflows/*.md`: `name`, ordered `steps:
  [Step { agentName, inputArtifacts: [String], gateAfter: Bool }]`.
- `ConductorRunManifest: Codable, Sendable` — run id, workflow snapshot,
  resolved agent bindings (provider/model/adapter version), base commit,
  worktree branch name, per-step `RunStepStatus { pending, running,
  awaitingGate, completed, failed(String), aborted }`, timestamps.
- `ConductorCLIAdapter` protocol (`Sendable`):
  - `var id: ConductorCLIID { get }`
  - `func probe() async -> AdapterProbe` — binary path, version string,
    `installed: Bool`.
  - `func authStatus() async -> AdapterAuthStatus { authenticated,
    notAuthenticated(hint: String), unknown }` — presence/metadata checks
    only; NEVER reads token values.
  - `func curatedModels() -> [ConductorModelChoice]`
  - `func discoverModels() async -> [ConductorModelChoice]?` — nil when the
    CLI has no listing command.
  - `var defaultEnabled: Bool { get }` / `var supportsModelDiscovery: Bool
    { get }` — pure; Settings reads both without performing I/O.
  - `func invocation(prompt: String, model: String,
    autonomy: ConductorAutonomy, workingDirectory: URL, runDirectory: URL,
    handoffDirectory: URL) -> AdapterInvocation` — returns
    `executableURL`, `arguments: [String]`, `environment: [String: String]`
    (minimal, explicit; a superset of `RAFU_HANDOFF`, `RAFU_RUN_DIR`, and a
    curated `PATH`). `runDirectory` is the run root `.rafu/runs/<id>/` and
    `handoffDirectory` is where THIS step writes; both are passed
    explicitly and NEITHER is derived from the other, so no adapter can
    point `RAFU_RUN_DIR` at the shared `.rafu/runs/` tree.

### Registry — `Sources/RafuApp/Conductor/ConductorAdapterRegistry.swift`

Assembles all seven adapters (from `Adapters/`) plus the test-only
`FakeConductorAdapter`. Registry-driven everywhere; no view or engine ever
switches on `ConductorCLIID` directly.

### File layout created by C0

```
Sources/RafuApp/Conductor/
  ConductorCore.swift
  ConductorAdapterRegistry.swift
  ConductorAgentFileParser.swift        // frontmatter Markdown parser
  ConductorWorkflowFileParser.swift
  RafuDotDirectory.swift                // .rafu/ conventions + gitignore seeding
  ConductorRunStore.swift               // read/write .rafu/runs/<id>/manifest.json
  Adapters/
    ClaudeCodeAdapter.swift             // stub — C2 owns
    CodexAdapter.swift                  // stub — C2 owns
    OpenCodeAdapter.swift               // stub — C3 owns
    ClineAdapter.swift                  // stub — C3 owns
    KimiAdapter.swift                   // stub — C3 owns
    GeminiCLIAdapter.swift              // stub — C4 owns
    CursorAdapter.swift                 // stub — C4 owns
    FakeConductorAdapter.swift          // real, test-only echo adapter
  Run/
    ConductorRunController.swift        // stub seams — C1 owns
Views/ (existing dir)
  ConductorRunsPanelView.swift          // placeholder — C5 owns
  ConductorRunDetailCanvas.swift        // placeholder — C5 owns
Settings/
  ConductorSettingsTab.swift            // registry-driven rows (real in C0)
Tests/RafuAppTests/Conductor/
  ConductorCoreTests.swift              // parsers, manifest round-trip, registry
```

Stub adapters compile, report `installed: false`, and return empty curated
model lists; each carries a header comment naming its owning phase.

### Shared seams C0 lands in existing files (the ONLY such edits)

- `WorkspaceNavigatorMode`: add case `.runs` (title "Runs", SF symbol) +
  rail button + panel branch to the placeholder
  `ConductorRunsPanelView`. Decode tolerance already protects restoration.
- `WorkspaceTerminalController`: a `TerminalProcessSpec` seam — spawn an
  arbitrary executable + argv + cwd + env under the PTY instead of the login
  shell, with a role badge label. The login-shell path stays byte-identical
  in behavior; the spec path is exercised by tests only until C1.
- `RafuSettingsView`: add the `Tab("Agents", …)` hosting
  `ConductorSettingsTab`.
- `WorkspaceSession`: minimal stored stubs C1/C5 will fill
  (`conductorRuns`, `openConductorRun`), mirroring how G0 pre-landed git
  seams.

### Settings surface (real in C0)

One row per registry adapter: install status (probe), version, auth status
(delegated hint text, e.g. "run `codex login` in a terminal"), enable
toggle (UserDefaults `conductorAdapterEnabled.<id>`), default model picker
(curated list + free-text custom entry; "Refresh models" when
`discoverModels` is available). No credentials are collected anywhere — the
UI must visibly say auth belongs to each CLI.

## Owned paths

Everything listed above, plus `docs/plans/phases/conductor/README.md` status
row and this file's status line. `Package.swift` only if a new test fixture
resource demands it (avoid if possible; report if not).

## Increments

1. **Core + parsers + run store** with tests (frontmatter parsing incl.
   unknown-key tolerance; manifest round-trip; `.rafu/` seeding is
   idempotent and gitignores `runs/` by default).
2. **Registry + seven stubs + fake adapter** with tests (fake adapter echo
   invocation builds argv correctly; registry completeness test pinned to
   `ConductorCLIID.allCases`).
3. **Terminal process-spec seam** with tests (spec spawn under PTY runs
   `/bin/echo` and captures exit; login-shell regression tests untouched
   and green). Takes the `swift-concurrency-pro` review path.
4. **Navigator case + settings tab + session seams**, headless-testable
   parts only.

## Exit criteria

- All gates green (`swift build` 0 warnings, `swift test`,
  `swift test --no-parallel`, format).
- A later phase can implement a real adapter or the run engine WITHOUT
  editing any shared file — proven by the stub/seam layout above.
- Staged-app GUI pass on `main` after merge: Agents settings tab renders all
  seven rows; Runs rail button shows the placeholder panel; second window
  unaffected.

## Completion notes (2026-07-24)

### Verified gates

- `swift build`: exit 0, no warnings attributable to any C0 file.
- `swift test`: 1362 tests in 60 suites, exit 0 (baseline before C0 was
  1294 ⇒ +68).
- `swift test --no-parallel`: 1362 tests, exit 0.
- `./script/format.sh --lint`: exit 0.
- Greps under `Sources/RafuApp/Conductor`: `@unchecked Sendable` = 0; bare
  non-`nonisolated` extensions = 0; `/bin/sh|bash -c|NSTask` = 0;
  `print`/`Logger`/`os_log` = 0; credential-value reads = 0.

### Test-file ownership

The review split the per-adapter stub tests into **seven phase-owned
files** instead of one shared file. One shared adapter-stub test file would
have produced a guaranteed three-way merge conflict when C2, C3, and C4
each replaced their stubs in parallel worktrees.

`ConductorRegistryTests`, `ConductorCoreTests`, `ConductorTerminalSpecTests`,
and `ConductorSettingsTests` are **integration-owned**: a phase must not
edit them. A failure in one of these is a stop-and-report signal, not a
test to update.

### Pre-existing warning and the incremental-build trap

A full **clean** rebuild surfaces one warning:
`Sources/RafuApp/Terminal/RafuTerminalView.swift:54` `#ActorIsolatedCall`.
That file is git-clean and predates C0 — it is not attributable to this
phase.

The reusable nuance: the "`swift build` with zero warnings" gate is
**misleading on incremental builds**. An unmodified file never recompiles,
so its warnings never resurface. Any phase claiming a zero-warning build
should say whether the build was clean or incremental, and periodically
run a clean build to re-expose latent warnings.

### Deferred GUI pass (still owed)

C0 was headless-only by instruction; the following are unexercised:

1. Agents settings tab renders all seven rows with install/auth lines and
   the model picker; Settings window at its fixed frame with a sixth tab
   (overflow check).
2. The `.runs` rail SF Symbol `list.bullet.rectangle` resolves and is
   visually distinguishable from `terminal` and `doc.on.doc` at rail size —
   needs an eyeball.
3. `Tab("Agents")` `systemImage` renders correctly — unverified visually.
4. Runs rail button opens the placeholder panel; the panel header pins to
   the TOP and the empty state centres in the remaining space (the
   AGENTS.md panel-alignment rule).
5. Second workspace window unaffected; navigator mode independent per
   window.
6. Keyboard reachability + VoiceOver on the new settings rows, the rail
   button, and the new "Show Runs" command-palette entry.
7. Full `./script/build_and_run.sh --verify` pass — the "Show Runs" palette
   entry and the Agents tab are unexercised UI changes.

### References landed with this phase

- [`../../../references/conductor-pty-spawn-and-child-environment.md`](../../../references/conductor-pty-spawn-and-child-environment.md)
  — binding on C1 (the `forkpty`/parallel-test finding and the curated
  `PATH`).
- [`../../../references/conductor-file-contracts.md`](../../../references/conductor-file-contracts.md)
  — binding on C1–C7 (`.rafu/` layout, parsers, manifest encoding,
  invocation contract).

## Goal-mode prompt

> /goal Implement phase C0 exactly as scoped in
> docs/plans/phases/conductor/C0-shim.md. Read that file AND
> docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. Use the advisor→implementor→documentor
> workflow. This phase runs serially on main with a clean tree — it is the
> shared shim every later conductor phase builds on; the contract names and
> file layout in the phase file are binding. Gates per increment: swift
> build with zero warnings, swift test and swift test --no-parallel green,
> ./script/format.sh --fix then --lint. Headless only — do not run
> build_and_run.sh. Security invariants from the README ground rules apply
> (argv arrays only, no credential reads, no prompt/output in Rafu logs, no
> @unchecked Sendable). Finish with one consolidated report: changes, files,
> test delta, verification evidence, intended doc-index rows, and remaining
> risks.
