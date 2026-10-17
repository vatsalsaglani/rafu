import AppKit
import Testing

@testable import RafuApp

@Suite("Hidden editor interaction", .serialized)
@MainActor
struct EditorHiddenInteractionTests {
    @Test("A hidden editor releases keyboard focus without taking another field's focus")
    func hiddenEditorResignsOnlyItsOwnResponder() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let host = editor.makeHost(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = container
        host.frame = container.bounds
        container.addSubview(host)
        defer {
            window.contentView = nil
            document.editorResources?.release()
        }
        let textView = try #require(coordinator.textView)
        #expect(window.makeFirstResponder(textView))
        host.setEditorVisible(false)
        #expect(window.firstResponder !== textView)
        host.setEditorVisible(true)
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        container.addSubview(other)
        #expect(window.makeFirstResponder(other))
        host.setEditorVisible(false)
        #expect(window.firstResponder === other)
    }

    @Test(
        "Hidden or scrolled editors reject an already running hover response",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func changingViewportCancelsHover(scroll: Bool) async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let host = editor.makeHost(coordinator: coordinator)
        defer { document.editorResources?.release() }
        let textView = try #require(coordinator.textView)
        textView.string = "identifier\n"
        let started = AsyncStream<Void>.makeStream()
        var complete: CheckedContinuation<EditorHoverInfo?, Never>?
        textView.hoverAction = { _ in
            await withCheckedContinuation { continuation in
                complete = continuation
                started.continuation.yield(())
            }
        }
        let task = try #require(textView.scheduleHover(atUTF16Offset: 2))
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        if scroll {
            let clipView = try #require(document.editorResources?.scrollView.contentView)
            clipView.setBoundsOrigin(NSPoint(x: 0, y: 10))
        } else {
            host.setEditorVisible(false)
        }
        try #require(complete).resume(
            returning: EditorHoverInfo(
                text: "old", symbolName: "identifier", signature: nil,
                documentation: "old", isMarkdown: false))
        await task.value
        #expect(!textView.isHoverTooltipPresented)
    }
}
