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
| [`editor-dependencies.md`](editor-dependencies.md) | Changing Markdown rendering, syntax highlighting, package pins, or editor memory behavior |
| [`ai-provider-rest-contracts.md`](ai-provider-rest-contracts.md) | Changing provider endpoints, streaming, Keychain secrets, connection tests, or commit generation |
| [`git-process-and-parsing.md`](git-process-and-parsing.md) | Changing Git capture, porcelain parsing, unborn repositories, diffs, history, branch operations, batch staging, or the Source Control tree view |
| [`editor-search-and-restoration.md`](editor-search-and-restoration.md) | Changing file/workspace find, replacement, undo grouping, editor splits, or restoration |
| [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) | Adding or changing `.onDrag`/`.onDrop` with a private `UTType`, `NSItemProvider` registration, or `NSTextView` drag acceptance |
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
