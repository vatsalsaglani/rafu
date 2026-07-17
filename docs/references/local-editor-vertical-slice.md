# Local editor vertical slice

- **Applies to:** local file trees, TextKit tabs, native Markdown/Mermaid preview,
  bundled JSON themes, and local Git status/stage/commit
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-13

## Rules and observed behavior

- A bounded working set keeps documents' `NSTextView` instances mounted: visible
  in any editor group, marked dirty, or among the newest eight accessed. Other
  documents hibernate (text storage released), reloading from disk on refocus
  with restored selection and scroll position; dirty documents never hibernate.
  Dirty text captured during a structural remount (group split/tab move) survives
  the SwiftUI subtree teardown via `pendingDirtyText`. See
  [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md).
- Live text stays in `NSTextStorage`. SwiftUI observes identity, dirty state,
  revision, preview mode, and errors only. Syntax attributes are debounced and
  applied without replacing the underlying string or selection.
- The tree excludes known generated/heavy roots and symbolic links, but keeps
  useful dotfiles such as `.env`, `.gitignore`, `.github`, and `.swift-format`.
  One unreadable child directory produces an empty node rather than discarding the
  entire workspace tree. UTF-8 editing is capped at 4 MB for this checkpoint.
  The sidebar tree is lazy and expansion-driven, not eagerly recursive — see
  [`memory-and-file-indexing.md`](memory-and-file-indexing.md).
- Markdown preview is a native block renderer. The native Mermaid preview renders
  a bounded supported subset — flowchart/graph (node shapes, subgraphs, direction,
  styled/labeled edges) and sequenceDiagram (lifelines, activations, alt/opt/loop/par
  blocks, notes) — as real 2D native diagrams with a "Simplified native preview" badge;
  every other or malformed diagram type falls back to the source code block plus a
  "not supported in native preview" notice, never a web view (see ADR 0008 and
  [`mermaid-native-preview.md`](mermaid-native-preview.md)).
- Parsed Markdown blocks and Mermaid edges/messages receive durable UUID identity
  before entering SwiftUI. Repeated prose or duplicate edges must not use content
  hashes or array offsets as `ForEach` identity; either choice can merge distinct
  rows or recycle view state after a reparse.
- Indigo and Khadi are decoded from `Resources/Themes/*.json`. The run script
  stages those JSON files and the seam SVG into the real app bundle. Tests also
  resolve resources from the repository working directory.
- A subprocess must not wait for termination while bounded pipes remain undrained:
  sufficiently large output can fill the pipe and deadlock. The initial Git
  client captures stdout/stderr to private temporary files, waits, closes the
  writers, then reads the result. Executable and arguments remain separate.
- An unborn repository needs a special unstage fallback (`git rm --cached`) when
  `git reset -- <path>` has no `HEAD`. The same service path is covered through an
  actual temporary repository's first commit.

## Why it matters

These boundaries preserve the product's memory/typing goals while still allowing
Rafu to edit and create the repository's first commit. They also keep Git output,
file paths, and document buffers out of shell interpolation and broad SwiftUI
invalidation.

## Evidence and verification

```bash
./script/format.sh --lint
swift test
./script/build_and_run.sh --verify
```

The focused tests cover tree bounds/order, UTF-8 atomic write/read, JSON theme
decoding, Markdown blocks, Mermaid flow/sequence parsing, and status/stage/commit
against a temporary unborn Git repository.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/`
- `Sources/RafuApp/Markdown/`
- `Sources/RafuApp/Services/`
- `Sources/RafuApp/Views/`
- `docs/plans/phases/pre-first-commit-vertical-slice.md`
- `docs/references/swiftui-appkit-boundary.md`
- `docs/references/concurrency.md`
