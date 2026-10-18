# macOS redesign: "One Gold Thread"

- Status: Active implementation (user direction, 2026-10-18).
- Source specification: [`macos-redesign/review.html`](macos-redesign/review.html)
  (open it in a browser, or grep it). Finding IDs (C1–C19, E1–E12, G1–G16,
  T1–T8, N1–N6, S1–S8) and section numbers (06 specs, 07 Canvas, 08 motion)
  refer to that file.
- Integration branch: `claude/rafu-macos-redesign-nqcu7h` (a new branch of `main`).
- The user accepted every suggestion and every new capability in the review.
  The user asked to ignore ADR constraints for this work. Do not edit ADRs.

## Direction in one paragraph

The interface is calm Indigo/Khadi cloth. Gold (`accent`/`focusRing`) is a
thread that appears only for keyboard focus inside content, the current
selection, a live agent link, and the one primary action in a view. Everything
else is neutral (`textSecondary`, `borderSubtle`). Relationships are dashed
"stitches"; live message links are solid gold. New York for Markdown and note
prose, SF Pro for UI, SF Mono for code and data. Pointer and keyboard changes
never animate; discrete changes use `RafuMotion`. Haptics (`RafuHaptics`) are
optional, alignment-only, and never the only feedback.

## Shared foundation (already on the integration branch)

- `Sources/RafuApp/Support/RafuMotion.swift` — all animation values from review section 08.
- `Sources/RafuApp/Support/RafuHaptics.swift` — throttled `.alignment` haptic; key
  `canvasHapticsEnabled` (default on), exposed in Settings ▸ General by W5.

## Workstreams and owned paths

Each workstream runs in its own git worktree and branch. Edit only owned paths.
A path marked "region" may be edited only in the named region. If a change is
needed outside the owned paths, make the smallest possible edit and list it in
the handoff under "Edits outside owned paths".

| ID | Workstream | Owned paths | Findings |
|---|---|---|---|
| W1 | Workbench chrome, editor, search, palette, status bar | `Support/RafuTheme.swift`, `Support/RafuWorkbenchStyles.swift`, `Support/RafuControlStyles.swift`, `Support/RafuMetrics.swift`, `Views/FlatWindowChrome.swift`, `Views/WorkspaceWindowView.swift`, `Views/WorkspaceSidebarView.swift`, `Views/EditorTabSwitcherView.swift`, `Editor/EditorTabSwitcher.swift`, `Views/WorkspaceNavigatorView.swift`, `Views/WorkspaceStatusBar.swift`, `Views/ResourcesView.swift`, `Views/CommandPaletteView.swift`, `Editor/DocumentFind.swift`; `Views/EditorCanvasView.swift` regions: find/replace bar, Markdown mode control, tab bar | E1–E12, gold budget for shared styles, G1 panel width, T5 tab overflow |
| W2 | Source Control | `Views/GitInspectorView.swift`, `Views/GitCommitGraphView.swift`, `Views/GitHunkPeekCard.swift`, Git badge/presentation models; `Views/EditorCanvasView.swift` region: diff view header and hunk header | G1–G16 |
| W3 | Terminals | `Views/WorkspaceTerminalsPanelView.swift`, `Terminal/TerminalsPanelModel.swift`, `Terminal/TerminalGroupView.swift`, `Views/TerminalGroupSavedLayoutsSection.swift`, terminal naming helpers | T1–T4, T6–T8 |
| W4 | Ensemble | `Views/ConductorRunsPanelView.swift`, `Views/EnsembleStartCanvas.swift`, `Conductor/Run/ConductorNewRunModel.swift` (strings/presentation), `Views/ConductorGraphCanvas.swift`, `Views/ConductorRunDetailCanvas.swift`, `Markdown/MarkdownFrontmatterCard.swift` | N1–N6 |
| W5 | Settings | `Settings/*`, `AI/AIProviderSettingsSection.swift`, `AI/AIThemeGeneratorSection.swift`, `App/RafuApp.swift`, `App/RafuAppCommands.swift` region: Settings command routing | S1–S8, Canvas haptics toggle, light/dark theme pair |
| W6a | Canvas board, nodes, interaction | `Canvas/Views/WorkspaceCanvasView.swift` (except the edge-drawing block and the edge overlay line, owned by W6b), `Canvas/Views/CanvasCardViews.swift` (except the note body call site, owned by W6c), `CanvasCommands.swift`, `CanvasDialogView.swift`, `CanvasConnectionDialog.swift`, `CanvasPresentations.swift`, `CanvasEditorTabItem.swift`, `CanvasFileDropDelegate.swift`, `Canvas/Adapters/` (except `CanvasNoteEditor.swift`), `Canvas/Integration/CanvasBoardState.swift`, `CanvasViewportActions.swift`, `WorkspaceCanvasActions.swift`, `Canvas/Domain/CanvasDocument.swift` (cards) | C1–C19, review 7.1–7.4, 7.7, node motion and haptics |
| W6b | Canvas edges and live links | new `Canvas/Views/CanvasEdgeLayer.swift`, new `Canvas/Domain/CanvasEdgeGeometry.swift`, `Canvas/Views/CanvasConnectionDrag.swift`, `Canvas/Views/CanvasSessionLinksBar.swift`, `Canvas/Integration/CanvasLiveBridge.swift`; regions: edge block in `WorkspaceCanvasView.swift`, `CanvasConnection` in `CanvasDocument.swift`, one marked edge block in `CanvasBoardState.swift` | review 7.5, 7.6, link status item |
| W6c | Markdown notes | `Canvas/Adapters/CanvasNoteEditor.swift`, new `Canvas/Adapters/CanvasNoteCard.swift`, new note Markdown/task helpers, new `Canvas/Views/CanvasNoteCommands.swift`; regions: note body call site in `CanvasCardViews.swift`, one `.commands` line in `App/RafuApp.swift` | review 7.8 |

