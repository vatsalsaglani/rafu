# Ensemble headless test rigs: notifier injection, socket serialization, bounded event awaits

- Applies to: `Tests/RafuAppTests/Conductor/*`, `Tests/RafuCoreTests/Ensemble/*`, and any test that reaches `WorkspaceSession`, a real `LauncherIPCServer` socket, or `ConductorEnsembleEventCenter`
- Last verified: Swift 6.2 / macOS 26 / 2026-07-26 (phase C8-04)

## Rule or observed behavior

### 1. Inject a spy attention notifier or the test process aborts

`SystemTerminalAttentionNotifier` uses `UNUserNotificationCenter`, which under `swift test` (no app bundle) raises `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`. That is an Objective-C exception, not a Swift failure: it **aborts the whole test process**, not just the failing test.

Any test that can reach `WorkspaceSession.raiseConductorGateAttention` must inject a spy notifier. The real notifier is constructed lazily (`WorkspaceSession.swift` ~851–853), so only tests that actually reach a bell are affected — a test can construct a `WorkspaceSession` safely as long as it never triggers gate attention.

Production is unaffected: the GUI always runs from a staged `.app`, where `bundleProxyForCurrentProcess` resolves.

### 2. Real-socket end-to-end suites must be `.serialized`

Four suites, each binding its own socket and driving a `LauncherIPCServer` actor with blocking POSIX I/O on `Task.detached`, starve the cooperative thread pool past the 2s one-shot client timeout.

Reproduction: all four running together fail; any three pass; each alone passes. This is a **test-rig starvation property**, not a product concurrency defect: production runs one server, has no 2s bound, and never fans four blocking-I/O clients out at once. Mark the real-socket suites `.serialized` — see `Tests/RafuAppTests/Conductor/EnsembleEndToEndTests.swift:19`, whose header comment records the same reasoning.

### 3. Await the shared event center bounded by EVENT COUNT

`ConductorEnsembleEventCenter` emits a heartbeat, so `iterator.next()` never returns `nil`. An unbounded `for await` loop therefore does not fail — it **hangs the entire serialized suite**. A sleep-based bound is equally wrong (flaky and slow).

Bound the loop by the number of events expected, and assert on what arrived. Worked example: `Tests/RafuAppTests/Conductor/ProposeMergeTests.swift` (`maxEventsToInspect`), which caps inspection at 64 events so a regressed `merged` event fails the test instead of wedging the run. Note the harness's own throttled event center is NOT what a `subscribe()` in a test observes — `ConductorEnsembleEventCenter.shared` is, with the real heartbeat interval.

## Why it matters

Each of these produces a failure mode that does not look like a test failure: a process abort with no attributed test (1), a suite that only fails in a particular combination (2), and a wedge with no output at all (3). In this phase an unbounded await cost a 6+ minute wedged suite before it was recognized.

## Reproduction or evidence

- (1) Any `swift test` run reaching the real notifier aborts with `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`.
- (2) Four-socket-suite combination fails; any three-suite subset and every single suite pass.
- (3) Unbounded `for await` over the event center never terminates because of the heartbeat.

## Verification

- `./script/build.sh` — exit 0, zero warnings.
- `./script/test.sh` — 1683 tests, 81 suites, 0 issues (76s).
- `./script/test.sh --no-parallel` — 1683 tests, 81 suites, 0 issues (206s).
- `./script/format.sh --fix` then `--lint` — both exit 0.

## Related code, ADRs, and phases

- `Sources/RafuApp/Models/WorkspaceSession.swift` (~851–853) — lazy notifier construction
- [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md) — `UNUserNotificationCenter` usage
- [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md) — IPC server and streaming events
- [`ensemble-run-state-observability.md`](ensemble-run-state-observability.md)
- [`../plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md`](../plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md)
