# Editor resource lifetime across group changes

- Applies to: `CodeEditorView`, `EditorDocument`, editor group moves and splits,
  and hidden multi-caret overlays.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

A loaded document retains one non-observed `EditorResources` owner. That owner
retains the scroll view and coordinator. The scroll view retains TextKit; the
coordinator retains the capped undo manager and syntax pipeline. The coordinator
has a weak document reference. Live text stays in `NSTextStorage`.

Each SwiftUI mount gets a new `EditorMountHostView`. A structural move transfers
the retained scroll view to that host. It does not read disk, reset selection,
clear undo, detach Find, or tear down the parser. A late update or dismantle
callback must match the active host and coordinator before it can act. A host
that lost ownership has no editor resources to remove.

Clean hibernation captures the current selection and scroll, then releases
resources and document actions. Dirty hibernation remains forbidden. Resource
release is idempotent. Action cleanup also checks coordinator ownership, so an
old owner cannot clear actions installed by a replacement owner. Document and
session callbacks in retained AppKit objects must capture documents and sessions
weakly. A callback must not capture an enclosing SwiftUI view that owns either.

The existing `pendingDirtyText` property remains as a compatibility input. Moves
do not write it. A caller-supplied first-load seed still takes precedence over
disk. This preserves existing clients and tests while removing structural moves
from the snapshot path.

A cross-group edge drop calls `EditorLayoutState.split(group:at:moving:)` once.
It collapses an empty source only after the target split exists. The session
must then update selection, hibernation, and persistence once. Same-group splits
can still leave an intentional empty pane.

Tab visibility is explicit. A hidden host hides its AppKit scroll view and
stops the multi-caret timer. Showing it restarts the timer unless Reduce Motion
is active. Reduce Motion also disables the group drop-preview spring.

## Evidence and reproduction

The source review identified structural teardown resetting undo and parser
resources. The runtime review measured one 53.73 ms editor creation. It did not
complete a verified tab move or identify a drag crash. These are separate facts.

`EditorLifetimeRepairTests` exercises actual TextKit text, undo/redo, multiple
selections, dirty state, save after a move, both dismantle orders, repeated moves,
clean and dirty hibernation, weak document release, hidden caret timers, responder
transfer, and cross-group split topology. The tests await load and save tasks;
they use no fixed sleeps. They pass in the integration checkout.

The coordinator's first test compilation rejected a mutating layout call inside
`#require`: the macro tried to mutate its immutable closure argument. Evaluate
`layout.split(...)` first, then pass its optional result to `#require`. This keeps
the mutation outside macro capture. The corrected test passes in the integration checkout.

The `EditorLifetime` signpost category uses subsystem
`dev.vatsalsaglani.rafu`. `EditorCreate` measures editor construction;
`EditorMount` measures host attachment. `EditorCreated`, `EditorUnmounted`, and
`EditorReleased` are lifetime events. There is no per-document log store and no
text, path, URL, or document name in the signpost payload. Compare create counts
with mount counts during repeated moves. A move should add mounts without adding
editor creations. Measure this before making a performance claim.

## Verification commands

Run these in the coordinator's machine build slot:

```sh
./script/test.sh --filter EditorLifetimeRepairTests
./script/test.sh --filter EditorLayout
./script/test.sh --filter DocumentHibernation
./script/test.sh --filter MultiCaret
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
```

The coordinator checked a second window, keyboard Find and Settings, a dirty tab
split, undo/redo/save after the split, large-file navigation and scrolling, and
full-screen entry/exit in Rafu Lightning. Automated pointer drags did not move a
tab, so drag behavior remains unverified. Active language servers and changed
accessibility settings were not exercised. Comparable profiling remains pending.

### Native deallocation synchronization

On this SDK and OS, the unmounted native text view can outlive its document,
resource owner, coordinator, scroll view, and ruler. An immediate weak-reference
assertion failed even after an autorelease pool and a main-queue callback. A
standalone AppKit-only TextKit 1 example showed the same immediate retention.
A reference trace included native notification, dispatch, and text-layout paths;
it did not establish that each reported reference was a strong owner.

The regression test now associates a test-only deallocation probe with the
text view and awaits its `AsyncStream` event. It still requires all weak owners
and the view to become nil. Its one-minute limit detects a persistent cycle;
there is no fixed sleep or production teardown workaround. The isolated test
passed in 1.156 seconds. Construction and teardown use separate synchronous
autorelease pools; a thread-local pool must never span an async suspension.
Evidence: `/tmp/rafu-repair-20261017/lifetime-deinit-event.log` and
`native-lifetime.swift`. Run `./script/test.sh --filter editorDoesNotRetainDocument`
to repeat the app regression.

## Related decisions and code

- ADR 0006 was amended on 2026-10-17 for document-owned TextKit resources
  and host transfer. The working-set bound and dirty-buffer rule are unchanged.
  `pendingDirtyText` remains the compatibility input described above.
- `Sources/RafuApp/Editor/CodeEditorView.swift`
- `Sources/RafuApp/Models/EditorDocument.swift`
- `Sources/RafuApp/Editor/EditorLayout.swift`
- `Sources/RafuApp/Editor/MultiCaretOverlayView.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Tests/RafuAppTests/EditorLifetimeRepairTests.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`
- Coordinator plan: `docs/plans/phases/editor-performance-repair.md`
- Related notes: `editor-working-set-and-hibernation.md`,
  `swiftui-appkit-boundary.md`, and `editor-tab-reorder-drop-zones.md`.
