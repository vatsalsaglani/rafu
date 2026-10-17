# Editor decoration viewport requests

- Applies to: TextKit 1 decorations and extra carets in `RafuTextView`.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

Build one `EditorViewportLayout` for a drawing pass or extra-caret refresh.
Request layout with `ensureLayout(forBoundingRect:in:)` for the visible
container rectangle. Get the resulting glyph range with the
`forBoundingRectWithoutAdditionalLayout` variant. Translate that range to
UTF-16 once. Reject offscreen caret positions and decoration ranges before
character-to-glyph conversion. Intersect any glyph expansion with the visible
glyph range before a geometry lookup.

Do not retain this snapshot between passes. Text, font, container, and scroll
changes must use a new snapshot. This avoids a second persistent geometry
cache with a separate invalidation protocol. All state stays on the main
actor, under the app target's default isolation. The patch adds no tasks or
cross-actor references.

An empty buffer uses its extra line fragment, or a font-height rectangle
when TextKit has not generated that fragment. A trailing newline uses the
extra line fragment. Blame uses the last visible visual fragment of a
logical line. It does not use the union of wrapped fragments. Blame is omitted
when the line end is offscreen. Current-line and indent geometry uses only
the visible portion of a bounded logical line. The bounded UTF-16 scan keeps
CRLF together, including a caret between CR and LF.

Clear inline-blame hit geometry at the start of every drawing pass and when
its annotation changes. A completion or full-file blame pass must not leave
a previous inline-blame hit target active.

## Why this matters

The old extra-caret path called `ensureLayout(for: textContainer)` for every
extra caret. Current-line, bracket, completion, and inline-blame paths could
ask for offscreen geometry before rejecting it. The repair removes those
requests. It preserves `writingToolsBehavior = .none` and the default
contiguous layout policy.

This is a bound on **Rafu requests**, not a promise about TextKit work. The
SDK header for `NSLayoutManager` states that layout can extend beyond a
requested range. With contiguous layout it can extend to the document's
start. The rectangle and glyph-range APIs also permit conservative results.
Only runtime traces can establish the resulting time or memory cost.

## Evidence and reproduction

Static evidence: `RafuTextView` has no full-container `ensureLayout` call.
The snapshot gates character geometry and clips ranges before glyph lookup.
`EditorViewportLayoutRepairTests` exercises real AppKit storage, layout,
selection, and bitmap-backed background drawing. It covers offscreen
requests, shared multi-caret passes, empty/trailing lines, UTF-16, wrapped and
long lines, CRLF, invalid ranges, edit/font/scroll/width changes, hidden
editors, and blame hit-target invalidation. The coordinator ran the initial
14 tests: 12 passed and two failed. Both failures also reproduced alone.
The follow-up patch adds a width-reflow test and awaits another test run.

`textView.viewportLayoutMetrics` counts viewport requests, accepted character
geometry requests, and rejected geometry requests. It stores only the most
recent accepted range. The counters do not count TextKit's internal calls.
Instruments intervals use subsystem `dev.vatsalsaglani.rafu`, category
`editor-layout`, and names `ViewportLayout` and `VisibleGeometry`. Intervals
contain no source text, paths, document identity, or credentials. Event
emission remains unverified until the coordinator runs the app.

## Frame callbacks during layout and test viewport ownership

On Swift 6.4 / macOS 27.0.1, the initial
`scrollRedrawRefreshesOverlay` test counted 36 viewport requests during one
explicit background drawing call after scrolling to y = 600. The same count
occurred when that test ran alone. Source review identified a nested path:
`ensureLayout(forBoundingRect:in:)` can update the text-view frame, whose
`setFrameSize` override requested another extra-caret viewport. The overlay
update guard did not protect the earlier drawing-pass layout request.

The drawing pass now sets a synchronous guard before it calls AppKit or
requests layout. Frame callbacks skip extra-caret refresh during that pass;
the pass updates the overlay after its shared snapshot is ready. Unchanged
frame sizes also skip refresh. The test keeps its one-request assertion and
its checks that scrolling removes and restores the overlay. All 15 viewport repair tests now pass, including this follow-up fix. It is not a measured performance result.

The initial width test changed the text-view frame to 180 points while its
scroll view stayed 320 points wide. The new snapshot still reported a
320-point viewport. This result also reproduced alone. A test of viewport
resizing must resize the scroll view, tile it, and size the document to its
content width. The fixture now uses the production width autoresizing mask.
The width ceiling remains, and an added test requires the narrower viewport
to move a wrapped caret to a later visual row.

Evidence: the coordinator's `repair-tests-6.log`,
`alone-geometryIsNotRetainedAcrossInvalidation.log`, and
`alone-scrollRedrawRefreshesOverlay.log` in
`/tmp/rafu-repair-20261017`. These logs identify the failed assertions and
values. They do not include a frame-callback stack trace.

## Verification commands

Static checks for the owned files:

```sh
swift format lint --strict Sources/RafuApp/Editor/RafuTextView.swift Sources/RafuApp/Editor/EditorViewportLayout.swift Tests/RafuAppTests/EditorViewportLayoutRepairTests.swift
swiftc -frontend -parse Sources/RafuApp/Editor/RafuTextView.swift Sources/RafuApp/Editor/EditorViewportLayout.swift Tests/RafuAppTests/EditorViewportLayoutRepairTests.swift
git diff --check
```

When the coordinator gives a build slot:

```sh
./script/test.sh --filter EditorViewportLayoutRepairTests
./script/test.sh --filter MultiCaret
./script/test.sh --filter 'indentGuideLineScanBounded|manyLineDocumentDrawIsBounded|inlineBlameDrawClearsRectBeyondScanCap'
```

The coordinator owns format, build, full parallel and serial tests, and the
canonical app validation. The coordinator checked native caret navigation and
scrolling in the 12,000-line fixture. Further checks should repeat this with extra
carets and compare wrapped and long-line files.
Check restored scroll position, font changes, empty and trailing lines,
blame, completion, and bracket decorations. A permitted runtime trace must
verify the signposts before any performance claim.

## Related code and decisions

- `Sources/RafuApp/Editor/RafuTextView.swift`
- `Sources/RafuApp/Editor/EditorViewportLayout.swift`
- `Tests/RafuAppTests/EditorViewportLayoutRepairTests.swift`
- [Writing Tools and TextKit layout](macos26-writing-tools-textkit-layout.md)
- [Large-file guard mode](large-file-guard-mode.md)
- [ADR 0013: Git experience scope](../decisions/0013-git-experience-scope.md)
- [Pre-initial-push workbench](../plans/phases/pre-initial-push-workbench.md)
- Editor performance repair plan, held in the primary checkout. The coordinator
  must add this note to the shared reference index during integration.
