import Foundation

/// Maps a file URL's extension to the LSP `languageId` Rafu sends in
/// `textDocument/didOpen` (see the LSP specification's `TextDocumentItem`).
/// An unrecognized extension declines (`nil`) rather than guessing — the
/// coordinator never starts or replays a language server for a document it
/// can't confidently identify.
nonisolated enum LanguageIdentifier {
    static func forURL(_ url: URL) -> String? {
        LanguageCatalog.byExtension[url.pathExtension.lowercased()]?.lspID
    }
}
