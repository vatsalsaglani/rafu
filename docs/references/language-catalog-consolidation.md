# Language identification catalog consolidation

- **Applies to:** language identification by file extension/name/fence info-string, grammar mapping, LSP language ID resolution
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

### Single canonical language mapping table

Four parallel language mappings previously drifted across the codebase: `LanguageIdentifier.forURL` (LSP ids), `GrammarLanguageID.languageID(forExtension:fileName:)`, `GrammarLanguageID.languageID(forInfoString:)`, and `SyntaxHighlighter`'s regex extension groups. This drift has caused bugs (e.g., `.tsx` → "tsx" vs "typescriptreact").

`LanguageCatalog` (Sources/RafuApp/Editor/Syntax/LanguageCatalog.swift) is now the single canonical, pure, nonisolated source of truth:
- **byExtension**: `[String: Mapping(grammarID?: GrammarLanguageID, lspID?: String)]` keyed by lowercase extension
- **byInfoString**: `[String: GrammarLanguageID]` for Markdown fence info strings (e.g., "swift", "python")
- **mapping(forFileName:)**: special-case handling (e.g., "dockerfile" → "Dockerfile" grammar ID)

All entry points (`LanguageIdentifier.forURL`, both `GrammarLanguageID.languageID(...)` functions, and markdown fence highlighting) are now thin, byte-identical wrappers delegating to this single table. No call site or pinned test was changed; all wrappers remain at the same signatures.

### Cross-axis asymmetries preserved

The info-string and extension namespaces are **separate and asymmetric**:
- Some languages appear only in info-strings (e.g., python, shell)
- Some appear only in extensions (e.g., .pyw, .md)
- Some in both with different grammar IDs (e.g., tsx → (.tsx, "typescriptreact"), jsx → (.javascript, "javascriptreact"))

These asymmetries are intentional reflections of how Markdown fence conventions, file extensions, and grammar availability interact. No "fixes" or consolidation was applied to the table itself — it is an exact recording of the existing codebase's behavior.

### SyntaxHighlighter regex language detection intentionally excluded

`SyntaxHighlighter`'s regex fallback path has a separate language-group mapping covering non-grammar languages (rust, go, ruby, java, C-family) and non-grammar concepts (html, css, ini, makefile). This was deliberately NOT folded into `LanguageCatalog` because:
1. Regex language groups cover a different set of languages/concepts than the grammar/LSP mapping
2. Changes to the consolidated table could silently alter regex highlighting output, which is pinned by `EditorSyntaxHighlighterTests`

The separation preserves isolation and prevents accidental regressions.

## Why it matters

Drift across four parallel mappings makes it easy to introduce inconsistencies (users see different highlighting vs LSP behavior for the same file). A single canonical table, verified cross-consistency, and thin stable wrappers ensure that every code path agrees on language identity.

The byte-identical behavior after consolidation (verified test-first) means no breaking changes to any caller or existing test.

## Reproduction or evidence

**Cross-consistency test (LanguageCatalogTests), verified before and after consolidation:**
- For every known extension/info-string/filename combination in the current code, the new wrapper output equals the old output exactly (byte-identical)
- Test written against GOLDEN LITERALS representing current behavior
- Test passed against CURRENT code before refactor
- Test passed after refactor (byte identity preserved)

**Test coverage:**
```bash
swift test -filter LanguageCatalogTests
# All cases passing; zero behavior change
```

## Verification

```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

All 485 tests passing; no warnings. Every language identification path compiles and matches prior behavior exactly.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/Syntax/LanguageCatalog.swift` (new, canonical table)
- `Sources/RafuApp/Editor/Syntax/LanguageIdentifier.swift` (wrapper delegation)
- `Sources/RafuApp/Editor/Syntax/GrammarLanguageID.swift` (wrapper delegation)
- `Sources/RafuApp/Editor/Syntax/SyntaxHighlighter.swift` (regex path, intentionally separate)
- `Tests/RafuAppTests/LanguageCatalogTests.swift` (cross-consistency verification)
- `docs/plans/phases/post-merge-validation-fixes.md` (Batch C, finding 6)
