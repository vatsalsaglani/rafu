# Editor canvas routing — one resolved route, not a chain

- **Applies to:** `EditorCanvasView` and every canvas mode it can show
  (welcome, empty, blame, standalone diff, Ensemble graph, Ensemble run
  detail, editor layout tree); any phase adding a new full-canvas surface.
- **Last verified:** Swift 6.2, macOS 26.x, on 2026-07-26 (UX-00).

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
| 1 | `.welcome` | `descriptor == nil` | No workspace at all — nothing else can render. |
| 2 | `.empty` | `!hasAnyEditorTabs && gitOpenDiff == nil && gitOpenBlame == nil && conductorRunCanvasID == nil && !conductorGraphVisible` | A workspace with no tab *and* no tabless canvas open. All five conditions are load-bearing; each one alone takes the route out of `.empty`. |
| 3 | `.blame` | `gitOpenBlame != nil && selectedDocument != nil` | Blame outranks every other canvas, and is the only one that survives a selected document — it *is* about that document, and titles itself with its name. |
| 4 | `.standaloneDiff` | `gitOpenDiff != nil && selectedDocumentID == nil` | A tabless canvas: opening any file dismisses it. |
| 5 | `.graph` | `conductorGraphVisible && selectedDocumentID == nil` | Same rule. Checked **before** run detail. |
| 6 | `.runDetail` | `conductorRunCanvasID != nil && selectedDocumentID == nil` | Same rule. |
| 7 | `.editor` | otherwise | The layout tree. |

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

## How to add a canvas mode

1. Add a case to `EditorCanvasRoute`.
2. Add its condition to `resolve`, **stating explicitly where in the
   precedence it sits** and why. Adding fields to `Inputs` is fine; reading
   the session inside `resolve` is not.
3. Add a branch to `EditorCanvasView.canvas(for:)`.
4. Add tests to `EditorCanvasRouteTests`: one for the case itself, plus a
   precedence pair against each neighbouring mode.

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

- `swift test --filter "Editor canvas route"` — 17 cases covering each route,
  the emptiness guard's exact condition set, and every precedence pair.
- `swift test --filter "Themed control styles"` — the source scan.
- GUI: `./script/build_and_run.sh --verify`, then visit each canvas
  (no workspace → welcome; open a workspace and close all tabs → empty;
  Source Control → blame and diff; Ensemble panel → graph and run detail;
  open a file → editor) and confirm no control renders in system blue.

## Verification

```bash
./script/build.sh
./script/test.sh
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorCanvasRoute.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- `Tests/RafuAppTests/EditorCanvasRouteTests.swift`,
  `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- [`ui-design-language.md`](ui-design-language.md) (token and component rules)
- `docs/plans/phases/ux/UX-00-canvas-route-and-theme.md` (this work);
  UX-01 and UX-02 each add a case to the route.
