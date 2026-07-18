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
