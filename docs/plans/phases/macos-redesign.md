# macOS redesign: "One Gold Thread"

- Status: Implemented; local macOS build and UI follow-up completed. See the
  local verification scope below; full accessibility and haptic checks remain.
  Started on user direction, 2026-10-18. See "Status and results" at the end.
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

## Status and results

Branch `claude/rafu-macos-redesign-nqcu7h` (new branch of `main`, base
`dcf2d68`). All workstreams below are merged on it. The user's direction was to
implement every suggestion and new capability and to ignore ADR constraints; no
ADR was edited.

### Verification actually done

- No macOS SDK was available. A Swift 6.2 Linux toolchain (swift.org,
  ubuntu24.04) was installed at `/opt/swift`. See
  [`../../references/linux-swift-verification.md`](../../references/linux-swift-verification.md).
- `swiftc -parse -swift-version 6` over all `Sources/` and `Tests/`: 0 errors
  after every merge.
- `swift-format lint --strict --recursive Sources Tests` with the repo
  `.swift-format`: clean.
- **No app build and no repo test run happened.** `RafuCore` imports `Darwin`
  and `RafuApp` needs SwiftUI/AppKit, so neither builds on Linux.
- Pure logic was compiled and tested in scratch SwiftPM packages outside the
  repo (file copies, `import CoreGraphics`/`SwiftUI` swapped to `Foundation`,
  `@testable import` renamed, `defaultIsolation(MainActor)` to mirror the GUI
  target). Roughly 250 Swift Testing tests passed across the workstreams and
  the Canvas audit (the Canvas audit alone ran about 107 or more tests in 8 or
  more suites). These are scratch runs, not the repo test suite, and they are
  not evidence for parallel or `--no-parallel` repo runs.
- `-warn-long-expression-type-checking` measured slow mixed `Double` x
  `CGFloat` Bezier math (2.8 s and 5.5 s). It was rewritten with `Double`
  locals.
- Three compile audits (A1 Canvas; A2 panels and settings; A3 chrome
  and editor) read every changed symbol against its definition and checked
  risky SwiftUI/AppKit APIs against Apple documentation JSON. Fixed by the
  audits: a `_ = x` statement inside a ViewBuilder body (must be `let _ = x`);
  two stale source-scan test literals; very long modifier chains split
  (`WorkspaceCanvasView.boardSurface`, `CanvasCardShell.body`); an 11-child
  `HStack` grouped; a nonisolated enum for cross-module test use; an explicit
  `Font.` on an `AttributedString` attribute; a long `||` chain split.

### W1 Workbench chrome, editor, search, palette, status bar

Landed:

- Editor-group border is neutral (`borderSubtle`). With more than one group,
  the focused group gets a `borderStrong` hairline. Gold stays only on a focused
  terminal (`TerminalSurfaceBorderStyle.Context.editorGroup(isFocused:hostsTerminal:hasSiblings:)`).
- Gold budget applied in shared styles; focus rings use `\.isFocused` with the
  `focusRing` token (see the visual-system reference).
- Window buttons are always visible again (they were hidden until hover). New
  28 pt `WindowTitlebarRow` with a plain sidebar toggle.
- Right panel minimum, ideal, maximum width 300, 340, 520 pt.
  `rafuNoWrapSegmentLabel()` helper.
- Files header: workspace name, Filter Files (opens the Go to File palette),
  New File and New Folder. Rows are at least 24 pt.
- Tabs: close control on selected or hovered tab; dirty dot becomes x on hover
  (`EditorTabAccessory`); tab strip scrolls under a 16 pt fade.
- Find bar compact; new Find in Selection scope (`FindSelectionScope`, protocol
  `findScopeSelection()` with a default implementation).
- Search toggles Aa, ab, .* (`RafuOptionToggle`); one-line results with the
  match highlighted.
- Markdown Source | Preview | Split control. Palette shortcut chips and footer
  "Navigate / Open / Close".
- Resources popover is summary-first; status bar and popover share
  `ResidentMemoryMonitor` and `ResourceMemoryFormat`. "Local editor" removed
  from the status bar; language-server item added.
- Wording: "Parked" became "Not running"; "1 pane"/"N panes"; "Start All Panes".

Skipped:

- File-tree indent not changed (system `DisclosureGroup`).
- No preview-tab concept exists, so none was added. The dashed line is the
  `StitchedAccentEdge` selection motif and was kept.

### W2 Source Control

Landed:

- `GitStatusPresentation` is the single source of status letters (U untracked,
  A added) for the panel and the Files sidebar.
- One-line rows with a status-letter badge; `GitSectionPicker` (icons below
  320 pt); branch pull-down (Switch To, Create Branch..., Merge into Current);
  neutral sync capsule ("up n, down n" / "No upstream" / "No remote"); Fetch,
  Pull, Push disabled without a remote; "Publish to GitHub..." when available.
- Commit composer: generate button in the field (Option-Command-G), "Commits N
  files", Command-Return commits.
- Diff header names the real comparison. Working tree: "Working Tree <-> Index"
  (git diff compares to the index). Staged: "Index <-> HEAD". Commit:
  "<hash> <-> Parent".
