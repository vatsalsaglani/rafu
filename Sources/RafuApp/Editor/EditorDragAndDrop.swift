import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type shared by editor tab drags (tab bar → group) and
    /// sidebar file drags (Files navigator → editor). Both must go through
    /// this one type so `RafuTextView` refuses them and `EditorDropDelegate`
    /// can dispatch on the decoded payload.
    ///
    /// `conformingTo: .data` is set explicitly on the initializer AND the
    /// identifier is declared in the app's Info.plist
    /// (`UTExportedTypeDeclarations`, see `script/build_and_run.sh`). Without
    /// the Info.plist declaration `conforms(to: .data)` is false for a type
    /// created only with `UTType(exportedAs:)`, which silently breaks the
    /// SwiftUI → AppKit drag pasteboard bridge. See
    /// `docs/references/drag-and-drop-custom-uttype.md`.
    nonisolated static let rafuEditorDrag = UTType(
        exportedAs: "dev.vatsalsaglani.rafu.editor-drag", conformingTo: .data)
}

/// A drag payload originating from either an editor tab or a sidebar file
/// row. One private UTI and one drop delegate handle both so a dragged tab
/// and a dragged file get the same live split/center preview.
nonisolated enum EditorDragPayload: Codable, Equatable, Sendable {
    case tab(id: String)
    case file(path: String)

    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(EditorDragPayload.self, from: data)
    }

    /// Builds an `NSItemProvider` with the payload pre-encoded into `Data`.
    /// The load handler captures only that immutable `Data`, never `self`'s
    /// call site or the session, so it stays safe to invoke off the main
    /// actor when the system loads the representation for a cross-window or
    /// cross-process drop.
    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? encodedData() else { return provider }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.rafuEditorDrag.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Pure geometry helper for the tab/file drop preview: which split edge (if
/// any) the pointer is nearest to inside a group's bounds. `nil` means the
/// pointer is in the central region, where a drop opens/moves the item in
/// place instead of splitting.
nonisolated enum EditorDropGeometry {
    /// Edge band width per side, capped so very large groups don't dedicate
    /// an oversized strip to split detection.
    private static let maxEdgeBand: CGFloat = 100

    static func target(at location: CGPoint, in size: CGSize) -> EditorSplitEdge? {
        let bandWidth = min(size.width / 4, maxEdgeBand)
        let bandHeight = min(size.height / 4, maxEdgeBand)
        let candidates: [(edge: EditorSplitEdge, distance: CGFloat, band: CGFloat)] = [
            (.leading, location.x, bandWidth),
            (.trailing, size.width - location.x, bandWidth),
            (.top, location.y, bandHeight),
            (.bottom, size.height - location.y, bandHeight),
        ]
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        return nearest.distance < nearest.band ? nearest.edge : nil
    }
}

/// Pure geometry helper for reordering within a tab strip: given a horizontal
/// drop location and the ordered frames of the strip's current tabs (in tab
/// order), which array index the dragged tab should land at. This is a
/// classic "insert before the first tab whose midpoint is at or past the
/// pointer" computation — the count of frames whose midpoint is strictly left
/// of `x` is exactly that index, and it degrades gracefully to `0` for an
/// empty or not-yet-laid-out strip.
nonisolated enum TabStripDrop {
    static func insertionIndex(forX x: CGFloat, tabFrames: [CGRect]) -> Int {
        guard !tabFrames.isEmpty else { return 0 }
        let index = tabFrames.filter { $0.midX < x }.count
        return min(max(index, 0), tabFrames.count)
    }
}

/// Handlers an editor group injects into its AppKit scroll view so drags over
/// the text area drive the same overlay and split logic as drags over the
/// group's SwiftUI chrome. Locations are top-left-origin points in the scroll
/// view's bounds.
@MainActor
struct EditorDropForwarding {
    let updated: (CGPoint, CGSize) -> Void
    let exited: () -> Void
    let perform: (CGPoint, CGSize, EditorDragPayload?) -> Bool
    /// Handles one or more Finder file paths dropped directly onto the
    /// AppKit text view or scroll view (an `.externalFiles`-classified drag,
    /// never `.rafuEditorDrag`). The split edge nearest `location` applies
    /// only to the FIRST path; the rest of a multi-file Finder drop open
    /// into the resulting group with a `nil` edge, mirroring one "open these
    /// files" action rather than splitting once per file.
    let performFiles: (CGPoint, CGSize, [String]) -> Bool
}

/// The editor's scroll view registers for the private editor-drag type AND
/// Finder's file-URL type, forwarding dragging events out to SwiftUI.
/// Necessary because AppKit routes a drag session to the deepest registered
/// NSView under the pointer: over the text area that's this subtree, and
/// without registration here the group's SwiftUI `.onDrop` never fires — the
/// drop preview used to work only over the thin SwiftUI tab-bar strip. Also
/// the fallback destination `RafuTextView` forwards an `.externalFiles` drag
/// to (see `RafuTextView`'s drag overrides) since the text view itself has
/// no split-preview overlay state.
final class EditorDropForwardingScrollView: NSScrollView {
    var dropForwarding: EditorDropForwarding? {
        didSet {
            guard (dropForwarding == nil) != (oldValue == nil) else { return }
            if dropForwarding == nil {
                unregisterDraggedTypes()
            } else {
                registerForDraggedTypes([Self.dragType, Self.fileURLType])
            }
        }
    }

    private static let dragType = NSPasteboard.PasteboardType(
        UTType.rafuEditorDrag.identifier)
    private static let fileURLType = NSPasteboard.PasteboardType.fileURL

    private func dragKind(_ sender: NSDraggingInfo) -> EditorDragKind {
        let identifiers = Set((sender.draggingPasteboard.types ?? []).map(\.rawValue))
        return EditorDragKind.classify(typeIdentifiers: identifiers)
    }

    /// Drag location converted to this view's bounds with a top-left origin,
    /// matching `EditorDropGeometry`'s SwiftUI-style coordinates.
    private func topLeftLocation(_ sender: NSDraggingInfo) -> CGPoint {
        var point = convert(sender.draggingLocation, from: nil)
        if !isFlipped {
            point.y = bounds.height - point.y
        }
        return point
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropForwarding, dragKind(sender) != .text else { return [] }
        dropForwarding.updated(topLeftLocation(sender), bounds.size)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropForwarding, dragKind(sender) != .text else { return [] }
        dropForwarding.updated(topLeftLocation(sender), bounds.size)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropForwarding?.exited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropForwarding != nil && dragKind(sender) != .text
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropForwarding else { return false }
        switch dragKind(sender) {
        case .internalPayload:
            let payload = sender.draggingPasteboard
                .data(forType: Self.dragType)
                .flatMap { try? EditorDragPayload(data: $0) }
            return dropForwarding.perform(topLeftLocation(sender), bounds.size, payload)
        case .externalFiles:
            let urls =
                (sender.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                    as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            return dropForwarding.performFiles(
                topLeftLocation(sender), bounds.size, urls.map(\.path))
        case .text:
            return false
        }
    }

    /// macOS 26 tiles vertical rulers as OVERLAYS: `super.tile()` keeps the
    /// clip view at the scroll view's full width and hides the gutter's span
    /// behind `contentInsets.left`, making the resting scroll position
    /// x = -ruleThickness. The wrapping text view then autoresizes to the
    /// FULL clip width, so the document is `ruleThickness` wider than the
    /// visible area — any code that scrolls to x = 0 (view-state restore,
    /// scrollRangeToVisible, NSClipView constraining) legally parks the
    /// first characters of every line UNDERNEATH the gutter. Re-tile
    /// classically instead: shrink the clip frame so it starts at the
    /// ruler's trailing edge and drop the overlay inset, which makes x = 0
    /// the true home, sizes the wrapped text to the visible width, and
    /// removes the phantom horizontal overflow entirely.
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView, ruler.superview === self else {
            return
        }
        let thickness = ruler.requiredThickness
        contentView.automaticallyAdjustsContentInsets = false
        var insets = contentView.contentInsets
        if insets.left >= thickness - 0.5 {
            insets.left -= thickness
            contentView.contentInsets = insets
        }
        var clipFrame = contentView.frame
        let expectedMinX = ruler.frame.maxX
        if abs(clipFrame.minX - expectedMinX) > 0.5 {
            let delta = expectedMinX - clipFrame.minX
            clipFrame.origin.x += delta
            clipFrame.size.width -= delta
            contentView.frame = clipFrame
        }
    }
}
