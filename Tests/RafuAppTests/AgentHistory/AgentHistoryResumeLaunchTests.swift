import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Agent History resume launch")
struct AgentHistoryResumeLaunchTests {
    private let claude = AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123")
    private let codex = AgentHistorySessionKey(provider: .codex, sessionID: "019a_x.y")

    @Test("Resume in Terminal starts the CLI itself with the resume arguments")
    func specificationPerProvider() throws {
        let folder = URL(fileURLWithPath: "/Users/me/project", isDirectory: true)
        let claudeSpec = try #require(
            AgentHistoryResumeLaunch.specification(
                for: claude, executableURL: URL(fileURLWithPath: "/opt/tools/bin/claude"),
                folder: folder))
        #expect(claudeSpec.executableURL.path == "/opt/tools/bin/claude")
        #expect(claudeSpec.arguments == ["--resume", "abc-123"])
        #expect(claudeSpec.currentDirectoryPath == "/Users/me/project")
        #expect(claudeSpec.agentProvider == .claudeCode)
        #expect(claudeSpec.roleBadge == "Claude Code")
        #expect(claudeSpec.environment.keys.sorted() == [RafuConductorEnvironment.path])
        #expect(
            claudeSpec.environment[RafuConductorEnvironment.path]?.hasPrefix("/opt/tools/bin:")
                == true)

        let codexSpec = try #require(
            AgentHistoryResumeLaunch.specification(
                for: codex, executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
                folder: folder))
        #expect(codexSpec.arguments == ["resume", "019a_x.y"])
        #expect(codexSpec.agentProvider == .codex)
        // The resolved launch is an argument array: no shell, no quoting.
        let launch = codexSpec.resolvedLaunch()
        #expect(launch.executable == "/usr/local/bin/codex")
        #expect(launch.arguments == ["resume", "019a_x.y"])
    }

    @Test("An unsafe session id or a relative executable starts nothing")
    func unsafeInputsAreRefused() throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for bad in ["", "-rf", "a b", "a;rm", "$(x)", "a\nb"] {
            let key = AgentHistorySessionKey(provider: .claudeCode, sessionID: bad)
            #expect(AgentHistoryResumeLaunch.processArguments(for: key) == nil)
            #expect(
                AgentHistoryResumeLaunch.specification(
                    for: key, executableURL: URL(fileURLWithPath: "/usr/bin/claude"),
                    folder: folder) == nil)
        }
        let remote = try #require(URL(string: "https://example.com/claude"))
        #expect(
            AgentHistoryResumeLaunch.specification(
                for: claude, executableURL: remote, folder: folder) == nil)
    }

    @Test("A missing CLI names the exact command to run")
    func missingCLIMessage() {
        let message = AgentHistoryResumeLaunch.missingCLIMessage(for: claude, folderName: "rafu")
        #expect(message.contains("Claude Code"))
        #expect(message.contains("“rafu”"))
        #expect(message.hasSuffix("run: claude --resume abc-123"))
        let codexMessage = AgentHistoryResumeLaunch.missingCLIMessage(
            for: codex, folderName: "app")
        #expect(codexMessage.hasSuffix("run: codex resume 019a_x.y"))
    }

    @Test("The child search path puts the executable folder first, once")
    func childSearchPath() {
        let curated = "/usr/local/bin:/usr/bin:/bin"
        #expect(
            AgentHistoryResumeLaunch.childSearchPath(
                prependingParentOf: URL(fileURLWithPath: "/opt/node/bin/claude"),
                curated: curated) == "/opt/node/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(
            AgentHistoryResumeLaunch.childSearchPath(
                prependingParentOf: URL(fileURLWithPath: "/usr/bin/codex"), curated: curated)
                == curated)
    }

    @Test("An Ensemble plan starts in the workspace-relative session folder")
    func ensemblePlan() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "packages/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try #require(
            AgentHistoryResumeLaunch.ensemblePlan(
                for: claude, sessionTitle: "Fix the\nparser", folder: nested, workspaceRoot: root))
        #expect(plan.startingFolder.rawValue == "packages/app")
        #expect(plan.line == "claude --resume abc-123")
        #expect(plan.title == "Fix the parser")

        let atRoot = try #require(
            AgentHistoryResumeLaunch.ensemblePlan(
                for: codex, sessionTitle: "  ", folder: root, workspaceRoot: root))
        #expect(atRoot.startingFolder == .root)
        #expect(atRoot.title == "Codex")
        #expect(atRoot.line == "codex resume 019a_x.y")

        let outside = FileManager.default.temporaryDirectory
        #expect(
            AgentHistoryResumeLaunch.ensemblePlan(
                for: claude, sessionTitle: "x", folder: outside, workspaceRoot: root) == nil)
        let unsafe = AgentHistorySessionKey(provider: .codex, sessionID: "a;b")
        #expect(
            AgentHistoryResumeLaunch.ensemblePlan(
                for: unsafe, sessionTitle: "x", folder: root, workspaceRoot: root) == nil)
    }

    @Test("A long session title becomes a valid node and terminal name")
    func nodeTitleIsBounded() {
        let long = String(repeating: "word ", count: 40)
        let title = AgentHistoryResumeLaunch.nodeTitle(long, provider: .claudeCode)
        #expect(title.count <= 72)
        #expect(title.hasSuffix("…"))
        #expect(TerminalGroupName(title) != nil)
        #expect(CanvasDocument.validTitle(title))
    }
}

