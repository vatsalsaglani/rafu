import Foundation

/// Maps a file URL's extension to the LSP `languageId` Rafu sends in
/// `textDocument/didOpen` (see the LSP specification's `TextDocumentItem`).
/// An unrecognized extension declines (`nil`) rather than guessing — the
/// coordinator never starts or replays a language server for a document it
/// can't confidently identify.
nonisolated enum LanguageIdentifier {
    static func forURL(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "rs": return "rust"
        case "go": return "go"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "c": return "c"
        case "h": return "c"
        case "cpp", "cc", "cxx": return "cpp"
        case "hpp": return "cpp"
        case "md", "markdown": return "markdown"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        default: return nil
        }
    }
}
