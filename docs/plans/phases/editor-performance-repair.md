# Editor performance and UI repair

Status: In progress, 2026-10-17. This work supports the pre-initial-push
workbench contract. It adds no product scope. The user requested eight
separate worktree chats and local integration without commits or publication.

## Base and evidence

All workers start at `84fd5f42524082dcded7a6d0c8c2697a279302d1`.
The primary checkout is the integration tree. Preserve the four uncommitted
changes in `/Users/vatsalsaglani/.codex/worktrees/03e4/rafu`.
Review the source report in the source chat's 2026/10/17 visualization folder
and `/tmp/rafu-runtime-review-20261017/evidence/runtime-review.md` and
`editor-analysis.md`. The title-bar defect is confirmed. Drag crash and lasting
scroll freeze are not reproduced. Debug trace numbers are not release budgets.

## Ownership

Paths below are relative to `Sources/RafuApp` unless stated otherwise.
Each worker also owns new, uniquely named tests and a focused reference note.
Shared indexes, this plan, config, and final integration belong to the coordinator.

1. **Editor lifetime:** `Editor/CodeEditorView.swift`, `Models/EditorDocument.swift`,
   `Editor/EditorLayout.swift`, `Editor/EditorDragAndDrop.swift`,
   `Views/EditorCanvasView.swift`, `Editor/MultiCaretOverlayView.swift`.
   Preserve dirty text, undo, selection, focus, and actions through moves.
   Use one transaction for a cross-group split. Guard stale teardown.
2. **Viewport layout:** `Editor/RafuTextView.swift`. Bound caret and decoration
   geometry to the visible range. Send any CodeEditorView patch to coordinator.
3. **Gutter:** `Editor/EditorGutterRulerView.swift` and a new line-index helper.
   Maintain one edit-driven index. Combine width updates. Preserve newline and
   Unicode semantics and ruler tiling.
4. **Syntax:** `Editor/SyntaxHighlighter.swift`, `Editor/Syntax/SyntaxParsingActor.swift`,
   `Editor/Syntax/SyntaxByteOffset.swift`, `Editor/Syntax/SyntaxSignpost.swift`.
   Bound queued snapshots, preserve edit ordering, and reject stale results.
5. **Find:** `Editor/DocumentFind.swift`. Stop inactive refresh work, move active
   search off the main actor, and preserve explicit find/replace commands.
6. **Navigation and restoration:** `Models/WorkspaceSession.swift`,
   `Services/WorkspaceRestorationStore.swift`, `App/ExternalOpenRequests.swift`,
   and `Tests/RafuAppTests/WorkspaceGotoLocationTests.swift`. Remove synchronous navigation
   reads, preserve dirty-buffer precedence, combine persistence, and flush close.
7. **Window and appearance:** `Views/FlatWindowChrome.swift`,
   `Views/WorkspaceWindowView.swift`, app scene entry file, welcome view.
   Fix empty-window chrome. Simplify empty panels and redundant boundaries.
   Send EditorCanvasView proposals to coordinator; do not edit that file.
8. **Test and build:** `Tests/RafuAppTests/LanguageServersCatalogModelTests.swift`,
   `ScratchRecentsProbe.swift`, `ResponsiveNavigationPresentationTests.swift`,
   `SettingsPresentationTests.swift`, `ThemedControlStyleScanTests.swift`,
   `RafuWorkbenchStyleContractTests.swift`; `script/build_and_run.sh`,
   `Support/RafuWorkbenchStyles.swift`, `docs/references/build-and-run.md`.
   Review and transfer the existing compatibility patch. Fix the test compiler
   failure. Remove only redundant or false-pass assertions with sound coverage.
   Later grants: pure `Models/GitTreeBadge.swift` and
   `LanguageIntelligence/Catalog/ServerPack.swift` and
   `Terminal/NotchHUDGeometry.swift` isolation fixes, the one redundant
   optional fallback in `Tests/RafuAppTests/Conductor/ProcessAttributionTests.swift`, and the
   nonisolated-extension reference note. Coordinator owns the fixture exclusion
   in `Package.swift`. Find also owns existing `EditorFindTests.swift` and
   `EditorFindFocusRoutingTests.swift` for async completion updates.

## Dependencies and gates

Workers implement in separate worktrees. They do not edit each other's files.
Worker 1 sends WorkspaceSession requests through the coordinator to worker 6.
Workers 2, 4, and 5 send CodeEditorView requests through the coordinator to worker 1.
Existing test files outside the ownership list require a specific ownership grant.
The coordinator granted worker 1 the two obsolete seed/remount tests in
`DocumentHibernationPolicyTests.swift`; these now exercise the actual editor.
Workers leave results in their own chats; the coordinator reads them.

