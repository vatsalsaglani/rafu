import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterDockerfile
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Stable identifiers for the tree-sitter grammars packaged in
/// `Package.swift` (ADR 0005 §7.4, lane-1 increment 7). `markdownInline` is
/// an injection-only secondary grammar used inside Markdown inline spans and
/// is never returned by `languageID(forExtension:fileName:)` directly — a
/// future Markdown-preview injection path (plan §7.7) requests it by case
/// name.
///
/// This increment only packages the grammars and exposes the lookup below;
/// `SyntaxHighlighter` keeps routing every language through its regex rules
/// until increment 8 wires `GrammarRegistry` into an incremental parsing
/// path.
nonisolated enum GrammarLanguageID: String, Sendable, CaseIterable {
    case swift
    case python
    case javascript
    case typescript
    case tsx
    case json
    case yaml
    case toml
    case bash
    case markdown
    case markdownInline
    case dockerfile

    /// Single source of truth for extension/filename → grammar mapping,
    /// mirroring `SyntaxHighlighter`'s regex-rule extension groups
    /// (`Sources/RafuApp/Editor/SyntaxHighlighter.swift`). Returns `nil` for
    /// extensions without a packaged grammar; the regex highlighter remains
    /// the fallback there (dotenv has no maintained SPM grammar — see
    /// `docs/references/editor-dependencies.md`).
    static func languageID(forExtension fileExtension: String, fileName: String)
        -> GrammarLanguageID?
    {
        let normalizedName = fileName.lowercased()
        if normalizedName == "dockerfile" || normalizedName.hasPrefix("dockerfile.") {
            return .dockerfile
        }
        switch fileExtension.lowercased() {
        case "swift":
            return .swift
        case "py", "pyw":
            return .python
        case "js", "jsx", "mjs", "cjs":
            return .javascript
        case "ts":
            return .typescript
        case "tsx":
            return .tsx
        case "json", "jsonc":
            return .json
        case "yaml", "yml":
            return .yaml
        case "toml":
            return .toml
        case "sh", "bash", "zsh":
            return .bash
        case "md", "markdown":
            return .markdown
        default:
            return nil
        }
    }

    /// Maps a Markdown fenced-code-block info string (the text after the
    /// opening ` ``` `) to a packaged grammar for increment 9's fence
    /// highlighter (plan §7.7). Distinct from `languageID(forExtension:
    /// fileName:)`: info strings use language names/common aliases, not file
    /// extensions, and only grammars with a vendored `highlights.scm` that
    /// makes sense standalone in a fence are listed. Returns `nil` for an
    /// unknown or unmapped info string; the fence then renders as plain,
    /// theme-styled text.
    static func languageID(forInfoString infoString: String) -> GrammarLanguageID? {
        switch infoString.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift":
            return .swift
        case "python", "py":
            return .python
        case "javascript", "js", "jsx":
            return .javascript
        case "typescript", "ts":
            return .typescript
        case "tsx":
            return .tsx
        case "json":
            return .json
        case "yaml", "yml":
            return .yaml
        case "toml":
            return .toml
        case "bash", "sh", "shell":
            return .bash
        default:
            return nil
        }
    }
}

