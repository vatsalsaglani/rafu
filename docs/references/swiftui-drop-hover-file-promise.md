# SwiftUI drop hover: never decode item providers (file-promise wedge)

- Applies to: every SwiftUI `DropDelegate` / `.onDrop` / `.dropDestination`
  that can receive a Rafu private drag (`rafuEditorDrag`, `rafuEnsembleDrag`),
  and any future private drag type that conforms to `public.data`
- Last verified: Swift 6.4 toolchain (Swift 6.2 language mode), macOS 27.0.1
  (26A434), 2026-10-20

## Rule

Inside `validateDrop`, `dropEntered`, `dropUpdated`, and `dropExited`, read
**type presence only**: `info.hasItemsConforming(to:)`. Call
`info.itemProviders(for:)` only inside `performDrop` (or a helper that only
`performDrop` calls; name it `perform…`). For a hover-time file count, read
`NSURL` objects (file URLs only) from `NSPasteboard(name: .drag)`, as the
AppKit board bridge does. `CanvasDropHoverSafetyTests` enforces the rule over
all of `Sources/RafuApp`.

## Why it matters

SwiftUI's `.onDrag` writes an `NSItemProvider` whose registered type conforms
to `public.data` as a **file promise**: the drag pasteboard carries
`com.apple.NSFilePromiseItemMetaData`, `com.apple.pasteboard.promised-file-url`
and related types next to the private type. Types that do not conform to
`public.data` (`public.content`, `public.item`, plain text, URLs) get no
promise. Both Rafu private types must conform to `public.data` (see
[`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md)), so every
Rafu drag carries a promise.

`DropInfo.itemProviders(for: [privateType])` outside the drop phase makes
SwiftUI receive that promise. `NSFilePromiseReceiver` then raises
`NSInternalInconsistencyException` ("receivePromisedFilesAtDestination… can
only be called during -prepareForDragOperation:, -performDragOperation:, and
-concludeDragOperation:"). AppKit catches it in `NSCoreDragTrackingProc` and
logs "Canceling drag because exception was raised during a dragging session".
The ObjC unwind skips SwiftUI's own cleanup, and the window's SwiftUI input
stays dead for the rest of the process: no tab, row, `Button`, or
`onTapGesture` reacts, and new content's `onAppear`/`task` work never runs
(an empty Markdown preview). AppKit-backed controls and keyboard menu
commands (Ctrl-Tab) still work, which makes it look like a hit-testing bug.
`hasItemsConforming(to:)` never raises, for the same pasteboard.

Production hit (pid 40811, 2026-10-20 00:11:56): a Terminals-panel row
dragged onto an Ensemble board. `CanvasFileDropDelegate.validateDrop` (and
the temporary `DragDiag` line in `dropEntered`) called
`itemProviders(for: [.rafuEnsembleDrag])`; the same assertion
(`NSFilePromiseReceiver.m:300`) also appears at 2026-10-19 23:20:18 in an
earlier session.

## Reproduction and evidence

- Live wedged app: `/usr/bin/log show --predicate 'process == "RafuLightning"'`
  around the drag shows, in order: "data requested for type
  com.apple.NSFilePromiseItemMetaData", "Assertion failure in
  NSFilePromiseReceiver.m:300", "Canceling drag because exception was raised
  during a dragging session". `lldb` read-only: `contentView hitTest:` at a
  tab returns the hosting view itself (nothing covers the tabs), no sheet,
  no modal, no live `NSDraggingSession`, mouse buttons up.
- Offscreen headless harness (in-process `NSApp.postEvent`, no `CGEvent`, no
  cursor): a SwiftUI `.onDrag` with `dev.vatsalsaglani.rafu.ensemble-drag`
  (declared system-wide by the staged app) puts the promise types on the drag
  pasteboard. Calling the SwiftUI `_PlatformDraggingDestinationView`'s
  `draggingEntered` with a synthetic `NSDraggingInfo` over that pasteboard
  and a delegate that calls `itemProviders(for: [privateType])` raises the
  exception above (caught with an ObjC `@try` wrapper). Every later tap in
  that window then fails (3 of 3); with `hasItemsConforming` only, all taps
  work (3 of 3).

## Verification

`./script/test.sh` (runs `CanvasDropHoverSafetyTests`). Manual: drag a
Terminals-panel row, an Agent History row, a Files row and a tab over an
Ensemble board and over an editor group, drop on a non-target and cancel with
Escape, then click tabs and sidebar rows.

## Related

- `Sources/RafuApp/Canvas/Views/CanvasFileDropDelegate.swift`
  (`CanvasBoardDropHoverKind`)
- `Sources/RafuApp/Views/EditorCanvasView.swift` (`EditorDropDelegate`,
  `TabStripReorderDropDelegate`: already presence-only while hovering)
- `Tests/RafuAppTests/Canvas/CanvasDropHoverSafetyTests.swift`
- [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md),
  [`appkit-drag-destination-type-precedence.md`](appkit-drag-destination-type-precedence.md)
