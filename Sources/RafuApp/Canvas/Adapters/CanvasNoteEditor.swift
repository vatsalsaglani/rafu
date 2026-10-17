import AppKit
import SwiftUI

/// Live note text belongs to TextKit, never to observable SwiftUI state.
final class CanvasNoteBuffer: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView(usingTextLayoutManager: true)
    private let undoOwner = UndoManager()
    var edited: (() -> Void)?
    private(set) var revision: UInt64 = 0

    init(snapshot: String) {
        super.init()
        textView.string = snapshot
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
    }

    func snapshot() throws -> String {
        let value = textView.string
        guard value.utf8.count <= CanvasLimits.noteBytes else { throw CanvasError.invalidDocument }
        return value
    }

    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString, let range = Range(affectedCharRange, in: textView.string)
        else { return true }
        let proposed = textView.string.replacingCharacters(in: range, with: replacementString)
        guard proposed.utf8.count <= CanvasLimits.noteBytes else {
            NSSound.beep()
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        revision &+= 1
        edited?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoOwner }

    isolated deinit {
        textView.delegate = nil
        undoOwner.removeAllActions()
    }
}

struct CanvasNoteEditor: NSViewRepresentable {
    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var noteFontSize: CGFloat = 13
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let presentationID: UUID?
    let isCurrentPresentation: Bool

    func makeNSView(context: Context) -> NativeContentMount { NativeContentMount() }
    func updateNSView(_ view: NativeContentMount, context: Context) {
        guard isCurrentPresentation, let resources = session.canvasResources[board.id],
            resources.board === board, resources.canPresent(owner: presentationID),
            let buffer = resources.note(for: card)
        else {
            view.detach()
            return
        }
        view.mount(buffer.scrollView)
        let font = NSFont.monospacedSystemFont(ofSize: noteFontSize, weight: .regular)
        if buffer.textView.font != font { buffer.textView.font = font }
        buffer.textView.backgroundColor = NSColor(theme.palette.editorBackground)
        buffer.textView.textColor = NSColor(theme.palette.textPrimary)
        buffer.textView.insertionPointColor = NSColor(theme.palette.accent)
        buffer.scrollView.backgroundColor = NSColor(theme.palette.editorBackground)
        buffer.textView.isEditable = board.contentIsActive
        buffer.textView.isSelectable = board.contentIsActive
        if board.contentIsActive, view.window?.firstResponder !== buffer.textView {
            view.window?.makeFirstResponder(buffer.textView)
        }
    }
    static func dismantleNSView(_ view: NativeContentMount, coordinator: ()) { view.detach() }
}