/// Lazily loads and caches tree-sitter `LanguageConfiguration`s (parser
/// `Language` + vendored `highlights.scm` query) for the grammars declared in
/// `Package.swift`. Declared as an actor because `RafuApp` defaults to
/// `@MainActor` isolation and grammar/query construction (resource lookup,
/// query compilation, `highlights.scm` file read) belongs off the main
/// actor; `Language`, `LanguageConfiguration`, and `Query` are all
/// `Sendable`, so a cached configuration crosses back to callers (the
/// syntax-parsing actor, increment 9's capture mapping) without copying live
/// buffer state.
///
/// No grammar is loaded eagerly. Each `GrammarLanguageID` is built once, on
/// its first request, and cached for the registry's lifetime.
///
/// Query loading (lane-1 increment 8a): SwiftTreeSitter's
/// `LanguageConfiguration(_:name:)` bundle resolver looks in
/// `Bundle.main/<Name>.bundle/Contents/Resources/queries`, which never exists
/// for SPM's flat resource bundles — so it returned empty queries under
/// `swift test`, `swift run`, and the staged `.app`. Instead we vendor each
/// grammar's `highlights.scm` into `Resources/Grammars/<Name>/` (see that
/// directory's `README.md`) and load the bytes directly with
/// `Query(language:url:)` via `Bundle.module`, which resolves in all three
/// hosts.
actor GrammarRegistry {
    /// Shared syntax-subsystem registry. One instance backs every open buffer
    /// so each grammar's `Language`/`Query` is built once and cached, never
    /// rebuilt per keystroke or per editor.
    static let shared = GrammarRegistry()

    private var cache: [GrammarLanguageID: LanguageConfiguration] = [:]
    /// Compiled `tags.scm` query cache for increment 9's grammar-backed `@`
    /// symbol extraction (`BufferSymbols.scanUsingGrammar`). Stored as
    /// `Query?` so a grammar with no vendored `tags.scm` (json/yaml/toml/
    /// bash/markdown/dockerfile — no meaningful symbols) or a compile
    /// failure caches its `nil` result too, instead of retrying every call.
    private var tagsCache: [GrammarLanguageID: Query?] = [:]

    /// Returns the cached configuration for `id`, building it on first
    /// request. `config.language` is always a valid, ABI-checked parser
    /// language. `config.queries[.highlights]` is populated when the grammar's
    /// vendored `highlights.scm` both resolves via `Bundle.module` and
    /// compiles against the language; on any missing-resource or compile
    /// failure the configuration is still returned with an EMPTY queries
    /// dictionary so the router degrades to the regex highlighter rather than
    /// crashing or blanking the editor.
    func configuration(for id: GrammarLanguageID) async throws -> LanguageConfiguration {
        if let cached = cache[id] {
            return cached
        }

        let language = id.language
        let name = id.configurationName

        // `Bundle.module` is `@MainActor`-isolated (RafuApp defaults to
        // MainActor isolation), so the trivial, cached URL lookup hops to the
        // main actor; the heavy work (reading and compiling the query) stays
        // on this actor, off the main actor.
        let url = await GrammarQueryResources.highlightsURL(forName: name)

        let configuration: LanguageConfiguration
        if let url, let query = try? Query(language: language, url: url) {
            configuration = LanguageConfiguration(
                language, name: name, queries: [.highlights: query])
        } else {
            // Missing resource (e.g. `markdownInline` in 8a) or a query
            // read/compile failure → keep the valid, ABI-checked language with
            // an EMPTY queries dictionary so the router degrades to the regex
            // highlighter instead of crashing or blanking the editor.
            configuration = LanguageConfiguration(language, name: name, queries: [:])
        }

        cache[id] = configuration
        return configuration
    }

    /// Returns the cached `tags.scm` query for `id`, building it on first
    /// request. `nil` when the grammar has no vendored `tags.scm`, its
    /// language failed to build, or the query fails to resolve/compile —
    /// callers (`BufferSymbols.scanUsingGrammar`) fall back to the regex
    /// `BufferSymbolScanner` in every one of those cases, never crash or
    /// leave the palette's `@` mode empty without explanation.
    func tagsQuery(for id: GrammarLanguageID) async -> Query? {
        if let cached = tagsCache[id] {
            return cached
        }
        guard let configuration = try? await configuration(for: id) else {
            tagsCache[id] = nil
            return nil
        }

        // Same main-actor `Bundle.module` gateway pattern as `highlightsURL`
        // above; see that property's doc for why the lookup hops to main.
        let url = await GrammarQueryResources.tagsURL(forName: id.configurationName)
        let query = url.flatMap { try? Query(language: configuration.language, url: $0) }
        tagsCache[id] = query
        return query
    }
}

/// Main-actor gateway to the vendored grammar query bundle. `Bundle.module`
/// is main-actor isolated in this target, so the URL lookup lives here and the
/// off-main `GrammarRegistry` actor `await`s it.
@MainActor
private enum GrammarQueryResources {
    static func highlightsURL(forName name: String) -> URL? {
        Bundle.module.url(
            forResource: "highlights", withExtension: "scm",
            subdirectory: "Grammars/\(name)")
    }

    /// `tags.scm` counterpart to `highlightsURL(forName:)`, `nil` when the
    /// grammar has none vendored (increment 9: Swift/Python/JavaScript/
    /// TypeScript/TSX only).
    static func tagsURL(forName name: String) -> URL? {
        Bundle.module.url(
            forResource: "tags", withExtension: "scm",
            subdirectory: "Grammars/\(name)")
    }
}

nonisolated extension GrammarLanguageID {
    /// The wrapped tree-sitter parser `Language` for this grammar. Not
    /// `fileprivate`: increment 9's `TreeSitterCodeSyntaxHighlighter`
    /// (`Sources/RafuApp/Markdown/MarkdownCodeSyntaxHighlighter.swift`) needs
    /// it for its own main-actor fence-highlighting query cache — Markdown
    /// fences render synchronously from a SwiftUI view body, so that cache
    /// cannot route through this actor.
    var language: Language {
        switch self {
        case .swift: return Language(language: tree_sitter_swift())
        case .python: return Language(language: tree_sitter_python())
        case .javascript: return Language(language: tree_sitter_javascript())
        case .typescript: return Language(language: tree_sitter_typescript())
        case .tsx: return Language(language: tree_sitter_tsx())
        case .json: return Language(language: tree_sitter_json())
        case .yaml: return Language(language: tree_sitter_yaml())
        case .toml: return Language(language: tree_sitter_toml())
        case .bash: return Language(language: tree_sitter_bash())
        case .markdown: return Language(language: tree_sitter_markdown())
        case .markdownInline: return Language(language: tree_sitter_markdown_inline())
        case .dockerfile: return Language(language: tree_sitter_dockerfile())
        }
    }

    /// Human-readable configuration name, also the vendored resource
    /// subdirectory under `Resources/Grammars/<name>/highlights.scm`. Not
    /// `fileprivate` for the same reason as `language` above.
    var configurationName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .tsx: return "TSX"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .bash: return "Bash"
        case .markdown: return "Markdown"
        case .markdownInline: return "MarkdownInline"
        case .dockerfile: return "Dockerfile"
        }
    }
}
