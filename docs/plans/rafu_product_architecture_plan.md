# Rafu
## A Native macOS Repository Editor — Product, Design, Theming, SSH, CLI, Architecture, and Delivery Plan

**Status:** Working product and engineering plan  
**Version:** 0.4  
**Date:** July 12, 2026  
**Relationship to v0.2/v0.3:** This document is additive and corrective. It retains the SwiftUI/AppKit editor, syntax, Git, AI commit-message, SSH, CLI, performance, and security direction, and adds the following:

- **Name decision.** The product is named **Rafu** (રફૂ — darning) with the CLI command `rafu` (section 2.4). v0.3's interim name "Darn" is superseded; Rafu is the same idea in the founder's own language.
- **Theme system.** JSON-defined themes covering fonts, UI colors, editor colors, Git semantics, and syntax highlighting, in the style of Obsidian/Zed theme files — data only, no code (sections 4.5–4.6). Two bundled themes ship from day one: **Indigo** (dark) and **Khadi** (light), joined by a **zari-gold** accent.
- **Markdown preview.** Markdown files open with edit and native preview by default, rendered without a per-document WebView (section 7.7).
- **Sequencing correction.** Phase 1A (local-only) is now an explicitly shippable internal v0.1 gate before SSH work begins in earnest, since the founding daily pain — touching `.env`, Compose, and config files next to a coding agent — is local (section 15).
- **Editor-core de-risking.** Evaluate STTextView / CodeEdit's source editor as a TextKit 2 foundation before committing to a fully bespoke `NSTextView` subclass (section 7.1).

---

## 1. Executive decision

Build a **native macOS repository companion editor** with two workspace types:

1. **Local workspace** — a folder or Git worktree on the Mac.
2. **SSH workspace** — a folder that remains on a remote machine selected through the user's OpenSSH configuration.

Each workspace opens in an independent macOS window. The application UI, editor buffers, syntax parsing, and unsaved changes remain local. For an SSH workspace, a small versioned helper runs on the remote machine over a standard SSH channel and performs file-system and, later, Git operations.

The implementation should be:

- **SwiftUI** for the application shell, windows, toolbar, settings, source-control views, sheets, and state composition.
- **AppKit/TextKit 2** for the code editor, selection behavior, line layout, undo, input methods, and high-performance text editing.
- **Tree-sitter** for bundled incremental syntax highlighting.
- **System OpenSSH** (`/usr/bin/ssh`) for remote authentication and transport, so existing `~/.ssh/config`, `Include`, `ProxyJump`, identity files, security keys, agents, and `known_hosts` behavior continue to work.
- A small **Rust remote agent** for reliable remote file operations over SSH. The macOS product remains a native Swift application; the helper is a headless implementation detail, not another desktop application.
- A small signed **command-line launcher** bundled with the app, installed under a product-specific command such as `rafu`.
- The installed **Git executable** locally, and the remote machine's Git executable for SSH workspaces.
- Direct `URLSession` integration for OpenAI-compatible commit-message generation, with user credentials in Keychain.

The defining product flow is:

```text
Open a local or SSH repository
        ↓
Review files changed by Codex or Claude Code
        ↓
Make focused edits without launching a large IDE
        ↓
Review and stage Git changes
        ↓
Generate an editable commit subject/body from an explicit diff scope
        ↓
Commit
```

---

## 2. Product position

### 2.1 Product statement

> A fast, native macOS editor for opening local and SSH repositories, making focused code or configuration edits, reviewing Git changes, and producing accurate commit messages without an extension host, embedded agent, or full IDE runtime.

### 2.2 Primary user

A developer who:

- Uses Codex, Claude Code, or another terminal-based coding agent for most implementation work.
- Frequently needs to inspect or adjust generated files, Dockerfiles, Compose files, `.env` files, scripts, manifests, and source code.
- Wants a small editor with high-quality native text editing and Git review.
- Works across both local repositories and remote Linux or macOS machines.
- Values predictable memory use more than a broad extension ecosystem.

### 2.3 Product principles

1. **Purpose over breadth.** Every feature must support opening, editing, reviewing, or committing a repository.
2. **Local responsiveness.** Typing, selection, search within an open buffer, undo, and syntax presentation must never wait on SSH or an AI service.
3. **User agency.** No automatic commit, no automatic transmission of diffs, no silent overwrite of external changes, and no silent host-key acceptance.
4. **Familiar macOS behavior.** Native windows, menus, keyboard shortcuts, sheets, focus, drag and drop, accessibility, and standard text behaviors.
5. **One mental model.** Local and SSH workspaces should share the same editor, file-tree, tab, Git, and AI surfaces. Differences appear only where connection state or remote latency matters.
6. **No extension platform.** Languages and features are built in and deliberately limited.
7. **Measure, do not assume.** Native technology creates an opportunity for a smaller footprint; disciplined buffer ownership, lazy loading, and profiling determine whether that opportunity is realized.

### 2.4 Name: Rafu

**Rafu (રફૂ / रफ़ू)** — darning. The word (from Persian *rafū*) is the everyday Gujarati/Hindi/Urdu term for mending a small hole in otherwise good fabric, and the *rafugar* — the craftsperson whose repairs are meant to be invisible — is the product's exact job description: the coding agent weaves the cloth; Rafu is what you reach for to mend the hole in the `.env`, the Dockerfile, the manifest.

Why not the earlier candidates:

- **Patch** — a POSIX command (`patch(1)`); an unshippable CLI collision.
- **Seam** — already an established macOS app (a notch/Dynamic Island utility, Homebrew cask `seam-app`) plus Seam the IoT API company.
- **Darn** — the right meaning, but in English; Rafu says the same thing in the founder's own language, is shorter as a CLI, and remains effortlessly pronounceable everywhere (*rah-foo*).

`rafu` checks out as a name: it is not a POSIX utility, not a shell builtin, not a Homebrew formula, and nothing in the developer-tool space uses it (the Rafu Shimpo, a Los Angeles Japanese-language newspaper, is an unrelated category). Verify `brew search rafu` and an App Store search once more immediately before public release.

| Item | Decision |
|---|---|
| Product name | Rafu |
| CLI command | `rafu` |
| Bundle identifier | Personal reverse-DNS, e.g. `dev.vatsalsaglani.rafu` (final: pick before Phase 0 signing) |
| Bundled themes | **Indigo** (dark) and **Khadi** (light) — indigo-dyed and undyed handspun cloth; both names have Indian textile roots, matching the product's |
| Accent | **Zari gold** — the metallic thread of Indian embroidery; Surat, in Gujarat, is its historic center |
| Remote agent binary | `rafu-agent` |
| App icon | **The seam** — two indigo cloth panels laced together by a zari-gold zigzag thread (see the icon spec below) |

Alternates kept in reserve if a late conflict appears: **Sandho** (સાંધો, the seam/joint), **Tanko** (ટાંકો, a stitch), **Thigdu** (થીગડું, the patch).

#### App icon: the seam

Two indigo cloth panels, laced together by a single zari-gold zigzag thread, on the standard macOS squircle. The mark encodes the product three times over: the lacing is the mend (rafu), the two panels are the split editor and side-by-side diff, and the joined halves are the local↔SSH workspace pair stitched by one seam.

Production rules:

- Build as a layered icon in Icon Composer: background cloth layer, panel layer, thread layer. Let macOS generate the dark and tinted appearances from the layers; the gold thread survives tinting.
- Colors are the brand palette: panels `#1E2634` on `#151A24`, thread `#E3A857` (Indigo) / `#A2701F` on `#FAF7F0` (Khadi/light variant).
- Small sizes: at 32 px the zigzag keeps three to four bends; at 16 px it may relax to a straight gold seam line between the two blocks. The two-panels-plus-gold-seam silhouette is the invariant.
- A monochrome template glyph (black panels and thread on transparent) is reserved for any future menu-bar presence.
- Source asset: `rafu-icon-seam.svg`.

