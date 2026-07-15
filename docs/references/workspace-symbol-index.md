# Workspace symbol index and syntactic navigation

- **Applies to:** `WorkspaceSymbolIndex`, `WorkspaceSymbolExtractor`, `SyntacticNavigationProvider`, the command palette `#` workspace-symbol mode, `WorkspaceSession` index ownership and rebuild, and the `NavigationLadder` with LSP insertion point
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

### Index design and capacity

`WorkspaceSymbolIndex` is an actor mirroring `WorkspaceFileNameIndex`: it accepts a `git ls-files` feed or falls back to a cancellable `FileManager` enumeration, parses only files whose grammar has a vendored `tags.scm` (currently: swift, python, javascript, typescript, tsx), skips all other files via a cheap extension check, and builds a flat symbol array using `WorkspaceSymbolExtractor` (pure, nonisolated).

Key capacity rules:
- **Per-file skip:** 512 KB (if a file exceeds this before reading, skip it without parsing).
- **Per-file symbol cap:** 2,000 symbols per file (enforced during extraction, excess discarded).
- **Global cap:** 500,000 symbols with truncation disclosure (`isTruncated` flag).
- **Preview laziness:** `previewLine` (the matched line's text) is computed **only at candidate-build time** when the user selects a symbol, not stored for all symbols (would consume ~30–40 MB at the 500k cap).

### Grammar-covered parsing and deduplication

`WorkspaceSymbolExtractor` reuses `SyntaxHighlighter`'s `scanUsingGrammar` mechanics (Parser + cursor.resolve honoring tree-sitter predicates like `#not-eq?`) but keeps **all** `@definition.*` capture kinds (function, method, class, interface, property, constant, module) and deduplicates by (name, range). This fixes both the pre-increment-10 duplicate-Swift-method artifact **and** the property/constant outline gap in `BufferSymbols` — though `BufferSymbols` itself was not edited (its @-symbol mode still has the gap; the workspace index is separate).

Non-grammar files are skipped by a cheap extension check, making the index affordable on large monorepos: in testing, 20,000 non-grammar `.txt` files cost almost nothing; only the ~8,000 `.swift` files dominated the build.

### No name index; bounded per-keystroke query

The index does **not** maintain a secondary name index. Instead, the `SyntacticNavigationProvider` performs a bounded scan of all symbols, and the command palette's `#` mode query does a full scan per keystroke, freed immediately after ranking (matching the behavior of file-name ranking via `rankFiles`). A new `WorkspaceSymbolRanker` (separate from `CommandPaletteMatcher.rank` / `score` / `rankFiles`) scores symbol names and is cancellable every 4,096 candidates.

### Incremental updates and memory shedding

- **Full rebuild:** triggered by `refreshWorkspace()` (workspace open, root re-list after FSEvents). 
- **Incremental rebuild:** `applyChanges` re-lists changed directories from `WorkspaceChangeSet.changedDirectoryRelativePaths`, re-parses changed files, and removes symbols for deleted files. 
- **Storm ⇒ full rebuild:** FSEvents storm (>1,000 surviving paths or >200 changed directories) signals a full rebuild via the existing circuit breaker.
- **Cancellation:** query is cancellable; a cancelled build leaves the prior state intact.
- **Memory pressure shedding:** `respondToMemoryPressure` snapshot-sheds the symbol index alongside the filename index on memory-pressure warn/critical.

Non-Sendable tree-sitter types (Parser, Tree, QueryCursor) never cross an await — all tree work is synchronous within one actor-confined step; no `@unchecked Sendable`.

### Incremental apply: /var vs /private/var symlink nuance (durable)

**Known bug fix:** `FileManager.enumerator(at:)` and `FileManager.contentsOfDirectory(at:)` disagree on whether `/var` symlinks are resolved. `FileManager.enumerator` can return children with the symlink resolved (`/private/var/...`) even when the **starting** URL was not resolved, while `contentsOfDirectory` does not do this. Computing a relative path by dropping the root URL's `path.count` prefix from an enumerated child's `path` silently produces garbage (truncated fragment, no crash) if only one side is resolved.

**Fix:** Resolve **both** the root and every enumerated child via `.resolvingSymlinksInPath().standardizedFileURL` before computing the relative path. This pattern applies to any new `FileManager.enumerator`-based code. Build-time and `applyChanges` both use this pattern; `WorkspaceSearchService.scan` already matched it before increment 10.

### SyntacticNavigationProvider tier behavior

`SyntacticNavigationProvider` implements `NavigationTierProvider` over the symbol index and:
- **.definition** / **.declaration** requests: exact-name lookup; candidates ranked same-file first, then same-directory (proximity), then lexicographic. An index that exists and returns no match is an authoritative empty answer (`NavigationAnswer(tier: .syntactic, candidates: [])`, not a decline).
- **.references** / **.hover** requests: returns `nil` (decline), falling through to the text-search navigation tier. The index deliberately stores no `@reference.*` captures (to stay bounded); precise reference and hover are lane 2's LSP responsibility.
- **.building** state: returns `NavigationAnswer(state: .indexing)` while the index rebuild is in flight.

### NavigationLadder and LSP insertion point

`WorkspaceSession` owns the index (alongside the filename index) and registers `SyntacticNavigationProvider` into a `NavigationLadder` with documented insertion points. The ladder's default ladder is `[SyntacticNavigationProvider, TextSearchNavigationProvider]`; lane 2's LSP provider will insert at index 0 (above syntactic, below LSP) when language servers are active, ensuring LSP answers shadow syntactic ones.

### Command palette # workspace-symbol mode

The palette's `#` prefix opens workspace-symbol mode (additive: `>` for commands, `@` for buffer symbols, `#` for workspace symbols, default file mode). Queries are keyed by **both** the search term and `symbolIndexGeneration` (a generation counter bumped on every index rebuild), ensuring a completed build during an open palette updates the results — omitting the generation from the task key is the exact failure mode that leaves the palette showing stale results forever. Direct jump on selection; the UI displays a header ("Workspace Symbols"), an empty-state message when no match, and a truncation caption at the 500k cap.

### Concurrency pattern: per-language parser reuse across actor-confined steps

Tree-sitter's `Parser.setLanguage()` is expensive (sets up the C→Swift bridge and state machines per language). The index calls `setLanguage` **once per grammar** at build time, then reuses the same `Parser` instance across **all files in that language** within the same actor-confined step. This amortizes the per-language setup cost across many files in a single build, with no cross-await exposure (the Parser never leaves the actor-confined step). After the step completes, the parser is released; the next build starts fresh.

## Why it matters

The 150 MB memory budget for local workspaces must accommodate parsing declarations from thousands of files without exhausting RAM. Three mechanisms keep the index affordable on 100k-file monorepos:

1. **Grammar-only filtering:** a cheap extension check skips files with no vendored tags.scm, avoiding parse attempts on ungrammar files (which dominate by count in monorepos).
2. **Per-language parser reuse:** one `setLanguage` per grammar amortizes the expensive C→Swift setup.
3. **Capacity and lazy preview:** 500k global cap, 2k per-file cap, and deferred preview-line loading prevent memory explosion at scale.

The `/var` ↔ `/private/var` symlink nuance matters because macOS temporary directories expose both paths; tests on temp-rooted workspaces must assert relative-path correctness, not just filename, or this class of bug remains invisible.

Staying below 150 MB idle memory allows the app to coexist with a long-running editor or terminal on typical development systems; the per-keystroke `#` query and no secondary name index keep the index lightweight and responsive.

## Reproduction or evidence

**Synthetic 28,000-file Git repository gate (debug build, 2026-07-15):**
- Repository shape: 8,000 `.swift` files with ~40,000 total declarations; 20,000 `.txt` filler files (non-grammar).
- Opened in staged `dist/Rafu.app`.
- RSS sampled via `ps -o rss= -p <pid>`.

| Point | RSS |
|---|---|
| Symbol-index build peak (all parsing and extraction) | ~137 MB |
| Settled after build completion | ~129 MB |
| Budget ceiling (150 MB) | Exceeded? **No** |

The 20,000 non-grammar `.txt` files were skipped by the extension check and cost almost nothing. Non-debug (Release) builds would be leaner. The 500k global symbol cap and memory-pressure shedding are the backstops for even larger repos.

## Verification

```bash
swift build
swift test
# Tests must include:
# - WorkspaceSymbolIndexTests (build, caps, incremental, generation, query cancellation)
# - SyntacticNavigationProviderTests (definition ranking, references decline, .building state, empty answer)
# - SearchCommandPaletteTests (# mode, keystroke cancellation, empty state, truncation caption)
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

All 255 tests passing; no warnings; app launches and the palette's `#` mode filters and selects workspace symbols correctly.

## Navigation UI flow (increment 10b)

### Selection seam: cursor position capture

`EditorDocument.selectionProvider: (() -> NSRange)?` is a closure seam (analogous to `textSnapshotProvider`) that captures the live cursor position from the mounted `RafuTextView`. It is set in `CodeEditorView.makeNSView` and cleared in `dismantleNSView`, ensuring the navigation ladder always has access to the current caret position when the editor is active.

### Identifier extraction

`IdentifierUnderCaret` is a pure nonisolated type that extracts the word at a given UTF-16 position using `NSString`/double-click semantics (never using `String` indices). The extraction matches `NavigationRequest.position` exactly on emoji and combining-mark text. Boundary rules:
- Caret inside a word expands the entire word.
- Caret just after a word (double-click behavior) expands the token behind the caret.
- Caret in whitespace or at the start of an empty selection with no adjacent word character returns `nil`.
- Out-of-range positions are clamped.

This pure logic is testable (10 tests) and reusable for any cursor-based feature that needs to capture a token.

### Navigation outcome decision layer

`NavigationPresentation` is a pure nonisolated decision layer that maps a resolved `NavigationAnswer?` to a UI action:
- `nil` or 0 candidates → `.empty(kind)` (brief empty-state message).
- `.indexing` state → `.indexing` (brief indexing message).
- Exactly 1 candidate → `.jump` (navigate directly).
- 2+ candidates → `.results(answer)` (show a peek sheet).

This decision is testable (6 tests) and independent of which tier answered the request, allowing lane-2 LSP answers to flow through the same UI unchanged.

### WorkspaceSession.navigate(kind:) orchestration

`WorkspaceSession.navigate(kind:)` orchestrates the full ladder walk:
1. Builds a `NavigationRequest` from the selected document's live caret (`selectionProvider`) and the word at caret (`IdentifierUnderCaret`).
2. Ensures the symbol index is warm (triggers build if needed).
3. Resolves the request against `navigationLadder` in a cancellable `Task` (a second call cancels the prior task).
4. Applies the `NavigationPresentation` outcome: `.jump` reuses `openWorkspaceSymbol`; `.results` sets `isNavigationPeekPresented` for sheet display.

The method is a no-op if the active editor is not mounted (hibernated or preview-only) or no workspace is open. It resets peek state in `resetFileTreeState()` and cancels the navigation task in the isolated `deinit`.

### Navigation peek view

`NavigationPeekView` is a candidate list sheet mirroring `CommandPaletteView`'s keyboard navigation pattern (`@State selectedIndex`, arrow keys, return, `ScrollViewReader`). It shows `NavigationAnswer.tier.label` for provenance (LSP/syntactic/text) but never branches on the `NavigationTier` case, ensuring lane-2 LSP answers render through the same row layout unchanged. VoiceOver labels are applied per row (name/kind/path) and on the header (title + tier). The `.indexing` and `.empty(kind)` outcomes show a brief message with a Close button.

### Menu commands and keyboard shortcuts

`RafuAppCommands.swift` defines three commands in `CommandMenu("Rafu")`:
- **Go to Definition** (⌃⌘J) — primary keyboard shortcut.
- **Go to Declaration** (menu-only, no keyboard shortcut).
- **Find References** (⌃⌘R).

Each command has its `NavigationCommandID` accessibility identifier and is disabled when no document is selected (`workspaceSession?.selectedDocument == nil`).

### Command-click (deferred)

⌘-click navigation is recorded for later implementation (beyond 10b). The AGENTS.md rule that "every core action needs a visible UI path and a menu/keyboard path" is satisfied by the ⌃⌘J shortcut and menu entry, so ⌘-click is additive convenience. The planned approach (for later pickup):
- `RafuTextView.mouseDown(with:)` checks `event.modifierFlags.contains(.command)`.
- On a command-click, resolve the clicked character index via the existing `characterIndexForInsertion(for:)` helper.
- Invoke `WorkspaceSession.navigate(kind: .definition)` at that position instead of the live selection.
- Requires a pointing-hand cursor affordance over an identifier while ⌘ is held.
- Plain command-click-to-place-cursor (the default AppKit behavior when the click lands outside an identifier) must still work.

## Related code, ADRs, and phases

- `Sources/RafuApp/Services/WorkspaceSymbolIndex.swift`
- `Sources/RafuApp/Services/WorkspaceSymbolExtractor.swift`
- `Sources/RafuApp/Navigation/SyntacticNavigationProvider.swift`
- `Sources/RafuApp/Navigation/NavigationLadder.swift`
- `Sources/RafuApp/Navigation/NavigationTypes.swift`
- `Sources/RafuApp/Editor/IdentifierUnderCaret.swift`
- `Sources/RafuApp/Navigation/NavigationPresentation.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Views/NavigationPeekView.swift`
- `Sources/RafuApp/Views/CommandPaletteView.swift`
- `Sources/RafuApp/Commands/RafuAppCommands.swift`
- `Tests/RafuAppTests/WorkspaceSymbolIndexTests.swift`
- `Tests/RafuAppTests/SyntacticNavigationProviderTests.swift`
- `Tests/RafuAppTests/IdentifierUnderCaretTests.swift`
- `Tests/RafuAppTests/NavigationPresentationTests.swift`
- `docs/references/memory-and-file-indexing.md`
- `docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increments 10a–10b)
