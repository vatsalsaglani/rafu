# Pre-initial-push workbench

## Status

Implemented; awaiting the user's hands-on acceptance and first commit. This
supersedes the narrower pre-first-commit vertical-slice brief. The repository
remains uncommitted until the user completes that pass and creates the commit
from Rafu.

## Product outcome

Rafu must feel like a polished, native repository workbench a macOS developer can
comfortably give to another Mac user: lightweight by default, keyboard-first,
multiwindow, and deep enough for focused editing, search, Markdown, Git, themes,
and explicit AI-assisted commit drafting.

## Acceptance contract

1. Tabs form a compact flat document shelf with icons, dirty state, hover close,
   and a clear stitched active indicator.
2. Markdown Edit/Preview/Split is a compact trailing icon control.
3. Git change click previews and double-click pins a titled side-by-side diff with
   line numbers, synchronized panes, addition/deletion and intraline semantics.
4. Exactly one system sidebar toggle exists; Files/Search/Git are navigator modes.
5. No compressed principal-toolbar file icon remains.
6. Source Control provides Changes and History plus branch selection/creation,
   checkout, merge, fetch, pull, push, upstream/divergence, progress, and errors.
7. Saved workspace bookmarks, windows, tabs, selection, navigator state, and split
   topology restore safely; stale access asks for reauthorization.
8. Markdown uses a maintained native parser/renderer with GFM tables, theme JSON
   colors, and native Mermaid fenced-block rendering.
9. `Command-F` provides find/replace, regex, case, whole-word, next/previous,
   replace current/all, and native undo integration.
10. `Command-Shift-F` provides cancellable workspace search/replace grouped by
    file; the Explorer header also exposes Search, New File, and New Folder.
11. `Command-Shift-P` opens a fuzzy command palette backed by the same command
    registry as menus/toolbars, including CLI install and navigator placement.
12. Active editor items select and reveal the matching file in the Files tree.
13. Tabs can be dragged left/right/above/below into any number of recursive editor
    groups; keyboard/menu commands provide the same operations.
14. `Command-W` closes the focused tab first; with no tabs it asks Quit/Cancel and
    offers a persisted “Don't ask again,” while preserving normal Close Window.
15. Syntax highlighting uses a replaceable maintained backend with broad common
    language/framework coverage, open-buffer-only parsing, and measured memory.
16. Folder context/hover actions create files and folders; menu/command paths exist.
17. Settings support OpenAI, Anthropic, Google, and custom OpenAI-compatible
    endpoints with model, base URL, transport, Keychain secret, and a `Rafu live!`
    connection test.
18. Commit-message generation streams over REST/SSE from checked diffs, or all
    changed files when none are checked; it discloses transmitted scope, remains
    editable, and never auto-commits.
19. Built-ins include Indigo, Khadi, Dracula, Notion Light/Dark, and GitHub
    Light/Dark. Users can create a JSON copy, import/validate JSON, reveal the
    theme folder, and reload without restarting.
20. Source Control design is polished and compact, with Changes/History progressive
    disclosure rather than a permanent wall of file rows.
21. An optional low-frequency status item reports honest process resident memory,
    not fictional per-window memory.

## Architecture locks

- Follow ADR 0002: one Navigator plus editor-hosted diff/detail items.
- Full live text remains in TextKit, never SwiftUI Observation.
- Secrets live only in Keychain. Diffs leave the machine only after explicit file
  selection and Generate; never log request bodies, keys, diffs, or responses.
- Use `/usr/bin/git` with executable/argument arrays and short-lived processes.
- Search and replacement respect ignore/symlink/binary rules, cancellation, result
  limits, version checks, atomic writes, and replacement previews.
- Provider adapters are separate because OpenAI Responses/Chat Completions,
  Anthropic Messages, and Google Generate Content/Interactions differ.
- Dependencies sit behind replaceable Markdown and syntax interfaces and must have
  pinned versions/licenses documented before the first commit.

## Verification

- Strict format/build/test and staged `.app` bundle: complete on 2026-07-13.
- Automated coverage: 53 Swift Testing checks passing on 2026-07-13.
- Focused service/model tests for every destructive or stateful operation.
- User hands-on pass for all 21 acceptance items without Computer Use automation:
  pending; deliberately left to the user.
- First repository commit created by the user from Rafu only.

### 2026-07-19: UI issue-fix batch

