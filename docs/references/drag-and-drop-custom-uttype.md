# Custom-UTI drag and drop (SwiftUI → AppKit bridge)

- Applies to: `.onDrag`/`.onDrop` with a private `UTType`, `NSItemProvider`
  registration, and `NSTextView` drag acceptance
- Last verified: Swift 6.2, AppKit/SwiftUI on macOS 15+, 2026-07-13

## Rule or observed behavior

- `UTType(exportedAs: "your.reverse-dns.id")` alone creates a type whose
  `conforms(to: .data)` is `false` unless the identifier is also declared in
  the app bundle's `Info.plist` under `UTExportedTypeDeclarations` (with
  `UTTypeConformsTo` including `public.data` or another concrete supertype).
  SwiftUI's `.onDrag`/`.onDrop` path goes through
  `NSItemProvider → NSDraggingItem → pasteboard → reconstructed NSItemProvider`,
  and that bridge silently drops types that don't conform to `public.data`.
  The `.onDrop(of:)` validator never matches, so neither the drop overlay nor
  `performDrop` ever fires — with no crash and no console error, which makes
  this easy to misdiagnose as a gesture or hit-testing bug.
- Belt-and-suspenders fix: use
  `UTType(exportedAs: identifier, conformingTo: .data)` in code **and**
  declare the same identifier in `Info.plist`. Keep both in lockstep (Rafu's
  `script/build_and_run.sh` asserts the staged plist's
  `UTExportedTypeDeclarations.0.UTTypeIdentifier` equals the Swift-side
  literal after every stage, so a future rename can't drift silently).
- `NSTextView` does not need to "steal" a private, non-text UTI to break a
  text-view drop target — it already registers `public.utf8-plain-text`
  (etc.) by default, and a `Transferable`/`.draggable(String)`-style payload
  will paste as plain text if a text view is anywhere under the drop point.
  
  **CORRECTION (2026-07-24):** Excluding `.fileURL`/`.URL`/`NSFilenamesPboardType` from
  `acceptableDragTypes` stops INTERNAL drag payloads (tab/file drags with a
  private UTI) from being misread as text, but it does NOT solve real Finder
  file drops — the text type is still registered and still consumes the drop.
  The actual fix for "don't let real Finder files land as pasted text" is
  classifying the FULL pasteboard type-identifier set with precedence
  (`rafuEditorDrag` > `.fileURL` > text) and forwarding accordingly, not
  registration exclusion alone. See [`appkit-drag-destination-type-precedence.md`](appkit-drag-destination-type-precedence.md)
  for the complete classification fix. The `acceptableDragTypes` exclusion
  remains useful for the internal-payload case; it is insufficient by itself.
- `DropProposal(operation: .move)` from an `.onDrag`-originated SwiftUI drag
  session can be rejected by macOS's drag source mask, silently preventing
  `performDrop` from firing even once the UTI conformance problem above is
  fixed. `.copy` is the operation that reliably validates; treat the
  operation value as cosmetic; the actual effect is always a layout
  move/split, never a data copy.
- One `NSItemProvider` load handler pattern serves both same-process and
  cross-window/cross-process drops cheaply: cache the payload on the
  originating model (e.g. `session.activeEditorDrag`) when the drag starts,
  and also pre-encode the same payload as `Data` into the provider via
  `registerDataRepresentation(forTypeIdentifier:visibility:loadHandler:)`.
  `performDrop` first tries the cached same-process value (a synchronous
  fast path); if it's `nil` — a fresh window with no drag history — fall
  back to the async `loadDataRepresentation(for:)` decode. Never use the
  cached value to decide whether a drop is *acceptable*; only read it after
  the drop delegate has already validated the `.rafuEditorDrag` type.
- The `loadDataRepresentation` completion handler and `NSItemProvider`'s
  `loadHandler` are imported as `@Sendable` closures. Capturing a
  `@MainActor`-isolated, non-`Sendable` reference type (e.g. a
  `WorkspaceSession`) directly inside one is a compiler error under strict
  concurrency. The safe pattern already used for cross-actor tab/file drops:
  build a small `let action: @MainActor @Sendable (Payload) -> Void = {
  [session] payload in ... }` closure — capturing only `Sendable` value
  types plus the `@MainActor` class — and hand *that* Sendable closure
  value into the off-actor completion handler; hop back with
  `Task { @MainActor in action(payload) }` before touching `session`.

## Step-1 diagnosis outcome

This implementation went straight to the full fix (Info.plist declaration +
`conformingTo: .data` + unified drag/drop rewrite) rather than landing the
Info.plist declaration alone first and re-testing. The declaration-alone
hypothesis was **not** isolated in a standalone experiment; it is stated here
as advisor-verified prior art, not independently re-confirmed by this change.
What *was* independently verified in this change:

- `plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier` against the
  staged `dist/Rafu.app/Contents/Info.plist` after `script/build_and_run.sh
  --stage` returns exactly `dev.vatsalsaglani.rafu.editor-drag`, matching
  `UTType.rafuEditorDrag`'s Swift-side identifier.
- `DropProposal(operation: .copy)` was adopted from the start (not `.move`)
  per the brief's stated risk; this was not independently A/B tested against
  `.move` in this change.

## Reproduction or evidence

- Unit tests exercise the payload → `Data` → payload round trip through both
  direct `JSONEncoder`/`JSONDecoder` and through a real
  `NSItemProvider.registerDataRepresentation` → `loadDataRepresentation`
  round trip (awaited via `withCheckedThrowingContinuation`, no fixed
  sleeps).
- `EditorDropGeometry.target(at:in:)` is covered for all four edge bands, the
  center dead zone, and degenerate (zero-size) containers.
- `EditorLayoutState.split(group:at:moving:)` followed by `insert(_:in:)` is
  covered for focus transfer and full restoration round-trip.
- `WorkspaceSession.handleEditorFileDrop`/`handleEditorTabDrop` are covered
  directly against a cheaply-constructible `WorkspaceSession()` (no open
  workspace, so `persistWorkspaceState()` is a documented no-op), including
  directory rejection, tab reuse instead of duplicate documents, and the
  nil-edge no-op-within-the-same-group behavior.
- Manual GUI drag verification (live preview tracking, actual mouse-driven
  tab/file drags, second-window and relaunch-restore behavior) cannot be
  driven headlessly and remains a pending manual pass — see the phase
  verification matrix in the implementation brief.

## Verification

`swift build`; `swift test` (`EditorDragAndDropTests`); `./script/format.sh
--fix` then `--lint`; `./script/build_and_run.sh --verify` plus `plutil
-extract UTExportedTypeDeclarations json dist/Rafu.app/Contents/Info.plist`.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorDragAndDrop.swift`
- `Sources/RafuApp/Editor/RafuTextView.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Views/WorkspaceSidebarView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `script/build_and_run.sh`
- `Tests/RafuAppTests/EditorDragAndDropTests.swift`
- [`build-and-run.md`](build-and-run.md)
- `docs/plans/phases/pre-initial-push-workbench.md`

## Second private type: `ensemble-drag` (2026-10-19)

Agent History rows drag onto an Ensemble board with their own type,
`dev.vatsalsaglani.rafu.ensemble-drag` (`UTType.rafuEnsembleDrag`,
`conformingTo: .data`), so editor groups and text views never see it. It has no
public text or file representation, so a drop anywhere else pastes nothing.
The item provider uses the same registration as
`EditorDragPayload.makeItemProvider` (`registerDataRepresentation`, `.all`
visibility).

- `script/build_and_run.sh` declares it as `UTExportedTypeDeclarations` index
  3 (0 is `editor-drag`, 1 `dev.rafu.ensemble`, 2 `dev.rafu.workspace`) and
  asserts it with `plutil -extract UTExportedTypeDeclarations.3.UTTypeIdentifier
  raw`. Release packaging uses the same script. Verified on 2026-10-19: the
  command returned `dev.vatsalsaglani.rafu.ensemble-drag` for
  `dist/Rafu Lightning.app/Contents/Info.plist`. Adding a fifth declaration
  means adding the next index assert in the same change.
- `UTType.conforms(to: .data)` is false inside a test process (the test
  runner has no app Info.plist). No test can check the declaration; only a
  source check of the script covers it. Do not write a test that expects
  conformance and conclude the plist is wrong when it fails.
- Never route a drop using the cached `session.activeEditorDrag`. After a
  cancelled drag it can be stale. Always decode the provider at drop time; the
  cache is only a hint for `validateDrop`. (This sharpens the "fast path" rule
  earlier in this note: the fast path is for decoding a payload already known
  to be valid, not for deciding what the drop is.)
- The board accepts this type, `rafuEditorDrag`, and `.fileURL`, in that
  priority. See [`canvas-interaction.md`](canvas-interaction.md), "Board
  drops".

## Previews, hover fidelity, and drag end (2026-10-19)

Commits 3380c53, 5860a98, 2debd37, 5c72b84. Verified on `main` at ba00643
(Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434)): format lint
clean; build with 0 warnings; parallel suite 250 + 2631 tests passed;
`--no-parallel` (CI mode) 250 + 2631 passed; `./script/build_and_run.sh
--verify` launched Rafu Lightning. Real mouse drags were not automated.

