import CoreGraphics
import Foundation
import ImageIO
import RafuCore
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

/// The board's notice is separate from the save-failure banner, and the drop
/// hover preview has one owner that every end of a drag clears.
@Suite("Ensemble board notice and drop preview ownership")
@MainActor
struct CanvasBoardNoticeTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private let sample = CanvasDropPreview(label: "Add image card", tone: .accept, shape: .board)

    private func makeFolders() throws -> (folder: URL, root: URL, outside: URL) {
        let folder = URL.temporaryDirectory.appending(path: "board-notice-\(UUID().uuidString)")
        let root = folder.appending(path: "workspace")
        let outside = folder.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (folder, root, outside)
    }

    private func fixture(_ root: URL) async throws -> (WorkspaceSession, CanvasBoardState) {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.board-notice-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: ".state"))))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Notice", location: .local(.init(path: root.path)))
        #expect(await session.canvas.configure(root: root))
        return (session, try #require(await session.canvas.create(title: "Sprint Plan")))
    }

    // MARK: Board state

    @Test("Clearing the drop preview is idempotent and an edit clears it")
    func clearDropPreview() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "B"))
        board.clearDropPreview()
        #expect(board.dropPreview == nil)
        board.updateDropPreview(sample)
        #expect(board.dropPreview == sample)
        board.clearDropPreview()
        board.clearDropPreview()
        #expect(board.dropPreview == nil)
        board.updateDropPreview(sample)
        try board.add(title: "N", content: .note(snapshot: ""))
        #expect(board.dropPreview == nil)
    }

    @Test("A new notice replaces the old one and an edit or undo dismisses it")
    func noticeReplaces() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "B"))
        board.showNotice("First")
        let first = try #require(board.notice)
        board.showNotice("Second", tone: .info)
        #expect(board.notice?.message == "Second")
        #expect(board.notice?.tone == .info)
        #expect(board.notice?.id != first.id)
        try board.add(title: "N", content: .note(snapshot: ""))
        #expect(board.notice == nil)
        board.showNotice("Again")
        board.performUndo()
        #expect(board.notice == nil)
        board.showNotice("Escape")
        board.dismissNotice()
        board.dismissNotice()
        #expect(board.notice == nil)
    }

    @Test("A notice never reaches the save-failure banner, and the reverse")
    func noticeAndSaveFailureAreIndependent() {
        let board = CanvasBoardState(document: CanvasDocument(title: "B"))
        board.showNotice("Drop refused")
        #expect(board.saveFailureMessage == nil)
        board.saveFailureMessage = "Disk full"
        board.dismissNotice()
        #expect(board.saveFailureMessage == "Disk full")
        // The legacy writer still in other workstreams' files routes to the
        // notice, never to the banner.
        board.saveFailureMessage = nil
        board.errorMessage = "Legacy"
        #expect(board.notice?.message == "Legacy" && board.saveFailureMessage == nil)
        board.errorMessage = nil
        #expect(board.notice == nil)
    }

    @Test("The drop-preview watchdog clears only when the primary button is up")
    func watchdog() {
        #expect(CanvasDropPreviewWatchdog.dragHasEnded(pressedMouseButtons: 0))
        #expect(CanvasDropPreviewWatchdog.dragHasEnded(pressedMouseButtons: 2))
        #expect(!CanvasDropPreviewWatchdog.dragHasEnded(pressedMouseButtons: 1))
        #expect(!CanvasDropPreviewWatchdog.dragHasEnded(pressedMouseButtons: 3))
    }

    // MARK: Drops on a session

    @Test("Every file-drop outcome leaves the drop preview cleared")
    func fileDropOutcomesClearPreview() async throws {
        let (folder, root, outside) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, board) = try await fixture(root)
        let inside = root.appending(path: "notes.md")
        try Data("n".utf8).write(to: inside)
        let text = outside.appending(path: "todo.txt")
        try Data("t".utf8).write(to: text)

        board.updateDropPreview(sample)
        await session.addCanvasDroppedFiles([inside], to: board.id, at: .zero)
        #expect(board.dropPreview == nil && board.cards.count == 1)

        board.updateDropPreview(sample)
        await session.addCanvasDroppedFiles([text], to: board.id, at: .zero)
        #expect(board.dropPreview == nil && board.cards.count == 1)

        board.updateDropPreview(sample)
        _ = CanvasFileDrop.perform(
            .agentSession(AgentHistorySessionKey(provider: .claudeCode, sessionID: "gone")),
            at: .zero, surface: CGSize(width: 800, height: 600), boardID: board.id,
            session: session)
        #expect(board.dropPreview == nil)
        #expect(board.notice?.message == "This session is no longer in Agent History.")

        board.updateDropPreview(sample)
        _ = session.dropTerminalGroupOnCanvas(TerminalGroupID(), boardID: board.id, at: .zero)
        #expect(board.dropPreview == nil)

        board.updateDropPreview(sample)
        _ = session.dropEditorTabOnCanvas(
            UUID().uuidString, boardID: board.id, at: .zero, surface: CGSize(width: 1, height: 1))
        #expect(board.dropPreview == nil)
        #expect(board.saveFailureMessage == nil)
        #expect(await session.canvas.flushAll())
    }

    @Test("An outside non-image shows a notice, not the save banner, and adds nothing")
    func outsideNonImageIsANotice() async throws {
        let (folder, root, outside) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, board) = try await fixture(root)
        let text = outside.appending(path: "todo.txt")
        let image = outside.appending(path: "shot.png")
        try Data("t".utf8).write(to: text)
        try Self.png.write(to: image)

        await session.addCanvasDroppedFiles([image, text], to: board.id, at: .zero)
        #expect(board.cards.isEmpty)
        #expect(board.pendingAssetImport == nil)
        #expect(board.notice?.message.contains("todo.txt") == true)
        #expect(board.saveFailureMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".rafu").path))
        #expect(await session.canvas.flushAll())
    }

    @Test("Outside images wait for consent, then are copied and added as one edit")
    func outsideImagesNeedConsent() async throws {
        let (folder, root, outside) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, board) = try await fixture(root)
        let inside = root.appending(path: "notes.md")
        try Data("n".utf8).write(to: inside)
        let images = (1...3).map { outside.appending(path: "Screenshot \($0).png") }
        for image in images { try Self.png.write(to: image) }
        let suite = TestDefaultsSuite.name("dev.rafu.board-notice-preferences")
        defer { TestDefaultsSuite.remove(suite) }
        let preferences = CanvasAssetImportPreferences(suiteName: suite)

        await session.addCanvasDroppedFiles(
            [images[0], inside, images[1], images[2]], to: board.id, at: CGPoint(x: 10, y: 10),
            preferences: preferences)
        let request = try #require(board.pendingAssetImport)
        #expect(board.cards.isEmpty)
        #expect(request.imageCount == 3)
        #expect(request.folder == ".rafu/ensemble-assets/sprint-plan")
        #expect(request.title == "Copy 3 images into .rafu/ensemble-assets/sprint-plan?")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".rafu").path))

        await session.confirmCanvasAssetImport(request, alwaysCopy: true, preferences: preferences)
        #expect(board.pendingAssetImport == nil)
        #expect(
            board.cards.map(\.content) == [
                .image(path: ".rafu/ensemble-assets/sprint-plan/Screenshot 1.png"),
                .file(path: "notes.md"),
                .image(path: ".rafu/ensemble-assets/sprint-plan/Screenshot 2.png"),
                .image(path: ".rafu/ensemble-assets/sprint-plan/Screenshot 3.png"),
            ])
        #expect(board.notice?.tone == .info)
        #expect(board.notice?.message == "Copied 3 images into .rafu/ensemble-assets/sprint-plan.")
        #expect(preferences.entry(forRootPath: root.path).alwaysCopy)
        board.performUndo()
        #expect(board.cards.isEmpty)

        // "Always copy" skips the question next time; the name does not clash.
        await session.addCanvasDroppedFiles(
            [images[0]], to: board.id, at: .zero, preferences: preferences)
        #expect(board.pendingAssetImport == nil)
        #expect(
            board.cards.map(\.content) == [
                .image(path: ".rafu/ensemble-assets/sprint-plan/Screenshot 1-2.png")
            ])
        #expect(await session.canvas.flushAll())
    }

    @Test("Cancel copies nothing and adds nothing")
    func cancelConsent() async throws {
        let (folder, root, outside) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, board) = try await fixture(root)
        let image = outside.appending(path: "shot.png")
        try Self.png.write(to: image)
        let suite = TestDefaultsSuite.name("dev.rafu.board-notice-cancel")
        defer { TestDefaultsSuite.remove(suite) }
        let preferences = CanvasAssetImportPreferences(suiteName: suite)

        await session.addCanvasDroppedFiles(
            [image], to: board.id, at: .zero, preferences: preferences)
        let request = try #require(board.pendingAssetImport)
        session.cancelCanvasAssetImport(request)
        #expect(board.pendingAssetImport == nil)
        // A stale confirmation after Cancel does nothing.
        await session.confirmCanvasAssetImport(request, alwaysCopy: true, preferences: preferences)
        #expect(board.cards.isEmpty)
        #expect(!preferences.entry(forRootPath: root.path).alwaysCopy)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".rafu").path))
        #expect(await session.canvas.flushAll())
    }

    @Test("One dropped file lands exactly where its hover ghost was")
    func singleFileLandsOnGhost() async throws {
        let (folder, root, _) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, board) = try await fixture(root)
        let file = root.appending(path: "shot.png")
        try Self.png.write(to: file)
        board.setViewport(.init(scale: 2, x: 100, y: 50))
        let point = CGPoint(x: 700, y: 450)
        let preview = try #require(
            CanvasFileDrop.preview(
                for: .files([file], fromFilesTree: false), at: point,
                surface: CGSize(width: 1_000, height: 800), boardID: board.id, session: session))
        #expect(preview.label == "Add image card")
        guard case .card(let ghost) = preview.shape else {
            Issue.record("Expected a ghost card")
            return
        }
        await session.addCanvasDroppedFiles([file], to: board.id, at: point)
        let card = try #require(board.cards.first)
        #expect(card.rect.cgRect == ghost)
        #expect(await session.canvas.flushAll())
    }

    @Test("A History chat ghost has the rect its resumed card gets")
    func agentSessionGhostMatchesCard() throws {
        let viewport = CanvasViewport(scale: 1, x: 0, y: 0)
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .agentSession(
                    AgentHistorySessionKey(provider: .claudeCode, sessionID: "a")),
                at: CGPoint(x: 500, y: 400), surface: CGSize(width: 1_000, height: 800),
                viewport: viewport, context: CanvasDropAction.Context(hasWorkspace: true)))
        let board = CanvasBoardState(document: CanvasDocument(title: "B"))
        let id = try board.add(
            title: "T", content: .terminal(groupID: TerminalGroupID()),
            center: CanvasBoardDropGeometry.boardPoint(CGPoint(x: 500, y: 400), viewport: viewport))
        let card = try #require(board.cards.first { $0.id == id })
        #expect(preview.shape == .card(card.rect.cgRect))
    }

    // MARK: Source contracts

    @Test("Only the store's save paths write the save-failure message")
    func saveFailureWriters() throws {
        let sources = try Self.packageRoot().appending(path: "Sources/RafuApp")
        let files = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var writers: [String] = []
        var legacy: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                if line.contains("saveFailureMessage =") {
                    writers.append(url.lastPathComponent)
                }
                if line.contains("errorMessage ="), url.path.contains("/Canvas/") {
                    legacy.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(
            Set(writers) == ["WorkspaceCanvasStore.swift", "WorkspaceCanvasActions.swift"],
            "\(writers)")
        // Files another workstream owns still use the routing shim; it shows
        // a notice. Remove each entry when its file moves to `showNotice`.
        let allowed: Set<String> = [
            "CanvasToolPalette.swift", "CanvasWhiteboardCardFace.swift",
        ]
        let offenders = legacy.filter { entry in
            !allowed.contains(String(entry.split(separator: ":")[0]))
        }
        #expect(offenders.isEmpty, "errorMessage writers in Canvas: \(offenders)")
    }

    // MARK: Image decode

    @Test("A card image decodes from the file to at most the requested side")
    func decodeBounded() async throws {
        let (folder, root, _) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(
            CGContext(
                data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 600 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: root.appending(path: "wide.png"))
        let thumbnail = try await CanvasPreviewLoader.image(
            path: "wide.png", root: root, pixels: 200)
        #expect(max(thumbnail.width, thumbnail.height) <= 200)
        #expect(thumbnail.bitsPerPixel <= 32)
        #expect(CanvasPreviewLoader.thumbnailMaxPixels(5_000) == 1_024)
        #expect(CanvasPreviewLoader.thumbnailMaxPixels(1) == 64)
    }

    @Test("An image over the cap is refused from its size alone")
    func decodeRefusesOversized() async throws {
        let (folder, root, _) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = root.appending(path: "big.png")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(CanvasPreviewLoader.maxImageBytes + 1))
        try handle.close()
        await #expect(throws: CanvasError.unavailable) {
            try await CanvasPreviewLoader.image(path: "big.png", root: root, pixels: 256)
        }
        #expect(throws: CanvasError.unavailable) {
            try CanvasPreviewLoader.checkRegularFile(
                big, maxBytes: CanvasPreviewLoader.maxImageBytes)
        }
    }

    private static func packageRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
