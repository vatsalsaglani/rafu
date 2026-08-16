import AppKit
import RafuCore
import SwiftUI
import Testing
import Vision

@testable import RafuApp

@Suite("Editor tab visibility presentation")
@MainActor
struct EditorTabVisibilityPresentationTests {
    @Test("One file tab has a visible runtime title")
    func oneFileTabHasVisibleRuntimeTitle() throws {
        let fixture = try EditorTabVisibilityFixture(fileNames: ["Package.swift"])
        defer { fixture.remove() }

        try assertVisible(
            ["Package.swift"], in: fixture, width: 640, theme: RafuThemeCatalog.indigo)
    }

    @Test("Three file tabs keep visible runtime titles before overflow")
    func threeFileTabsKeepVisibleRuntimeTitles() throws {
        let fileNames = ["Package.swift", "EditorCanvasView.swift", "README.md"]

        for theme in [RafuThemeCatalog.indigo, RafuThemeCatalog.khadi] {
            let fixture = try EditorTabVisibilityFixture(fileNames: fileNames)
            defer { fixture.remove() }

            try assertVisible(fileNames, in: fixture, width: 960, theme: theme)
        }
    }

    @Test("Long titles stay bounded and keep neighboring tab titles visible")
    func longTitlesStayBounded() throws {
        let fileNames = [
            "ThisIsAnExtremelyLongDocumentNameThatMustRemainBoundedInsideItsTab.swift",
            "Neighbor.swift",
            "Tail.swift",
        ]
        let fixture = try EditorTabVisibilityFixture(fileNames: fileNames)
        defer { fixture.remove() }

        try assertVisible(
            ["Neighbor.swift", "Tail.swift"],
            in: fixture,
            width: 760,
            theme: RafuThemeCatalog.indigo)
    }

    @Test("Horizontal overflow keeps leading inactive tab titles visible")
    func overflowKeepsLeadingInactiveTitlesVisible() throws {
        let fileNames = [
            "Alpha.swift", "Bravo.swift", "Charlie.swift", "Delta.swift", "Echo.swift",
            "Foxtrot.swift", "Golf.swift", "Hotel.swift",
        ]
        let fixture = try EditorTabVisibilityFixture(fileNames: fileNames)
        defer { fixture.remove() }

        let group = try fixture.focusedGroup()
        #expect(group.tabs.count == fileNames.count)
        #expect(CGFloat(group.tabs.count * 96) > 480)
        try assertVisible(
            ["Alpha.swift", "Bravo.swift"],
            in: fixture,
            width: 480,
            theme: RafuThemeCatalog.indigo)
    }

    @Test("Mixed file and Terminal Group tabs keep both runtime titles visible")
    func mixedFileAndTerminalGroupTabsKeepVisibleRuntimeTitles() throws {
        let fixture = try EditorTabVisibilityFixture(fileNames: ["Source.swift"])
        defer { fixture.remove() }
        fixture.session.openDocuments[0].isDirty = true
        let terminalTitle = fixture.addInactiveTerminal(exited: true)

        try assertVisible(
            ["Source.swift", terminalTitle],
            in: fixture,
            width: 720,
            theme: RafuThemeCatalog.indigo)
    }

    private func assertVisible(
        _ expectedTitles: [String],
        in fixture: EditorTabVisibilityFixture,
        width: CGFloat,
        theme: RafuTheme
    ) throws {
        let group = try fixture.focusedGroup()
        #expect(group.tabs.count == fixture.expectedTabCount)
        #expect(fixture.session.openDocuments.count == fixture.fileNames.count)
        #expect(
            group.tabs.compactMap { fixture.session.document(for: $0)?.displayName }
                == fixture.fileNames)

        let renderedText = try fixture.renderedText(width: width, theme: theme)
        for title in expectedTitles {
            #expect(
                renderedText.contains(title),
                "Missing visible tab title \(title); rendered text was \(renderedText)")
        }
    }
}

@MainActor
private final class EditorTabVisibilityFixture {
    let directory: URL
    let fileNames: [String]
    let session = WorkspaceSession()
    private(set) var expectedTabCount: Int

    init(fileNames: [String]) throws {
        self.fileNames = fileNames
        expectedTabCount = fileNames.count
        directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-wp71-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        session.descriptor = WorkspaceDescriptor(
            displayName: "WP-71",
            location: .local(LocalWorkspaceReference(path: directory.path))
        )
        for fileName in fileNames {
            let url = directory.appending(path: fileName)
            try "let rafu = true\n".write(to: url, atomically: true, encoding: .utf8)
            session.open(
                WorkspaceFileNode(url: url, relativePath: fileName, isDirectory: false))
        }
    }

    func focusedGroup() throws -> EditorGroupState {
        try #require(session.editorLayout.group(id: session.editorLayout.focusedGroupID))
    }

    func addInactiveTerminal(exited: Bool = false) -> String {
        let controller = session.terminal.newSession(
            startingDirectory: directory.path,
            shell: TerminalShell(path: "/bin/zsh", name: "Console", isDefault: false))
        session.revealTerminalSession(controller.id)
        if exited {
            controller.processDidTerminate(exitCode: 7)
        }
        expectedTabCount += 1

        if let fileTab = session.editorLayout.group(id: session.editorLayout.focusedGroupID)?
            .tabs.first(where: {
                if case .file = $0.resource { return true }
                return false
            })
        {
            session.selectEditorTab(fileTab.id, in: session.editorLayout.focusedGroupID)
        }
        guard
            let (groupID, _) = session.terminal.terminalGroupAndPane(
                containing: controller.id),
            let terminalGroup = session.terminal.terminalGroup(groupID)
        else {
            return ""
        }
        return terminalGroup.name.rawValue
    }

    func renderedText(width: CGFloat, theme: RafuTheme) throws -> String {
        _ = NSApplication.shared
        let content = EditorCanvasView(session: session, openFolder: {})
            .rafuTheme(theme)
            .frame(width: width, height: 420)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let cgImage = try #require(representation.cgImage)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    func remove() {
        session.terminal.shutdownAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