No commits, pushes, pull requests, releases, or Codex restart are authorized.
Do not start SwiftPM, launch apps, or profile without a coordinator build slot.
Prefer one integrated build cache to eight cold caches. Do not delete a failed
cache. Run only one expensive build, test, or profile operation on this machine.

Final automated gates: format fix, lint, build, parallel tests, serial tests,
and canonical Rafu Lightning launch verification. The user later authorized
computer use. The coordinator checked a second window, keyboard Find and Settings,
a dirty tab split with undo/redo/save, large-file caret navigation and scrolling,
and full-screen transitions. Pointer-drag attempts did not move a tab; this is
an unverified check, not evidence that a drag crash is fixed. Comparable runtime
profiling is still pending. Never infer speed from code changes alone.

## Integration review

The coordinator amends ADR 0006 for stable document-owned TextKit resources.
The working-set bound remains eight recent editors plus visible and dirty
editors. Structural moves no longer use text snapshots. Review found and
corrected an inherited NSObject notification-selector collision, Find temporary
attribute updates during TextKit edit processing, and request-state gaps.
The window worker reviewed syntax and navigation concurrency. The test worker
reviewed viewport code and Find concurrency. No worker ran SwiftPM in its
worktree; all builds and tests use the primary checkout.

Runtime speed, a drag-crash fix, and memory-budget compliance remain unproved.
Use automated regression results for behavior only. Keep the remaining interactive checks
and a comparable runtime trace as follow-up work.

## Integration verification notes

Focused repair tests pass, including the native text-view deallocation event.
The first full parallel run also encountered a long Vision OCR model compilation
in `EditorTabVisibilityPresentationTests`. A process sample showed the native
recognizer and model compiler. Two close-save tests exceeded their time limits,
and an existing usage-TTL test failed during that delay. All three pass in an
isolated run. Their timeouts and behavior assertions were not relaxed. Final
parallel and serial checks must run after formatting and all file edits.

The existing SwiftTerm resource-bundle build warning remains documented in
`docs/references/test-source-policy-and-bookmark-isolation.md`. It is not suppressed. No dependency source was changed.

## 2026-10-17 user follow-up: file and window interaction

The user requested support for the 6,722,977-byte text file in the screenshot,
a usable top window drag area and native double-click behavior, single-click
file opening, shorter documentation hover delay, and Settings/Ensemble surfaces
that keep existing file tabs accessible. This extends the repair scope within
the workbench phase. Four GPT-6.1 Sol medium subagents work on disjoint paths in
the shared integration checkout. The coordinator owns hover timing, shared
indexes, cross-file integration, all builds/tests, and app checks. No worker may
run SwiftPM, launch an app, modify another worker's files, or commit.

- Large-file worker: `Services/WorkspaceFileService.swift`,
  `Editor/DocumentGuardPolicy.swift`, focused file-service tests, ADR 0019 and
  large-file reference notes. Preserve a bounded read and guarded editing.
- Window worker: `Views/FlatWindowChrome.swift`, narrow new drag-region helper,
  focused window tests, window-chrome note. Coordinate any other view changes.
- Files worker: `Views/WorkspaceSidebarView.swift`, focused sidebar tests and
  single-click reference note. Preserve folder disclosure, context menus, drag,
  keyboard selection, and editor-to-tree reveal.
- Canvas worker: `Views/EditorCanvasView.swift`, `Models/WorkspaceSession.swift`,
  narrow new canvas/tab helpers, focused tests and related ADR/reference note.
  Keep files and split ownership intact when Settings or Ensemble is selected.
- Coordinator: `Editor/RafuTextView.swift` hover timing and request lifetime,
  plus integrations requested by workers. Canvas worker must not change the
  diff-hover implementation without coordination.

Final gates remain format, lint, build, full parallel and serial tests, canonical
Rafu Lightning launch, and targeted UI checks. Preserve all earlier uncommitted
repairs. Do not commit, push, or publish.

Follow-up integration grants: the canvas worker may suppress the redundant header
in `SettingsCanvas`, `EnsembleStartCanvas`, `ConductorGraphCanvas`,
`ConductorRunDetailCanvas`, and `ConductorNewRunCanvas` (in
`ConductorRunsPanelView`), and guard delayed focus in these retained surfaces.
A narrow auxiliary hosting boundary owns responder release. The coordinator also
owns `CodeEditorView.EditorMountHostView` visibility cleanup and adds the top drag
strip in `WorkspaceWindowView`. Shared reference updates belong to the coordinator.