- History: two-line rows, `GitRelativeTime`, ref capsules; commit details
  expand under the row; hash split by characters without a hyphen
  (`GitHashDisplay`).

Skipped (no `GitService` primitive): branch rename and delete, Add Remote,
Discard Hunk, Open in Terminal for worktrees, more diff context (diff stays at
`--unified=3`).

### W3 Terminals

Landed:

- "Start Agent" uses a popover, not `Menu`, because vendor SVG icons render at
  1 x 1 pt inside `NSMenu` (they appear as dots). Rows use `FileIconView` at
  16 pt. `agent-terminals.md` still describes the icon grid and needs updating.
- `TerminalNaming`: automatic names ("zsh - fixtures"), plurals, states,
  subtitle cleanup. Split "+" uses `Menu(primaryAction:)`. Stopped pane shows
  "Start Shell".
- Saved groups: double-click opens; "..." menu; new rename
  (`WorkspaceSession.renameSavedTerminalGroup`); new delete confirmation. Group
  menu reordered: "Save Layout..." always opens the naming sheet; "Update Saved
  Layout" for saved groups.

Note: `TerminalShellPickerView` is now unused. It is kept because tests pin it.

### W4 Ensemble

Landed:

- "+" menu (New Run..., New Ensemble..., New Workflow from Template...), graph
  button, `ConductorSectionPicker` (`ViewThatFits` with an icons fallback). The
  panel switches to Runs while a full-tab Ensemble surface is open.
- New Ensemble: title-case headers, 32 pt CLI rows, budget rows. New Run form
  in `ConductorFormControls.swift` (theme card, one 128 pt label column,
  bordered prompt editor, base reference field filled from already-loaded
  branches, so no Git process starts).
- Header clipping: the likely cause is `.fixedSize()` text menus in the header
  and rows. They were changed, but the fix is not verified at runtime.
- Activity copy plain. Frontmatter count "N fields" equals the shown rows.
  Attention states use `warning`, not accent.

### W5 Settings

Landed:

- Command-comma and the status-bar gear open the standard `Settings` scene
  (`TabView` panes, 680 pt). `SettingsCommandRouter` was deleted.
  `editor-canvas-routing.md` and `settings-surface.md` are stale.
- General: Canvas haptics toggle. Appearance: new Follow System with a
  light/dark theme pair (`ThemeAppearancePreference`, keys `themeLightChoice`
  and `themeDarkChoice`; the old "system" value still works), radio cards,
  labelled buttons. AI: provider list with + and -, "Save default" only when
  changed (`AIProviderDraftChange`, `persistedIDs`). Language Servers and Agents
  tables; agent custom-model combo field; sign-in state shows "Sign-in needed"
  (not "Update needed", because no version data exists). Usage: drag reorder;
  privacy text visible until first connect. Ensemble skill copy.

Left in place on purpose (unreachable now): `WorkspaceSession.showSettings`,
`closeSettings`, `settingsVisible`; `WorkspaceAuxiliaryTab.settings`;
`EditorCanvasRoute.settings`; the `.settings` cases; the `SettingsCanvas` stub
(opens the window and closes the tab). Also unused: `RafuSettingsSection`,
`RafuSettingsRow`, `LanguageServerCatalogRow`.

### W6a Canvas board

Landed:

- One 36 pt bar with a zoom capsule (Command-9 fit, Option-Command-9 selection,
  Command-0 actual size); viewport scale 10% to 400%; Command-scroll zooms
  about the pointer.
- 32 pt header move handle; no footer; resize zones with `pointerStyle`;
  per-type minimum sizes with resistance and spring; the PTY resizes once on
  mouse-up; two-layer shadows; bring-to-front by `board.cards` array order
  (last on top), skipped for clicks inside native terminal and web bodies to
  keep first responder.
- Snapping (`CanvasSnapper`), guides, haptics; marquee; Align, Distribute, Tidy
  (`CanvasLayoutMath`); full key map including Control-Tab "Return to Board"
  through a local key monitor; Tab and Shift-Tab reading order; N and T on board
  focus.
- Card types: terminal Start Shell block, file excerpt (40 lines, 8 KiB),
  Mac-app Preview badge and popover, web Load. Zoom faces (`CanvasZoomFace`);
  terminals and web unmount below 50% zoom.
- List tables, Open Canvas sheet (`CanvasSummary.cardCount/modified`), Connect
  form, unified card menu, Add menu, Help > Canvas Shortcuts, one-time empty
  board tip (`canvasEmptyBoardTipDismissed`).
- Control-Tab is also Next Tab in the app commands. The key monitor wins only
  while card content is active.

Skipped: Stop for a running terminal (no safe API), image pixel size, file
excerpt selection, "last command" summary, board-focus VoiceOver hint, real
arrow-key menu shortcuts (item titles show hints instead).

### W6b Canvas edges and live links

Landed:

- Pure types: `CanvasEdgeGeometry`, `CanvasLinkState` (Live, Paused,
  Disconnected(reason), Failed(reason), burst policy), `CanvasConnectionRules`.
