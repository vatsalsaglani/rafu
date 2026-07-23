import Foundation
import UniformTypeIdentifiers

/// Which kind of drag a set of pasteboard type identifiers represents, so
/// AppKit drop targets under the editor's text view can route a Finder file
/// drag correctly instead of pasting its path as text.
///
/// AppKit dispatches a drag session to the DEEPEST registered `NSView` under
/// the pointer. `RafuTextView` is that deepest view over the text area, and
/// (like every `NSTextView`) it registers `public.utf8-plain-text` and
/// friends by default for ordinary in-editor text drag. Finder usually
/// advertises BOTH `public.file-url` and a `public.utf8-plain-text` string
/// representation of the dropped path(s), so without classifying the drag
/// first, the string type would win and insert the raw path as pasted text
/// (see `docs/references/drag-and-drop-custom-uttype.md`, which documents
/// the deepest-registered-destination rule but stops short of this
/// Finder-drop implication).
///
/// Pure and independent of any live `NSPasteboard`/`NSDraggingInfo` so it can
/// be unit tested directly against a `Set<String>` of type identifiers.
nonisolated enum EditorDragKind: Equatable, Sendable {
    /// The private `.rafuEditorDrag` payload — a Files-navigator row or an
    /// editor tab being dragged within/between groups. Always takes
    /// precedence over a coincidentally-present file URL or string type, so
    /// an internal drag is never misclassified as an external Finder drop.
    case internalPayload
    /// One or more Finder file URLs, with no `.rafuEditorDrag` type present.
    case externalFiles
    /// Plain text/RTF only — ordinary in-editor text selection drag.
    case text

    private static let fileURLIdentifiers: Set<String> = [
        UTType.fileURL.identifier,
        "NSFilenamesPboardType",
    ]

    /// Classifies a drag from the raw pasteboard type identifiers it
    /// advertises. Precedence: `rafuEditorDrag` > file URL > text.
    static func classify(typeIdentifiers: Set<String>) -> EditorDragKind {
        if typeIdentifiers.contains(UTType.rafuEditorDrag.identifier) {
            return .internalPayload
        }
        if !typeIdentifiers.isDisjoint(with: fileURLIdentifiers) {
            return .externalFiles
        }
        return .text
    }
}