All paths above are under `Sources/RafuApp/` unless they start with `docs/` or `Tests/`.
Tests for owned behaviour go in `Tests/RafuAppTests/` (new files preferred).

## Cross-workstream contracts

These names must match exactly, because no workstream can compile the others.

- **Ports (W6b defines, W6a uses).** W6b adds in `CanvasConnectionDrag.swift`:

  ```swift
  struct CanvasConnectionPorts: View {
      let title: String
      let isVisible: Bool          // hover, selection, or keyboard focus
      let connect: () -> Void      // click/keyboard path: opens the Connect sheet
      let changed: (CGPoint) -> Void   // location in the board coordinate space
      let ended: (CGPoint) -> Void
      let cancelled: () -> Void
  }
  ```

  It fills the card frame (`.overlay { CanvasConnectionPorts(...) }`) and draws
  four ports at the side midpoints. W6a replaces the `CanvasConnectionHandle(...)`
  call in `CanvasCardShell` with it. W6b may delete `CanvasConnectionHandle`.
- **Link status item (W6b defines, W6a places).** W6b replaces
  `CanvasSessionLinksBar` with `struct CanvasLinkStatusItem: View { let board: CanvasBoardState }`
  (capsule "⇄ 1 live · 0 paused" that opens a per-link popover; renders nothing
  when the board has no message links). W6a removes the `CanvasSessionLinksBar(board:)`
  usage and puts `CanvasLinkStatusItem(board: board)` in the new Canvas bar.
  `CanvasTerminalSessionStatus` stays (W6a may move it into the node header).
- **Edge deletion (W6b defines, W6a calls).** W6b adds
  `@discardableResult func deleteSelectedConnectionIfAny() -> Bool` on
  `CanvasBoardState` (extension in a W6b file). W6a's ⌫/Delete handling calls it
  first and stops when it returns `true`. Selecting a card clears the edge
  selection: W6b also adds `func clearConnectionSelection()`, which W6a calls
  when the card selection changes.
- **Note body (W6c defines, W6a hosts).** W6c provides
  `struct CanvasNoteCard: View` and changes only the note body call site in
  `CanvasCardShell` (today `CanvasNoteEditor(...)`). W6a does not edit that call site.
- **Board focus.** "Leave Content" becomes "Return to Board" in every string,
  shortcut ⌃⇥ (Control-Tab). W6a owns the command and the strings.

## Rules for every workstream

1. Read `AGENTS.md`, this file, and the relevant sections of `review.html` first.
2. **No Swift toolchain exists in this Linux environment.** You cannot build or
   test. So: read the definition of every type and function you call; copy
   patterns that already compile in this repository; respect Swift 6 strict
   concurrency (the GUI target is `MainActor` by default); target macOS 15 APIs
   only; grep every symbol you rename or remove and update all call sites and tests.
3. Theme colours only through existing palette tokens (`theme.palette.*`). No
   hard-coded colours. No new required theme JSON keys.
4. Keep live document text out of observable state (AGENTS.md invariants).
   Keep process start explicit: nothing starts without a visible user action.
5. Every icon-only control gets `.help(...)` and an accessibility label. Every
   contextual (hover) action is also in a menu.
6. Glossary: card (UI word for a Canvas node), Return to Board, Not running
   (not "Parked"), Message link, Relationship, "1 pane"/"2 panes", title-case
   headers (no all caps), ellipsis "…" when an item opens a further step.
7. Update tests that assert changed strings or presentation. Add Swift Testing
   tests for new pure logic (geometry, formatting, parsing, state machines).
8. Commit in your worktree on a branch named `redesign/<id>-<topic>`. Do not push.
   Do not delete `.build` (it does not exist here).
9. Handoff: branch, commit SHAs, findings done, findings skipped (and why),
   edits outside owned paths, tests added/changed, compile risks you see.
