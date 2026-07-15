import Foundation

/// A resolved highlight span emitted by `SyntaxParsingActor`: a `RafuTheme`
/// syntax key and the UTF-16 range it applies to.
///
/// This is a first-party `Sendable` value type deliberately used instead of
/// `Neon.Token` at the actor boundary. `Neon.Token` is a public struct from
/// another module without a `Sendable` conformance, so returning `[Token]`
/// across the actor hop would require `@unchecked Sendable` (forbidden here).
/// The pipeline maps `SyntaxSpan` → `Neon.Token` on the main actor.
nonisolated struct SyntaxSpan: Sendable, Equatable {
    /// A `RafuTheme.syntax` key (e.g. `keyword`, `string`, `comment`) that
    /// `SyntaxHighlighter.attributes(for:)` can resolve, or the empty string
    /// mapping is dropped before a span is created.
    let themeKey: String
    /// The UTF-16 range the span covers, ready to hand to `Neon.Token`.
    let range: NSRange
}