- **There is no SwiftUI drag-end callback.** `.onDrag` gives you a start and
  nothing else: no cancel, no completion. Anything a drag turns on must be
  turned off by something outside SwiftUI's drag API. Rafu's source ghost uses
  `WorkspaceSession.dragInFlight`, a token set inside each `.onDrag` closure
  and cleared by a **local** `NSEvent` monitor for `leftMouseUp` and
  `Escape`, with a 12 s fallback timer.
- **A local monitor must always return the event.** Rafu's returns the event
  unchanged in every branch, so it can never consume a click. A **global**
  monitor cannot consume events but needs Accessibility permission, which is
  the wrong trade for a cosmetic dim.
- **UNVERIFIED:** whether a local monitor observes `leftMouseUp` while
  `NSDraggingSession` runs its own nested event loop. If it does not, the
  source dim persists until the 12 s fallback fires. The designed fallback, if
  a manual pass shows that symptom, is a real `NSDraggingSource` implementing
  `draggingSession(_:endedAt:operation:)` — which is the only API that
  reliably reports drag end. Do not "fix" this by shortening the timer.
- **`.onDrag(_:preview:)` is the preview path.** All seven internal drag
  sources pass a `RafuDragPreviewLabel` (icon + title). Without an explicit
  preview, AppKit snapshots the source view, which for a list row or a tab is
  a wide, mostly-empty rectangle.
