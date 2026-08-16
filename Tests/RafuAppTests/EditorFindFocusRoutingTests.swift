import AppKit
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Editor Find focus routing")
@MainActor
struct EditorFindFocusRoutingTests {
    @Test("Every Find invocation advances the active document focus request")
    func everyFindInvocationAdvancesFocusRequest() {
        let session = WorkspaceSession()
        let document = EditorDocument(url: URL(filePath: "/tmp/WP-71.swift"))
        session.openDocuments = [document]
        session.selectedDocumentID = document.id
        let state = session.findState(for: document)

        #expect(state.queryFocusRequest == 0)
        session.showDocumentFind()
        #expect(state.queryFocusRequest == 1)
        #expect(state.isActive)
        #expect(session.isDocumentFindPresented)

        session.showDocumentFind(includeReplace: true)
        #expect(state.queryFocusRequest == 2)
        #expect(session.isDocumentReplacePresented)
    }

    @Test("Find focus requests remain isolated between workspace windows")
    func focusRequestsRemainWindowLocal() {
        let first = WorkspaceSession()
        let second = WorkspaceSession()
        let firstDocument = EditorDocument(url: URL(filePath: "/tmp/First.swift"))
        let secondDocument = EditorDocument(url: URL(filePath: "/tmp/Second.swift"))
        first.openDocuments = [firstDocument]
        first.selectedDocumentID = firstDocument.id
        second.openDocuments = [secondDocument]
        second.selectedDocumentID = secondDocument.id

        first.showDocumentFind()

        #expect(first.findState(for: firstDocument).queryFocusRequest == 1)
        #expect(second.findState(for: secondDocument).queryFocusRequest == 0)
        #expect(first.isDocumentFindPresented)
        #expect(!second.isDocumentFindPresented)
    }

