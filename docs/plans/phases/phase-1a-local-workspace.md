# Phase 1A — Local workspace shell and internal v0.1

- **Status:** Planned
- **Depends on:** Product Phase 0 exit
- **Canonical scope:** v0.4 §15 Phase 1A, §16, and §§4–7, 10

## Goal

Ship a coherent local-only internal v0.1 for genuine daily use before full SSH work: independent workspace windows, focused editing, external-change safety, canonical themes, and native Markdown preview.

## Scoped deliverables

- `WindowGroup` multi-window shell with one `WorkspaceSession` per window, Open Folder, recents, restoration, native menus, and shortcuts.
- Lazy local file tree; create, rename, move, delete; hidden `.git`; bounded ignored/generated-file behavior; useful ignored files such as `.env` remain visible but marked.
- Tabs and buffer registry; save/save-all, dirty state, crash restoration, external clean reload, dirty conflict choices, encoding/binary warnings, LF/CRLF preservation.
- Phase 1 editor baseline from §7.2, line-number gutter, find/replace, go-to-line, indentation, comments, line operations, soft wrap, and core bundled syntax set.
- Data-only theme engine with bundled **Indigo** and **Khadi**, validation/inheritance/fallback, system appearance, cached attributes, and user-theme discovery/hot reload.
- Native Markdown Edit/Split/Preview, GFM subset, fenced-code highlighting, bounded image policy, scroll sync, and per-file mode restoration.
- Sparse toolbar/sidebar anatomy, accessibility identifiers, keyboard traversal, and performance telemetry.

## Explicit non-goals

- SSH product parity, complete CLI integration, Git, AI, arbitrary editor pane splits, multiple cursors, project-wide search, LSPs, or embedded terminal.
- Per-document `WKWebView`, executable themes, themed file icons, or broad branded icon packs.
- Decorative animation on typing, tab changes, Quick Open/command surfaces, or frequent keyboard actions.

## Owned paths

- Shell owner: `Rafu/App`, `Rafu/Workspace`, window composition, shared commands.
- Local files owner: `Rafu/FileSystem`, `Rafu/Tests/FileSystemTests`.
- Editor/syntax owner: `Rafu/EditorCore`, `Rafu/Syntax`, editor tests.
- Theme/Markdown owner: `Rafu/Theming`, `Rafu/Markdown`, theme resources and focused tests.
- Integration owner alone edits shared project/resource manifests and `WorkspaceWindowView` composition.

## Locked decisions

- Independent workspace windows; no global super-window.
- File tree is lazy; no whole-repository index.
- Live text remains in TextKit storage, not observable state.
- Themes are data-only JSON and canonical names are Rafu/Indigo/Khadi.
- Markdown preview is native TextKit and raw HTML is displayed as code.
- Local external changes never silently replace a dirty buffer.

## Open blockers to resolve

- Phase 1 maximum editable file size and large-file thresholds.
- Exact generated-directory and filename/icon mapping.
- Whether Changes is hidden or visible-disabled before Phase 3.
- Final Markdown preview shortcut.
- Whether user-theme hot reload is always enabled in release builds.
- Reconcile stale Darn/Linen theme assets to canonical Rafu/Khadi schema and filenames.
- Resolve the system-material versus theme-controlled sidebar/toolbar/status boundary in an ADR before opaque chrome styling.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/swiftui-appkit-boundary.md`](../../references/swiftui-appkit-boundary.md)

## Required skills and capabilities

- `.agents/skills/swiftui-expert-skill` for Observation, stable list identity, view invalidation, accessibility, and Instruments checks.
- `.agents/skills/swift-concurrency-pro` for file I/O, watcher streams, syntax actors, cancellation, and restoration tasks.
- `.agents/skills/apple-design` for immediate feedback, restraint, typography, and reduced-motion/transparency behavior.
- `build-macos-apps:swiftui-patterns`, `build-macos-apps:window-management`, and `build-macos-apps:appkit-interop` for scenes, desktop commands, restoration, and TextKit.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for the daily-driver loop and evidence; use `build-macos-apps:test-triage` only after a failure.
- `.agents/skills/swiftui-pro` as a focused phase-end review, not a substitute for tests.

## Worktree decomposition and integration order

1. Shell owner stabilizes workspace/session, routing, commands, and restoration contracts.
2. Local-file, editor/syntax, and theme/Markdown worktrees proceed against test doubles.
3. Integrate local file system/tree before connecting real buffers.
4. Integrate editor/syntax, then external-change conflict handling.
5. Integrate theme engine before Markdown so preview consumes the same semantic tokens.
6. Integrate Markdown and final shell composition; then run accessibility and performance gates.

## Verification and measurements

- Build/launch from a clean checkout; focused unit tests plus the full app suite.
- Two local workspaces in independent windows with independent tabs, selection, dirty state, and restoration.
- Local create/rename/move/delete and external clean/dirty/deleted/renamed cases.
- UTF-8, LF/CRLF, emoji, combining marks, RTL, CJK IME, binary, unsupported encoding, large/minified files.
- Lazy expansion in a 50,000+ file fixture; verify no recursive preload.
- Indigo/Khadi system switching, malformed/partial theme fallback, hot reload, and contrast/accessibility checks.
- Markdown GFM fixture, raw HTML safety, local image cap, scroll sync, and typical README preview overhead target of roughly 15 MB.
- Record Release idle local-workspace resident memory against the roughly 150 MB target and typing p95 against one display frame.

## Exit criteria

- A local repository opens in its own window and survives relaunch restoration.
- Files can be safely opened, edited, saved, created, renamed, moved, and deleted.
- External agent edits are detected and dirty buffers are never overwritten silently.
- Core languages highlight; ordinary config/source edits are usable.
- Markdown defaults to Split where width permits and preview is accurate/native.
- Indigo and Khadi follow system appearance; malformed themes fail safely.
- The build is used as an internal daily driver with recorded issues and baselines.

## Documentation handoff

Record TextKit and watcher nuances, theme schema/version, language detection, file limits, restoration format, measured memory/typing/Markdown results, daily-driver issues, and all resolved open decisions. Hand Phase 1B stable workspace/file-system contracts and known latency-sensitive boundaries.
