# Editor tab reorder vs. split: three-zone drop-target model

- **Applies to:** `EditorDragAndDrop.swift` tab-strip reorder, `EditorLayoutState` tab insertion, `EditorCanvasView` drop zones and insertion indicators
- **Last verified:** Swift 6.2, macOS 26, 2026-07-24

## Rule or observed behavior

The editor canvas defines three mutually exclusive drop zones that resolve which tab action is taken when a tab or file is dropped:

1. **Tab strip (y ∈ [0, 28] where 28 = `RafuMetrics.tabBarHeight`):** reorders the dropped tab within its group (or moves it to the target group's insertion index if dropped on a different group's tab strip). A tab dragged over the tab strip never splits.

2. **Body edge bands** (≤ 25% of either edge, or min(width/4, height/4), = 100pt cap): splits the editor group and moves the dragged tab into the new split.

3. **Body center:** moves the dragged tab into an existing editor group without splitting.

## The prior bug: split hijacking tab drops

A previous implementation had a SINGLE group-wide drop target with an edge band of `min(size/4, 100)`. Because the tab bar sits at `y ∈ [0, 28]`, which is ALWAYS inside the 100pt top split band, every tab-bar drop was incorrectly classified as a split and moved the tab into a new vertical split instead of reordering it within the same group.

**Fix approach:** Rather than relying on overlapping SwiftUI `.onDrop` targets and their hit-test priority, the group's split-movement `.onDrop` handler is STRUCTURALLY scoped to exclude the tab bar. The tab bar's drop zone is a sibling view within a `GeometryReader` placed one level down from the group, preventing the tab bar's coordinate space from ever reaching the split handler. This is deterministic and does not rely on view-priority arbitration — a tab-bar drop PHYSICALLY CANNOT reach the split delegate.

## Off-by-one insertion index

Moving a tab from position `i` to a visual gap at position `j` within the same group requires an index adjustment: `moveTab`/`insert` interpret the index AFTER the removal, so the computed visual gap index must become `j > i ? j - 1 : j`. This is the central correctness risk and is covered by dedicated unit tests.

## Tab frame registration and horizontal scroll

The tab strip is implemented as a `ScrollView(.horizontal) { HStack { ForEach(tabs) } }`. Reordering depends on precise x-coordinate resolution of each tab within the scrolled content:

- Each tab registers its frame via a `TabStripFramePreferenceKey` and publishes its bounds
- The reorder drop delegate collects these frames and matches the pointer's x-coordinate against them
- A named coordinate space `"editorTabStrip"` is shared between the drag gesture and the drop targets so that pointer x remains valid when the strip is horizontally scrolled
- If a tab's frame preference hasn't published yet (first layout pass after adding a new tab), that tab is skipped from the ordered-frames array; this could momentarily shift computed indices by one slot. Risk is sub-frame (single-frame lag); transient.

## Drag type filtering

The tab strip registers ONLY `.rafuEditorDrag` (a private UTType defined in the app) for drag acceptance. Public types like `.fileURL` are explicitly NOT accepted by the tab strip; instead, they are handled by the body's `EditorDropForwardingScrollView`. This separation ensures:

- Tab/file drags from the sidebar fall through to the body handler (split or move)
- Finder file drops reach the body handler (open in new tab or split)
- A sidebar file dropped directly on the tab bar is now a harmless no-op (previously it would wrongly force-split)

## Why it matters

Reorder vs. split is a foundational UI interaction; users expect it to work predictably. The prior bug where EVERY tab-bar drop split was a regression that made it impossible to reorder tabs within a single group. The three-zone model is standard in most IDEs (VS Code, Sublime Text) and is intuitive once the user discovers it. The structural scope fix (not a hit-test priority fix) makes the behavior deterministic and testable.

## Reproduction or evidence

- Unit tests for insertion-index computation: moving tabs from position `i` to position `j` across all combinations where `i < j`, `i > j`, and `i == j`
- Tab frame capture and named-space coordinate tests
- Drop-zone classification tests: pointer over tab strip, edge bands, center, and boundaries
- Full integration test with live drops in the GUI (pending manual user acceptance pass)

## Verification

```bash
swift build
swift test --filter EditorDrag
swift test --filter EditorLayout
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

`swift test`: 1294 tests passing, 0 build warnings. `./script/format.sh --lint`: clean. `./script/build_and_run.sh --verify`: app launches successfully. Manual GUI verification (drag tabs left/right, verify reorder; drag tabs to edges and corners, verify split; drag files from sidebar and Finder to tab strip and body) pending user acceptance pass.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorDragAndDrop.swift` — `TabStripDrop.insertionIndex`, `EditorDropForwarding`, drop-zone classification
- `Sources/RafuApp/Editor/EditorLayout.swift` — `EditorGroupState.move(_:toInsertionIndex:)`, `EditorLayoutState.reorderTab(…)`
- `Sources/RafuApp/Models/WorkspaceSession.swift` — `reorderOrMoveEditorTab(…)` command routing
- `Sources/RafuApp/Views/EditorCanvasView.swift` — `TabStripFramePreferenceKey`, `TabStripReorderDropDelegate`, insertion indicator, drop-zone geometry
- [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) — private UTType registration and AppKit drag-destination ordering
- [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md) — tab lifecycle
- `docs/plans/phases/pre-initial-push-workbench.md` — acceptance item #13 (tab drag/reorder)

## Known minor gap

A sidebar file dropped directly on the tab bar is now a harmless no-op (the drop is consumed by the tab strip, which doesn't handle `.fileURL`, and the body handler never sees it). Previously, this drop would wrongly force-split. The new no-op behavior is correct but lacks user feedback. A future polish pass could add a visual "not here" indicator or forward sidebar files to the body handler even when dropped on the tab strip.

## Latent design note: `.onMove` unsuitability

`.onMove` (SwiftUI's List/Form reorder gesture) is UNUSABLE for this component because the tab strip is `ScrollView(.horizontal) { HStack { ForEach } }`, not a `List` or `Form`. `.onMove` only works within a `List` context where the framework controls layout; custom layouts must implement drag-and-drop via `.onDrag`/`.onDrop`.
