import AppKit
import SwiftUI

/// Lets a SwiftUI button read the live text of a `CanvasWhiteboardTextEditor`.
/// The text stays in the native text view; nothing observes it.
final class CanvasTextEditorHandle {
    weak var textView: NSTextView?
    var text: String { textView?.string ?? "" }
}

/// A small TextKit 2 editor for Mermaid source, text cards and shape labels.
/// `NSTextView` owns the live text; SwiftUI only receives the committed
/// string. Command-Return commits, Escape cancels, and leaving the editor
/// (focus moves away, or the view goes away) commits.
struct CanvasWhiteboardTextEditor: NSViewRepresentable {
    let initialText: String
    var monospaced = false
    var fontSize: CGFloat = 13
    var textColor: NSColor = .textColor
    var byteLimit: Int
    var handle: CanvasTextEditorHandle?
    var accessibilityLabel: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommandReturnTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = !monospaced
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = initialText
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.delegate = context.coordinator
        textView.onCommandReturn = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.finish(commit: textView.string)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        configure(textView, coordinator: context.coordinator)
        handle?.textView = textView
        Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(
                NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        configure(textView, coordinator: context.coordinator)
    }

    private func configure(_ textView: NSTextView, coordinator: Coordinator) {
        let font =
            monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor { textView.textColor = textColor }
        textView.insertionPointColor = textColor
        coordinator.byteLimit = byteLimit
        coordinator.onCommit = onCommit
        coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // A card scrolled off the board keeps what was typed. The commit runs
        // after the current view update, never inside it.
        let text = (scrollView.documentView as? NSTextView)?.string
        Task { @MainActor in
            if let text { coordinator.finish(commit: text) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var byteLimit = Int.max
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        private var finished = false

        func finish(commit text: String) {
            guard !finished else { return }
            finished = true
            onCommit?(text)
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            onCancel?()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // NSTextView maps Escape to `complete:`; here it cancels editing.
            if commandSelector == #selector(NSResponder.cancelOperation(_:))
                || commandSelector == #selector(NSTextView.complete(_:))
            {
                cancel()
                return true
            }
            return false
        }

        func textView(
            _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }
            let current = textView.string as NSString
            guard affectedCharRange.location != NSNotFound,
                NSMaxRange(affectedCharRange) <= current.length
            else { return true }
            let next = current.replacingCharacters(in: affectedCharRange, with: replacementString)
            if next.utf8.count > byteLimit {
                NSSound.beep()
                return false
            }
            return true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            finish(commit: textView.string)
        }
    }

    /// Command-Return arrives as a key equivalent, before `keyDown`.
    final class CommandReturnTextView: NSTextView {
        var onCommandReturn: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .command, event.keyCode == 36 || event.keyCode == 76,
                window?.firstResponder === self
            {
                onCommandReturn?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