@Suite("Agent History Resume in Ensemble")
@MainActor
struct AgentHistoryResumeInEnsembleTests {
    private func makeSession(root: URL) -> WorkspaceSession {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.agent-resume-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "state"))))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Resume", location: .local(.init(path: root.path)))
        return session
    }

    private func summary(projectPath: String) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            key: AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123"),
            title: "Fix the parser", projectPath: projectPath, startedAt: nil, updatedAt: nil,
            gitBranch: "main", messageCount: 2, isMessageCountEstimated: false,
            fileURL: URL(fileURLWithPath: "/tmp/rafu-missing-\(UUID().uuidString).jsonl"),
            fileSize: 10, modificationDate: Date(timeIntervalSince1970: 0))
    }

    @Test("The resume node is a stopped shell in the session folder, selected and starting")
    func addsTerminalNode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        #expect(await session.canvas.configure(root: root))
        let board = try #require(await session.canvas.create(title: "Work"))
        session.presentCanvasBoard(board)
        #expect(session.agentResumeEnsembleBoard === board)

        let plan = try #require(
            AgentHistoryResumeLaunch.ensemblePlan(
                for: AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123"),
                sessionTitle: "Fix the parser", folder: nested, workspaceRoot: root))
        let cardID = try #require(session.addAgentResumeNode(plan, to: board))
        let card = try #require(board.cards.first { $0.id == cardID })
        #expect(card.title == "Fix the parser")
        guard case .terminal(let groupID) = card.content else {
            Issue.record("Expected a terminal card")
            return
        }
        let pane = try #require(session.terminal.terminalGroup(groupID)?.panes.first)
        #expect(pane.runtimeKind == .ordinaryShell)
        #expect(pane.status == .stopped)
        #expect(pane.launchProfile?.startingFolder.rawValue == "app")
        #expect(board.selection == [cardID])
        #expect(board.focusedCardID == cardID)
        #expect(board.terminalStartRequest == cardID)
        // Nothing runs until the card starts its shell.
        #expect(session.terminal.sessions.isEmpty)
        // One undoable board edit.
        board.performUndo()
        #expect(!board.cards.contains { $0.id == cardID })
    }

    @Test("With no Ensemble open, Resume in Ensemble asks to create one")
    func asksForNewEnsemble() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        #expect(session.agentResumeEnsembleBoard == nil)
        session.resumeAgentSessionInEnsemble(summary(projectPath: root.path))
        let plan = try #require(session.agentEnsembleResumeAwaitingConfirmation)
        #expect(plan.line == "claude --resume abc-123")
        #expect(plan.startingFolder == .root)
        #expect(!session.isOpenFolderErrorPresented)
    }

    @Test("A folder outside the workspace is refused with a message")
    func outsideFolderIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let session = makeSession(root: root)
        session.resumeAgentSessionInEnsemble(summary(projectPath: other.path))
        #expect(session.agentEnsembleResumeAwaitingConfirmation == nil)
        #expect(session.isOpenFolderErrorPresented)
    }
}
