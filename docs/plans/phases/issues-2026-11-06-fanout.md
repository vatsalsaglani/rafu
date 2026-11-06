# Issues 2026-11-06 fan-out

- Source: `rafu-issues/issues-6-11-26/issues.md` (local, untracked: screenshots and a recording).
- Advisors: two read-only Fable briefs (Ensemble A–E; Files, paths, Markdown F–I), 2026-11-06.
- Routing: CLAUDE.md "Model routing for subagents".
- Coordinator: the primary checkout on `main`. It creates the worktrees, merges, runs
  both test modes on `main`, owns `docs/references/README.md`,
  `docs/decisions/README.md`, and this file.

## Constraint

The development Mac has 8 cores and 8 GB of memory. Run at most three worktree builds
at the same time. Each worktree has its own `.build`; delete it after the branch is
committed (AGENTS.md).

## Groups

| ID | Branch | Items | Model | Depends on |
|---|---|---|---|---|
| G1 | `issues/mac-app-removal` | B: remove Mac App cards, `app_open`/`app_inspect`, AX docking; legacy cards decode as tombstone notes | Sonnet, high | none. Merge first. |
| G2 | `issues/files-tree` | F: Files multi-select (⇧-click, ⌘-click, ⇧↑↓), Move to Trash (context menu, ⌘⌫, confirm, undo), Copy Paths. G: ⇧⌘C relative / ⌥⌘C absolute path of the active file, status-bar notice | Opus, medium | none |
| G3 | `issues/markdown-image-paste` | H: paste/drop images into saved `.md` files, assets folder setting | Opus, medium | none |
| G4 | `issues/ensemble-drop` | A: one owner for the drop preview, `draggingEnded` clear, board notice separate from the save-failure banner, external images copied into the workspace with consent; E-fix 3 (decode images from a file URL) | Opus, medium | G1 |
| G5 | `issues/ensemble-popups-shortcuts` | C: board key map, key badges on tools and Add tiles, Tools menu. D: Rafu popup components (ADR 0033), Open Ensemble, Icon Library, Add palette, Ensemble dialogs and confirms. E-fix 1: release the Icon Library panel, bound the icon cache | Opus, medium | G1 |
| G6 | `issues/mdx` | I: `.mdx` routing, MDX block scanner, native component registry, fallback block (ADR 0034) | Opus, medium | none (runs in stage 2 for the build limit) |
| G7 | `issues/ensemble-memory` | E-fix 2: hibernate a document hidden under a board; memory profile note with the user's S0–S6 measurements | Sonnet, high, or coordinator | G2 merged (shares `WorkspaceSession.swift`) |
| G9 | `issues/all-dialogs` | Every alert and confirmation in the Rafu popup language (ADR 0033 amendment): `RafuMessagePopup`, `RafuTextFieldPopup`, `RafuPopupPresenter`, footer order | Sonnet, high (user direction) | G5 |
| G10 | `issues/image-polish` | Issues seen only in the screenshots: drop placement avoids cards, themed Files focus ring, shell labels, search-field focus ring, untitled numbering; "Ask Siri" investigated, not changed | Sonnet, high (user direction) | G4, G5 |

Stages: 1 = G1, G2, G3. 2 = G4, G5, G6 (after G1 merges). 3 = G7, then a
documentation pass for the indexes.

## Shared-file rules

- G2 owns `Views/WorkspaceSidebarView.swift`, `Views/WorkspaceStatusBar.swift`, and the
  File menu items in `App/RafuAppCommands.swift`. G5 does not migrate the Rename File
  alert in this round (superseded: G9 migrated it).
- G3 owns the paste/drop region of `Editor/RafuTextView.swift` and the coordinator wiring
  in `Editor/CodeEditorView.swift`. It must not edit `Editor/EditorDragAndDrop.swift`.
- G4 owns `Canvas/Views/WorkspaceCanvasView.swift`, `CanvasFileDropDelegate.swift`,
  `CanvasDropPreview.swift`, `Canvas/Adapters/CanvasScrollBridge.swift`,
  `CanvasBoardState.swift`, `WorkspaceCanvasActions.swift`, `WorkspaceCanvasStore.swift`,
  `CanvasPreviewLoader.swift`, and every `errorMessage` writer in `Canvas/`.
