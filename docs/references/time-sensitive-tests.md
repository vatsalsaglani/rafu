# Time-sensitive tests

- Applies to: any test that reads the real clock, sleeps, or polls with an
  iteration budget. Fixed in this pass: `VoiceSessionIntegrationTests`,
  `AgentActivityStoreTests`, and the `until` test helper. Related gates:
  [`../../AGENTS.md`](../../AGENTS.md) ("Triage a failing test by isolation").
- Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
  Mac17,13, 2026-11-15 (commit ff189c4).

## Rule or observed behavior

These tests failed under machine load (load 55 to 78 from parallel worktree
builds) in at least three separate runs on 2026-11-15, and passed alone each
time. A test that fails across runs under load and passes alone is a
time-sensitive test, not a bug to grind on.

Rules:

1. A quiet gate or timer that reads the wall clock goes through an injectable
   clock. Do not let a test depend on how long the machine took.
2. Do not bound a polling loop by an iteration count. A yield-count budget has no
   wall-clock meaning: under load it ends early or runs far too long. Use a
   generous wall-clock deadline and short sleeps.
3. A failure-deadline sleep that races a real OS notification must be generous
   (120 s). The test still uses the real notification; only the failure
   deadline moves.

## What failed and why

- **`VoiceSessionIntegrationTests` agent-update tests** ("A reply gives exactly
  one commentary, after the quiet gate", "Approval and waiting are spoken; two
  agents share one sentence", "A spoken agent update becomes the card's agent
  line"). They read the real session clock. The quiet gate needs 1.5 s since the
  last local speech. Under load more than 1.5 s passed between session open and
  the scan, so the update was spoken at once and the wait for "queued" never
  held. The `until` helper had a 200,000-yield budget and no wall-clock bound; it
  timed out at about 23.6 s.
- **`AgentActivityStoreTests` "A native directory notification drains..."**
  raced a 5 s failure sleep against the real directory notification.
- **`LauncherRequestRouterTests` "A stopped listener..."** needed no change. It
  already uses the 20 s `canvasBridgeTimeoutSeconds`; the read code 35 in the
  failing runs came from an older 2 s default.

## Fixes (commit ff189c4)

- An internal `VoiceSession.Dependencies.now` seam. Default is
  `ContinuousClock.now`, so live behavior is unchanged. Tests use
  `VoiceManualClock`. All 8 agent-update tests use it.
- `until` has a 120 s wall-clock deadline and sleeps 1 ms between checks after
  1,000 yields. It covers 81 uses.
- The directory-notification failure deadline is 120 s. The test still waits
  for the real notification.

## Shared polling helper (commit b4ed608, 2026-11-15)

The "same pattern, not failing yet" suites are now fixed. One shared file,
`Tests/RafuAppTests/PollingSupport.swift`, replaces the private copies. Do not add
private copies.

- `TestPolling` holds the constants: 120 s deadline; up to 1,000 yields, then 1 ms
  sleeps; it stops early on cancellation.
- `waitUntil(timeout:isolation:_:) -> Bool`: the predicate runs on the caller's
  actor (`#isolation`).
- `until(_ label, ...) async throws`: on timeout it records an issue and throws
  `CancellationError`.
- `waitUntilOnMain(...)`: for tests that are not `@MainActor` and read
  `@MainActor` state.

Suites moved to the helper: `LSPNavigationProviderTests`,
`LanguageServerSessionTests`, `TerminalAttentionTests`, `CanvasLiveBridgeTests`,
`CanvasAgentActionsTests`, `ViewToolsPolicyTests`, `CanvasAgentConfigureTests`,
`CanvasChannelPromptLaunchTests`, `VoiceSessionIntegrationTests`,
`VoiceShowViewTests`, `TerminalEditorTabTests`, `LanguageServerManagerTests`,
`LanguageIntelligenceCoordinatorTests`, `LanguageServerTrustFlowTests`,
`LanguageServersCatalogModelTests`, `WorkspaceTrustSettingsModelTests`.

- Negative assertions keep a bounded yield drain (`drainPendingTasks`,
  `holdsAfterDrain`, and the two `Task.yield()` calls in the Voice closed-session
  test), because "nothing happens" has no event to wait for.
- A fixed 20 ms `Task.sleep` that waited for a subscriber raced the subscription
  task. Wait on observable state instead. The seam is
  `EditorDocument.editDeltaSubscriberCountForTesting` (read-only).

**Real-time timer tests left unchanged** (the delay is the behaviour under test):
`LanguageServerManagerTests` idle timeout (60 ms with 30, 45 and 120 ms sleeps),
`LanguageIntelligenceCoordinatorTests` 50 and 100 ms negative waits,
`MultiCaretUndoDiagnosticTests`, `LauncherRequestRouterTests` (2 s connection
count) and `CanvasBoardDropRoutingTests` (10 ms). Fix one of them when it fails
under load.

Stress evidence (Swift 6.4.2, Xcode with macOS 27.2 SDK 26B118, Darwin 27.2.0,
Mac17,13): 3 parallel runs with 30 `yes` processes plus ambient load of about 70 to
95, each 495 tests and 3850 tests, all green. Main gate after the later merges:
495 tests in 36 suites and 3870 tests in 314 suites, parallel and `--no-parallel`.

## Why it matters

CI runs serial, but a parallel run under load is the only mode that exposes a
timing assumption. A test that fails like this wastes rounds: the failure reads
as a code bug, and the advisor-implementor loop is bounded at two rounds. If the
single test passes alone and serial passes, the verdict is scheduler starvation;
see the triage table in `AGENTS.md`.

## Reproduction or evidence

Stress recipe: start 2 `yes > /dev/null` processes per core from a script with a
`trap` that kills them on exit, then run the parallel suite 3 times.

Evidence: 30 `yes` processes on a 15-core machine (ambient load about 27); three
full parallel runs were green (469 tests + 3771 tests each, as reported). Main
after the merges: both modes green, 470 tests in 33 suites and 3801 tests in 308
suites each; the parallel run was the first green parallel run that day.

## Verification

```bash
./script/test.sh                 # parallel
./script/test.sh --no-parallel   # serial, the CI gate
swift test --filter "<exact test name>"   # isolation
```

## Related code, ADRs, and phases

- `VoiceSession.Dependencies.now` (the voice session sources) and
  `VoiceManualClock` plus the `until` helper (the test target); search with
  `rg -n "VoiceManualClock|func until" Tests`
- `Tests/RafuAppTests/PollingSupport.swift` (`TestPolling`, `waitUntil`, `until`,
  `waitUntilOnMain`)
- [`concurrency.md`](concurrency.md),
  [`ensemble-headless-test-rigs.md`](ensemble-headless-test-rigs.md) (bound
  awaits; real-socket flows)
- Phase: [`voice-control.md`](../plans/phases/voice-control.md)