    @Test("Find targets the selected document in each focused split")
    func findTargetsFocusedSplitDocument() throws {
        let session = WorkspaceSession()
        let firstDocument = EditorDocument(url: URL(filePath: "/tmp/SplitFirst.swift"))
        let secondDocument = EditorDocument(url: URL(filePath: "/tmp/SplitSecond.swift"))
        session.openDocuments = [firstDocument, secondDocument]
        session.select(firstDocument)
        session.select(secondDocument)

        let firstGroupID = session.editorLayout.focusedGroupID
        let firstTab = try #require(
            session.editorLayout.tab(matching: .file(firstDocument.url)))
        let secondTab = try #require(
            session.editorLayout.tab(matching: .file(secondDocument.url)))
        let splitGroupID = session.editorLayout.split(
            group: firstGroupID, at: .trailing, moving: firstTab.id)
        let secondGroupID = try #require(splitGroupID)

        session.selectEditorTab(secondTab.id, in: firstGroupID)
        session.showDocumentFind()
        #expect(session.findState(for: secondDocument).queryFocusRequest == 1)
        #expect(session.findState(for: firstDocument).queryFocusRequest == 0)

        session.selectEditorTab(firstTab.id, in: secondGroupID)
        session.showDocumentFind()
        #expect(session.findState(for: firstDocument).queryFocusRequest == 1)
        #expect(session.findState(for: secondDocument).queryFocusRequest == 1)
    }

    @Test("Exact Control-F is consumed by RafuTextView only")
    func exactControlFIsConsumedByRafuTextViewOnly() throws {
        let textView = RafuTextView.makeTextKit1()
        textView.string = "editor text"
        var invocationCount = 0
        textView.findAction = { invocationCount += 1 }

        textView.keyDown(with: try keyEvent(characters: "f", modifiers: [.control], keyCode: 3))
        textView.keyDown(with: try keyEvent(characters: "f", modifiers: [.control], keyCode: 3))

        #expect(invocationCount == 2)
        #expect(textView.string == "editor text")
        #expect(
            !RafuTextView.isExactControlFind(
                try keyEvent(characters: "f", modifiers: [.command], keyCode: 3)))
        #expect(
            !RafuTextView.isExactControlFind(
                try keyEvent(characters: "f", modifiers: [.control, .shift], keyCode: 3)))
        #expect(
            !RafuTextView.isExactControlFind(
                try keyEvent(characters: "g", modifiers: [.control], keyCode: 5)))
    }

    @Test("Command-F remains routed by the existing app command")
    func commandFRouteRemainsValid() throws {
        let sourceURL = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "Sources/RafuApp/App/RafuAppCommands.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            source.contains(#"Button("Find in File…") { workspaceSession?.showDocumentFind() }"#))
        #expect(source.contains(#".keyboardShortcut("f", modifiers: .command)"#))
    }

    @Test("CodeEditorView installs the local Control-F bridge")
    func codeEditorInstallsControlFBridge() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "rafu-wp71-find-\(UUID().uuidString).swift")
        try "editor text\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let document = EditorDocument(url: fileURL)
        var invocationCount = 0
        let host = NSHostingView(
            rootView: CodeEditorView(
                document: document,
                theme: RafuThemeCatalog.indigo,
                requestFind: { invocationCount += 1 }
            )
            .frame(width: 480, height: 320)
        )
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(host.firstDescendant(of: RafuTextView.self))

        textView.keyDown(with: try keyEvent(characters: "f", modifiers: [.control], keyCode: 3))

        #expect(invocationCount == 1)
    }

    @Test("Initial and repeated Find focus query; typing and Escape preserve editor text")
    func findBarFocusLifecycle() throws {
        let fixture = try FindFocusRuntimeFixture()
        defer { fixture.remove() }

        let hosted = fixture.host()
        defer { hosted.window.orderOut(nil) }
        fixture.session.showDocumentFind()
        hosted.flushViewLifecycle()

        let editor = try #require(hosted.host.firstDescendant(of: RafuTextView.self))
        let initialEditorText = editor.string
        let firstFieldEditor = try #require(hosted.window.firstResponder as? NSTextView)
        #expect(firstFieldEditor !== editor)

        firstFieldEditor.insertText(
            "needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        hosted.flushViewLifecycle()
        let state = fixture.session.findState(for: fixture.document)
        #expect(state.query == "needle")
        #expect(editor.string == initialEditorText)

        hosted.window.makeFirstResponder(editor)
        #expect(hosted.window.firstResponder === editor)
        fixture.session.showDocumentFind()
        hosted.flushViewLifecycle()
        let repeatedFieldEditor = try #require(hosted.window.firstResponder as? NSTextView)
        #expect(repeatedFieldEditor !== editor)
        #expect(state.queryFocusRequest == 2)

        repeatedFieldEditor.keyDown(
            with: try keyEvent(characters: "\u{1B}", modifiers: [], keyCode: 53))
        hosted.flushViewLifecycle()
        #expect(!fixture.session.isDocumentFindPresented)
        #expect(hosted.window.firstResponder === editor)
        #expect(state.query == "needle")
        #expect(editor.string == initialEditorText)
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
    }
}

@MainActor
private final class FindFocusRuntimeFixture {
    let directory: URL
    let fileURL: URL
    let session = WorkspaceSession()
    let document: EditorDocument

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-wp71-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "Focus.swift")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try "editor text\n".write(to: fileURL, atomically: true, encoding: .utf8)
        session.descriptor = WorkspaceDescriptor(
            displayName: "WP-71 Find",
            location: .local(LocalWorkspaceReference(path: directory.path)))
        session.open(
            WorkspaceFileNode(url: fileURL, relativePath: "Focus.swift", isDirectory: false))
        document = session.openDocuments[0]
    }

    func host() -> FindFocusHostedWindow {
        _ = NSApplication.shared
        let content = EditorCanvasView(session: session, openFolder: {})
            .rafuTheme(RafuThemeCatalog.indigo)
            .frame(width: 840, height: 520)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.animationBehavior = .none
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        FindFocusWindowRetainer.retain(window)
        return FindFocusHostedWindow(window: window, host: host)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private enum FindFocusWindowRetainer {
    private static var windows: [NSWindow] = []

    static func retain(_ window: NSWindow) {
        windows.append(window)
    }
}

@MainActor
private struct FindFocusHostedWindow {
    let window: NSWindow
    let host: NSView

    func flushViewLifecycle() {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}

@MainActor
extension NSView {
    fileprivate func firstDescendant<ViewType: NSView>(of _: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(of: ViewType.self) }.first
    }
}
