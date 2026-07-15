import Foundation

/// Extracts the identifier under (or immediately behind) a caret position,
/// double-click-selection style. Pure and nonisolated: operates purely on
/// `NSString` (UTF-16) so `position` matches `NSRange`/`NavigationRequest`
/// addressing exactly — never `String` character indices, which would
/// misalign on emoji or combining marks.
nonisolated enum IdentifierUnderCaret {
    /// Word characters for identifier purposes: Unicode letters, digits, and
    /// underscore. Matches the whole-word boundary class already used by
    /// `TextSearchPattern`'s `.wholeWord` option.
    private static let wordCharacters = CharacterSet(charactersIn: "_")
        .union(.alphanumerics)

    /// Returns the identifier touching `position` and its UTF-16 start
    /// offset, or `nil` when no identifier is adjacent. `position` is
    /// clamped into `0...text.utf16.count` first, so an out-of-range caret
    /// (e.g. a stale selection after an external edit) never crashes.
    ///
    /// Boundary rule: if the character AT `position` is a word character,
    /// the token expands left and right from there. Otherwise, if
    /// `position` sits just after a word character (the common "caret right
    /// after the last letter" case), the token expands from `position - 1`.
    /// Any other position (whitespace, punctuation, start of file with no
    /// adjacent word character) returns `nil`.
    static func word(in text: String, at position: Int) -> (word: String, position: Int)? {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return nil }
        let clamped = min(max(position, 0), length)

        let anchor: Int
        if clamped < length, isWordCharacter(nsText, at: clamped) {
            anchor = clamped
        } else if clamped > 0, isWordCharacter(nsText, at: clamped - 1) {
            anchor = clamped - 1
        } else {
            return nil
        }

        var start = anchor
        while start > 0, isWordCharacter(nsText, at: start - 1) {
            start -= 1
        }
        var end = anchor + 1
        while end < length, isWordCharacter(nsText, at: end) {
            end += 1
        }

        let word = nsText.substring(with: NSRange(location: start, length: end - start))
        return (word: word, position: start)
    }

    private static func isWordCharacter(_ text: NSString, at index: Int) -> Bool {
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return wordCharacters.contains(scalar)
    }
}
