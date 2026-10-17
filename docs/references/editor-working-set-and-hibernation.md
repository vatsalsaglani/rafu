# Editor working set and hibernation

- Applies to: document lifecycle, TextKit ownership, group moves, and undo.
- Last checked: Swift 6.4, macOS 27.0.1, 2026-10-17. Source review for the
  resource-lifetime amendment. Automated checks are listed in the repair plan;
  interactive checks belong to the user.

## Rule

A document retains its editor resources while visible in a group, dirty, or
among the newest eight documents by access order. All other clean documents
can hibernate. Dirty documents never hibernate. The policy, document guard,
and loaded-document view path enforce this rule.

The loaded document owns a non-observed `EditorResources`. TextKit owns the
live text. The owner also retains the coordinator, capped undo manager, and
syntax pipeline. The coordinator holds the document weakly. A SwiftUI host
can change without changing these resources. Group moves and splits transfer
the scroll view to the new host. They do not read disk or clear undo. Late
callbacks from an old host cannot act on the new host.

Clean hibernation captures selection and scroll, then releases resources.
Refocus reads disk and restores those values, clamped to the current text.
The document stays clean. `pendingDirtyText` remains a first-load compatibility
seed; structural moves do not write a snapshot there.

Undo has a 200-operation cap. Restoration starts non-visible tabs hibernated,
even when the session has eight or fewer tabs. Only a visible editor in each
group initially loads. Cross-launch cursor and scroll are not persisted.

## Why it matters

The policy limits retained editors without discarding dirty text. The resource
owner preserves undo and parser state when SwiftUI replaces a layout subtree.
A dirty-text snapshot alone could not preserve those objects. This is an
ownership correction, not proof of a latency or memory target.

## Evidence and reproduction

The earlier implementation destroyed editor resources at every structural
remount and rebuilt them from a transient text snapshot. The repair separates
mount identity from resource identity. `EditorLifetimeRepairTests` uses real
TextKit storage and verifies both dismantle orders, moves, undo, save,
hibernation, focus, and weak release. See
[`editor-resource-lifetime-repair.md`](editor-resource-lifetime-repair.md)
for its signposts and exact tests. The reported drag crash was not reproduced.

Hibernation does not send LSP `didClose`. The language server can retain its
own text state after Rafu releases TextKit. Server memory is separate from the
editor working set; no server-memory saving is claimed for this behavior.

## Limits and verification

A clean large file can lose its temporary highlighting override after
hibernation. Scroll restoration is best effort on very large files.

```sh
./script/test.sh --filter 'EditorLifetimeRepairTests|DocumentHibernation|EditorLayout'
./script/build_and_run.sh --verify
```

The user checks tab moves, undo after a split, second-window state, keyboard
focus, and clean-tab refocus. No computer use is authorized for this repair.

## Related code and decisions

- ADR 0006, amended on 2026-10-17.
- `Sources/RafuApp/Editor/DocumentHibernationPolicy.swift`
- `Sources/RafuApp/Models/EditorDocument.swift`
- `Sources/RafuApp/Editor/CodeEditorView.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `docs/plans/phases/editor-performance-repair.md`
- `docs/references/swiftui-appkit-boundary.md`