- Bridge: per-link pause and resume; state mapping (restore paused; stop
  becomes disconnected; conversation changed; transport lost; a refused send is
  failed until the next accepted message or a pause/resume). Accepted-message
  events carry no body.
- Behaviour change: new terminal-to-terminal links start Paused.
- `CanvasEdgeLayer` (below cards), `CanvasEdgeOverlay` (above cards; since
  2026-10-20 interaction chrome only, every edge draws below the cards),
  `CanvasConnectionPorts`, `CanvasLinkStatusItem` (replaces
  `CanvasSessionLinksBar`; "Enable Links" and "Pause Links" are gone, so
  `canvas-live-sessions.md` is stale). The message dot shows only while a
  message is active (`TimelineView`); Reduce Motion uses a badge pulse. Default
  labels "Related to" and "Session link" count as unlabelled.

Skipped: "Show Message Log..." (there is no log).

### W6c Notes

Landed:

- Read mode renders MarkdownUI per top-level block
  (`RafuNoteMarkdownStyling.swift`); task toggles go through the TextKit buffer
  so undo stays intact. Edit mode uses SF Pro with incremental syntax styling
  (`CanvasNoteSyntax`), formatting commands (`CanvasNoteFormatCommand`) and a
  Format menu. A key monitor resolves the Command-B and Shift-Command-L
  conflict while editing. Zoom faces. Links: workspace files open in Rafu;
  http, https and mailto open in the system handler; other schemes are ignored.
  Images load only from workspace files.

Known gaps (MarkdownUI limits): Command-C copies rendered text (a "Copy Note as
Markdown" context item exists); no link hover underline; no inline-code radius.

### Audits A1 to A3

A1 (Canvas), A2 (panels and settings) and A3 (chrome and editor) were
read-only compile audits; their fixes are listed under "Verification actually
done". They do not replace a compiler run.

### Local macOS follow-up (2026-10-18)

Checked on macOS 27.0.1 with Apple Swift 6.4 in Swift 6.2 language mode.
The full app builds and the canonical Lightning launch passes. The first
parallel run found one stale source-policy test that banned the native
Settings tabs now required by this phase. The exception is limited to the
standard Settings host; workbench controls retain the theme guard.

The local UI pass found and fixed clipped model refresh controls in Agents
settings, inherited gold tint on secondary Git and Canvas menus, and Canvas
zoom controls pushed off screen by a large card in a smaller window. See
`docs/references/macos-redesign-visual-system.md` for the native layout rules.

Checks exercised: native Settings tabs and model menu, Canvas note editing,
Control-Tab return to the board, terminal typing, T to create a stopped card,
selected terminal removal, editor Find, a second independent workspace,
and Source Control with a working-tree diff in a test repository.
Haptics, VoiceOver speech, live agent traffic, and the full OS accessibility
settings matrix are not covered by this local pass.

### Required macOS verification

Run on a Mac, in the order from `AGENTS.md`: `swift-format format --fix`, then
`--lint`, `swift build`, `./script/test.sh` (parallel), `./script/test.sh
--no-parallel` (CI gate), then `./script/build_and_run.sh --verify`. Expect
some compile fixes. Then check by hand:

- Visual pass with the right panel at 300 pt and at 520 pt.
- Split "+" menu look; swatch tint inside `NSMenu`.
- Titlebar row layout (`WindowTitlebarRow`) and traffic-light visibility.
- Settings tables inside the grouped `Form`.
- Terminal first-click focus after bring-to-front; the Tab key reaching the
  board; Control-Tab versus Next Tab.
- Ensemble header clipping (W4) at narrow panel widths.
- Second window, keyboard reachability, and VoiceOver/Reduce Motion behaviour
  of the new Canvas controls.

### Window redesign on `main` (2026-10-19)

A separate, user-directed four-increment window redesign landed on `main` after
this phase (703e827, 4c72f8c, 450c453, a28c154, 96e54b3): an `appBackground`
window frame with one raised rounded editor deck, a 40 pt left Activity Rail
carrying all five navigator modes, a custom drag-to-resize sidebar handle, and
detached rounded tab cards with activity dots and a text-only hover preview. It
changes the `WindowTitlebarRow` and tab-strip results recorded under W1 above.
Status, gates, and the open manual checks live in
[`workbench-presentation-upgrade.md`](workbench-presentation-upgrade.md); the
decision is
[ADR 0030](../../decisions/0030-framed-workbench-left-rail-and-detached-tabs.md).
This phase's "Do not edit ADRs" instruction was scoped to these workstreams,
which had no macOS toolchain; it does not bind that work.

### Follow-ups

- After the build is green, remove the unreachable Settings-tab code and the
  unused views listed under W5 and W3.
- Update stale references: `flat-window-chrome-titlebar-merge.md`,
  `editor-canvas-routing.md`, `settings-surface.md`, `canvas-live-sessions.md`,
  `agent-terminals.md`.
- Features marked "Skipped" under W2 and W6a need a `GitService` primitive or a
  safe API first.
