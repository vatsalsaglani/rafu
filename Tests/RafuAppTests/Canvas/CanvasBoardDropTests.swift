import AppKit
import Foundation
import RafuCore
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

@Suite("Ensemble board drag payload and geometry")
struct CanvasBoardDragPayloadTests {
    private let payload = CanvasBoardDragPayload.agentSession(
        provider: .claudeCode, sessionID: "abc-123_x.y")

    @Test("The private type has a fixed name that the staged Info.plist declares as public.item")
    func typeIdentity() throws {
        #expect(UTType.rafuEnsembleDrag.identifier == "dev.vatsalsaglani.rafu.ensemble-drag-v2")
        #expect(UTType.rafuEditorDrag.identifier == "dev.vatsalsaglani.rafu.editor-drag-v2")
        #expect(UTType.rafuEnsembleDrag != UTType.rafuEditorDrag)
        // A test process has no Info.plist, so the system declaration cannot
        // be checked here. The private types conform to public.item, never
        // public.data: SwiftUI writes a public.data drag type as a file
        // promise (docs/references/swiftui-drop-hover-file-promise.md). The
        // staging script writes the declaration and asserts it after every
        // stage; this guards that both stay in lockstep.
        let script = try Self.source("script/build_and_run.sh")
        #expect(
            script.contains(
                """
                      <string>dev.vatsalsaglani.rafu.ensemble-drag-v2</string>
                      <key>UTTypeDescription</key>
                      <string>Rafu Ensemble drag item</string>
                      <key>UTTypeConformsTo</key>
                      <array>
                        <string>public.item</string>
                      </array>
                """))
        #expect(
            script.contains(
                """
                      <string>dev.vatsalsaglani.rafu.editor-drag-v2</string>
                      <key>UTTypeDescription</key>
                      <string>Rafu editor drag item</string>
                      <key>UTTypeConformsTo</key>
                      <array>
                        <string>public.item</string>
                      </array>
                """))
        #expect(!script.contains("<string>public.data</string>"))
        #expect(
            script.contains(
                "UTExportedTypeDeclarations.3.UTTypeIdentifier raw \"$INFO_PLIST\")\" = \"dev.vatsalsaglani.rafu.ensemble-drag-v2\""
            ))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(
                    contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("The payload survives JSON and names only the provider and the id")
    func jsonRoundTrip() throws {
        let data = try payload.encodedData()
        #expect(try CanvasBoardDragPayload(data: data) == payload)
        #expect(CanvasBoardDragPayload.decode(data) == payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("claudeCode"))
        #expect(text.contains("abc-123_x.y"))
        #expect(
            payload.sessionKey
                == AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123_x.y"))
    }

    @Test("Data over 16 KB is refused")
    func oversizedDataIsRefused() throws {
        var data = try payload.encodedData()
        data.append(Data(repeating: 0x20, count: CanvasBoardDragPayload.maximumEncodedBytes))
        #expect(data.count > CanvasBoardDragPayload.maximumEncodedBytes)
        #expect(CanvasBoardDragPayload.decode(data) == nil)
        #expect(throws: CanvasBoardDragPayload.DecodeError.tooLarge) {
            try CanvasBoardDragPayload(data: data)
        }
    }

    @Test("An unsafe session id or an unknown provider is refused")
    func unsafeContentIsRefused() throws {
        let unsafe = try CanvasBoardDragPayload.agentSession(
            provider: .codex, sessionID: "a;rm -rf"
        ).encodedData()
        #expect(CanvasBoardDragPayload.decode(unsafe) == nil)
        let leadingDash = try CanvasBoardDragPayload.agentSession(
            provider: .codex, sessionID: "-x"
        ).encodedData()
        #expect(CanvasBoardDragPayload.decode(leadingDash) == nil)
        let unknown = Data(#"{"agentSession":{"provider":"mystery","sessionID":"abc"}}"#.utf8)
        #expect(CanvasBoardDragPayload.decode(unknown) == nil)
        #expect(CanvasBoardDragPayload.decode(Data("not json".utf8)) == nil)
    }

    @Test("The item provider carries only the private type and loads back the same payload")
    func itemProviderRoundTrip() async throws {
        let provider = payload.makeItemProvider()
        #expect(provider.registeredTypeIdentifiers == [UTType.rafuEnsembleDrag.identifier])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .rafuEnsembleDrag) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
        #expect(CanvasBoardDragPayload.decode(data) == payload)
    }

    @Test("A view point maps to a board point through the viewport")
    func boardPoint() {
        let viewport = CanvasViewport(scale: 2, x: 100, y: -50)
        let point = CanvasBoardDropGeometry.boardPoint(
            CGPoint(x: 300, y: 150), viewport: viewport)
        #expect(point == CGPoint(x: 100, y: 100))
        #expect(
            CanvasBoardDropGeometry.boardPoint(CGPoint(x: 7, y: 9), viewport: CanvasViewport())
                == CGPoint(x: 7, y: 9))
    }

    @Test("An editor payload decodes to a file or a tab, and nothing else")
    func editorContentDecoding() throws {
        let tabID = UUID().uuidString
        #expect(
            CanvasFileDropDecoder.editorContent(try EditorDragPayload.tab(id: tabID).encodedData())
                == .tab(tabID))
        #expect(
            CanvasFileDropDecoder.editorContent(try EditorDragPayload.tab(id: "x").encodedData())
                == nil)
        #expect(
            CanvasFileDropDecoder.editorContent(
                try EditorDragPayload.file(path: "/tmp/a.swift").encodedData())
                == .files([URL(fileURLWithPath: "/tmp/a.swift")], fromFilesTree: true))
        #expect(
            CanvasFileDropDecoder.editorContent(
                try EditorDragPayload.file(path: "relative.swift").encodedData()) == nil)
    }

    @Test("A terminal-group payload round-trips and names no Agent History session")
    func terminalGroupPayloadRoundTrip() async throws {
        let groupID = TerminalGroupID()
        let payload = CanvasBoardDragPayload(terminalGroupID: groupID)
        let data = try payload.encodedData()
        #expect(try CanvasBoardDragPayload(data: data) == payload)
        #expect(CanvasBoardDragPayload.decode(data) == payload)
        #expect(payload.terminalGroupID == groupID)
        #expect(payload.sessionKey == nil)

        let provider = payload.makeItemProvider()
        #expect(provider.registeredTypeIdentifiers == [UTType.rafuEnsembleDrag.identifier])
        let loaded: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .rafuEnsembleDrag) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
        #expect(CanvasBoardDragPayload.decode(loaded) == payload)
    }

    @Test("A tab moves to the board only from the centre zone and only for a terminal")
    func tabRoutingTable() {
        let edges: [EditorSplitEdge] = [.leading, .trailing, .top, .bottom]
        #expect(
            CanvasBoardTabDrop.decide(edge: nil, isTerminalGroupTab: true) == .moveTerminalToBoard)
        #expect(
            CanvasBoardTabDrop.decide(edge: nil, isTerminalGroupTab: false) == .forwardToGroup(nil))
        for edge in edges {
            #expect(
                CanvasBoardTabDrop.decide(edge: edge, isTerminalGroupTab: true)
                    == .forwardToGroup(edge))
            #expect(
                CanvasBoardTabDrop.decide(edge: edge, isTerminalGroupTab: false)
                    == .forwardToGroup(edge))
        }
    }

    @Test("The board's drop-decode cache only reuses a SUCCESSFUL decode")
    @MainActor
    func dropDecodeCacheOnlyReusesSuccess() {
        typealias Host = CanvasScrollBridge.Host
        let content = CanvasBoardDropContent.tab(UUID().uuidString)

        // A fresh sequence number never reuses the cache, decoded or not.
        #expect(
            !Host.canReuseCachedDecode(
                requestSequence: 2, cachedSequence: 1, cachedContent: content))
        #expect(
            !Host.canReuseCachedDecode(
                requestSequence: 2, cachedSequence: 1, cachedContent: nil))

        // The SAME sequence number reuses a successful decode...
        #expect(
            Host.canReuseCachedDecode(
                requestSequence: 1, cachedSequence: 1, cachedContent: content))
        // ...but never a cached nil (a transient decode failure), so a later
        // call in the same drag session gets a chance to decode again.
        #expect(
            !Host.canReuseCachedDecode(
                requestSequence: 1, cachedSequence: 1, cachedContent: nil))
        #expect(
            !Host.canReuseCachedDecode(
                requestSequence: 1, cachedSequence: nil, cachedContent: nil))
    }

    @Test("A terminal card's block follows pane-running state first, then lease ownership")
    func terminalCardBlockDecidesRunningBeforeLease() {
        // Stopped: always the Start Shell block, regardless of lease.
        #expect(
            CanvasTerminalCardBlock.decide(isRunning: false, ownsLease: false) == .notRunning)
        #expect(
            CanvasTerminalCardBlock.decide(isRunning: false, ownsLease: true) == .notRunning)
        // Running and this card holds the lease: the live terminal view.
        #expect(CanvasTerminalCardBlock.decide(isRunning: true, ownsLease: true) == .live)
        // Running but the lease is held elsewhere (or resources are
        // unavailable): "not attached", never confused with "not running".
        #expect(
            CanvasTerminalCardBlock.decide(isRunning: true, ownsLease: false) == .notAttached)
    }
}

