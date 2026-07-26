# Editor canvas routing — one resolved route, not a chain

- **Applies to:** `EditorCanvasView` and every canvas mode it can show
  (welcome, empty, blame, standalone diff, Ensemble graph, Ensemble run
  detail, New Ensemble, New Ensemble Run, Settings, editor layout tree); any
  phase adding a new full-canvas surface.
- **Last verified:** Swift 6.2 language mode (Swift 6.3.3, Xcode 26.6),
  macOS 26.5.2, on 2026-07-26 (UX-01 + UX-02).

## Rule

`EditorCanvasView.body` renders exactly one canvas, chosen by a single pure
function:

```swift
EditorCanvasRoute.resolve(EditorCanvasRoute.Inputs(session: session))
```

`EditorCanvasRoute` (`Sources/RafuApp/Editor/EditorCanvasRoute.swift`) is a
`nonisolated` enum with one case per mode plus an `Inputs` value holding the
booleans the decision reads. The resolver never touches `WorkspaceSession`,
so precedence is testable without a session, a window, or the main actor.
`Inputs.init(session:)` is the only place session properties are read, and it
makes no decisions.

## The precedence, and why each rule exists

First match wins. This ordering was transcribed verbatim from the `if/else`
chain it replaced; it is behaviour, not taste.

| # | Route | Fires when | Why |
|---|---|---|---|
| 1 | `.welcome` | `descriptor == nil && !settingsVisible` | No workspace at all. A welcome window hosting Settings is the deliberate exception; with no window at all, ⌘, routes to the native Settings scene before this resolver is involved. |
| 2 | `.empty` | No editor tab and none of the **seven** tabless canvases open | A workspace with nothing to render. All eight conditions (tab + seven canvases) are load-bearing; each one alone takes the route out of `.empty`. |
| 3 | `.blame` | `gitOpenBlame != nil && selectedDocument != nil` | Blame outranks every other canvas, and is the only one that survives a selected document — it *is* about that document, and titles itself with its name. |
| 4 | `.standaloneDiff` | `gitOpenDiff != nil && selectedDocumentID == nil` | A tabless canvas: opening any file dismisses it. |
| 5 | `.graph` | `conductorGraphVisible && selectedDocumentID == nil` | Same rule. Checked **before** run detail. |
| 6 | `.runDetail` | `conductorRunCanvasID != nil && selectedDocumentID == nil` | Same rule. |
| 7 | `.ensembleStart` | `ensembleStartCanvasVisible && selectedDocumentID == nil` | Same rule. Defensive ordering preserves the pre-UX-01 graph/run precedence. |
| 8 | `.ensembleNewRun` | `ensembleNewRunCanvasVisible && selectedDocumentID == nil` | Same rule. Checked after New Ensemble start; the activators make this pair mutually exclusive. |
| 9 | `.settings` | `settingsVisible && selectedDocumentID == nil` | Same tabless-canvas rule. Unlike `.welcome`, it may render in a workspace-less window so the status-bar control and focused-window ⌘, never no-op. |
| 10 | `.editor` | otherwise | The layout tree. |

Two subtleties worth keeping in mind before "simplifying" anything here:

- **Rules 2 and 3 read different things.** The emptiness guard tests
  `gitOpenBlame`; the blame branch tests `selectedDocument`. So blame open
  with no resolved document is neither `.empty` (the guard is defeated) nor
  `.blame` (the branch cannot fire) — it lands on `.editor`, showing the
  layout tree. That is pre-existing behaviour, preserved deliberately.
- **`selectedDocument` is not `selectedDocumentID != nil`.** It is the open
  document *matching* that id, so a selected id with no matching open
  document (a terminal tab, a closed document) behaves differently from a
  selected file. `Inputs` carries both as separate fields for that reason.
- **No descriptor does not always mean welcome.** A live welcome window owns
  a `WorkspaceSession`, so its status-bar Settings button and focused-window
  ⌘, command can set `settingsVisible` and resolve `.settings`. With every
  window closed there is no session or resolver; `SettingsCommandRouter`
  invokes the registered native Settings scene instead.

## How to add a canvas mode

1. **Make the mode's activator clear every other canvas mode's state**, and
   make theirs clear yours. This is the step that is easy to skip and
   expensive to miss — see "Exclusivity lives in the mutators" below.
2. Add a case to `EditorCanvasRoute`.
3. Add its condition to `resolve`, **stating explicitly where in the
   precedence it sits** and why. Adding fields to `Inputs` is fine; reading
   the session inside `resolve` is not.
4. Add a branch to `EditorCanvasView.canvas(for:)`.
5. Add tests to `EditorCanvasRouteTests`: one for the case itself, plus a
   precedence pair against each neighbouring mode.

## Exclusivity lives in the mutators, not the resolver