Rejected and reassigned concepts: a woven gold hash (too close to a hashtag and to Slack's fourfold-symmetric mark), the khadi patch with running stitch (kept as fallback — most legible of all at 16 px), and the રફૂ monogram (reserved for the About window and the wordmark, where the script has room to breathe).

---

## 3. Scope

### 3.1 First complete product

| Area | Included |
|---|---|
| Workspaces | Local folders, Git repositories, worktrees, and SSH folders |
| Windows | Multiple independent workspace windows |
| File management | Lazy tree, open, create, rename, delete, move, reveal locally, copy path |
| Editing | Tabs, line numbers, undo/redo, find/replace, go to line, indentation, line operations, brackets, multiple selections, soft wrap |
| Syntax | A fixed bundled language set using Tree-sitter |
| External changes | Detect files changed by terminal agents, Git, or another process |
| SSH | Read OpenSSH config, connect through system SSH, browse and edit remote folders, reconnect safely |
| Git | Status, diffs, file-level stage/unstage, editable commit form, commit |
| AI | Generate commit subject/body from staged, selected, or all changes |
| CLI | `rafu .`, file opening, line/column navigation, SSH workspace opening, and `--wait` |
| Settings | Editor, appearance, Git, AI provider, SSH, and command-line installation |
| Icons | SF Symbols plus a small bundled filename/extension mapping |
| Markdown | Edit and native preview by default: Edit / Split / Preview per document, GFM subset, no per-document WebView |
| Theming | JSON theme files (fonts, UI colors, editor colors, Git colors, syntax); bundled Indigo (dark) and Khadi (light); user themes folder |

### 3.2 Explicit non-goals for the initial product

- Extension marketplace or third-party plugin runtime
- Embedded terminal
- Debugger
- Collaboration
- AI chat, inline generation, or autonomous agents
- Full language-server ecosystem
- Remote containers, Kubernetes, WSL, or dev-container orchestration
- GitHub pull-request UI
- Rebase UI, history browser, blame, or advanced conflict resolution
- Hunk-level staging in the first Git release
- Remote Windows hosts in the first SSH release
- A custom SSH implementation

### 3.3 Optional future scope

Only after the core product is stable:

- A small number of optional built-in language servers, disabled by default
- Hunk staging
- Remote terminal handoff to Terminal/iTerm rather than an embedded terminal
- Remote port-forward management
- Read-only Git history and blame
- Built-in formatting for selected languages
- Workspace tasks, without an extension platform

---

## 4. Design direction

The design guidance in `emilkowalski/skills` is primarily expressed for web interfaces. Use its underlying principles, but **do not transplant the CSS implementation literally into a macOS app**. Native AppKit and SwiftUI controls already provide pointer states, focus, animation, accessibility, vibrancy, and platform-specific behavior.

### 4.1 Principles adopted from the skills and Apple guidance

#### Immediate response

- Text insertion, cursor motion, selection, tab changes, quick open, and command-palette invocation respond immediately.
- Keyboard-initiated, high-frequency actions do not receive decorative open/close animations.
- Show a local state change before starting slow work. For example, Stage immediately enters an in-progress state while Git executes.

#### Spatial consistency

- A popover comes from the toolbar item or row that opened it.
- A sidebar collapses back toward its original edge.
- Authentication and connection errors belong to the affected workspace window, not a global modal over every window.
- A diff opens in the editor area because it is document content, not in a floating inspector detached from the file that caused it.

#### Restraint

- The editor canvas is opaque, calm, and optimized for text contrast.
- Materials and Liquid Glass are used by standard system chrome—toolbar, sidebar, menus, and sheets—not as stacked cards behind code, diffs, or file rows.
- Color is reserved for semantic states: modification, addition, deletion, warning, error, connection state, and a true primary action.

#### Familiarity

- Standard macOS menu structure and shortcuts are the source of truth.
- Destructive actions use standard confirmation only when undo or recovery is not reasonable.
- File and folder selection follows Finder conventions.
- Multiple windows use normal macOS window behavior rather than tabs inside one global super-window.

#### Agency and responsibility

- The exact AI diff scope is visible before transmission.
- Sensitive files are excluded by default and require explicit override.
- Unknown SSH host keys require a meaningful confirmation; changed host keys block the connection.
- Unsaved changes remain available after a remote disconnect.
- External file changes never silently replace a dirty buffer.

#### Accessibility

- Respect Reduce Motion, Reduce Transparency, Increase Contrast, VoiceOver, Full Keyboard Access, and system accent color.
- Use system typography for app UI. The editor font is user-configurable and monospaced by default.
- Do not encode Git state or connectivity using color alone.
- Keep all commands reachable through menus, not only contextual icons.

### 4.2 Window anatomy

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Toolbar: Sidebar | Quick Open | Search | Git summary | Remote state │
├─────────────────┬───────────────────────────────────────────────────┤
│ Sidebar         │ Tab strip                                         │
│                 ├───────────────────────────────────────────────────┤
│ Files / Changes │ Editor or diff                                    │
│                 │                                                   │
│ Native outline  │                                                   │
│ and sections    │                                                   │
│                 │                                                   │
├─────────────────┴───────────────────────────────────────────────────┤
│ Status: branch · SSH alias · line:column · spaces · encoding       │
└─────────────────────────────────────────────────────────────────────┘
```

Recommended behavior:

- Use one sidebar with two primary modes: **Files** and **Changes**.
- Avoid a permanent VS Code-style activity rail unless later usability testing proves it necessary.
- Keep the toolbar sparse. Group related actions by function and frequency; put secondary actions under a More menu.
- A remote workspace title should read something like `api — prod` and include a subtle remote indicator.
- Connection loss appears as an inline, nonblocking banner with Reconnect and Details.
- Git and AI progress should be visible but not take focus from the editor.

### 4.3 Motion rules

| Interaction | Motion policy |
|---|---|
| Quick Open / command palette from keyboard | No decorative animation |
| Tab selection | Immediate |
| Cursor and selection | Native text-system behavior |
| Sidebar show/hide | Native window/sidebar transition |
| Toolbar popover | Native source-anchored presentation |
| Sheet | Native sheet transition |
| Toast/status confirmation | Short and subtle, no bounce |
| Drag-and-drop reordering | Direct manipulation with native feedback |
| Commit success | Status/check indicator, no celebration animation |

### 4.4 Native control policy

- Prefer standard `ToolbarItem`, `NavigationSplitView`/AppKit split views where suitable, `Menu`, `Table`, `OutlineGroup` or `NSOutlineView`, sheets, alerts, and `NSTextView`.
- Do not manually recreate Liquid Glass with custom blur layers.
- Let newer macOS versions provide their system appearance automatically.
- Gate explicit newer visual APIs with availability checks and provide ordinary material/opaque fallbacks.
- Use custom drawing only where the product genuinely needs it: code editor decorations, line-number gutter, diff markers, minimap if ever added, and syntax attributes.

### 4.5 Theme system

Themes are **data-only JSON files** — fonts, colors, and syntax styles. No scripting, no CSS, no code. This gives users Obsidian/Zed-style personalization without violating the no-extension-runtime principle (D-008): a theme cannot execute anything.

#### Locations and lifecycle

```text
Bundled:  Rafu.app/Contents/Resources/Themes/indigo.json, khadi.json
User:     ~/Library/Application Support/Rafu/Themes/*.json
```

- The app follows the **system appearance by default**: Indigo in dark mode, Khadi in light mode. The user can pin any theme per appearance, or one theme for both.
- User theme files are watched and **hot-reloaded** on save, so iterating on a theme is edit → save → see.
- The schema is versioned (`"version": 1`). Unknown keys are ignored; a malformed theme falls back to the bundled default for the current appearance with a nonblocking warning, never a blank editor.
- Themes are validated on load: every color must be `#RRGGBB` or `#RRGGBBAA`; missing tokens inherit from the bundled theme of the same appearance, so partial themes are legal.

#### Performance rule

Theme JSON is parsed **once** into cached `NSColor` / `NSFont` / attribute-dictionary tables keyed by semantic token. The syntax highlighter and renderers consume those tables; nothing on the typing path touches JSON, string keys, or color parsing. A theme change or hot reload swaps the tables and invalidates visible attributes only.

#### Schema shape

```json
{
  "$schema": "https://rafu.dev/schemas/theme/v1.json",
  "version": 1,
  "name": "Indigo",
  "id": "dev.rafu.theme.indigo",
  "appearance": "dark",
  "fonts": {
    "editor":  { "family": "SF Mono", "fallback": ["JetBrains Mono", "Menlo"],
                 "size": 13, "lineHeightMultiple": 1.5, "ligatures": false },
    "ui":      { "family": "system", "size": 13 },
    "markdownPreview": {
      "prose": { "family": "New York", "fallback": ["Georgia"],
                 "size": 15, "lineHeightMultiple": 1.6 },
      "code":  "editor"
    }
  },
  "ui":     { "appBackground": "#10141C", "accent": "#E3A857", "…": "…" },
  "editor": { "background": "#151A24", "cursor": "#E3A857", "…": "…" },
  "git":    { "added": "#7CC08A", "modified": "#D2B958", "…": "…" },
  "diff":   { "addedBackground": "#142E1D", "…": "…" },
  "syntax": {
    "keyword":  { "color": "#9D8CE8" },
    "comment":  { "color": "#5F6980", "fontStyle": "italic" },
    "…": "…"
  }
}
```

#### Semantic token model and Tree-sitter mapping

Syntax tokens are semantic, not per-language. Tree-sitter highlight-query captures map onto them centrally:

| Tree-sitter capture | Theme token |
|---|---|
| `@comment`, `@comment.documentation` | `comment` |
| `@string`, `@string.special` | `string` |
| `@string.escape` | `escape` |
| `@number`, `@float` | `number` |
| `@constant`, `@constant.builtin`, `@boolean` | `constant` |
| `@keyword`, `@keyword.*` | `keyword` |
| `@operator` | `operator` |
| `@punctuation.*` | `punctuation` |
| `@function`, `@function.call`, `@function.method` | `function` |
| `@type`, `@type.builtin` | `type` |
| `@variable` | `variable` |
| `@variable.parameter` | `parameter` |
| `@property`, `@field` | `property` |
| `@tag` | `tag` |
| `@attribute`, `@tag.attribute` | `attribute` |
| `@namespace`, `@module` | `namespace` |
| `@markup.heading` | `markup.heading` |
| `@markup.bold` / `@markup.italic` | `markup.bold` / `markup.italic` |
| `@markup.link`, `@markup.link.url` | `markup.link` |
| `@markup.raw` | `markup.code` |
| `@markup.quote` | `markup.quote` |
| `@markup.list` | `markup.list` |

UI, Git, and diff tokens are consumed by the sidebar, tab strip, gutter, status bar, diff viewer, and markdown preview so a theme restyles the whole window coherently, not just the code canvas.

### 4.6 Bundled palettes: Indigo and Khadi

The two bundled themes are one identity in two appearances: **indigo-dyed cloth** for dark, **undyed khadi cotton** for light, with a shared **zari-gold accent** — the visible mending thread. Every name is native to the product's roots: indigo dyeing is historically Indian and Gujarat was a hub of its trade, khadi is handspun Indian cloth, and zari — metallic gold thread — has its center in Surat. Gold-on-indigo is deliberately not the ubiquitous blue-accent editor look, and both palettes reserve strong color for semantic states, per section 4.1.

#### Indigo (dark)

| Token | Value | Note |
|---|---|---|
| `ui.appBackground` / sidebar | `#10141C` | Deep indigo-ink |
| `ui.editorBackground` | `#151A24` | Slightly lifted canvas |
| `ui.elevated` (popover/sheet) | `#1B212D` | |
| `ui.selection` / `ui.hover` | `#242C3C` / `#1D2431` | |
| `ui.borderSubtle` / strong | `#262E3E` / `#333D52` | |
| `ui.textPrimary` / secondary / muted | `#E7EAF2` / `#9AA3B8` / `#67718A` | |
| `ui.accent` / hover / onAccent | `#E3A857` / `#EDB96F` / `#201709` | Zari gold |
| `ui.error` / warning / info / success | `#E06C75` / `#D4A24E` / `#82A7F0` / `#7CC08A` | |
| `editor.cursor` | `#E3A857` | |
| `editor.selectionBackground` | `#2C3A55` | Indigo selection |
| `editor.lineHighlight` | `#1A2030` | |
| `editor.gutterForeground` / active | `#4B5670` / `#9AA3B8` | |
| `git.added` / modified / deleted | `#7CC08A` / `#D2B958` / `#E06C75` | |
| `git.untracked` / ignored / conflict | `#6FAECB` / `#67718A` / `#C678DD` | |
| `diff.addedBackground` / removedBackground | `#142E1D` / `#331D20` | |
| `syntax.comment` | `#5F6980` *italic* | |
| `syntax.string` / escape | `#9FC98F` / `#74BFCB` | |
| `syntax.number` / constant | `#E0B36A` / `#E3A857` | Constants tie to accent |
| `syntax.keyword` | `#9D8CE8` | Wisteria violet |
| `syntax.function` | `#74BFCB` | Moonlit teal |
| `syntax.type` | `#82A7F0` | Indigo blue |
| `syntax.variable` / parameter / property | `#E7EAF2` / `#C9D2E6` / `#B8C2DC` | |
| `syntax.operator` / punctuation | `#98A6C4` / `#6E7A94` | |
| `syntax.tag` / attribute / namespace | `#E08D8D` / `#D2B958` / `#A9B4CE` | |
| `markup.heading` / link / code | `#E3A857` **bold** / `#74BFCB` / `#9FC98F` on `#1B212D` | |

#### Khadi (light)

| Token | Value | Note |
|---|---|---|
| `ui.appBackground` / sidebar | `#F1EDE3` | Warm khadi cotton |
| `ui.editorBackground` | `#FAF7F0` | Paper canvas, not stark white |
| `ui.elevated` | `#FFFFFF` | |
| `ui.selection` / `ui.hover` | `#E7E0CE` / `#EFE9DB` | |
| `ui.borderSubtle` / strong | `#E3DCCB` / `#CFC6B0` | |
| `ui.textPrimary` / secondary / muted | `#2B2F3A` / `#5D6474` / `#8A90A0` | Indigo-ink text |
| `ui.accent` / hover / onAccent | `#A2701F` / `#8A5D14` / `#FFF9EE` | Deep zari gold |
| `ui.error` / warning / info / success | `#B3362E` / `#8F6A10` / `#3557B7` / `#2E7D46` | |
| `editor.cursor` | `#A2701F` | |
| `editor.selectionBackground` | `#D8E1F2` | Indigo-tinted |
| `editor.lineHighlight` | `#F2EDE1` | |
| `editor.gutterForeground` / active | `#A8ABB6` / `#5D6474` | |
| `git.added` / modified / deleted | `#2E7D46` / `#8F6A10` / `#B3362E` | |
| `git.untracked` / ignored / conflict | `#23708A` / `#8A90A0` / `#8B3FA8` | |
| `diff.addedBackground` / removedBackground | `#E3F2E6` / `#FBE6E4` | |
| `syntax.comment` | `#8C8776` *italic* | Warm greige |
| `syntax.string` / escape | `#4E7D45` / `#1E7A87` | |
| `syntax.number` / constant | `#9A5F12` / `#A2701F` | |
| `syntax.keyword` | `#6C4FC4` | Violet ink |
| `syntax.function` | `#1E7A87` | Teal ink |
| `syntax.type` | `#3557B7` | Indigo ink |
| `syntax.variable` / parameter / property | `#2B2F3A` / `#4A5568` / `#52608F` | |
| `syntax.operator` / punctuation | `#55617A` / `#7A8294` | |
| `syntax.tag` / attribute / namespace | `#AD3B3B` / `#8F6A10` / `#5C6474` | |
| `markup.heading` / link / code | `#8A5D14` **bold** / `#1E7A87` / `#4E7D45` on `#F1EDE3` | |

Contrast requirements: body text and syntax tokens meet WCAG AA (≥ 4.5:1) against their editor background; verify accent-as-text usage with Increase Contrast enabled and never encode Git state with color alone (section 4.1). The full machine-readable palettes ship as `indigo.json` and `khadi.json`.

---

## 5. Core architecture

### 5.1 High-level system

```text
┌──────────────────────────────── Native macOS app ────────────────────────────────┐
│                                                                                  │
│  SwiftUI/AppKit UI                                                               │
│  ├── Window coordinator                                                          │
│  ├── WorkspaceSession per window                                                 │
│  ├── File tree / source control / settings                                       │
│  └── NSTextView + TextKit 2 editor                                               │
│                                                                                  │
│  Local services                                                                  │
│  ├── Tree-sitter syntax sessions                                                 │
│  ├── LocalFileSystemClient                                                       │
│  ├── LocalGitClient                                                              │
│  ├── SSHConnectionManager ── /usr/bin/ssh ───────────────┐                       │
│  ├── AICommitMessageProvider                              │                       │
│  ├── KeychainStore                                       │                       │
│  └── LauncherIPCServer ◀──── Unix socket ◀──── CLI tool  │                       │
└───────────────────────────────────────────────────────────┼───────────────────────┘
                                                            │ encrypted SSH channel
                                                            ▼
                                              ┌───────────────────────────┐
                                              │ Remote machine            │
                                              │                           │
                                              │ Versioned headless agent  │
                                              │ ├── file operations       │
                                              │ ├── file watches          │
                                              │ ├── directory listing     │
                                              │ └── Git operations later  │
                                              │                           │
                                              │ Repository remains remote │
                                              └───────────────────────────┘
```

### 5.2 Technology choices

| Concern | Choice |
|---|---|
| App lifecycle and shell | SwiftUI |
| Text editor | AppKit `NSTextView`, TextKit 2 |
| State model | Swift Observation with narrow ownership |
| Syntax | Tree-sitter through a maintained Swift wrapper |
| Local file events | FSEvents / appropriate Foundation-AppKit APIs |
| Remote transport | System OpenSSH subprocess |
| Remote operations | Versioned Rust agent over SSH stdio |
| Local Git | Git executable via `Foundation.Process` |
| Remote Git | Git invoked by remote agent |
| AI networking | `URLSession` |
| Secrets | macOS Keychain |
| Preferences | `UserDefaults` / `@AppStorage` for nonsecret values |
| CLI IPC | Unix-domain socket with peer validation |
| Distribution | Developer ID signing and notarized direct download first |

### 5.3 Deployment recommendation

- Compile with the current stable Xcode/macOS SDK.
- A reasonable first public deployment target is **macOS 15 or newer**.
- For a strictly personal build, raising the deployment target to the oldest macOS version on your own machines is a valid simplification.
- Use standard controls so current and future macOS design behavior arrives automatically; avoid making the entire architecture depend on one generation of visual APIs.

---

## 6. State and ownership

### 6.1 Global application services

```text
AppServices
├── SettingsStore
├── KeychainStore
├── RecentWorkspaceStore
├── LanguageRegistry
├── SSHHostCatalog
├── SSHConnectionPool
├── AIProviderFactory
└── LauncherIPCServer
```

Shared services are injected through the environment where they are genuinely app-wide. Feature-specific dependencies are passed explicitly.

### 6.2 Per-window state

Every window owns one `WorkspaceSession`:

```text
WorkspaceSession
├── WorkspaceDescriptor
├── WorkspaceFileSystem
├── open EditorBuffers
├── selected tab and pane layout
├── FileTreeModel
├── RepositoryState
├── connection state
└── restoration state
```

`WorkspaceSession` is `@MainActor` because it coordinates UI-visible state. File I/O, parsing, Git, SSH, and AI work run in actors or cancellable tasks outside the main actor.

### 6.3 Workspace identity

The earlier URL-only buffer model must be generalized for SSH:

```swift
enum WorkspaceLocation: Hashable, Codable, Sendable {
    case local(LocalWorkspaceReference)
    case ssh(SSHWorkspaceReference)
}

struct SSHWorkspaceReference: Hashable, Codable, Sendable {
    let hostAlias: String
    let root: RemotePath
}

struct WorkspaceFileID: Hashable, Sendable {
    let workspaceID: UUID
    let path: WorkspacePath
}
```

A remote file is not represented internally as a `file://` URL. Commands that require a local URL are explicitly unavailable or use a temporary exported copy.

### 6.4 File-system protocol

```swift
protocol WorkspaceFileSystem: Sendable {
    func listDirectory(_ path: WorkspacePath) async throws -> [FileEntry]
    func metadata(for path: WorkspacePath) async throws -> FileMetadata
    func readFile(_ path: WorkspacePath) async throws -> FileSnapshot
    func writeFile(
        _ path: WorkspacePath,
        contents: Data,
        expectedVersion: FileVersion?
    ) async throws -> FileSnapshot
    func createDirectory(_ path: WorkspacePath) async throws
    func move(_ source: WorkspacePath, to destination: WorkspacePath) async throws
    func remove(_ path: WorkspacePath, recursively: Bool) async throws
    func watch(_ request: WatchRequest) async throws -> AsyncThrowingStream<FileEvent, Error>
}
```

Implementations:

- `LocalWorkspaceFileSystem`
- `RemoteWorkspaceFileSystem`

The UI and editor should depend on this protocol, not branch on local versus remote throughout the view hierarchy.

### 6.5 Editor buffer rule

**Do not put the full document string in SwiftUI observable state.**

```text
File system snapshot
        ↓
EditorBuffer metadata
├── file identity
├── dirty state
├── revision
├── disk/remote version
├── encoding and line endings
└── selection metadata
        ↓
NSTextStorage / NSTextView owns live text
        ↓
Tree-sitter actor receives edit deltas
```

This limits copying and invalidation. SwiftUI observes small metadata, not every character.

---

## 7. Editor implementation

### 7.1 Editor control

```text
NSScrollView
├── LineNumberRulerView
└── CodeTextView: NSTextView
    ├── TextKit 2 layout
    ├── native input methods
    ├── undo manager
    ├── selection-set command layer
    ├── bracket/current-line decorations
    └── syntax attributes
```

Before committing to a fully bespoke `NSTextView` subclass, evaluate **STTextView** and the **CodeEdit source editor** (both MIT, both TextKit 2) as a foundation or, at minimum, a reference implementation for ruler views, invisible characters, TextKit 2 edge cases, and IME handling. Adopting one does not change the architecture above; it changes how much of it is written from scratch. Audit memory behavior and keep the dependency surgically replaceable — the buffer-ownership rule in section 6.5 must hold either way.

### 7.2 Phase 1 editing baseline

- Open and save UTF-8 text files
- Preserve LF versus CRLF
- Native undo/redo
- Cut/copy/paste/select all
- Line numbers
- Current-line highlight
- Find and replace
- Go to line and column
- Tabs versus spaces and tab width
- Indent/outdent
- Auto-indent on return
- Toggle comments for supported languages
- Move and duplicate lines
- Soft-wrap toggle
- Dirty tab indicator
- External modification handling
- Binary and unsupported-encoding warning
- Core bundled syntax highlighting

### 7.3 Phase 2 editor completeness

- Select next occurrence
- Multiple cursors/selections
- Bracket matching and auto-closing pairs
- Quick file open
- Project-wide search
- Horizontal and vertical splits
- Restore tabs, selections, and scroll positions
- Configurable shortcuts
- Large-file mode
- Status bar details
- Optional code outline from Tree-sitter captures

### 7.4 Syntax language set

Initial bundled languages:

```text
Plain text
.env / dotenv
Bash
Dockerfile
JSON
YAML
TOML
Markdown
Swift
Python
JavaScript
TypeScript
```

Detection combines extensions and exact filenames:

```text
Dockerfile
Dockerfile.*
Makefile
.env
.env.local
.env.production
.gitignore
Package.swift
compose.yaml
docker-compose.yml
```

### 7.5 Syntax pipeline

1. `NSTextView` applies an edit locally.
2. Record edited UTF-16 range, inserted bytes, removed bytes, and document revision.
3. Send a compact delta to a per-buffer syntax actor.
4. Update the existing syntax tree incrementally.
5. Reparse and query only changed or visible ranges.
6. Return highlight spans tagged with the source revision.
7. Discard stale results.
8. Apply attributes on the main actor without creating undo entries.

### 7.6 Large-file policy

Thresholds are tuned through profiling, but the behavior is defined in advance:

| Size/complexity | Behavior |
|---|---|
| Normal | Full syntax and editing features |
| Medium-large | Visible-range highlighting; disable expensive structure |
| Very large | Plain text, no wrap, reduced decorations |
| Extreme or binary | Read-only warning or external-app suggestion |

### 7.7 Markdown: edit and preview by default

Markdown is a first-class document type. `.md`/`.markdown` files open with **both editing and preview available by default** via a per-document mode control:

```text
[ Edit | Split | Preview ]        toggle: ⇧⌘V (verify against final menu map)
```

- **Default mode: Split** (source left, live preview right), collapsing automatically to Edit below a window-width threshold. The default is configurable in Settings (Edit / Split / Preview) and the last mode is remembered per file in restoration state.
- **Rendering is native.** Parse with **cmark-gfm** (or `swift-markdown`, which wraps it) and render to an attributed string in a TextKit 2 view. **No per-document `WKWebView`**: each WebView adds a content process worth tens of MB, which the section 14 budget cannot absorb, and a web surface reopens script/CSP questions the product otherwise avoids.
- **GFM subset:** headings, emphasis, lists, task lists, tables, block quotes, fenced code, strikethrough, autolinks, thematic breaks. Fenced code blocks are highlighted through the same Tree-sitter registry and theme syntax tokens as the editor.
- **Raw HTML blocks are not rendered** — they display as code. No script execution of any kind.
- **Images:** local workspace-relative images load (size-capped, decoded lazily); remote images are **blocked by default** with a per-document allow action, consistent with the no-silent-network principle. In SSH workspaces, images resolve through `WorkspaceFileSystem` chunked reads with a bounded cache.
- **Split-mode scroll sync** maps source blocks to rendered blocks (heading/block anchor map); best-effort, never blocking typing.
- **Incremental updates:** re-render is debounced (~100 ms) and prioritizes the visible range for large documents; the editor pane always stays responsive per section 2.3.
- **Theming:** preview typography and colors come from the theme's `markdownPreview` and `markup.*` tokens (Indigo/Khadi ship serif-prose previews via New York with the editor's mono for code).
- Preview participates in the large-file policy (section 7.6): very large markdown falls back to Edit-only with a notice.

Budget: preview overhead for a typical README-sized document should stay under roughly 15 MB, measured in the section 14 fixtures.

---

## 8. SSH workspaces

### 8.1 Product behavior

The app provides:

- **File → Open SSH Folder…**
- A searchable picker of concrete aliases found in `~/.ssh/config` and included files
- A manual host field for aliases or `user@host`
- Recent remote workspaces
- A remote folder browser after authentication
- Connection status and reconnect controls scoped to the workspace window
- CLI equivalents such as `rafu --ssh prod /srv/api`

The window should feel like a normal workspace after connection. The fact that it is remote remains visible in the title/status area but does not dominate the interface.

### 8.2 Why use the system OpenSSH client

Do not implement SSH configuration or authentication in a Swift SSH library for the first product. The user's actual SSH behavior may include:

- `Host` and `Match` rules
- `Include` files and globs
- `ProxyJump` or `ProxyCommand`
- Multiple `IdentityFile` entries
- `IdentityAgent` and `ssh-agent`
- Security keys and PKCS#11 providers
- Certificates
- Custom `UserKnownHostsFile`
- Hostname canonicalization
- Enterprise authentication

The app should execute the same host alias the user already runs in Terminal. OpenSSH remains the authority for configuration evaluation and security behavior.

### 8.3 Host catalog versus configuration resolution

Two separate responsibilities are required:

#### Host catalog

A lightweight parser discovers concrete host aliases for display:

```sshconfig
Host prod-api
    HostName 10.0.0.8
    User deploy

Host staging-*
    User ubuntu
```

The picker can list `prod-api`; it cannot enumerate every possible value represented by `staging-*`. Wildcard-only entries still affect connections entered manually.

The catalog parser should:

- Read `~/.ssh/config`.
- Follow `Include` directives and globs.
- Watch relevant files for changes.
- Extract only concrete, non-negated aliases for the picker.
- Avoid pretending it has fully evaluated `Match`, token expansion, or precedence.

#### Effective resolution

For diagnostics and preview, run:

```bash
/usr/bin/ssh -G prod-api
```

This returns the configuration after OpenSSH evaluates `Host` and `Match`. The actual connection still invokes `ssh prod-api`; parsed preview data never replaces OpenSSH as the source of truth.

### 8.4 Safe connection command

The process runner passes an executable and argument array, never a shell string. A conceptual connection looks like:

```bash
/usr/bin/ssh \
  -T \
  -S <app-control-socket> \
  -o ControlMaster=auto \
  -o ControlPersist=60 \
  -o RequestTTY=no \
  -o RemoteCommand=none \
  -o PermitLocalCommand=no \
  -o ClearAllForwardings=yes \
  prod-api \
  <fixed-agent-command>
```

Exact options must be verified against supported macOS OpenSSH versions. Important policies:

- Preserve authentication, proxies, identity, certificates, and known-host behavior from user config.
- Disable unrelated configured local/remote forwards for the editor's agent session.
- Disable configured remote commands and local commands that could prevent or alter agent startup.
- Do not allocate a pseudo-terminal.
- Use an app-owned control socket in a user-only directory.
- Never invoke a general-purpose shell with user-controlled command text.

### 8.5 Connection multiplexing

Maintain an app-owned SSH control master per effective host identity, or initially per remote workspace if that is simpler. Use a control path under a directory with mode `0700`, such as:

```text
~/Library/Caches/<bundle-id>/ssh/<hash>/control.sock
```

Benefits:

- Authentication occurs once for related sessions.
- Agent bootstrap and subsequent commands avoid repeated handshakes.
- Multiple remote windows can share the transport when safe.

The pool must close idle masters and remove stale sockets.

### 8.6 Authentication and askpass

Because the app launches SSH without an interactive terminal, bundle a tiny `ssh-askpass` helper.

```text
ssh process
   │ invokes SSH_ASKPASS with prompt
   ▼
bundled askpass helper
   │ private Unix-socket request
   ▼
SSHAskpassBroker in app
   │ window-attached native sheet
   ▼
user response
   │ returned only through private IPC/stdout
   ▼
ssh process
```

Environment:

```text
SSH_ASKPASS=<path to signed helper>
SSH_ASKPASS_REQUIRE=force
```

Rules:

- Passwords and passphrases are never logged or persisted by the app.
- Prefer the user's existing agent/Keychain/security-key setup.
- The relevant workspace window owns the prompt.
- Cancellation terminates the connection attempt cleanly.
- The prompt text is treated as untrusted display text.
- Only one sensitive prompt is active per connection attempt.

### 8.7 Host-key policy

- Keep OpenSSH's normal `known_hosts` behavior.
- Never set `StrictHostKeyChecking=no`.
- For an unknown host, show the host, resolved destination where available, key type, and fingerprint from the OpenSSH prompt, then allow Connect or Cancel.
- Let OpenSSH update the configured known-hosts file after confirmation.
- A changed host key is a blocking security error. Do not offer a one-click “ignore and continue.” Provide diagnostic guidance and a way to reveal the relevant known-hosts entry.

### 8.8 Remote agent architecture

#### Purpose

A persistent agent prevents the app from running a new remote shell command for every file read, directory expansion, save, watch event, or Git query.

#### Language

Use Rust for the first remote agent because it can produce small, predictable headless binaries for Linux and macOS, including static Linux builds. The main app remains Swift/AppKit/SwiftUI.

#### Transport

- The agent communicates through stdin/stdout of the SSH exec channel.
- It opens no TCP listening port.
- It runs as the authenticated remote user.
- Stderr is reserved for structured diagnostics and never mixed into protocol frames.

#### Installation layout

```text
${XDG_CACHE_HOME:-$HOME/.cache}/<product>/agent/
└── <agent-version>/
    └── <target-triple>/
        └── rafu-agent
```

Permissions:

- Directories private to the remote user where possible.
- Agent binary mode `0700`.
- Temporary upload followed by an atomic rename.
- A per-host custom install directory setting for `noexec` home/cache environments.

#### Bootstrap

1. Connect with system SSH.
2. Detect remote OS, architecture, shell availability, and home/cache path using a fixed script.
3. Check the installed agent version and protocol compatibility.
4. Upload the matching signed/release binary over the encrypted channel if missing or mismatched.
5. Verify transfer/build identity.
6. Start `rafu-agent --stdio` using a fixed, app-controlled remote command.
7. Complete a versioned capability handshake, then send the selected workspace root as raw path data inside the protocol. Never interpolate a user-selected remote path into the SSH remote-command string.

Initial targets:

```text
Linux x86_64
Linux arm64
macOS x86_64
macOS arm64
```

Remote Windows is deferred.

### 8.9 Remote protocol

Use a small, versioned, length-prefixed binary protocol such as CBOR or MessagePack.

```text
4-byte big-endian frame length
        ↓
encoded message
```

Every request contains:

- Protocol version
- Request ID
- Operation
- Workspace-relative path or parameters
- Optional expected file version

Every response contains:

- Matching request ID
- Result or structured error
- Remote metadata/version

The protocol also supports unsolicited events for:

- File-system changes
- Watch overflow
- Git-state invalidation
- Agent shutdown

Capabilities in Phase 1:

```text
handshake
list directory
stat/lstat
read file in chunks
atomic write
create directory
rename/move
delete
watch paths
cancel request
ping
```

Later capabilities:

```text
Git status/diff/stage/unstage/commit
project search
optional formatters/language tools
```

### 8.10 Remote paths

Unix filenames are byte sequences, not guaranteed UTF-8. Define a `RemotePath` that can preserve raw bytes:

```swift
struct RemotePath: Hashable, Codable, Sendable {
    let rawComponents: [Data]
    let displayString: String
}
```

The protocol sends raw path bytes. The UI uses a lossless escaped display for invalid UTF-8. Do not silently replace bytes and then write to a different filename.

### 8.11 Remote read and save semantics

#### Read

A `FileSnapshot` contains:

- Contents or streamed chunks
- Size
- Permissions/mode
- Modification time
- File identity where available
- A version token derived from stable metadata and/or content hash
- Encoding and line-ending detection results

#### Save

1. Compare the expected version from the opened snapshot with the current remote version.
2. If it differs and the buffer is dirty, return a conflict rather than overwrite.
3. Write to a temporary file in the same directory.
4. Preserve appropriate permissions.
5. Flush as required.
6. Atomically rename over the destination.
7. Return the new metadata/version.

This prevents partial writes and reduces the chance of overwriting changes made by an agent or another SSH session.

### 8.12 Remote file watching

The remote agent watches:

- Open files
- Expanded directories
- Workspace metadata needed for refresh
- `.git` metadata relevant to status, once Git is added

Use native mechanisms through a Rust watcher abstraction—such as inotify on Linux and FSEvents on macOS—then debounce bursts before sending them to the app. Do not recursively watch every directory in a huge repository by default. If an event stream overflows, invalidate the affected model and perform a bounded refresh.

### 8.13 Disconnection behavior

| State | Behavior |
|---|---|
| Clean buffer, connection drops | Keep local snapshot, mark unavailable, reconnect automatically with bounded backoff |
| Dirty buffer, connection drops | Keep every unsaved edit locally; never close the tab |
| Reconnected, remote unchanged | Resume normally |
| Reconnected, remote changed | Show Compare / Keep Mine / Reload decision |
| Agent version mismatch | Restart or reinstall agent, preserving buffers |
| Host unavailable | Nonblocking banner with Retry and diagnostics |
| Authentication expires | Prompt in the workspace window |

Unsaved remote buffers should also participate in local crash restoration, encrypted or protected using standard application storage permissions.

### 8.14 Remote workspace trust

Introduce a simple trust state for local and remote folders:

- **Untrusted:** editing and viewing are allowed; executable features are disabled.
- **Trusted:** Git commit hooks and any later tasks/language tools may execute.

The initial app has no extension or task system, so the risk is narrower. However, `git commit` can execute repository hooks. Explain this at the moment the first commit is attempted rather than presenting a vague startup warning.

---

## 9. Command-line launcher

The command is **`rafu`**, matching the product name. A collision check against POSIX utilities, common Homebrew formulae and casks, and shipping macOS developer tools found no conflicts (see section 2.4).

### 9.1 Command surface

```bash
# Open current local directory
rafu .

# Open a local file
rafu README.md

# Open in a new workspace window
rafu --new-window .

# Reuse the best matching existing window
rafu --reuse-window .

# Open a file at line and column
rafu --goto Sources/App.swift:42:8

# Wait until the file or workspace is closed
rafu --wait README.md

# Open a remote folder using an SSH config alias
rafu --ssh prod-api /srv/api

# Open a remote file at a location
rafu --ssh prod-api --goto /srv/api/Sources/main.py:42:8

# URI form for scripts and links
rafu 'ssh://prod-api/srv/api'

# Diagnostics
rafu --list-ssh-hosts
rafu --status
rafu --version
rafu --help
```

### 9.2 CLI target

Add a separate Xcode command-line-tool target:

```text
RafuLauncher
├── argument parser
├── path resolver
├── app locator
├── IPC client
└── wait-session handling
```

The launcher should be small, signed, and bundled under the app's `Contents/SharedSupport/bin` directory.

### 9.3 Installation

Provide **Settings → General → Command Line Tool → Install…**

Preferred first implementation:

1. Copy the signed launcher binary to `~/.local/bin/rafu`.
2. If `~/.local/bin` is not on `PATH`, show the exact one-line shell configuration for the detected shell.
3. Also offer a user-directed destination such as `/usr/local/bin` when it already exists and is writable.
4. Avoid a privileged helper in the first release.
5. Provide Uninstall and Verify buttons.

Do not make the installed command a fragile absolute symlink into an app bundle that may later move. The launcher should locate the app by bundle identifier through Launch Services.

### 9.4 Local IPC

Use a Unix-domain socket:

```text
~/Library/Caches/<bundle-id>/ipc/launcher.sock
```

Security and lifecycle:

- Parent directory mode `0700`; socket accessible only to the user.
- Validate peer credentials and same user ID where supported.
- Version every request.
- Validate message sizes and all paths.
- Remove stale sockets on startup.
- Use one app-level server that routes requests to the correct workspace window.

Conceptual request:

```swift
struct LauncherRequest: Codable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let operation: LauncherOperation
    let activationPolicy: ActivationPolicy
    let wait: Bool
}

enum LauncherOperation: Codable, Sendable {
    case openLocal(paths: [String], locations: [SourceLocation])
    case openSSH(hostAlias: String, path: RemotePath, location: SourceLocation?)
    case listSSHHosts
    case status
}
```

### 9.5 Startup behavior

1. CLI resolves relative local paths against its current working directory.
2. It attempts to connect to the app socket.
3. If unavailable, it launches the app by bundle identifier using Launch Services.
4. It waits for the versioned socket handshake.
5. It sends the open request.
6. The app acknowledges only after the workspace/file has been accepted or a concrete error is known.

Do not use only `open --args`; argument delivery is unreliable for a long-running app and cannot implement robust `--wait` behavior.

### 9.6 Window routing

- `--new-window`: always create a workspace window.
- `--reuse-window`: reuse a window already rooted at the same local folder or SSH host/root.
- Default: reuse an exact existing workspace; otherwise create a new window.
- Opening a file inside an existing workspace focuses that window and opens a tab.
- Opening a path outside every workspace opens its containing folder or a lightweight standalone file window, depending on the final product decision.

### 9.7 `--wait`

The app returns a wait token. The CLI keeps its socket request alive or subscribes using that token until:

- The specific file tab closes, for a file request; or
- The workspace window closes, for a folder request.

Signals terminate the wait cleanly without closing the editor window.

---

## 10. File tree and external changes

### 10.1 Loading strategy

- Enumerate directory children only when expanded.
- Never preload an entire remote repository tree.
- Hide `.git` internals.
- Hide common generated directories by default, with Show Excluded Files.
- Continue to show useful ignored leaf files such as `.env`, dimmed and marked ignored.
- Do not recursively follow directory symlinks without loop detection.

### 10.2 External modification policy

| Buffer state | External event |
|---|---|
| Not open | Refresh relevant tree and Git status |
| Open and clean | Reload automatically, preserving selection when practical |
| Open and dirty | Show Compare, Reload from Source, or Keep My Version |
| Deleted externally | Mark deleted; offer Save As or Close |
| Renamed externally | Reassociate by file identity when reliable; otherwise delete/create |

This policy applies equally to local events and events reported by the remote agent.

### 10.3 File icons

Use a small semantic registry rather than a large branded icon pack:

```text
folder
source
configuration
markup
image
archive
database
text
binary
unknown
```

Add exact-name overrides for Docker, Compose, `.env`, Git, package manifests, and lockfiles. Use SF Symbols for general chrome and bundled vector assets only where a distinct file mark materially improves scanning.

---

## 11. Git architecture: local and remote parity

### 11.1 Shared domain layer

```swift
protocol RepositoryClient: Sendable {
    func status() async throws -> RepositoryStatus
    func diff(_ request: DiffRequest) async throws -> DiffResult
    func stage(paths: [WorkspacePath]) async throws
    func unstage(paths: [WorkspacePath]) async throws
    func commit(message: CommitMessage) async throws -> CommitResult
}
```

Implementations:

- `LocalGitClient` runs local Git through `Foundation.Process`.
- `RemoteGitClient` sends typed requests to the remote agent, which runs Git in the remote workspace.

The SwiftUI source-control UI consumes the same models in both cases.

### 11.2 Git commands and parsing

Use stable, machine-oriented output:

```bash
git status --porcelain=v2 -z --branch
git diff --no-color --no-ext-diff -- <paths>
git diff --cached --no-color --no-ext-diff -- <paths>
git add -- <paths>
git commit -F -
```

Rules:

- Pass arguments directly; never construct a shell command.
- Use `--` before path arguments.
- Parse NUL-delimited output as bytes.
- Drain stdout and stderr concurrently.
- Support cancellation and a bounded timeout.
- Serialize index-changing operations per repository.
- Preserve and display Git hook output.

### 11.3 Initial source-control UI

```text
SOURCE CONTROL

Staged Changes
  M  Sources/App.swift
  A  Sources/SSHConnection.swift

Changes
  M  Dockerfile
  M  .env
  ?? compose.local.yaml

[Generate Commit Message ▾]

Subject
[Add SSH-backed workspace support                  ]

Body
[Describe remote transport and reconnect handling ]

[Commit]
```

Initial Git release supports file-level staging only.

### 11.4 Cases to test

- Repository without an initial commit
- Detached HEAD
- Worktree with `.git` as a file
- Rename/delete/untracked files
- Merge conflict status
- Submodules
- Mixed staged and unstaged changes in one file
- Unicode and newline-containing filenames
- Git executable missing locally/remotely
- Hooks that fail, prompt, or take too long
- Connection loss during a remote operation

---

## 12. AI commit-message generation

### 12.1 Feature boundary

AI generates editable text. It does not stage files, run commands, or commit automatically.

Scopes:

1. **Staged changes** — default
2. **Selected files**
3. **All changes**

Always show:

- Scope name
- File count and filenames
- Approximate payload size
- Sensitive-file exclusions/redactions
- A warning when generated scope differs from the staged commit scope

### 12.2 Provider abstraction

```swift
protocol CommitMessageProvider: Sendable {
    func generate(_ request: CommitMessageRequest) async throws -> CommitSuggestion
}

struct CommitMessageRequest: Sendable {
    let repositoryName: String
    let branchName: String?
    let workspaceLocation: WorkspaceLocationSummary
    let scope: CommitScope
    let sanitizedDiff: String
    let style: CommitStyle
    let customInstructions: String?
}

struct CommitSuggestion: Decodable, Sendable {
    let subject: String
    let body: String?
}
```

First implementation: `OpenAICompatibleCommitProvider`.

Settings:

```text
Provider display name
Base URL
API mode: Responses / Chat Completions compatibility
Model identifier
API key
Commit style: Plain / Conventional Commits
Custom instructions
Request timeout and payload limit
```

### 12.3 API behavior

- Prefer the Responses API for OpenAI endpoints.
- Use a strict structured-output schema for `{ subject, body }` when supported.
- Provide Chat Completions and plain-JSON fallback modes for compatible base URLs.
- Validate output locally before placing it into the commit form.
- Keep the request stateless and tool-free.

### 12.4 Remote diff flow

```text
Remote Git creates diff
        ↓ encrypted SSH
Native app receives diff
        ↓ local secret scanner/redactor
User previews exact payload
        ↓ HTTPS to configured provider
Structured subject/body
        ↓ editable form
User explicitly commits
```

The remote agent never receives the API key. The configured AI provider never receives SSH credentials.

### 12.5 Sensitive-file policy

Default AI exclusions:

```text
.env
.env.*
*.pem
*.key
*.p12
id_rsa
credentials*
secrets*
*token*
```

Local redaction detects likely assignments and headers:

```text
API_KEY=...
PASSWORD=...
SECRET=...
TOKEN=...
Authorization: Bearer ...
```

Replace values with `<redacted>` while retaining enough context to describe the type of change.

Other requirements:

- Require HTTPS for nonlocalhost endpoints.
- Do not log request bodies or full diffs.
- Do not persist generated diff payloads.
- Never send binary content.
- Require a narrower selection when the diff exceeds the configured payload limit; do not silently truncate arbitrary sections.
- Store a user-provided key in Keychain.
- Never ship a shared vendor API key inside the desktop app. A product-funded shared key requires a backend service.

---

## 13. Security model

### 13.1 Assets

- Local and remote source files
- Unsaved buffers
- SSH keys and authentication responses
- OpenAI-compatible API keys
- Diff contents and secrets within them
- Git credentials and hooks
- Local CLI IPC
- Remote agent binary and protocol

### 13.2 Trust boundaries

```text
CLI process → native app IPC
Native app → system SSH process
System SSH → remote host
Native app → AI provider
Workspace files → Git hooks / future executable features
```

### 13.3 Required controls

#### SSH

- System SSH and existing known-hosts files remain authoritative.
- No automatic disabling of host-key verification.
- Private askpass IPC; no credential logging.
- App-owned control sockets in user-only directories.
- Fixed executable paths and argument arrays.
- Remote command content fixed or strongly encoded; no interpolation of arbitrary shell text.

#### Remote agent

- No listening network socket.
- Runs with user privileges only.
- Versioned protocol and maximum frame size.
- Workspace-root capability selected through the binary protocol—not the remote shell command—and path traversal protection.
- Safe symlink policy.
- Atomic writes and expected-version conflict checks.
- Release manifests/checksums and build identifiers.
- Bounded concurrency and resource limits.

#### CLI

- Socket owner and peer validation.
- Versioned, size-bounded messages.
- Canonicalize local paths before routing.
- Treat all CLI arguments as untrusted.
- No remote command execution surface in the launcher protocol.

#### AI

- Keychain for user secrets.
- Local redaction and explicit preview.
- Sensitive files excluded by default.
- No automatic request.
- Endpoint validation and TLS policy.

#### Git

- Argument arrays and `--` path separator.
- Repository trust prompt before the first hook-capable action.
- Clear display of hook output and failures.
- No destructive reset/clean UI in the initial release.

---

## 14. Performance architecture and budgets

These are initial engineering budgets, not promises. Record baselines in Release builds and keep regression fixtures.

| Metric | Initial budget |
|---|---|
| Idle local workspace resident memory | Target below roughly 150 MB |
| Additional idle remote-workspace client overhead | Target below roughly 20–40 MB beyond open buffers |
| Remote agent idle memory | Target below roughly 25 MB |
| Typing latency | p95 edit handling within one display frame |
| Persistent local Git subprocesses | Zero |
| Remote repository preloading | None |
| Syntax parsing | Open buffers only |
| File tree | Lazy children |
| Git refresh | Debounced and cancellable |
| Remote saves | Asynchronous; never block typing |
| AI network activity | Explicit user action only |

### 14.1 Performance rules

- No full document in SwiftUI state.
- No entire repository index in memory for Phase 1.
- Stable identifiers in all file lists.
- No expensive sorting, icon generation, parsing, or path formatting in SwiftUI `body`.
- Cancel stale directory, syntax, diff, and search requests.
- Coalesce file events.
- Cache only bounded metadata and icons.
- Release closed buffers after a restoration snapshot is written.
- Measure local and remote scenarios with Instruments and signposts.

### 14.2 Regression fixtures

- 50,000+ file repository
- Deep directory hierarchy
- 100 open tabs
- Large minified JSON
- Multi-megabyte diff
- Emoji, combining marks, CJK input methods
- Invalid UTF-8 remote filename
- Agent modifying an open file once per second
- High-latency SSH connection
- Disconnect during read, save, directory listing, and Git operation
- Remote inotify/watch overflow

---

## 15. Delivery phases

The inclusion of SSH in Phase 1 materially increases risk. Keep it in Phase 1 as requested, but divide the phase into explicit internal gates so the team does not build the entire application on an unproven remote layer.

**v0.3 sequencing correction:** the founding use case — quick edits to `.env`, Docker, Compose, and config files beside a running coding agent — is local. Therefore **Phase 1A concludes with a shippable internal v0.1** (local workspaces, editing baseline, themes, markdown preview) that goes into genuine daily use *before* Phase 1B lands. This yields real-usage feedback on the editor core while the SSH/agent layer is still being proven, and guarantees a useful product exists even if the remote layer slips. SSH remains in scope for the Phase 1 public release; only the internal gating order is being made explicit.

---

### Phase 0 — Technical feasibility and architecture locks

**Goal:** Prove the three highest-risk foundations before product breadth.

#### Workstream A: editor core

- Wrap TextKit 2 `NSTextView` in SwiftUI.
- Open, edit, save, undo, and line numbers.
- Implement one Tree-sitter language incrementally.
- Verify IME, Unicode, large-file behavior, and no full-string SwiftUI observation.

#### Workstream B: SSH transport

- Discover concrete SSH aliases including `Include` files.
- Run `ssh -G` for diagnostics.
- Establish a connection through `/usr/bin/ssh` using the user's config.
- Build askpass broker and unknown-host-key flow.
- Start a prototype remote helper over stdio.
- Read and atomically write one remote file.
- Disconnect and reconnect without losing a dirty local buffer.

#### Workstream C: CLI

- Build launcher target.
- Launch the app by bundle identifier.
- Send one `open local folder` request over a Unix socket.
- Validate stale-socket recovery and same-user security.

#### Exit criteria

```text
One local file can be edited and saved.
One remote file can be edited and saved through an SSH config alias.
Unsaved remote edits survive a connection drop.
rafu . launches or focuses the app and opens a folder.
Baseline memory and typing traces are recorded.
```

No file tree, Git UI, or visual polish proceeds until this gate passes.

---

### Phase 1 — Usable local and SSH workspace release

**Goal:** Deliver the smallest coherent editor that can replace opening a large IDE for focused local or remote edits.

#### Phase 1A: local workspace shell

- Multi-window `WindowGroup` architecture
- One workspace per window
- Open Folder and recent workspaces
- Lazy local file tree
- Tabs and editor-buffer registry
- Save, Save All, dirty state, and restoration
- External local file events
- Create, rename, move, and delete
- Core syntax set
- Baseline editing commands
- Native menus and keyboard shortcuts
- JSON theme engine with bundled Indigo and Khadi themes, following system appearance
- Markdown edit + native preview (Edit / Split / Preview) with theme-driven typography
- **Gate: internal v0.1** — daily-driver use of the local build begins here

#### Phase 1B: SSH workspace parity

- Open SSH Folder flow
- Searchable config-alias picker
- Manual alias/host entry
- Effective configuration diagnostics
- Askpass authentication UI
- Host-key confirmation and changed-key blocking
- App-owned ControlMaster lifecycle
- Remote OS/architecture detection
- Versioned agent install/update
- Remote directory browser and lazy file tree
- Chunked remote file reads
- Atomic writes with conflict detection
- Remote create/rename/delete
- Remote watch events
- Reconnect state machine
- Remote workspace restoration and recents
- Linux x86_64/arm64 and macOS x86_64/arm64 support

#### Phase 1C: CLI and integration

- Settings-based CLI installation/verification/uninstall
- `rafu .`
- Local file open and `--goto`
- `--new-window` and `--reuse-window`
- `--wait`
- `rafu --ssh <alias> <path>`
- SSH URI parsing
- App-running and app-not-running paths
- Correct routing among multiple windows
- Finder drag/drop and Open With integration where practical

#### Phase 1 design pass

- Standard toolbar and menu hierarchy
- Files/Changes sidebar container, with Changes disabled until Phase 3
- Remote title/status treatment
- Window-scoped connection and authentication sheets
- Accessibility labels, keyboard traversal, contrast and motion checks
- No decorative animation for frequent keyboard actions

#### Phase 1 exit criteria

```text
rafu . opens a local repository in an independent window.
rafu --ssh prod /srv/app opens a remote folder through ~/.ssh/config.
Two local/remote workspaces operate independently in separate windows.
Files can be opened, edited, saved, created, renamed, and deleted locally and remotely.
Changes made by Codex/Claude Code or another remote process are detected.
A dirty buffer survives disconnect and app relaunch recovery.
Unknown host keys require confirmation; changed keys are blocked.
Typing remains entirely local and responsive under high SSH latency.
A markdown file opens in Split mode with an accurate native preview.
Both bundled themes render correctly and track the system appearance; a user theme JSON hot-reloads.
```

#### Explicit Phase 1 exclusions

- Git UI
- AI commit generation
- Project-wide remote search
- Split panes
- Multiple cursors
- Language servers
- Embedded terminal

The architecture for these features exists, but the release remains focused.

---

### Phase 2 — Editing completeness and performance

**Goal:** Make ordinary code/config editing comfortable enough that another editor is rarely needed.

#### Features

- Multiple selections and select-next-occurrence
- Bracket matching and auto-closing pairs
- Quick Open
- Local and agent-backed remote project search
- Replace in files with preview
- Split panes
- Move/duplicate/delete line commands
- Restore selection and scroll state
- Configurable keyboard shortcuts
- Status bar details
- Large-file mode
- Optional Tree-sitter outline
- Drag files between folders

#### Engineering

- Central selection-set and edit transaction engine
- Reverse-order multi-range edits in one undo group
- Search index strategy that does not preload repository contents
- Instruments performance pass
- Remote latency and cancellation tests
- Memory regression suite

#### Exit criteria

```text
Normal edits to source, Docker, Compose, environment, and manifest files do not require another editor.
Quick Open and command surfaces feel instantaneous.
Large repositories remain lazy and responsive.
Local and remote editing use the same commands and visual model.
```

---

### Phase 3 — Git for local and SSH workspaces

**Goal:** Complete the edit-review-stage-commit loop in either workspace type.

#### Features

- Repository detection
- Branch and detached-state display
- Porcelain-v2 status parser
- Changes and Staged Changes sections
- Unified diff viewer
- Open changed file from source control
- File-level stage/unstage
- Editable subject/body
- Commit through stdin
- Refresh after external Git commands
- Readable conflict state
- Worktree and submodule awareness

#### Remote behavior

- All remote Git commands execute on the remote host through the agent.
- Only structured status and requested diff content cross SSH.
- Git executable/version diagnostics are per workspace.
- Remote connection loss cancels cleanly without corrupting UI state.

#### Exit criteria

```text
Local: edit → review → stage → commit succeeds.
SSH: edit → review → stage → commit succeeds on the remote repository.
Mixed staged/unstaged files are represented accurately.
Hooks and failures are visible and do not freeze the UI.
```

---

### Phase 4 — AI-generated commit messages

**Goal:** Add a narrow, safe AI accelerator to the existing Git flow.

#### Features

- OpenAI-compatible provider settings
- Base URL, API mode, model, and API key
- Keychain storage
- Responses API adapter
- Chat Completions compatibility adapter
- Structured subject/body output
- Staged, selected-file, and all-change scopes
- Exact payload preview
- Sensitive-file exclusion and secret redaction
- Scope mismatch warning
- Retry and cancellation
- Plain and Conventional Commit styles
- Editable result; no automatic commit

#### Exit criteria

```text
A user can preview the exact sanitized local or remote diff sent to the provider.
.env and likely-secret files are excluded by default.
The generated message accurately corresponds to its displayed scope.
The user edits or rejects it before committing.
No API credential is sent to the remote agent.
```

---

### Phase 5 — Hardening and distribution

**Goal:** Make the app reliable enough for daily use and external distribution.

#### Reliability

- Crash restoration for local and remote buffers
- Agent rollback on incompatible update
- Corrupt upload and noexec-directory recovery
- Watch overflow recovery
- Disk-full and permission-error flows
- Network transitions and sleep/wake
- Stale SSH control socket recovery
- Moved/renamed app and CLI verification

#### Security

- Documented threat model
- Fuzz/negative tests for CLI and remote protocol frames
- Path traversal and symlink tests
- Host-key and askpass review
- Secret scanner fixtures
- Dependency and release-signing process

#### Accessibility and design

- VoiceOver audit
- Full Keyboard Access audit
- Reduce Motion/Transparency and Increase Contrast
- Light/dark and accent-color verification
- Localization readiness
- Toolbar customization and compact-window checks

#### Distribution

- Developer ID signing
- Notarization
- Signed agent release manifest and checksums
- Direct updater only after core release reliability is established
- Privacy policy explaining remote agent and AI data flow

#### Exit criteria

```text
Notarized build installs cleanly.
CLI installation is reversible and survives normal app updates.
Supported remote targets receive the correct verified agent.
Recovery paths preserve user work.
Performance and accessibility gates pass on supported macOS versions.
```

---

### Phase 6 — Optional controlled expansion

Only consider items that maintain the product's small-runtime premise:

- Built-in formatter integrations
- A few opt-in bundled language servers
- Hunk staging
- Read-only Git history/blame
- Open remote shell in external Terminal
- Remote port-forward UI
- Workspace tasks with explicit trust

Do not add a general extension host unless the product strategy intentionally changes.

---

## 16. Phase 1 implementation backlog

### Foundation

1. Create app, editor, launcher, protocol, and remote-agent targets.
2. Define `WorkspaceLocation`, `WorkspaceFileID`, `WorkspacePath`, and `RemotePath`.
3. Define `WorkspaceFileSystem` and test doubles.
4. Build `WorkspaceSession` ownership and multi-window routing.
5. Add structured logging with privacy redaction and signposts.

### Editor

6. Implement `CodeTextView` and SwiftUI bridge.
7. Implement buffer registry and text-storage ownership.
8. Add line-number ruler, dirty state, save, and undo.
9. Add command routing through native menus.
10. Add syntax registry and first Tree-sitter grammar.
11. Add find/replace, go-to-line, indentation, and soft wrap.
12. Add external-change conflict banner.

### Local workspace

13. Implement lazy local directory listing.
14. Implement local file read/write/version tokens.
15. Add local file watcher and event coalescing.
16. Add create/rename/delete with undo where feasible.
17. Add recent workspace and restoration records.

### SSH

18. Implement SSH config catalog and `Include` traversal.
19. Implement `ssh -G` parser for diagnostics.
20. Implement `SSHProcessRunner` with concurrent stdout/stderr draining.
21. Implement askpass helper and broker.
22. Implement host-key prompt classification and UI.
23. Implement control-master pool and stale-socket cleanup.
24. Define remote protocol framing and handshake.
25. Implement Rust agent metadata/list/read/write operations.
26. Implement agent bootstrap and target selection.
27. Implement remote file-system client.
28. Implement remote watcher events.
29. Implement reconnect and expected-version conflict handling.
30. Add remote folder browser and recent paths.

### CLI

31. Build command-line argument parser.
32. Implement Launch Services app discovery/start.
33. Implement app Unix-socket server and peer validation.
34. Implement local folder/file requests.
35. Implement SSH requests and URI parsing.
36. Implement line/column navigation.
37. Implement `--wait` lifecycle.
38. Implement installation, verification, and removal UI.

### Design/accessibility/performance

39. Build native toolbar/sidebar anatomy.
40. Add remote and connection status presentation.
41. Add keyboard-focus and VoiceOver identifiers.
42. Add Reduce Motion/Transparency behavior checks.
43. Capture Release-build memory, hang, and time-profiler baselines.
44. Add large-repository and high-latency automated fixtures.

### Theming and markdown

45. Define the theme JSON schema, parser, validation, and fallback rules.
46. Implement the theme store: bundled/user discovery, appearance following, hot reload, cached attribute tables.
47. Author and contrast-check the Indigo and Khadi theme files, including `markup.*` and diff tokens.
48. Implement the cmark-gfm → attributed-string markdown renderer with fenced-code highlighting.
49. Implement the Edit / Split / Preview document mode control, scroll sync, and per-file mode restoration.
50. Implement image policy (local allowed and size-capped, remote blocked with per-document allow) across local and SSH workspaces.

---

## 17. Suggested source layout

```text
Rafu/
├── App/
│   ├── RafuApp.swift
│   ├── AppServices.swift
│   ├── AppCommands.swift
│   ├── WindowCoordinator.swift
│   └── LauncherIPCServer.swift
├── DesignSystem/
│   ├── AppMetrics.swift
│   ├── SemanticStyles.swift
│   ├── ConnectionStatusView.swift
│   └── AccessibilitySupport.swift
├── Workspace/
│   ├── WorkspaceSession.swift
│   ├── WorkspaceDescriptor.swift
│   ├── WorkspaceLocation.swift
│   ├── WorkspaceFileID.swift
│   ├── WorkspaceWindowView.swift
│   ├── WorkspaceRestoration.swift
│   └── RecentWorkspaceStore.swift
├── EditorCore/
│   ├── EditorBuffer.swift
│   ├── EditorBufferRegistry.swift
│   ├── CodeTextView.swift
│   ├── CodeTextViewRepresentable.swift
│   ├── EditorSelectionSet.swift
│   ├── EditorCommand.swift
│   ├── LineNumberRulerView.swift
│   └── FindController.swift
├── FileSystem/
│   ├── WorkspaceFileSystem.swift
│   ├── WorkspacePath.swift
│   ├── FileSnapshot.swift
│   ├── FileVersion.swift
│   ├── LocalWorkspaceFileSystem.swift
│   ├── LocalFileWatcher.swift
│   └── FileTreeModel.swift
├── Remote/
│   ├── SSHHostCatalog.swift
│   ├── SSHConfigParser.swift
│   ├── SSHResolvedConfig.swift
│   ├── SSHProcessRunner.swift
│   ├── SSHControlMasterPool.swift
│   ├── SSHAskpassBroker.swift
│   ├── RemoteAgentInstaller.swift
│   ├── RemoteAgentClient.swift
│   ├── RemoteProtocol.swift
│   ├── RemotePath.swift
│   └── RemoteWorkspaceFileSystem.swift
├── Syntax/
│   ├── LanguageRegistry.swift
│   ├── LanguageConfiguration.swift
│   ├── SyntaxSession.swift
│   └── HighlightSpan.swift
├── Theming/
│   ├── Theme.swift
│   ├── ThemeSchema.swift
│   ├── ThemeParser.swift
│   ├── ThemeStore.swift
│   ├── ThemeAttributeCache.swift
│   └── CaptureTokenMap.swift
├── Markdown/
│   ├── MarkdownRenderer.swift
│   ├── MarkdownPreviewView.swift
│   ├── MarkdownDocumentModeView.swift
│   ├── MarkdownScrollSync.swift
│   └── MarkdownImagePolicy.swift
├── Git/
│   ├── RepositoryClient.swift
│   ├── LocalGitClient.swift
│   ├── RemoteGitClient.swift
│   ├── ProcessRunner.swift
│   ├── GitStatusParser.swift
│   ├── RepositoryState.swift
│   └── DiffModel.swift
├── CommitAI/
│   ├── CommitMessageProvider.swift
│   ├── OpenAICompatibleProvider.swift
│   ├── CommitPromptBuilder.swift
│   ├── DiffSanitizer.swift
│   └── CommitSuggestion.swift
├── Security/
│   ├── KeychainStore.swift
│   ├── WorkspaceTrustStore.swift
│   └── SensitiveValueRedactor.swift
├── Settings/
│   ├── SettingsStore.swift
│   ├── SettingsView.swift
│   ├── SSHSettingsView.swift
│   └── CommandLineToolSettingsView.swift
├── Launcher/
│   ├── main.swift
│   ├── LauncherArguments.swift
│   ├── LauncherIPCClient.swift
│   └── WaitSession.swift
└── Tests/
    ├── EditorTests/
    ├── FileSystemTests/
    ├── SSHConfigTests/
    ├── RemoteProtocolTests/
    ├── GitParserTests/
    ├── LauncherTests/
    └── PerformanceFixtures/

remote-agent/
├── Cargo.toml
├── protocol/
│   └── src/
├── agent/
│   └── src/
├── integration-tests/
└── release-manifest/
```

Keep these as folders in a manageable project initially. Extract Swift packages only when boundaries stabilize or independent testing/build speed justifies it.

---

## 18. Testing matrix

### 18.1 Editor

- ASCII, emoji, combining characters, RTL samples, and CJK IME
- Undo grouping for indentation and line operations
- LF/CRLF preservation
- External modification while clean and dirty
- Large and minified files
- Rapid tab close/open and restoration

### 18.2 SSH configuration

- Basic alias
- `Include` relative paths, absolute paths, globs, and nested includes
- Wildcard `Host`
- Negated host patterns
- `Match` blocks
- `ProxyJump`
- `ProxyCommand`
- Multiple identities
- `IdentityAgent`
- Security key prompts
- Custom known-hosts file
- Config syntax error
- Missing config

### 18.3 Authentication and trust

- Agent authentication
- Key passphrase
- Password
- Multi-step/MFA-style prompts
- Unknown host key accepted/canceled
- Changed host key
- Canceled askpass
- App window closed during prompt

### 18.4 Remote agent

- Linux and macOS, x86_64 and arm64
- Missing cache directory
- `noexec` home/cache
- Permission denied
- Disk full
- Corrupt or partial binary upload
- Protocol mismatch
- Agent crash and restart
- Remote shell with unusual startup files
- Path containing spaces, quotes, Unicode, newline, and invalid UTF-8
- Symlink inside/outside root
- Watch event overflow
- Network loss during each operation

### 18.5 CLI

- App closed/running
- Stale socket
- Multiple installed app copies
- App moved after CLI installation
- Relative and absolute paths
- Symlinks
- `--goto` validation
- `--wait` and signals
- Local and SSH window routing
- Concurrent CLI requests
- Unsupported protocol version

### 18.6 Git and AI

- All Git repository edge cases listed earlier
- Remote Git under latency/disconnection
- Diff containing prompt-injection text
- Secret redaction false positives/negatives
- Provider timeout/rate limit/schema error
- Custom base URL path joining
- Scope mismatch
- Binary and huge diffs

---

## 19. Decision register

| ID | Decision | Rationale |
|---|---|---|
| D-001 | SwiftUI shell + AppKit/TextKit editor | Native window composition without putting high-frequency text editing in SwiftUI state |
| D-002 | Workspace-per-window | Matches repository mental model and isolates connection/Git state |
| D-003 | Local UI and buffers for SSH | Typing remains responsive and dirty edits survive network loss |
| D-004 | System OpenSSH | Reuses actual user config, agents, proxies, certificates, and host verification |
| D-005 | Versioned remote agent over stdio | Efficient, typed remote operations without a listening port or repeated shells |
| D-006 | Rust remote helper | Practical small cross-platform headless binaries; desktop app remains native Swift |
| D-007 | CLI through Unix-socket IPC | Reliable with a running app and supports `--wait` and window routing |
| D-008 | No extension host | Protects scope, memory, security, and product identity |
| D-009 | Local and remote Git share one model | Keeps UI behavior consistent; execution occurs where repository lives |
| D-010 | AI runs locally against an explicit sanitized diff | Keeps SSH credentials remote, API credentials local, and user in control |
| D-011 | Direct notarized distribution first | Simplifies arbitrary local folders, CLI integration, system Git, and SSH subprocess use |
| D-012 | Standard system design before custom glass | Better compatibility, accessibility, performance, and future macOS adaptation |
| D-013 | Product name **Rafu** (રફૂ, darning), CLI `rafu` | Exact mending metaphor in the founder's own language; short, globally pronounceable; no POSIX/Homebrew/macOS-app collision, unlike Patch (POSIX) and Seam (existing macOS app) |
| D-014 | Data-only JSON theme files | Obsidian/Zed-style personalization with zero code execution; preserves D-008's no-extension-runtime principle |
| D-015 | Native TextKit markdown preview; no per-document WebView | Protects the memory budget and avoids a script/CSP surface; the GFM subset covers repository documentation |
| D-016 | Phase 1A exits as shippable internal v0.1 before Phase 1B | The founding pain is local; guarantees a usable product independent of remote-layer risk |
| D-017 | "Seam" laced-panels app icon | Avoids hashtag/Slack fourfold symmetry; triple encoding (mend, split/diff view, local↔remote join); silhouette survives 16 px |

---

## 20. Open product decisions

These do not block Phase 0 but should be resolved before Phase 1 polish:

1. ~~Product name, bundle identifier, and noncolliding CLI command.~~ **Resolved: Rafu / `rafu`** (section 2.4); final bundle identifier (e.g. `dev.vatsalsaglani.rafu`) still to be fixed before Phase 0 signing.
2. Minimum deployment target: broad macOS 15+ versus personal/current-version-only.
3. Whether a file outside any folder opens a lightweight standalone window or its containing folder.
4. Whether remote agent installation is automatic after host trust or requires a one-time explanatory confirmation.
5. Whether app-owned SSH control masters are shared per host or isolated per workspace in the first release.
6. Exact remote symlink policy.
7. Maximum Phase 1 file size and remote chunk size.
8. Whether source-control Changes mode is visible-but-disabled before Phase 3 or hidden entirely.
9. Whether the app stores crash-restoration snapshots of dirty remote buffers by default and how clearly this is disclosed.
10. Which filename/icon mapping is included without becoming a theme ecosystem.
11. Final markdown preview toggle shortcut (⇧⌘V candidate) after auditing the complete menu/shortcut map.
12. Whether user-theme hot reload stays always-on in release builds or moves behind a developer setting.
13. Whether file icons ever become themable (recommended: no in v1 — icons stay a fixed semantic set; themes control color and type only).

---

## 21. Recommended first vertical slice

Build this exact path before adding broad editor commands:

```text
Terminal: rafu .
        ↓
Native app opens one local workspace window
        ↓
Open, edit, and save a file
        ↓
File modified externally and clean buffer reloads
        ↓
Terminal: rafu --ssh prod /srv/app
        ↓
App uses ~/.ssh/config and authenticates through native sheet
        ↓
Remote agent starts and lists the folder lazily
        ↓
Open, edit, and atomically save one remote file
        ↓
Disconnect network while buffer is dirty
        ↓
Reconnect; buffer remains and conflict behavior is correct
```

Once this succeeds with measured memory and latency, finish the rest of Phase 1. Git and AI should be built only after the local/remote file-system abstraction has proven that both workspace types behave consistently.

---

## 22. References reviewed

### Design

- Emil Kowalski skills repository: <https://github.com/emilkowalski/skills>
- Apple-design skill: <https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md>
- Emil design-engineering skill: <https://github.com/emilkowalski/skills/blob/main/skills/emil-design-eng/SKILL.md>
- Apple, “Meet Liquid Glass”: <https://developer.apple.com/videos/play/wwdc2025/219/>
- Apple, “Get to know the new design system”: <https://developer.apple.com/videos/play/wwdc2025/356/>
- Apple Human Interface Guidelines: <https://developer.apple.com/design/human-interface-guidelines/>

### SSH and remote architecture

- OpenSSH `ssh(1)`: <https://man.openbsd.org/ssh>
- OpenSSH `ssh_config(5)`: <https://man.openbsd.org/ssh_config>
- Zed remote development architecture: <https://zed.dev/docs/remote-development>

### AI integration

- OpenAI text generation guide: <https://developers.openai.com/api/docs/guides/text>
- OpenAI structured outputs guide: <https://developers.openai.com/api/docs/guides/structured-outputs>
- OpenAI API-key safety guidance: <https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety>

### Editor and Git foundations

- Tree-sitter documentation: <https://tree-sitter.github.io/tree-sitter/>
- cmark-gfm (GitHub-flavored CommonMark): <https://github.com/github/cmark-gfm>
- swift-markdown: <https://github.com/swiftlang/swift-markdown>
- STTextView (TextKit 2 text view): <https://github.com/krzyzanowskim/STTextView>
- CodeEdit source editor: <https://github.com/CodeEditApp/CodeEditSourceEditor>
- Git porcelain status documentation: <https://git-scm.com/docs/git-status>
- Apple Keychain Services: <https://developer.apple.com/documentation/security/keychain-services>

---

## 23. Final recommendation

Proceed with the product, but treat **TextKit editor behavior, SSH/askpass/remote-agent lifecycle, and CLI-to-app IPC as the three architectural gates**. SSH belongs in Phase 1 as requested, yet it should be built behind the same file-system protocol as local editing from the first day. That prevents remote support from becoming a second editor implementation.

The best product distinction is not merely “written in Swift.” It is:

- no extension runtime,
- no embedded coding agent,
- no remote repository mirror,
- no background language servers by default,
- local typing and unsaved buffers,
- explicit Git and AI actions,
- native macOS interaction and accessibility,
- and a small, observable set of processes and caches.

That combination gives the project a credible path to the calm, low-overhead repository companion you described.
