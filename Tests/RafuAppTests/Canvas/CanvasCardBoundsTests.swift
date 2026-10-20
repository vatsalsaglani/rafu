import AppKit
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

/// A card must draw exactly inside its stored rect. Edges, ports and the
/// selected edge's handles are computed from that rect, so a card face that
/// grows past it (and is then centred by the placement frame) shows its top
/// border above the rect and the edge seems to end inside the header.
@Suite("Canvas card bounds")
@MainActor
struct CanvasCardBoundsTests {
    private static let proposal = CGSize(width: 300, height: 200)

    /// Pins the SwiftUI rule behind the bug: a flexible frame with no
    /// minimum reports an inflexible child's height when it exceeds the
    /// proposal; `minHeight: 0` caps it at the proposal.
    @Test("A maxHeight-only frame grows to its child; canvasCardFill does not")
    func flexibleFrameRule() {
        let grows = NSHostingController(
            rootView: Color.clear.frame(height: 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        #expect(grows.sizeThatFits(in: Self.proposal).height == 620)
        let fills = NSHostingController(
            rootView: Color.clear.frame(height: 620).canvasCardFill())
        #expect(fills.sizeThatFits(in: Self.proposal) == Self.proposal)
    }

    @Test("A 40-line file excerpt keeps the size it is given")
    func fileExcerptIsBounded() {
        let lines = (1...40).map { AttributedString("line \($0)") }
        let host = NSHostingController(rootView: CanvasFileExcerptLines(lines: lines, notice: nil))
        #expect(host.sizeThatFits(in: Self.proposal) == Self.proposal)
    }

    @Test(
        "A card shell takes exactly its proposed size even when its face asks for more",
        arguments: [
            // A live body: the terminal card of a missing group shows the
            // inflexible "No terminal yet" block, far taller than 64 - 33 pt.
            (CanvasCardContent.terminal(groupID: TerminalGroupID()), 1.0),
            // A zoomed-out face: its title font grows as the scale falls.
            (CanvasCardContent.terminal(groupID: TerminalGroupID()), 0.15),
            (CanvasCardContent.file(path: "Dockerfile"), 0.15),
        ])
    func shellKeepsProposedSize(content: CanvasCardContent, scale: Double) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(folder)
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Bounds"))
        board.setViewport(CanvasViewport(scale: scale, x: 0, y: 0))
        let size = CGSize(width: 200, height: 64)
        let card = CanvasCard(
            title: "Card", rect: CanvasRect(x: 0, y: 0, width: 200, height: 64),
            content: content)
        let host = NSHostingController(
            rootView: CanvasCardShell(card: card, board: board, session: session)
                .environment(CanvasInteractionState()))
        #expect(host.sizeThatFits(in: size) == size)
    }

    /// Defence in depth: should any card still report more than its rect,
    /// the placement frame keeps its top on the rect and overflows downward.
    @Test("Placement keeps an oversized card's top edge on its stored rect")
    func placementIsTopAligned() {
        let probe = CanvasCardTopProbe()
        let rect = CanvasRect(x: 100, y: 50, width: 300, height: 200)
        let board = ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 32)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named("board")).minY
                    } action: {
                        probe.headerTop = $0
                    }
                Color.clear.frame(height: 620)
            }
            .modifier(
                CanvasCardPlacement(
                    id: CanvasCardID(), rect: rect, viewport: CanvasViewport(),
                    live: CanvasLiveGeometry()))
        }
        .frame(width: 1000, height: 1000, alignment: .topLeading)
        .coordinateSpace(.named("board"))
        let host = NSHostingView(rootView: board)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        host.layoutSubtreeIfNeeded()
        #expect(probe.headerTop == 50)
    }

    private func makeSession(_ folder: URL) -> WorkspaceSession {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-bounds-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder.appending(path: "state"))))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Bounds", location: .local(.init(path: folder.path)))
        return session
    }
}

@MainActor
private final class CanvasCardTopProbe {
    var headerTop: CGFloat?
}