- G5 owns `Support/RafuPopupComponents.swift` (new), `CanvasAddMenu.swift`,
  `CanvasCommands.swift`, `CanvasDialogView.swift`, `CanvasConnectionDialog.swift`,
  `CanvasPresentations.swift`, `Canvas/Whiteboard/*`, `Canvas/Diagram/CanvasDiagramMenus.swift`,
  `CanvasIconLibraryView.swift`, `CanvasIconPackLibrary.swift`, `CanvasBoardKeyMap.swift` (new),
  and the container of `Views/CommandPaletteView.swift`. It leaves the N/T handlers in
  `WorkspaceCanvasView.swift`; the coordinator moves them after G4 and G5 merge.
- G6 touches `Models/EditorDocument.swift` and `CanvasMarkdownCardContent.swift` only
  for the `isMarkdown` predicate.
- ADR numbers: 0033 = Rafu popup language (G5), 0034 = MDX native components (G6).

## Exit criteria

Each branch: `format --fix` → `format --lint` → `build` (no new warnings) → parallel
tests → commit. Coordinator on `main` after each merge: build, parallel and serial
tests. GUI checks are manual by the user (no computer-use automation); each handoff
lists its manual steps.

## Status

| ID | Status |
|---|---|
| G1 | merged (a8b89f8) |
| G2 | merged (50429ac) |
| G3 | merged (9b2e9f1, + validateMenuItem 71238a9) |
| G4 | merged (34f3950, + review fixes F1/F3 dec163e) |
| G5 | merged (2a7aa1d) |
| G6 | merged (a66ede5) |
| G7 | merged (94d8729): no behaviour change; the newest-8 grace keeps the document under a board loaded, so hiding it saves nothing. S0–S6 table awaits the user's measurements |
| G8 | merged (7244528): probe output through pipes, child killed at the cap (disk-fill incident 2026-11-06 17:00) |
| G9 | merged (260033d): no `.alert`, `.confirmationDialog` or `NSAlert` left except the no-window fallback in `RafuPopupPresenter`; `RafuDialogPolicyTests` pins this |
| G10 | merged (c60a2b9) |
| UX Round A | merged (8aad547): fit on arrival, 25 % zoom floor, overview, drop grammar, set-down, seeds, warning hue (brief: Fable UX review 2026-11-06) |
| UX Round B | merged (4f1b033): tab pill and Dock badge, readable small faces, Agents pill, agent provenance with gated Undo, settled memory chip, Resources Ensemble rows |
| UX Round C | merged (f9d8ed9): board name only on the tab, palette in the bar when wide (key monitor on the board), saved tick, Open Ensemble silhouettes, monochrome file icons with a setting, Icon Library density, branch once |

### Open follow-ups

- N and T board keys still live in `WorkspaceCanvasView.swift`; move them to `CanvasBoardKeyMap` (G5).
- `errorMessage` shim writers in `CanvasToolPalette.swift` and `CanvasWhiteboardCardFace.swift` move to `showNotice` (G4/G5).
- G4 review F2 (symlinked root mislabels the hover), F4 (empty folder after rollback, stale `.rafu-import-*`), F5 (raw Cocoa error), F6 (persistent notice for Save As/export failures), F7 (settings row for "always copy" and the asset folder), F8 (decode tests' file).
- G6: unclosed-tag scan is quadratic in document size; Ensemble cards show `.mdx` tags as text.
- G8: Gemini and Cursor adapters keep the `readabilityHandler` + `readDataToEndOfFile` capture race.
- `LauncherRequestRouterTests` (`listenerRestartsAfterStop`, the live-cap test) and `AgentActivityStoreTests.watchSpool` fail under heavy parallel load only (pass alone and serially).
- G10: "Ask Siri" needs an AppKit outline view for the Files tree (SwiftUI owns the context `NSMenu`); measure the drop placement search on a full board; the untitled breadcrumb drag area is gone.
- UX Round A: Indigo ANSI yellow moved from `#D4A24E` to `git.modified` `#D2B958` (Khadi unchanged); confirm the not-allowed cursor on the AppKit drop path; agent-created cards get no landing ring.
- UX Round B: the Dock badge refreshes only from mounted tab items; the provenance badge prunes only at ≥ 50 % zoom; "✓ Allow" without the "Agents:" prefix needs a GUI judgement.
- G9: check sheet sizes and Escape in sheets on screen; two popups fired at once from one view can clash (one sheet per view).