`resolve` orders the canvas modes, but in practice **no two full-canvas modes
are ever active at once**, because each activator clears the others:

| Activator | Sets | Clears |
|---|---|---|
| `showConductorRunDetail` | `conductorRunCanvasID` | graph + both creation canvases + Settings |
| `showConductorGraph` | `conductorGraphVisible` | run detail + both creation canvases + Settings |
| `showEnsembleStart` | `ensembleStartCanvasVisible` | graph + run detail + New Run + Settings |
| `showEnsembleNewRun` | `ensembleNewRunCanvasVisible` | graph + run detail + New Ensemble + Settings |
| `showSettings` | `settingsVisible` | graph + run detail + both creation canvases, and any open Git diff/blame |
| `revealTerminalSession` | — | all five canvases |

The consequence is worth stating, because it was already misread once: the
precedence among graph, run detail, the two creation canvases, and Settings
is **unreachable through their activators**, so the resolver's order is a
defensive statement of intent rather than observable behaviour.
`graphBeatsRunDetail`, `runDetailBeatsCreationCanvases`, and
`ensembleStartBeatsNewRun` pin it so a future change is deliberate.

**UX-01 and UX-02 built their canvases in parallel, so neither branch's
activators cleared the other's flags — the cross-clears were added at merge.**
That is the concrete form this failure takes: each branch is internally
correct and the union is not. If two plans add canvas modes concurrently
again, the merge must complete this table, not just concatenate it.

One scoped exception preserves C8-07's two-phase guided launch:
`ConductorCoordinatorLauncher` reveals its terminal while
`EnsembleStartModel.start(in:)` is still running, but the copyable-goal
confirmation must remain in front. `beginEnsembleStartLaunch()` /
`endEnsembleStartLaunch()` suppress only that internal reveal's start-canvas
clear. Ordinary user-requested terminal reveal still clears every canvas.

A new canvas mode that sets its own flag **without clearing the others**
silently makes the resolver's ordering load-bearing — and the resulting bug
is "the wrong screen appears" with no error and no failing test, because the
route tests only assert the ordering, not the invariant that keeps it moot.
If you add a mode, extend this table.

If the new mode should not be dismissed by a selected document, say so in the
code comment — that is the exception blame carries, and the next reader will
otherwise assume the common rule.

## Theme rule for controls

Rafu owns `RafuSegmentedPicker` and `RafuProminentButtonStyle`
(`Sources/RafuApp/Support/RafuControlStyles.swift`). AppKit's
`.pickerStyle(.segmented)` and `.buttonStyle(.borderedProminent)` paint with
the **system** accent, which ignores the active theme — so a blue control
inside Rafu's own chrome is a defect, not a style preference.

`RafuSegmentedPicker` takes `fillsWidth:` for the sites that replaced a
system segmented control inside a `Form` row or full-width header, where
AppKit stretched and evenly divided the available width. If a future call
site cannot be expressed, **extend the component** — falling back to the
system style reintroduces the defect.

`ThemedControlStyleScanTests` scans every `.swift` file under
`Sources/RafuApp/` and fails on either literal. A line carrying the marker
`themed-control-scan:allow` is skipped, for prose that must quote the banned
form.

## Reproduction or evidence

- `swift test --filter EditorCanvasRouteTests` — 22 tests covering each route,
  the emptiness guard's exact condition set, and every precedence pair.
- `./script/test.sh --filter "RafuAppTests.SettingsCanvasTests"` — seven
  cases covering the Settings route, selected-document precedence,
  peer-canvas exclusivity, both command destinations, per-window state, and
  restoration omission.
- `swift test --filter "Themed control styles"` — the source scan.
- GUI: `./script/build_and_run.sh --verify`, then visit each canvas
  (no workspace → welcome; open a workspace and close all tabs → empty;
  Source Control → blame and diff; Ensemble panel → graph and run detail;
  New Ensemble / New Run → their creation canvases; Settings menu, ⌘, or the
  status-bar gear → Settings; open a file → editor) and confirm no control
  renders in system blue.

## Verification

```bash
./script/build.sh
./script/test.sh
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorCanvasRoute.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Views/EnsembleStartCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `Sources/RafuApp/Settings/SettingsCanvas.swift`
- `Sources/RafuApp/Settings/SettingsCommandRouter.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- `Tests/RafuAppTests/EditorCanvasRouteTests.swift`,
  `Tests/RafuAppTests/SettingsCanvasTests.swift`,
  `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- [`ui-design-language.md`](ui-design-language.md) (token and component rules)
- [`settings-surface.md`](settings-surface.md) (command fallback, layout, and
  restoration contract)
- `docs/plans/phases/ux/UX-00-canvas-route-and-theme.md` (route extraction);
  `UX-01-ensemble-as-editor-tabs.md` (the two creation canvases);
  `UX-02-settings-as-editor-tab.md` (the settings route and its fallback).
