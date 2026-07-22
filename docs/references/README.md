# Engineering references

These notes are Rafu's durable implementation memory. They record verified behavior and repeatable guidance, not aspirations or temporary debugging transcripts.

## Standing rule

A task that discovers a reusable platform, SDK, toolchain, lifecycle, concurrency, security, performance, packaging, or testing nuance must document it in the same change. See [`../../AGENTS.md`](../../AGENTS.md) for the completion rule.

## Index

| Reference | Read when |
|---|---|
| [`project-structure.md`](project-structure.md) | Adding targets, folders, resources, worktrees, or shared contracts |
| [`build-and-run.md`](build-and-run.md) | Building, launching, debugging, verifying, or staging the app/CLI |
| [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md) | Changing scenes, per-window state, the editor bridge, commands, or native controls |
| [`concurrency.md`](concurrency.md) | Adding actors, tasks, process I/O, cancellation, streams, or cross-actor models |
| [`launcher-cli.md`](launcher-cli.md) | Changing CLI grammar, validation, exit codes, or command help |
| [`cli-app-ipc.md`](cli-app-ipc.md) | Changing the CLI ↔ app Unix-domain socket protocol: framing/codec, same-user listener, request routing/window focus, goto selection, or the CLI connect/fallback flow |
| [`cli-app-location.md`](cli-app-location.md) | How `rafu <path>` finds Rafu.app: real executable path via `_NSGetExecutablePath` (not argv[0]), symlink-based install, dangling-link handling, and the argv[0]/PATH gotcha |
| [`ui-design-language.md`](ui-design-language.md) | Implementing or auditing UI surfaces, color/spacing/radius tokens, form fields, card anatomy, button styles, or titled sheets |
| [`local-editor-vertical-slice.md`](local-editor-vertical-slice.md) | Changing local file trees, open buffers, Markdown/Mermaid preview, JSON themes, or Git capture |
| [`mermaid-native-preview.md`](mermaid-native-preview.md) | Changing Mermaid parsing, diagram-type classification, layered layout, Canvas flow/sequence rendering, or the honest unsupported/malformed fallback |
| [`memory-and-file-indexing.md`](memory-and-file-indexing.md) | Changing the lazy sidebar tree, the background ⌘P file-name index, `WorkspaceChangeSet` directory tracking, or file-ranking behavior |
| [`navigation-and-lsp-contracts.md`](navigation-and-lsp-contracts.md) | Changing the navigation ladder, document edit deltas, language intelligence seams, or process resource tracking |
| [`editor-dependencies.md`](editor-dependencies.md) | Changing Markdown rendering, syntax highlighting, package pins, or editor memory behavior |
| [`large-file-guard-mode.md`](large-file-guard-mode.md) | Understanding large-file thresholds, guard-mode design, suppression chokepoint, known limitations, deferred override commands, bounded draw-path line scans, or headless `NSView` draw-test patterns |
| [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md) | Understanding document hibernation, bounded working set (visible ∪ dirty ∪ newest-8), tab/split data-loss fixes, `pendingDirtyText` exception, undo cap, and known limitations |
| [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md) | App-level memory-pressure monitoring, document hibernation + filename-index shedding on warnings, resource caps (Git/AI/search buffers), polling-audit findings, and cap values table |
| [`ai-provider-rest-contracts.md`](ai-provider-rest-contracts.md) | Changing provider endpoints, streaming, Keychain secrets, connection tests, or commit generation |
| [`git-process-and-parsing.md`](git-process-and-parsing.md) | Changing Git capture, porcelain parsing, unborn repositories, diffs, history, branch operations, batch staging, whole-hunk staging/unstaging, stash, blame, inline blame decorations, hunk peek, commit graph layout, worktree parsing, or the Source Control tree view |
| [`editor-search-and-restoration.md`](editor-search-and-restoration.md) | Changing file/workspace find, replacement, undo grouping, editor splits, or restoration |
| [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) | Adding or changing `.onDrag`/`.onDrop` with a private `UTType`, `NSItemProvider` registration, or `NSTextView` drag acceptance |
| [`multi-caret-editing.md`](multi-caret-editing.md) | Understanding view-owned multi-caret state, TextKit `selectedRanges` bridging (Spike A/B findings), `MultiCaretOverlayView` secondary-caret rendering, batch edits as one undo group with N ordered deltas, ⌥-click/⌘D/⌘⇧L/⌥⌘↑↓ gestures and commands, IME bail, and hibernation restoration |
| [`tree-sitter-highlighting.md`](tree-sitter-highlighting.md) | Tree-sitter full-parse syntax highlighting, SyntaxParsingActor, query loading, router fallback, the 8a/8b split, grammar-backed symbols across ten grammars (hand-authored Bash/Dockerfile/TOML/YAML/Markdown tags.scm), the Markdown @-mode divergence guard, and the bounded lazy markdown_inline injection with the CaptureTokenMap `text.*` rows |
| [`workspace-symbol-index.md`](workspace-symbol-index.md) | Workspace symbol index design (grammar filtering across ten grammars, JSON skip rationale, parser reuse, caps, incremental updates), SyntacticNavigationProvider tier behavior (including idle-as-indexing and the go-to-definition `navigableKinds` filter that excludes Markdown sections), NavigationLadder with LSP insertion point, navigation UI flow (cursor seam, IdentifierUnderCaret, NavigationPresentation, peek view with reference ranking/disclosure, menu commands, ⌘-click implementation), unified buffer symbols, and the /var symlink resolution nuance |
| [`language-catalog-consolidation.md`](language-catalog-consolidation.md) | Canonical language identification mapping (extensions/info-strings/filenames to grammar and LSP IDs), consolidation of parallel mappings, cross-consistency verification, and intentional regex-highlighter separation |
| [`workspace-trust-and-lsp-settings.md`](workspace-trust-and-lsp-settings.md) | Workspace trust approval/revocation in Settings, trust store persistence, end-to-end trust flow with UI prompt mounting, and deferred live-teardown design choice |
| [`language-server-install-staging.md`](language-server-install-staging.md) | StagingValidator's zip-slip symlink policy (allow within-staging targets, reject escapes via lexical resolution), npm dependency resolution within staging (npm-cli derivation, mandatory `--ignore-scripts`, atomic-move seam, optional `ArchiveLayout.npmPackageRoot`), curated-catalog SHA-256 checksum pinning, and the fixture relative-symlink caveat |
| [`skill-routing.md`](skill-routing.md) | Selecting a local skill or Build macOS Apps capability |
| [`command-palette-and-search-pitfalls.md`](command-palette-and-search-pitfalls.md) | Debugging command-palette result rendering, file-index build/retry behavior, or "a fix doesn't seem to work" during manual GUI verification |
| [`searchable-dropdown-component.md`](searchable-dropdown-component.md) | Reusing or extending `RafuSearchableDropdown`/`RafuDropdownFilter` for a new trigger-plus-filterable-list picker |
| [`markdown-local-image-preview.md`](markdown-local-image-preview.md) | Changing Markdown image resolution, the local/remote `ImageProvider` split, or local image decode bounds |
| [`editor-gutter-ruler-tiling.md`](editor-gutter-ruler-tiling.md) | Understanding macOS 26 NSRulerView overlay tiling, the clip-view-width bug, text-under-gutter symptom, and the `EditorDropForwardingScrollView.tile()` classic-tiling fix |
| [`github-cli-integration.md`](github-cli-integration.md) | Implementing or changing GitHub account lookup, repository publishing, or the locator/subprocess/error-taxonomy for system `gh` CLI invocations |
| [`ai-ignore-suggestion-privacy.md`](ai-ignore-suggestion-privacy.md) | Changing ignore-file suggestion prompts, tree serialization, response parsing, bounds, or the explicit accept-before-write policy |
| [`macos26-writing-tools-textkit-layout.md`](macos26-writing-tools-textkit-layout.md) | Understanding the macOS 26 Writing Tools full-TextKit-1-layout hang on selection change, why `RafuTextView` disables `writingToolsBehavior`, and the deferred `allowsNonContiguousLayout` evaluation |
| [`diff-syntax-highlighting-and-hover.md`](diff-syntax-highlighting-and-hover.md) | Diff-canvas syntax highlighting (per-side join-then-slice parsing, the pre-resolved-Language+Query seam, UTF-16 span → `AttributedString` conversion), and new-side-only hover (LSP-only navigation ladder, monospace column hit-test, `.task(id:)` stale-assignment guard) |
| [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md) | Changing terminal session lifecycle, SwiftTerm delegate signals (title/cwd/exit and the bell-forwarding gap), bounded terminal-content reads, `/etc/shells` shell discovery, `UserDefaults`-not-`Sendable` stores, or `UNUserNotificationCenter` usage |
| [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md) | Declaring pure `static`/`func` members in a bare `extension` under a default-`MainActor` target — `nonisolated` does not propagate into the extension and the member silently becomes `@MainActor`, trapping at runtime the first time it runs off-main |
| [`notch-companion.md`](notch-companion.md) | Changing the notch companion (resting strip, hover/pin peek panel, attention feed, usage tiles): derived notch geometry, AppKit-hit-test click-through, focus non-theft invariants, per-panel observer teardown, Codex/Claude usage-file shapes, and the feed's coupling to the `.hud` attention-surface preference |

## Reference-note template

```markdown
# Topic

- Applies to:
- Last verified: Swift/Xcode/macOS version and date

## Rule or observed behavior

## Why it matters

## Reproduction or evidence

## Verification

## Related code, ADRs, and phases
```

Keep one focused subject per note. Add it to this index. Use an ADR instead when the content is a choice among alternatives rather than an observed engineering fact.
