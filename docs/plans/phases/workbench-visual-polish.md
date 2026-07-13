# Workbench visual polish ("wow pass")

## Status

In progress (2026-07-13). Started from the user's hands-on acceptance pass of the
pre-initial-push workbench. Everything was functional but visually flat, several
interaction bugs surfaced, and themes did not fully apply. This brief is the
running log of what is being changed, why, and how — written so the next
agent/model can pick up any thread without re-deriving the analysis.

## User-reported problems (verbatim intent) and root causes

| # | Problem | Root cause (verified in code) |
|---|---------|-------------------------------|
| 1 | Themes "don't come out entirely"; buttons don't pick theme colors | `RafuTheme` decoded only 8 of 23 `ui` keys and 5 of 16 `editor` keys; `git`, `diff`, `fonts` blocks silently dropped. Chrome used `.bar`/`.regularMaterial`/`.accentColor`/hardcoded `.red/.green/.blue` instead of tokens. |
| 2 | File-tree header buttons look disabled, no hover anywhere | `WorkspaceSidebarView` header buttons used `.buttonStyle(.plain)` — draws nothing on hover. No shared hover-capable icon-button style existed. |
| 3 | Command palette ⌘⇧P: arrows don't move selection | `CommandPaletteView` had **no selection state and no key handling at all** — only `.onSubmit` running the first result. |
| 4 | Markdown opens in preview; second .md shows first file's preview | (a) `EditorDocument` hardcoded `.md → .preview`. (b) `MarkdownPreviewView` refreshed via `.task(id: document.revision)`; two unsaved docs share `revision == 0` and the view is reused without `.id(document.id)`, so stale `segments` persisted. |
| 5 | Diff view "pathetic" | Loose two-pane layout, hardcoded `.red/.green.opacity(0.16)` washes, no alignment discipline, no intraline emphasis, theme `diff` tokens never decoded. |
| 6 | Split-drag shows four arrow cards | `EditorDropAffordanceOverlay` rendered four arrow buttons; no drop-zone preview of the resulting pane. |
| 7 | Git + Search should live on the right; left = files only | ADR 0002 put Files/Search/Git in one left navigator with an activity strip. User direction supersedes: left sidebar = file tree only; Search + Source Control move to a right-side panel. |
| 8 | No glass effects | Materials existed but were plain system `.bar` surfaces painted over by nothing; no layered translucency in palette/overlays. |
| 9 | Folder/file icons generic | `FileTreeRow` had a 4-case extension tint; no folder personalization. |
| 10 | AI settings confusing; model id vs display name | One flat field grid; `AIProviderConfiguration` has `name` (per provider) but no per-model alias. |
| 11 | Syntax highlighting shallow | Regex token source only emits ~12 of 24 theme token kinds; theme `fonts` ignored (hardcoded 13pt system mono). SwiftTreeSitter is a version pin only, not used. |

## Design direction