All 15 items in `docs/issues/issues_ui.md` (found during the pending
hands-on acceptance pass) were implemented and landed on `main` across 7
commits: flat sidebar chrome (ADR 0012), removal of the clipped
top-right "Open Folder" toolbar button, commit-graph lane-column sizing
(`CommitGraphLayout.laneCount`), terminal sessions presented as
first-class editor tabs (ADR 0014, narrowing ADR 0004), selection
bracket/quote wrap (`BracketWrap`) and `⌘/` per-language comment toggle
(`CommentSyntaxTable`), `⌘N` blank untitled document + `⌘S` save-panel
flow, `⌘⇧N` new window, an animated/cancellable AI commit-composer border
with a Stop Generating action, a redesigned worktree row with a compact
icon-only menu, the reusable `RafuSearchableDropdown`/`RafuDropdownFilter`
component (first used for the branch dropdown and the new status-bar
branch switcher), native local-image rendering and live split/preview
editing in Markdown preview, additional VS Code-style shortcuts (`⌘N`,
`⌘⇧N`, `⌘B`, `⌃G` seeded with `:` for go-to-line), and an opt-in,
off-by-default full-file per-line git blame mode (amendment to ADR 0013).
Verified: 789 tests passing, 0 build warnings, lint clean. See
[`ui-flat-modern-refresh.md`](ui-flat-modern-refresh.md),
[`git-experience-and-worktrees.md`](git-experience-and-worktrees.md), and
[`editor-terminal-tabs.md`](editor-terminal-tabs.md) for the sibling phase
docs each cluster of fixes touches, and
[`command-palette-and-search-pitfalls.md`](../../references/command-palette-and-search-pitfalls.md),
[`searchable-dropdown-component.md`](../../references/searchable-dropdown-component.md), and
[`markdown-local-image-preview.md`](../../references/markdown-local-image-preview.md)
for the new engineering references this batch produced. The user's
hands-on acceptance pass for the 21 acceptance items above remains
pending.

### 2026-07-19 (continued): Flat HSplitView, gutter tiling fix, GitHub/AI features

Three additional commits landed on `main` after the UI issue-fix batch:

1. **Flat HSplitView sidebar (macOS 26 Liquid Glass fix):** `NavigationSplitView`
   was replaced with an AppKit-backed `HSplitView` in `WorkspaceWindowView` because
   macOS 26 floats the `NavigationSplitView` sidebar as an inset rounded Liquid
   Glass card whenever the window is key, contradicting ADR 0012's flat-chrome
   decision. `HSplitView` preserves drag-to-resize while keeping the sidebar
   flush. One custom toolbar toggle (`sidebar.left`, driving
   `session.isSidebarCollapsed`; ⌘B unchanged) replaced the automatic system
   toggle `NavigationSplitView` contributed, satisfying ADR 0002's "exactly one
   toggle" requirement.

2. **Editor gutter: macOS 26 ruler overlay-tiling fix:** On macOS 26, NSScrollView
   tiles vertical NSRulerViews as OVERLAYS after `tile()` — the clip view keeps
   the scroll view's full width and the ruler covers its left edge via
   `contentInsets.left == ruleThickness`, parking the resting scroll at
   `x = -ruleThickness` instead of `0`. This caused text to appear underneath
   the line-number gutter. `EditorDropForwardingScrollView.tile()` now re-tiles
   classically: removes the overlay inset and moves the clip view's frame to
   start at the ruler's trailing edge, making `x = 0` the true home.
   Regression tests: `EditorGutterTilingTests` (3 tests).

3. **GitHub publish, AI ignore suggestions, commit hygiene:**
   - `GitHubCLIService` + `GitHubCLILocator`: system `gh` CLI subprocess runner
     (argv-only, full environment to preserve `gh`'s auth state, deliberate
     deviation from the hardened `/usr/bin/git` runner). `gh api user` and
     `gh repo create … --push` with explicit error mapping
     (notAuthenticated/remoteAlreadyExists/commandFailed).
   - `GitHubAccountModel` + status-bar account chip + `GitHubPublishSheet`:
     account display, "Create & Push" action (gated by repo + ≥1 commit +
     no origin).
   - `IgnoreFileTreeSerializer`, `IgnoreSuggestionPrompt`, `IgnoreSuggestionSheet`:
     bounded, paths-only tree serialization (never file contents); explicit
     accept-before-write; inert untrusted-data directive.
   - `CommitHygieneChecker`: pure heuristic scan of staged paths (secrets,
     dependencies, build artifacts, OS cruft) with advisory-only composer warning.
   - 53 new tests across 4 suites: `GitHubCLIParsingTests`,
     `IgnoreFileTreeSerializerTests`, `IgnoreSuggestionPromptTests`,
     `CommitHygieneCheckerTests`.

Verified: 848 tests passing, 0 build warnings, lint clean. New reference
notes: [`editor-gutter-ruler-tiling.md`](../../references/editor-gutter-ruler-tiling.md),
[`github-cli-integration.md`](../../references/github-cli-integration.md),
[`ai-ignore-suggestion-privacy.md`](../../references/ai-ignore-suggestion-privacy.md).
New ADR: [`0015-github-publishing-via-system-gh.md`](../../decisions/0015-github-publishing-via-system-gh.md).
Amendment to ADR 0012 documenting the HSplitView/Liquid Glass fix.

### 2026-07-20: Two main-thread hang fixes (macOS 26 Writing Tools; bounded blame/highlight draws)