@Suite("Ensemble board drops on a session")
@MainActor
struct CanvasBoardDropSessionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appending(path: "app"), withIntermediateDirectories: true)
        return root
    }

    private func makeSession(root: URL) -> WorkspaceSession {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.board-drop-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "state"))))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Drops", location: .local(.init(path: root.path)))
        return session
    }

    private func makeBoard(_ session: WorkspaceSession, root: URL, title: String = "Work")
        async throws -> CanvasBoardState
    {
        #expect(await session.canvas.configure(root: root))
        return try #require(await session.canvas.create(title: title))
    }

    private func summary(projectPath: String) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            key: AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123"),
            title: "Fix the parser", projectPath: projectPath, startedAt: nil, updatedAt: nil,
            gitBranch: "main", messageCount: 2, isMessageCountEstimated: false,
            fileURL: URL(fileURLWithPath: "/tmp/rafu-missing-\(UUID().uuidString).jsonl"),
            fileSize: 10, modificationDate: Date(timeIntervalSince1970: 0))
    }

    /// An inert stopped Terminal Group with a tab in the focused editor group.
    /// Nothing starts a process.
    private func openStoppedGroup(
        _ session: WorkspaceSession, panes: Int = 1, name: String = "Build"
    ) throws
        -> TerminalGroupID
    {
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let ids = (0..<panes).map { _ in SavedTerminalPaneID() }
        let records = try ids.map {
            try SavedTerminalPaneRecord(
                id: $0, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: profile)
        }
        let root: SavedTerminalGroupNode =
            panes == 1
            ? .pane(ids[0])
            : .split(
                id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: .pane(ids[0]), second: .pane(ids[1]))
        let record = try SavedTerminalGroupRecord(
            id: SavedTerminalGroupID(), name: try #require(TerminalGroupName(name)),
            root: root, focusedPaneID: ids[0], panes: records)
        let snapshot = try session.terminal.insertStoppedSavedGroup(record)
        _ = try session.terminal.perform(.detachDeletedSavedLayout(record.id))
        session.revealTerminalGroup(snapshot.id)
        return snapshot.id
    }

    private func tabID(of groupID: TerminalGroupID, in session: WorkspaceSession) -> EditorTabID? {
        session.editorLayout.tab(matching: .terminalGroup(groupID: groupID))?.id
    }

    // MARK: Resume from a History row

    @Test("A resume drop uses the explicit board and puts the card on the drop point")
    func resumeDropOnExplicitBoard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let first = try await makeBoard(session, root: root, title: "First")
        let target = try #require(await session.canvas.create(title: "Target"))
        session.presentCanvasBoard(first)
        #expect(session.agentResumeEnsembleBoard === first)

        session.resumeAgentSessionInEnsemble(
            summary(projectPath: root.path), on: target, center: CGPoint(x: 500, y: 400))

        #expect(first.cards.isEmpty)
        let card = try #require(target.cards.first)
        #expect(card.rect.x == 180)
        #expect(card.rect.y == 190)
        #expect(card.rect.width == 640)
        #expect(card.rect.height == 420)
        #expect(target.selection == [card.id])
        #expect(target.terminalStartRequest == card.id)
        // One undoable board edit.
        target.performUndo()
        #expect(target.cards.isEmpty)
    }

    @Test("A resume drop keeps the folder rule and the full-board refusal")
    func resumeDropKeepsRules() async throws {
        let root = try makeRoot()
        let other = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)

        session.resumeAgentSessionInEnsemble(
            summary(projectPath: other.path), on: board, center: CGPoint(x: 10, y: 10))
        #expect(board.cards.isEmpty)
        #expect(session.isOpenFolderErrorPresented)
        session.isOpenFolderErrorPresented = false

        try board.edit { document in
            document.cards = (0..<CanvasLimits.cards).map { index in
                CanvasCard(title: "Card \(index)", content: .file(path: "file-\(index).swift"))
            }
        }
        session.resumeAgentSessionInEnsemble(
            summary(projectPath: root.path), on: board, center: CGPoint(x: 10, y: 10))
        #expect(board.cards.count == CanvasLimits.cards)
        #expect(session.isOpenFolderErrorPresented)
        #expect(session.openFolderErrorMessage.contains("full"))
    }

    // MARK: Terminal Group to board

    @Test("A stopped one-pane terminal moves to the board centre and stays parked and stopped")
    func terminalMoves() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session)
        #expect(tabID(of: groupID, in: session) != nil)

        #expect(
            session.moveTerminalGroupToEnsemble(
                groupID, board: board, center: CGPoint(x: 500, y: 400)))

        let card = try #require(board.cards.first)
        #expect(card.content == .terminal(groupID: groupID))
        #expect(card.title == "Build")
        #expect(card.rect.x == 180)
        #expect(card.rect.y == 190)
        #expect(board.focusedCardID == card.id)
        #expect(tabID(of: groupID, in: session) == nil)
        #expect(session.terminal.terminalGroup(groupID) != nil)
        #expect(session.parkedTerminalGroupIDs.contains(groupID))
        #expect(session.terminal.terminalGroup(groupID)?.panes.first?.status == .stopped)

        // Undo removes the card AND returns the group to an editor tab (the
        // user's 2026-10-19 decision amending the move amendment): the
        // process keeps running, but the group is no longer parked.
        // `undoAfterMoveRestoresTabAndRedoReparks` covers this in detail.
        board.performUndo()
        #expect(board.cards.isEmpty)
        #expect(session.terminal.terminalGroup(groupID) != nil)
        #expect(!session.parkedTerminalGroupIDs.contains(groupID))
        #expect(tabID(of: groupID, in: session) != nil)
    }

    @Test("A terminal that cannot move is refused with a message and its tab stays")
    func terminalRefusals() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)

        // More than one pane.
        let multi = try openStoppedGroup(session, panes: 2)
        #expect(!session.moveTerminalGroupToEnsemble(multi, board: board, center: nil))
        #expect(board.errorMessage == "Only a terminal with one pane can move to an Ensemble.")
        #expect(tabID(of: multi, in: session) != nil)
        #expect(board.cards.isEmpty)
        board.errorMessage = nil

        // Already on a loaded Ensemble.
        let single = try openStoppedGroup(session)
        try board.add(title: "Existing", content: .terminal(groupID: single))
        #expect(!session.moveTerminalGroupToEnsemble(single, board: board, center: nil))
        #expect(board.errorMessage == "This terminal is already on an Ensemble.")
        #expect(tabID(of: single, in: session) != nil)
        #expect(board.cards.count == 1)
        board.errorMessage = nil

        // A group that is not open in this window.
        #expect(!session.moveTerminalGroupToEnsemble(TerminalGroupID(), board: board, center: nil))
        #expect(board.errorMessage == "Drag a terminal onto an Ensemble in its own window.")
        board.errorMessage = nil

        // A full board.
        let other = try openStoppedGroup(session)
        try board.edit { document in
            document.cards = (0..<CanvasLimits.cards).map { index in
                CanvasCard(title: "Card \(index)", content: .file(path: "file-\(index).swift"))
            }
        }
        #expect(!session.moveTerminalGroupToEnsemble(other, board: board, center: nil))
        #expect(board.errorMessage == "This Ensemble is full. Remove a card, then try again.")
        #expect(tabID(of: other, in: session) != nil)
        #expect(board.cards.count == CanvasLimits.cards)
    }

    // MARK: Tab dropped on a visible board

    @Test("A terminal tab dropped in the centre moves onto the board")
    func centreDropMovesTerminal() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session)
        session.presentCanvasBoard(board)
        let tab = try #require(tabID(of: groupID, in: session))

        let handled = session.dropEditorTabOnCanvas(
            tab.rawValue.uuidString, boardID: board.id, at: CGPoint(x: 500, y: 400),
            surface: CGSize(width: 1_000, height: 800))

        #expect(handled)
        let card = try #require(board.cards.first)
        #expect(card.content == .terminal(groupID: groupID))
        #expect(card.rect.x == 180)
        #expect(card.rect.y == 190)
        #expect(tabID(of: groupID, in: session) == nil)
        #expect(session.selectedCanvas === board)
    }

    @Test("A tab dropped in an edge band splits the group under the board")
    func edgeDropSplitsGroup() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session)
        session.presentCanvasBoard(board)
        let tab = try #require(tabID(of: groupID, in: session))
        let before = session.editorLayout.groupIDs.count
        #expect(session.editorGroupShowingCanvas(board.id) != nil)

        let handled = session.dropEditorTabOnCanvas(
            tab.rawValue.uuidString, boardID: board.id, at: CGPoint(x: 10, y: 400),
            surface: CGSize(width: 1_000, height: 800))

        #expect(handled)
        #expect(board.cards.isEmpty)
        #expect(session.editorLayout.groupIDs.count == before + 1)
        #expect(tabID(of: groupID, in: session) != nil)
    }

    @Test("A tab from another window is refused with a message and changes nothing")
    func unknownTabIsRefused() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        session.presentCanvasBoard(board)
        let before = session.editorLayout.groupIDs.count

        let handled = session.dropEditorTabOnCanvas(
            UUID().uuidString, boardID: board.id, at: CGPoint(x: 500, y: 400),
            surface: CGSize(width: 1_000, height: 800))

        #expect(handled)
        #expect(board.errorMessage == "Drag a tab onto an Ensemble in its own window.")
        #expect(board.cards.isEmpty)
        #expect(session.editorLayout.groupIDs.count == before)
    }

    @Test("The menu move needs one pane and an Ensemble, and shows the Ensemble after")
    func menuMove() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let groupID = try openStoppedGroup(session)
        let multi = try openStoppedGroup(session, panes: 2)
        #expect(!session.canMoveTerminalGroupToEnsemble(groupID))

        let board = try await makeBoard(session, root: root)
        session.presentCanvasBoard(board)
        session.revealTerminalGroup(groupID)
        #expect(session.canMoveTerminalGroupToEnsemble(groupID))
        #expect(!session.canMoveTerminalGroupToEnsemble(multi))

        session.moveTerminalGroupToCurrentEnsemble(groupID)
        #expect(board.cards.map(\.content) == [.terminal(groupID: groupID)])
        #expect(tabID(of: groupID, in: session) == nil)
        #expect(session.selectedCanvas === board)
    }

    // MARK: Terminals-panel row dropped directly on the board

    @Test("A panel-dropped Terminal Group moves onto the board, by id alone")
    func panelDropMovesTerminal() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session)

        let handled = session.dropTerminalGroupOnCanvas(
            groupID, boardID: board.id, at: CGPoint(x: 500, y: 400))

        #expect(handled)
        let card = try #require(board.cards.first)
        #expect(card.content == .terminal(groupID: groupID))
        #expect(tabID(of: groupID, in: session) == nil)
        #expect(session.selectedCanvas === board)
    }

    @Test("A panel-dropped multi-pane group keeps the existing refusal message")
    func panelDropRefusesMultiplePanes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let multi = try openStoppedGroup(session, panes: 2)

        let handled = session.dropTerminalGroupOnCanvas(
            multi, boardID: board.id, at: CGPoint(x: 500, y: 400))

        #expect(handled)
        #expect(board.errorMessage == "Only a terminal with one pane can move to an Ensemble.")
        #expect(board.cards.isEmpty)
        #expect(tabID(of: multi, in: session) != nil)
    }

    // MARK: Undo returns the group to its tab; redo re-parks it

    @Test("A pane the user named keeps that name on the card and on the tab undo restores")
    func namedPaneKeepsItsNameOnTheBoard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session, name: "Terminal Group 1")
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.panes.first?.id)
        session.renameTerminalPane(paneID, to: "ONe")
        let named = try #require(session.terminal.terminalGroup(groupID))
        #expect(TerminalNaming.resolvedGroupTitle(named, agentTitle: nil) == "ONe")

        #expect(
            session.moveTerminalGroupToEnsemble(
                groupID, board: board, center: CGPoint(x: 500, y: 400)))
        let card = try #require(board.cards.first)
        // The card stores the automatic group name; it shows the pane's name.
        #expect(card.title == "Terminal Group 1")
        let pane = try #require(session.terminal.terminalGroup(groupID)?.panes.first)
        #expect(
            TerminalNaming.resolvedGroupTitle(
                storedName: card.title, paneUserName: pane.explicitUserName?.rawValue,
                agentTitle: nil) == "ONe")

        board.performUndo()
        #expect(tabID(of: groupID, in: session) != nil)
        let restored = try #require(session.terminal.terminalGroup(groupID))
        #expect(TerminalNaming.resolvedGroupTitle(restored, agentTitle: nil) == "ONe")
    }

    @Test("Undo after a move restores the tab to its source editor group; redo re-parks it")
    func undoAfterMoveRestoresTabAndRedoReparks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let board = try await makeBoard(session, root: root)
        let groupID = try openStoppedGroup(session)
        let tab = try #require(tabID(of: groupID, in: session))
        let sourceGroupID = try #require(session.editorLayout.group(containing: tab)?.id)

        #expect(
            session.moveTerminalGroupToEnsemble(
                groupID, board: board, center: CGPoint(x: 500, y: 400)))
        #expect(tabID(of: groupID, in: session) == nil)

        board.performUndo()
        #expect(board.cards.isEmpty)
        let restoredTab = try #require(tabID(of: groupID, in: session))
        #expect(session.editorLayout.group(containing: restoredTab)?.id == sourceGroupID)
        #expect(!session.parkedTerminalGroupIDs.contains(groupID))
        #expect(session.terminal.terminalGroup(groupID) != nil)

        board.performRedo()
        #expect(board.cards.map(\.content) == [.terminal(groupID: groupID)])
        #expect(tabID(of: groupID, in: session) == nil)
        #expect(session.parkedTerminalGroupIDs.contains(groupID))
    }
}
