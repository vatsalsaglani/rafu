# Source policy tests and bookmark test isolation

- **Applies to:** the editor repair test work at base
  `84fd5f42524082dcded7a6d0c8c2697a279302d1`.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rules and evidence

A source match can enforce a construction policy. It cannot prove view
retention, focus, accessibility output, hit testing, or drag safety. Keep pure
model assertions in mixed test files. Keep explicit security and compiler
workaround checks until equivalent executable coverage exists.

The old `probeRecentsRoundTrip` printed errors and returned without a failed
assertion. It also called `record` and `remove` on `RecentWorkspacesStore`,
which uses `UserDefaults.standard`. A test must not change the app's recent
workspace list. The replacement tests encode and decode a real bookmark
entry, resolve it through the store, and assert that invalid data throws.
They use a unique temporary directory and do not call `load`, `record`, or
`remove`. They do not establish MRU order, list capacity, or store persistence.
Testing those behaviors needs an injected storage boundary in a separate
owned change; saving and restoring standard defaults is not test isolation.

The immutable `ServerPack.all` catalog is explicitly `nonisolated`. Its
bare extension otherwise inherits the app target's default main-actor
isolation, despite the nonisolated value type. The catalog test compares
local IDs before `#expect` without an unnecessary actor hop. Do not disable
concurrency checking to repair a macro autoclosure error. The three geometry shapes are pure value types;
their explicit `nonisolated` declaration is a separate compatibility fix.

## Consolidated checks

- `SettingsPresentationTests` owns pane order, titles, subtitles, unique
  glyphs, and the below/at/above 812-point breakpoint cases.
- One source policy check owns the lazy visited-pane host construction.
  Actual pane state and initialization counts across resize remain runtime
  acceptance checks. No Settings production API changed in this work.
- `ResponsiveNavigationPresentationTests` retains compact disclosure,
  source order, accessibility modifiers, and theme construction checks.
- `ThemedControlStyleScanTests` retains the explicit system-accent ban.
- `RafuWorkbenchStyleContractTests` retains pure geometry and resolver
  matrices. The terminal-status check keeps API source policy assertions;
  it no longer requires a particular comment.

## Other source checks: review classification

This table classifies the source checks named by the source review. It does
not authorize deletion or claim that all tests in each file use source text.
Paths are under `Tests/RafuAppTests`; `Conductor/` is the internal source path
for Ensemble.

| File or group | Keep as source policy | Runtime or executable evidence still needed |
| --- | --- | --- |
| `Conductor/ConductorModelResolutionTests.swift` | Central wording rule | Model resolution assertions remain separate |
| `Conductor/ConductorRunsPanelPresentationTests.swift` | Shared canvas and tab construction | Close action, width, visual hierarchy |
| `Conductor/EnsemblePresentationTests.swift` | Shared component use | Row selection, geometry, source order as rendered |
| `Conductor/EnsembleStartCanvasTests.swift` | Picker and shared canvas construction | Close, selection, width, pane lifetime |
| `EditorTabAndGroupPresentationTests.swift` | No decorative tab motion; shared tab construction | Drop, focus, hit testing, accessible labels |
| `EditorThemeColorApplicationTests.swift` | Shared identity resolver use | Vendor mark and actual theme application |
| `ReleaseOptimizerWorkaroundTests.swift` | Explicit destructor workaround | Matching optimized build check before removal |
| `TerminalGroupFocusBridgeTests.swift` | Focus gate and pane identity forwarding | Responder changes among actual panes |
| `TerminalGroupManagerHierarchyTests.swift` | Frozen workspace action inputs | Commands affect the intended workspace |
| `TerminalGroupSplitViewTests.swift` | Snapshot authority | Mounted split layout and resize behavior |
| `TerminalGroupSwitcherPresentationTests.swift` | Group summary construction | Visible summary and keyboard selection |
| `TerminalGroupViewPresentationTests.swift` | Renderer boundary and typed action use | Focus, pane actions, accessibility output |
| `TerminalManagerPresentationTests.swift` | Shared row construction and no terminal clipping | Geometry, menu actions, visible status, scrolling |
| `TerminalShellPickerPresentationTests.swift` | Picker construction | Selection and keyboard paths |
| `TerminalsPanelTests.swift` | Separate identity and status fields | Displayed status and row actions |
| `UtilityPanelPresentationTests.swift` | Shared host, rail, segmented control construction | Search, source control, popover use |
| `WindowChromeTopologyLifecycleTests.swift` | One topology token | First frame, second window, full-screen lifecycle |
| `WorkbenchDeckPresentationTests.swift` | One deck, native split, external inset | Rendered boundaries and split interaction |
| `WorkspaceFolderPickerTests.swift` | One importer owner | Actual dialog and window routing |

Keep parser, UTF-16, undo, stale-result, dirty-text, ruler-tiling, drag-type,
restoration, process, cancellation, and security assertions. The SwiftTerm
bell and OSC parser checks are useful tests despite the probe filename.