Keep the existing theme palettes exactly (user constraint: "keep the colors as
they are"). The wow factor comes from *finishing* the theme system, not new
colors: every surface answers to the active theme, depth comes from layered
translucent materials tinted by theme tokens, and interactions (hover, focus,
drag) always respond visibly.

Principles:

1. **Theme is law.** Every chrome surface reads `RafuTheme` tokens. System
   materials remain only as *underlays* beneath theme-tinted washes so
   translucency survives while the theme's hue dominates.
2. **One button vocabulary.** A shared `RafuIconButtonStyle` (hover wash,
   pressed state, accent tint when active) replaces ad-hoc `.plain` buttons.
3. **Left = files, right = context.** File tree owns the left sidebar. A right
   utility panel hosts Search and Source Control with its own slim rail.
4. **Motion where it informs.** Drop-zone previews animate to show the future
   split; nothing decorative on the typing path (AGENTS rule preserved).

## Decisions taken in this pass

- **Supersedes part of ADR 0002**: the single left navigator with three modes is
  replaced by Files-only left sidebar + right utility panel (Search, Source
  Control). ADR note added in `docs/decisions/` as part of this work. The
  "editor-hosted diffs" part of ADR 0002 is unchanged.
- **Theme schema fully decoded**: `RafuTheme` now decodes `ui` (23), `editor`
  (16), `git` (8), `diff` (6), and `fonts`. All new keys are optional with
  derived fallbacks so older/user JSONs missing keys still load. A stored,
  pre-resolved `RafuThemePalette` (SwiftUI `Color` values, built once at decode)
  avoids per-frame hex parsing.
- **Sidebar/theming vs. old "don't paint native sidebars" rule**: user direction
  explicitly asks for full theme application; sidebar surfaces now take theme
  tint over the system material rather than staying purely system-chrome.
- **Markdown default**: `.md` opens in Edit mode; the last mode the user picked
  becomes the default for subsequently opened markdown files
  (`@AppStorage("markdownDefaultMode")`). Preview identity keyed by
  `document.id` so switching files always re-renders.
- **Terminal**: initially deferred as an AGENTS non-goal, then explicitly
  requested by the user as a goal change — adopted via ADR 0004 (SwiftTerm
  1.14.0, lazy bottom panel, bounded scrollback, ⌃` toggle). AGENTS.md amended.
- **Tree-sitter**: not adopted this pass (each grammar is a C dependency; memory
  and license review required). Instead the regex token source was extended to
  emit more of the 24 theme token kinds and to honor theme editor fonts. A
  follow-up note marks tree-sitter as the replaceable backend upgrade path.

## Work log (append as things land)

- [x] Exploration + this brief.
- [x] Theme engine expansion: `RafuTheme` now decodes all `ui`/`editor`/`git`/
      `diff`/`fonts` tokens (new keys optional, fallbacks derived) and builds a
      stored `RafuThemePalette` of SwiftUI `Color`s once at decode.
- [x] Shared control styles: `RafuIconButtonStyle` (hover wash / active accent),
      `RafuProminentButtonStyle`, `RafuSecondaryButtonStyle`,
      `RafuSegmentedPicker`, `RafuHoverRow` in `RafuControlStyles.swift`.
- [x] Window restructure per ADR 0003: Files-only left sidebar; Search + Source
      Control in a right utility panel behind a slim rail
      (`WorkspaceUtilityPanelView` / `WorkspaceUtilityRail`);
      `navigatorPlacement` removed; ⌘⇧G toggles Source Control.
- [x] File-tree header buttons use the shared icon style; `FileIconProvider`
      maps known folders (.agents/.claude/.codex/docs/src/tests/…) and file
      types to symbols + semantic/brand tints; tabs reuse it.
- [x] Command palette: `selectedIndex` + `.onKeyPress(.up/.downArrow)` with
      wraparound, hover-follow, scroll-into-view, Return runs selection, glass
      background tinted by theme, theme-switch commands added.
- [x] Markdown: `.md` no longer forces preview — new docs use the last-picked
      mode (`markdownDefaultMode`); stale preview fixed via `.id(document.id)`
      on editor/preview and a url+revision task key in `MarkdownPreviewView`.
- [x] Diff redesign: theme `diff` tokens for row/gutter washes, intraline
      changed-span emphasis (`IntralineDiff` prefix/suffix trim) on
      modification rows, +/− stats in the header, tighter rows, stitched
      active-tab underline.
- [x] Drop-zone split preview: `EditorTabDropDelegate` (SwiftUI `DropDelegate`)
      tracks the pointer edge live; `EditorSplitPreviewOverlay` shows the
      translucent dashed pane the tab would occupy. Arrow cards removed.
- [x] Status bar, Git inspector, search panel, find bar, empty states, welcome
      screen all themed; welcome gains shortcut hints and a Recent Workspaces
      list (`RecentWorkspacesStore`, security-scoped bookmarks, cap 6).
- [x] AI settings: `modelAlias` on `AIProviderConfiguration` (display-only,
      never sent on the wire), clearer "Model ID"/"Alias" fields with captions,
      provider picker shows "Name · Model".
- [x] AI theme generator (`AIThemeGeneratorSection` + `AIThemePrompt`): copy a
      full schema-bearing prompt for any chatbot, or stream generation through
      the configured provider; result is JSON-extracted, validated by
      `ThemeFileService.importThemeData`, installed, and applied.
- [x] Syntax highlighting: rule set now emits type/constant/attribute/function
      call/operator/escape/docComment plus richer markdown tokens; rules are
      ordered so strings/comments override inner matches; editor + highlighter
      honor `fonts.editor` family/size from the theme.
- [x] Verification: `swift build` clean, `swift format` clean, 53/53 tests
      pass, `./script/build_and_run.sh --verify` launches the staged bundle.

- [x] Embedded terminal (user-directed goal change, ADR 0004): SwiftTerm
      1.14.0 pinned; `WorkspaceTerminalController` (lazy login shell at the
      workspace root, themed colors/font/ANSI palette, Restart on exit,
      shutdown on workspace switch) + `WorkspaceTerminalPanel` bottom split;
      toggled by ⌃`, View menu, and the command palette. AGENTS.md non-goal
      list amended. Amended same day for multiple terminal tabs:
      `WorkspaceTerminalManager` owns N sessions per window, tab strip in the
      panel header, ⌃⇧` / + / palette create tabs, closing a tab kills only
      its shell.

- [x] Layout regression fixes (user screenshots, 2026-07-13): AppKit-backed
      `HSplitView`/`VSplitView` collapse to child ideal size unless every
      level gets `.frame(maxWidth/maxHeight: .infinity)` + `.layoutPriority`
      — the welcome screen was squeezing into a horizontal band and clipping
      the utility rail. Also: utility panel hidden and rail disabled when no
      workspace is open; terminal prefers an installed Nerd Font (MesloLGS NF
      et al.) when the theme names no editor family so powerlevel10k/starship
      glyphs render; terminal cwd falls back to the home directory instead of
      `/` when no workspace is open.

- [x] Feature pass 2 (2026-07-13, advisor→implementor workflow, three packages):
      **Bugs**: search panel top-aligned; small diffs pinned top-leading
      (both-axes ScrollView centers undersized content — stretch to viewport);
      tab drags use a private `dev.rafu.editor-tab` UTType so NSTextView can
      no longer swallow the drop or paste the tab UUID; bitmap images open in
      a downsampled native preview (`ImagePreviewView`, ≤2560px, evicted on
      close) and SVG gets the markdown-style Edit/Preview/Split control.
      **Navigation**: ⌘P Go to File (palette file mode; Print menu replaced),
      ">" command / "@" buffer-symbol prefixes (`BufferSymbolScanner`,
      `textSnapshotProvider` bridge), clickable breadcrumb bar
      (`EditorBreadcrumbView`).
      **Editor**: `RafuTextView` (explicit TextKit 1 stack) +
      `EditorGutterRulerView` — line numbers, active line, git change strips
      (`git diff --unified=0` hunk headers on open/save only,
      `GitGutterHunkParser`); current-line highlight, indent guides, bracket
      boxes drawn in `drawBackground` (never storage attributes — see
      swiftui-appkit-boundary.md note); find-match temporary-attribute
      highlights gated on `DocumentFindState.isActive`; ⌘/ `LineCommenter`;
      `AutoIndenter` on Return.
      **Workspace**: `WorkspaceLivenessService` (FSEvents, 400ms debounce,
      `IgnoreSelf` + `knownDiskModificationDate` mtime guard so saves never
      wipe undo; classifier unit-tested); search include/exclude globs
      (`WorkspaceSearchGlob`) + per-workspace history
      (`WorkspaceSearchHistoryStore`, 15, deduped); terminal tabs start in the
      active file's directory and tab chips tooltip the OSC 7 cwd.
      Suite grew 53 → 101 tests. Tree-sitter remains deferred (measured gate).

- [x] Post-package regression fix (user screenshot: "unable to see content of
      files or tabs"): the gutter ruler's unclipped `dirtyRect.fill()` painted
      the editor background over all content (macOS 14+ `clipsToBounds`
      default change) — fixed with `clipsToBounds = true` plus a bitmap
      regression test; `RafuTextView.makeTextKit1` now retains its
      `NSTextStorage` (nothing else in a hand-built TextKit 1 stack does).
      Nuances recorded in `docs/references/swiftui-appkit-boundary.md`.

- [x] Post-package fixes round 2 (user screenshots): (a) editor text rendered
      under the gutter — `EditorGutterRulerView` computed its width lazily in
      `draw()`, so the text view was already tiled at the old narrow width;
      now width is computed eagerly on text change (cheap newline count) with
      an immediate `scrollView.tile()`, covered by an assertion in
      `EditorGutterRenderTests`. (b) File-tree phantom-selection overlap —
      `List(selection:)` bound to the open file's path rendered a phantom row
      when its folders were collapsed; replaced with a self-drawn per-row
      highlight (`FileTreeRow.isSelected`) that only paints rendered rows.
- [x] Drag-and-drop package (advisor→implementor): root cause of the broken
      tab-split was `UTType(exportedAs:)` with no Info.plist declaration →
      `conforms(to: .data) == false` → the SwiftUI→AppKit drag bridge silently
      rejects the drop. Fix declares `dev.vatsalsaglani.rafu.editor-drag` in
      the staged Info.plist (with a `plutil` assertion in build_and_run.sh),
      unifies tab + sidebar-file drags behind one `EditorDragPayload` and one
      `EditorDropDelegate` with a live edge/center preview, adds
      `handleEditorFileDrop`, and hardens `RafuTextView.acceptableDragTypes` so
      the editor never accepts a file/URL as pasted text. Nuance recorded in
      `docs/references/drag-and-drop-custom-uttype.md`.

- [x] Git-scale package (advisor→implementor): AI commit generation never
      hard-fails on size — smallest-first budgeting (≤64 full patches /
      256 KiB, 48 KiB per-file cap with [truncated] markers), numstat-based
      summaries for the rest, disclosure in prompt + scope caption;
      `selectedDiffsTooLarge` deleted; git process count bounded (≤64 diff
      fetches + 2 numstat) instead of ~3/file. Source Control gained a
      persisted flat/tree toggle: chain-compacted folder tree, tri-state
      folder checkboxes, batch stage/unstage via one git process using
      `--pathspec-from-file=-` with `:(literal)` pathspecs over stdin (also
      fixed latent glob-matching bug for names like `[a].txt`). Notes in
      `docs/references/git-process-and-parsing.md`.

- [x] Branch-driven releases: `.github/workflows/release.yml` publishes a
      GitHub release from any `release/v*` push (pre-release when the version
      carries a suffix), gated on green CI on `main`; `--package` mode and
      `RAFU_VERSION` added to `build_and_run.sh`; notes include the
      quarantine-removal command.
- [x] `rafu <path>` now opens the folder in the app: CLI locates its
      enclosing bundle (`LauncherAppLocator`) and launches it via
      `/usr/bin/open -a`; the app consumes the open event through
      `RafuAppDelegate`/`ExternalOpenRequests` (key window wins; a fresh
      launch skips restoration in favor of the requested folder).
      `openLocalWorkspace` now accepts scope-less but readable directories.
- [x] "New Workspace Window" no longer re-opens the same folder: last-
      workspace restoration is gated to once per app launch
      (`WorkspaceRestorationGate`).

## Still open / next agent

- Editor gutter (line numbers), indent guides, and find-match colors decode
  into the palette but the NSTextView has no line-number ruler yet.
- Tree-sitter remains the documented upgrade path behind
  `SyntaxHighlighter.tokenApplication` (Neon token source); each grammar is a
  C dependency needing license + memory review.
- Terminal memory should be re-measured in a Release build with the panel
  open before distribution (ADR 0004 expectation: tens of MB after first
  open, zero before).
- Theme `fonts.markdownPreview` block is still unused by `MarkdownPreviewView`.
- `RafuSegmentedPicker` is used by Source Control (Changes/History); consider
  adopting it for other segmented controls if any are added.

## File map for the next agent

- Theme model/palette: `Sources/RafuApp/Support/RafuTheme.swift`
- Control styles: `Sources/RafuApp/Support/RafuControlStyles.swift` (new)
- File icons: `Sources/RafuApp/Support/FileIconProvider.swift` (new)
- Window/split chrome: `Sources/RafuApp/Views/WorkspaceWindowView.swift`,
  `WorkspaceNavigatorView.swift` (renamed role: right utility panel),
  `WorkspaceSidebarView.swift` (files tree)
- Diff: `Sources/RafuApp/Views/EditorCanvasView.swift` (`GitSideBySideDiffView`)
- Palette: `Sources/RafuApp/Views/CommandPaletteView.swift`
- Markdown: `Sources/RafuApp/Models/EditorDocument.swift`,
  `Sources/RafuApp/Markdown/MarkdownPreviewView.swift`
- AI: `Sources/RafuApp/AI/AIProviderConfiguration.swift`,
  `AIProviderSettingsModel.swift`, `AIProviderSettingsSection.swift`
- Theme AI generator: `Sources/RafuApp/Settings/ThemeSettingsSection.swift` +
  `Sources/RafuApp/AI/AIThemePrompt.swift` (new)
