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
| [`launcher-cli.md`](launcher-cli.md) | Changing CLI grammar, validation, exit codes, IPC drafts, or command help |
| [`local-editor-vertical-slice.md`](local-editor-vertical-slice.md) | Changing local file trees, open buffers, Markdown/Mermaid preview, JSON themes, or Git capture |
| [`memory-and-file-indexing.md`](memory-and-file-indexing.md) | Changing the lazy sidebar tree, the background ⌘P file-name index, `WorkspaceChangeSet` directory tracking, or file-ranking behavior |
| [`navigation-and-lsp-contracts.md`](navigation-and-lsp-contracts.md) | Changing the navigation ladder, document edit deltas, language intelligence seams, or process resource tracking |
| [`editor-dependencies.md`](editor-dependencies.md) | Changing Markdown rendering, syntax highlighting, package pins, or editor memory behavior |
| [`large-file-guard-mode.md`](large-file-guard-mode.md) | Understanding large-file thresholds, guard-mode design, suppression chokepoint, known limitations, or deferred override commands |
| [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md) | Understanding document hibernation, bounded working set (visible ∪ dirty ∪ newest-8), tab/split data-loss fixes, `pendingDirtyText` exception, undo cap, and known limitations |
| [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md) | App-level memory-pressure monitoring, document hibernation + filename-index shedding on warnings, resource caps (Git/AI/search buffers), polling-audit findings, and cap values table |
| [`ai-provider-rest-contracts.md`](ai-provider-rest-contracts.md) | Changing provider endpoints, streaming, Keychain secrets, connection tests, or commit generation |
| [`git-process-and-parsing.md`](git-process-and-parsing.md) | Changing Git capture, porcelain parsing, unborn repositories, diffs, history, branch operations, batch staging, or the Source Control tree view |
| [`editor-search-and-restoration.md`](editor-search-and-restoration.md) | Changing file/workspace find, replacement, undo grouping, editor splits, or restoration |
| [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) | Adding or changing `.onDrag`/`.onDrop` with a private `UTType`, `NSItemProvider` registration, or `NSTextView` drag acceptance |
| [`tree-sitter-highlighting.md`](tree-sitter-highlighting.md) | Tree-sitter full-parse syntax highlighting, SyntaxParsingActor, query loading, router fallback, the 8a/8b split, and deliberate markdownInline deferral |
| [`workspace-symbol-index.md`](workspace-symbol-index.md) | Workspace symbol index design (grammar filtering, parser reuse, caps, incremental updates), SyntacticNavigationProvider tier behavior (including idle-as-indexing), NavigationLadder with LSP insertion point, navigation UI flow (cursor seam, IdentifierUnderCaret, NavigationPresentation, peek view with reference ranking/disclosure, menu commands, ⌘-click implementation), unified buffer symbols, and the /var symlink resolution nuance |
| [`language-catalog-consolidation.md`](language-catalog-consolidation.md) | Canonical language identification mapping (extensions/info-strings/filenames to grammar and LSP IDs), consolidation of parallel mappings, cross-consistency verification, and intentional regex-highlighter separation |
| [`workspace-trust-and-lsp-settings.md`](workspace-trust-and-lsp-settings.md) | Workspace trust approval/revocation in Settings, trust store persistence, end-to-end trust flow with UI prompt mounting, and deferred live-teardown design choice |
| [`skill-routing.md`](skill-routing.md) | Selecting a local skill or Build macOS Apps capability |

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