## Build warning classification

The input `build.log` and `tests.log` name the unhandled file
`Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json`.
`RafuThemeTests.convergedSurfaceFixtureUsesPublicThemePath` reads this file
from the checkout through `repositoryRoot()`. It does not use `Bundle.module`.
The integration adds this exact argument to the `RafuAppTests` target in
`Package.swift`, after `dependencies`:

```swift
exclude: ["Fixtures/workbench-converged-surfaces.json"]
```

This removes the package warning without changing fixture access. Do not
exclude the complete `Fixtures` tree: it also contains Swift fixture code.
A resource declaration would need a separate test lookup change.

The `missing creator for mutated node` warning names
`SwiftTerm_SwiftTerm.bundle/Contents/MacOS` in Swift Build output. The log
shows a completed app build after this warning. The staging script runs
later, so its resource copy cannot repair this build-graph diagnostic.
No evidence here establishes a Rafu manifest repair for it. Keep it as an
upstream/toolchain warning to check in integration; do not edit dependency
checkouts or remove resources to hide it.

## Verification

Static checks for this change: `swift format lint --strict` on changed Swift
files, `bash -n script/build_and_run.sh`, and `git diff --check`.
After integration, run these focused suites through the approved build slot:

```bash
./script/test.sh --filter 'LanguageServersCatalogModelTests|RecentWorkspaceBookmarkPersistenceTests|SettingsPresentationTests|ResponsiveNavigationPresentationTests|ThemedControlStyleScanTests|RafuWorkbenchStyleContractTests'
```

Then run the full parallel and serial gates and the canonical app launch.
Check Settings pane state and load counts across compact/regular resize in
a mounted view. A passing source policy suite does not replace that check.

Related: ADR 0001, `docs/plans/phases/pre-initial-push-workbench.md`,
`docs/plans/phases/editor-performance-repair.md`, `build-and-run.md`,
`Sources/RafuApp/Services/RecentWorkspacesStore.swift`, and the test files above.

## Swift Testing mutation expressions

On Swift 6.4, `#require(layout.split(...))` rewrites the call through an
immutable closure argument. A mutating method then fails to compile. Evaluate
the mutation first and pass its optional result to `#require`. This keeps the
assertion and its failure location without changing the model operation.
The integration compiler reported this in the navigation and editor lifetime
repair tests (`repair-tests-2.log` and `repair-tests-3.log` in the temporary
integration evidence directory). The real editor tests also replace two old
hibernation checks that merely copied the implementation's branch logic.

The redundant `?? []` on nonoptional `launch.arguments` was removed from
`Conductor/ProcessAttributionTests.swift`; the optional environment check stays.

## OCR and parallel test timing

The first integrated full parallel run spent about 130 seconds in the existing
runtime-title OCR test. A read-only process sample showed `VNRecognizeTextRequest`
and Apple Neural Engine model compilation. Two close-save test limits and a
usage-TTL assertion failed during that run, then passed in isolation (3 tests,
0.036 seconds). Do not change those tests on this evidence. Run serial tests to
check order dependence. Evidence: `full-review-sample.txt`,
`full-review-parallel.log`, and `timing-isolation.log` in
`/tmp/rafu-repair-20261017`. Repeat with `./script/test.sh --filter
'refreshUsageRespectsTTLUnlessForced|closedWindowCannotOverwriteQuitState|lateCloseCannotEscapeFinalSave'`.

A later full parallel run passed all repair tests but failed the existing
`EnsembleEndToEndTests.statusEndToEnd` heartbeat deadline (39.658 seconds).
The isolated test passed in 0.030 seconds. The test file already documents socket
work starving under parallel load. No assertion or timeout was changed. Evidence:
`final-parallel.log` and `status-isolation.log` in the same evidence directory.
Check the serial result before classifying this as load-related timing.

## Known load-sensitive tests (2026-10-19)

Three full parallel suites ran at once in separate worktrees. Two tests failed
under that load only:

- `GeminiCLIAdapterTests`, "A successful bounded probe caches its absolute URL
  for pure invocation".
- `CanvasBridgeIPCTests`, "A typed bridge request reaches the handler...",
  which read `EAGAIN` (code 35) after about 10 s.

Both passed when run alone and passed in serial mode. By the AGENTS.md triage
table this is row two (passes alone, passes serial): scheduler starvation. It
is not a failure and not a clean pass; change nothing. Do not run several full
suites at once to save time. Together with `EnsembleEndToEndTests.statusEndToEnd`
above, these are the tests to suspect first when a parallel run fails only
under machine load. `CanvasBridgeIPCTests` showed the same `EAGAIN` again on
2026-10-19 during the Ensemble shell-choice and card-navigation work, under the
implementor's parallel load and with no code change in that area; it passed
alone, so it stays row two. A test that repeats this across rounds is
time-sensitive, not broken. Separate hang cause for the whole suite:
[`test-keychain-isolation.md`](test-keychain-isolation.md).
