# Large-file guard mode

- Applies to: editor document open, syntax highlighting suppression, symbol scanning
- Last verified: Swift 6.2, macOS 14+, Xcode 16, 2026-07-15

## Rule or observed behavior

When a document is opened, `DocumentGuardPolicy.decide(for:)` evaluates two thresholds:

- **Maximum unguarded file size**: 2 MB (2,097,152 bytes)
- **Maximum unguarded line length**: 10,000 UTF-16 code units

If either threshold is exceeded, the document enters guarded mode. In guarded mode:

- No syntax highlighting is applied (base text style only)
- The `@`-symbol scan (`CommandPaletteView.prepareSymbolsIfNeeded`) is skipped
- No per-keystroke tokenization work runs (`NeonSyntaxHighlightingPipeline.isSuppressed`)
- An in-editor banner prompts the user to enable highlighting (session-only override button)

The policy computation runs **once at document open** off the main actor (inside the existing cancellation-checked load Task), never recomputed per keystroke or paste event.

## Why it matters

Guarded mode prevents parsing workload from blocking the editor's main-actor typing path on large files. The 2 MB threshold is carefully chosen to guard the 2–4 MB band of files that are still openable (the `WorkspaceFileService.readText` hard-rejects files > 4 MB), ensuring guard mode actually engages for files that would otherwise incur syntax overhead without violating the hard-close cap. The 10,000 UTF-16 limit catches minified or procedurally generated single-line files that would otherwise tokenize wastefully.

## Reproduction or evidence

- `Sources/RafuApp/Editor/DocumentGuardPolicy.swift` — pure `nonisolated` type with `decide(for:)` async concurrent function
- Single chokepoint for suppression: `NeonSyntaxHighlightingPipeline.isSuppressed` (bool flag; when true, base style is applied then tokenization is skipped in both initial `invalidate(.all)` and per-edit `didProcessEditing`)
- `CodeEditorView.Coordinator.syncGuardSuppression(forceRepaint:)` — must force a repaint on load (bare on-change-only sync would skip the always-needed load-time highlight when the guard flag equals its default, silently breaking highlighting-on-open for normal files); `updateNSView` calls it without forcing so a banner override is picked up on the next update pass
- Banner with one-click "Enable Highlighting" override in `EditorCanvasView` area; override is session-only and does not persist to disk

## Verification

Tested via `DocumentGuardPolicyTests` (10 tests, all passing):
- Thresholds correctly classify small, medium, large, and edge-case files
- One-line minified case (single 10,001-character line) correctly triggers guard
- Classic Mac line-ending case (lone `\r` scanned as one line) conservatively guards
- Guard state computed once at open, not recomputed on keystroke

App-level verification: `./script/build_and_run.sh --verify` confirmed UI banner displays and override button functions; highlighting toggles correctly on small files and remains suppressed on guarded files.

## Related code, ADRs, and phases

- **Code**: `Sources/RafuApp/Editor/DocumentGuardPolicy.swift`, `Sources/RafuApp/Editor/CodeEditorView.swift` (Coordinator), `Sources/RafuApp/Views/CommandPaletteView.swift` (prepareSymbolsIfNeeded gate), `Sources/RafuApp/Views/EditorCanvasView.swift` (banner host)
- **Deviation**: The lane-1 phase plan proposed an 8 MB threshold, but `WorkspaceFileService.readText` already hard-rejects files > 4 MB (`maximumEditorBytes`), so an 8 MB guard would be dead code. Threshold finalized at 2 MB to engage in the openable band.
- **Known limitations**:
  1. Pasting a huge line into an already-open normal document does not retroactively guard it; guard mode engages at open only with an explicit session-only override.
  2. Files with lone-`\r` (classic Mac) line endings scan as one line, conservatively triggering the line-length guard.
  3. Markdown opened directly in preview-only mode has no `CodeEditorView`, so guard state stays `.normal` and no banner is shown.
- **Symbol index reuse**: Increment 10 (`WorkspaceSymbolIndex`) reads the same `document.suppressesSyntax` flag to skip guarded files from the index.
- **Deferred**: A dedicated menu/command-palette "Enable Highlighting for this file" override command; the banner Button is the sufficient keyboard-reachable path this increment (accessible via Full Keyboard Access, not hidden behind a gesture).
- **Lane**: Lane 1, Increment 2 — memory resilience + Tree-sitter Stages A/B
