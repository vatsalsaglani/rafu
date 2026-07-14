import Foundation

/// One buffer mutation, in the shape a tree-sitter incremental parser
/// (`SyntaxParsingActor`, lane 2 increment 8) needs to build an `InputEdit`:
/// the pre-edit UTF-16 range that changed, and the length of the text that
/// replaced it.
///
/// Mapping from `NSTextStorageDelegate`'s post-edit
/// `textStorage(_:didProcessEditing:range:changeInLength:)` callback: given
/// its `editedRange` (post-edit) and `changeInLength` (`delta`),
///
///     range = NSRange(location: editedRange.location, length: editedRange.length - delta)
///     replacementLength = editedRange.length
///
/// `range` is the pre-edit range that was replaced; `replacementLength` is
/// the length, in UTF-16 units, of the text that now occupies it.
nonisolated struct DocumentEditDelta: Sendable, Equatable {
    /// The pre-edit UTF-16 range that was replaced.
    let range: NSRange
    /// The length, in UTF-16 units, of the text that replaced `range`.
    let replacementLength: Int
    /// Monotonic per-document edit counter, bumped on every recorded delta.
    /// Independent of `EditorDocument.revision`, which only increments on
    /// save and external reload, never per keystroke.
    let version: Int
}
