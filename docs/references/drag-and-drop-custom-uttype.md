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
  The real fix for "don't let a tab/file drag land as pasted text" is
  overriding `NSTextView.acceptableDragTypes` to exclude
  `.fileURL`/`.URL`/`NSFilenamesPboardType` and calling
  `updateDragTypeRegistration()` once after building the view (AppKit calls
  it automatically on property changes like `isEditable`, not on init). Do
  not call `unregisterDraggedTypes()` wholesale — that would also break
  in-editor text drag-and-drop.
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