One commit fixed two main-thread hangs reported via macOS stackshots:

1. **75 s hang on macOS 26**: every `NSTextView` selection change runs
   Apple's Writing Tools selection-rect computation, which forces
   synchronous full-document layout on a contiguous-layout TextKit 1
   document. Repro was ⌘F find-next; it also explains "place caret, then
   scrolling stalls." Fix: `textView.writingToolsBehavior = .none` in
   `RafuTextView.makeTextKit1()`. `allowsNonContiguousLayout` was
   evaluated and explicitly deferred pending Instruments evidence (it
   interacts with scroll-fraction restore, gutter fragment math, and the
   Neon TextKit 1 integration).
2. **Bounded draw follow-up**: `drawCurrentLineHighlight` and
   `drawInlineBlameAnnotation` still used unbounded
   `NSString.lineRange(for:)` per draw; both now use the existing
   `boundedLineRange(around:in:)` (4096-unit cap), matching
   `drawIndentGuides`/`drawFileBlameAnnotations`. `inlineBlameRect` resets
   to `.zero` when the bound declines, so blame-hover hit-testing never
   uses stale geometry.

Verified: 856 tests passing (parallel and `--no-parallel`), 0 build
warnings, lint clean. New reference note:
[`macos26-writing-tools-textkit-layout.md`](../../references/macos26-writing-tools-textkit-layout.md).
Extended: [`large-file-guard-mode.md`](../../references/large-file-guard-mode.md)
with the two new bounded call sites, the measured linear (not quadratic)
cost of `NSString.lineRange(for:)`, deterministic-vs-timing test guidance,
and the headless `NSView.display()` no-op / `cacheDisplay` testing
pattern. No ADR: no architectural fork, only a bug fix and a testing
correction.

### 2026-07-20 (continued): Diff canvas syntax highlighting + new-side-only hover

Advisor→implementor→documentor pass for
[`diff-syntax-highlighting-and-hover.md`](diff-syntax-highlighting-and-hover.md):
the editor-hosted diff canvas now syntax-highlights both columns (per-side
join-then-slice tree-sitter parsing via a new shared
`PlainTextSyntaxHighlighter` core plus `DiffSyntaxHighlighter`, theme-
independent spans cached per opened diff and resolved to colors at render)
and offers hover on the new side only of working-tree-scoped diffs
(LSP-only, gated by scope/dirty-state/file-open checks, via a new
`DiffHoverPositionMapper` and `WorkspaceSession.diffHoverInfo`). Advisor
read-only review approved the implementation; the review's one hardening
suggestion (a `Task.isCancelled` guard around the `.task(id:)` diff-highlight
cache assignment) landed before handoff. New baseline: 876 tests, both
`swift test` and `swift test --no-parallel` green, 0 build warnings, lint
clean. Uncommitted, pending the user's hands-on review. New reference note:
[`diff-syntax-highlighting-and-hover.md`](../../references/diff-syntax-highlighting-and-hover.md).
No ADR (stays inside ADR 0005's opt-in LSP client and the approved
tree-sitter boundary).

### 2026-07-21: Terminal manager — sessions panel, hide/close, shells, attention

Advisor→implementor→documentor pass for
[`terminal-manager.md`](terminal-manager.md), landed across 4 commits (all
five stages T-A through T-E): ⌃` now parks the focused terminal (tab
removed, shell alive) instead of killing it, with reveal via a derived,
MRU-ordered parked-session set; a third "Terminals" utility-rail panel
lists sessions with status glyph, live cwd, and parked indicator; shell
choice (`TerminalShellCatalog`, `/etc/shells` + Homebrew probing,
existence/executability only) with a remembered preferred shell; auto-
naming from OSC 0/2 titles plus inline rename and theme-token session
colors; and per-session `.bell` attention state driving a rail badge and,
reversing two positions the phase document had locked, an on-by-default
(lazily authorized) system notification carrying a bounded output snippet
and an inline reply routed back into the session's pty. A latent
`WorkspaceNavigatorMode` decode bug (an unknown persisted mode threw and
wiped the ENTIRE restoration store, not just the mode) was found and fixed
during T-B. Verified: 956 tests passing in both `swift test` and `swift
test --no-parallel`, 0 build warnings, lint clean. New reference note:
[`terminal-signals-and-shell-catalog.md`](../../references/terminal-signals-and-shell-catalog.md).
Amended [ADR 0004](../../decisions/0004-embedded-terminal.md) and
[ADR 0014](../../decisions/0014-terminal-as-editor-tab.md) for the
sessions-outlive-tabs lifecycle; new
[ADR 0016](../../decisions/0016-terminal-attention-notifications.md)
(Proposed) records the attention-notification reversals and their
security argument. See `terminal-manager.md` for the corrected T-A/T-D
claims and the accepted unbounded-exited-session-row trade-off.