- **Hover must not decode the provider on the SwiftUI path.** `.onDrop`'s
  update callbacks have no synchronous decode, and an async decode per hover
  frame is both slow and racy. Use type presence plus a same-window cached
  hint (`activeEditorDrag`, `activeEnsembleDragHint`) and accept a generic
  label for cross-window drags: generic but never wrong. Only the AppKit
  bridge, which can read `NSPasteboard` synchronously, shows an exact preview.
  The decode-at-drop-time rule above is unchanged.
- **The deepest-registered-NSView rule bites more views than the scroll
  view.** `RafuTextView` kept `NSTextView`'s default drag types including the
  file URL, so a Files-tree drag (private editor-drag type **and** a file URL)
  was routed to the text view, which forwarded only external files. It now
  forwards every non-text kind through a pure, `nonisolated`
  `RafuTextView.shouldForward`. Dropping an already-open file into the same
  group now selects that file's existing tab instead of doing nothing.
- **A note card's `NSTextView` was taking board drops** for the same reason.
  Its drag types are now unregistered. Known cost: you can no longer drag
  selected text to reposition it inside a note.
- **Never cache a failed pasteboard decode per `draggingSequenceNumber`.**
  `CanvasScrollBridge` cached a `nil` decode and then rejected the whole drag
  for its remaining lifetime. Only successful decodes are cached now
  (`canReuseCachedDecode`).

## AppKit subtree dead zone (2026-07-13 follow-up)

SwiftUI `.onDrop` on the editor group only received drag events while the
pointer was over the group's SwiftUI-drawn chrome (tab bar/breadcrumb strip).
Over the `NSScrollView`/`NSTextView` subtree the preview vanished: AppKit
routes a drag session to the deepest registered NSView under the pointer, and
nothing in that subtree accepted the private type. Fix:
`EditorDropForwardingScrollView` registers for `rafuEditorDrag` and forwards
`draggingEntered/Updated/Exited/performDragOperation` (top-left-normalized
location + bounds) into the same overlay state and session drop handlers via
`EditorDropForwarding` closures injected by `EditorGroupView`. Additionally,
the SwiftUI `EditorDropDelegate.dropUpdated` now sets `isTargeted = true`
itself — enter/exit pairing is unreliable when bodies re-evaluate mid-drag.
