import Foundation
import RafuCore
import Testing

@testable import RafuApp

// MARK: Doubles

/// Stands in for jr-4a's card implementation. It validates by one rule (a
/// "Bad" component is invalid), keeps every change one board undo step, and
/// records stream pushes by count and bytes only.
@MainActor
final class FakeGeneratedViewHost: GeneratedViewHost {
    private(set) var creates = 0
    private(set) var updates: [GeneratedViewChange] = []
    private(set) var handles: [FakeViewStreamHandle] = []

    static func summary(_ specJSON: String) -> Result<GeneratedViewSummary, GeneratedViewError> {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(specJSON.utf8))
                as? [String: Any],
            let elements = object["elements"] as? [String: Any]
        else { return .failure(.invalidSpec("spec: not an object")) }
        let types = elements.values.compactMap { ($0 as? [String: Any])?["type"] as? String }
        if types.contains("Bad") {
            return .failure(.invalidSpec("element b: unknown component type Bad"))
        }
        return .success(
            GeneratedViewSummary(
                elementCount: elements.count, types: Array(Set(types)).sorted(), warnings: 0))
    }

    static func view(_ specJSON: String, provenance: CanvasGeneratedViewProvenance)
        -> CanvasGeneratedView
    {
        CanvasGeneratedView(
            specJSON: specJSON, catalogVersion: RafuCatalog.version, provenance: provenance,
            state: nil)
    }

    func validate(specJSON: String) -> Result<GeneratedViewSummary, GeneratedViewError> {
        Self.summary(specJSON)
    }

    func create(
        specJSON: String, title: String, rect: CanvasRect,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) throws -> CanvasCardID {
        if case .failure(let error) = Self.summary(specJSON) { throw error }
        creates += 1
        let card = CanvasCard(
            title: title, rect: rect,
            content: .generatedView(Self.view(specJSON, provenance: provenance)))
        try board.edit { $0.cards.append(card) }
        return card.id
    }

    func update(
        _ card: CanvasCardID, change: GeneratedViewChange,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) async throws -> GeneratedViewSummary {
        guard let index = board.cards.firstIndex(where: { $0.id == card }),
            case .generatedView(var view) = board.cards[index].content
        else { throw GeneratedViewError.notAView }
        updates.append(change)
        switch change {
        case .spec(let text):
            let summary = try Self.summary(text).get()
            view.specJSON = text
            view.state = nil
            try board.edit { $0.cards[index].content = .generatedView(view) }
            return summary
        case .reset:
            return try Self.summary(view.specJSON).get()
        case .patches:
            throw GeneratedViewError.invalidSpec("patches are not supported by the double")
        }
    }

    func beginStreaming(
        title: String, rect: CanvasRect, provenance: CanvasGeneratedViewProvenance,
        on board: CanvasBoardState
    ) throws -> any GeneratedViewStreamHandle {
        let skeleton = #"{"elements":{"r":{"props":{},"type":"Skeleton"}},"root":"r"}"#
        let card = CanvasCard(
            title: title, rect: rect,
            content: .generatedView(Self.view(skeleton, provenance: provenance)))
        try board.edit { $0.cards.append(card) }
        let handle = FakeViewStreamHandle(
            cardID: card.id, title: title, rect: rect, provenance: provenance, board: board)
        handles.append(handle)
        return handle
    }
}

/// A skeleton card that collapses into one undo step on finish, and is undone
/// on cancel or on an invalid final spec.
@MainActor
final class FakeViewStreamHandle: GeneratedViewStreamHandle {
    let cardID: CanvasCardID
    let title: String
    private let rect: CanvasRect
    private let provenance: CanvasGeneratedViewProvenance
    private weak var board: CanvasBoardState?
    private(set) var pushes = 0
    private(set) var pushedBytes = 0
    private(set) var finished = false
    private(set) var cancelled = false

    init(
        cardID: CanvasCardID, title: String, rect: CanvasRect,
        provenance: CanvasGeneratedViewProvenance, board: CanvasBoardState
    ) {
        self.cardID = cardID
        self.title = title
        self.rect = rect
        self.provenance = provenance
        self.board = board
    }

    func push(_ argumentsDelta: String) {
        pushes += 1
        pushedBytes += argumentsDelta.utf8.count
    }

    func finish(specJSON: String) async -> Result<GeneratedViewSummary, GeneratedViewError> {
        finished = true
        board?.performUndo()
        let summary = FakeGeneratedViewHost.summary(specJSON)
        guard case .success = summary, let board else { return summary }
        let card = CanvasCard(
            id: cardID, title: title, rect: rect,
            content: .generatedView(FakeGeneratedViewHost.view(specJSON, provenance: provenance)))
        do {
            try board.edit { $0.cards.append(card) }
        } catch {
            return .failure(.capacity)
        }
        return summary
    }

    func cancel() {
        cancelled = true
        board?.performUndo()
    }
}

/// The voice session seen from the executor: one board, real undo ledger,
/// a view host double, and the stream handle map the session keeps.
@MainActor
final class FakeVoiceToolHost: VoiceToolHost {
    let callerID = UUID()
    let personaName = "Rafu"
    let voicePreferences: VoicePreferences
    let undoLedger = VoiceUndoLedger()
    let session: WorkspaceSession
    let board: CanvasBoardState
    var generatedViewHost: (any GeneratedViewHost)?
    var streams: [String: any GeneratedViewStreamHandle] = [:]
    private(set) var boardEffects: [String] = []

    init(
        session: WorkspaceSession, board: CanvasBoardState, viewHost: (any GeneratedViewHost)?,
        suite: String
    ) {
        self.session = session
        self.board = board
        self.generatedViewHost = viewHost
        self.voicePreferences = VoicePreferences(suiteName: suite)
    }

    func voiceTarget() -> VoiceTarget? { VoiceTarget(session: session, board: board) }
    func voiceWorkspaces() -> [WorkspaceSession] { [session] }
    func voiceStatus() -> VoiceJSON { .object([:]) }
    func latchFromTool() {}
    func confirm(_ request: VoiceConfirmRequest) async -> VoiceConfirmAnswer { .allowOnce }
    func resolveConfirm(_ answer: VoiceConfirmAnswer) -> VoiceConfirmResolution { .nothingPending }
    func hasSessionGrant(_ key: String) -> Bool { false }
    func grantForSession(_ key: String) {}
    func noteBoardEffect(_ title: String, detail: String) { boardEffects.append(detail) }
    func viewStreamHandle(for callID: String) -> (any GeneratedViewStreamHandle)? {
        streams[callID]
    }
    func takeViewStreamHandle(for callID: String) { streams.removeValue(forKey: callID) }
}

/// Removes the fixture's temporary workspace.
private final class ShowViewScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-show-view-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
private struct ShowViewFixture {
    let workspace: WorkspaceSession
    let board: CanvasBoardState
    let viewHost = FakeGeneratedViewHost()
    let host: FakeVoiceToolHost
    let suite: String
    private let scratch = ShowViewScratchFolder()

    init(mode: CanvasAgentControlMode = .ask, installsHost: Bool = true) async throws {
        let scratch = scratch
        suite = TestDefaultsSuite.name("dev.rafu.show-view-tests")
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.show-view-restoration"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "Show view test"))
        try board.add(title: "Plan", content: .note(snapshot: "# Plan\n"))
        board.setAgentControlMode(mode)
        self.workspace = workspace
        self.board = board
        host = FakeVoiceToolHost(
            session: workspace, board: board, viewHost: nil, suite: suite)
        if installsHost { host.generatedViewHost = viewHost }
    }

    func run(_ arguments: String, callID: String? = nil) async -> VoiceToolOutcome {
        await VoiceToolExecutor.run(
            name: "show_view", argumentsJSON: arguments, callID: callID, host: host)
    }

    var views: [CanvasCard] {
        board.cards.filter {
            if case .generatedView = $0.content { return true }
            return false
        }
    }
}

private let tableArguments =
    #"{"title":"Failing tests","root":"card","elements":{"card":{"type":"Card","props":{"title":"Secret words"},"children":["t"]},"t":{"type":"Table","props":{"rows":{"$state":"/rows"}},"children":[]}},"state":{"rows":[{"suite":"private"}]}}"#

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: Executor

@Suite("Voice show_view")
@MainActor
struct VoiceShowViewTests {
    @Test("Off refuses with the Off message and changes nothing")
    func offRefuses() async throws {
        let fixture = try await ShowViewFixture(mode: .off)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(tableArguments)
        #expect(outcome.isError)
        #expect(outcome.summary == "agent_control_off")
        #expect(outcome.output.contains("agent_control_off"))
        #expect(fixture.views.isEmpty)
        #expect(fixture.viewHost.creates == 0)
    }

    @Test("Ask runs at once: one card, one voice undo step, an Undo notice")
    func askRunsWithNotice() async throws {
        let fixture = try await ShowViewFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(tableArguments)
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(outcome.summary == "2 elements")
        let output = try json(outcome.output)
        #expect(output["status"] as? String == "ok")
        #expect(output["elements"] as? Int == 2)
        #expect(output["message"] as? String == "Showing Failing tests.")
        let card = try #require(fixture.views.first)
        #expect(output["node_id"] as? String == card.id.rawValue.uuidString)
        #expect(card.title == "Failing tests")
        guard case .generatedView(let view) = card.content else {
            Issue.record("Expected a view")
            return
        }
        #expect(view.provenance.provider == "voice")
        #expect(view.provenance.admission == "voice")
        #expect(!view.specJSON.contains("Failing tests"))
        #expect(view.specJSON.hasPrefix(#"{"elements":"#))
        let notice = try #require(fixture.board.notice)
        #expect(notice.message == "Rafu (voice) showed Failing tests")
        #expect(notice.action?.title == "Undo")
        #expect(fixture.host.boardEffects == ["1 added"])
        #expect(fixture.host.undoLedger.undo(on: fixture.board))
        #expect(fixture.views.isEmpty)
        #expect(!fixture.host.undoLedger.undo(on: fixture.board))
    }

    @Test("Allow runs; the timeline summary never holds the title or a prop")
    func allowRuns() async throws {
        let fixture = try await ShowViewFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(tableArguments)
        #expect(!outcome.isError)
        #expect(fixture.views.count == 1)
        #expect(!outcome.summary.contains("Failing"))
        #expect(!outcome.summary.contains("Secret"))
    }

    @Test("A spec nested under spec is accepted")
    func nestedSpecAlias() async throws {
        let fixture = try await ShowViewFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(
            #"{"title":"Nested","spec":{"root":"t","elements":{"t":{"type":"Text","props":{"text":"x"},"children":[]}}}}"#
        )
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(fixture.views.first?.title == "Nested")
    }

    @Test("An invalid spec returns the validator's message and leaves no card")
    func invalidSpec() async throws {
        let fixture = try await ShowViewFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(
            #"{"title":"Broken","root":"b","elements":{"b":{"type":"Bad","props":{},"children":[]}}}"#
        )
        #expect(outcome.summary == "invalid_spec")
        #expect(outcome.output.contains("unknown component type Bad"))
        #expect(fixture.views.isEmpty)
    }

    @Test("Missing root or elements, and unknown top-level keys, are refused before the host")
    func shapeRefusals() async throws {
        let fixture = try await ShowViewFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        #expect(await fixture.run(#"{"title":"Empty"}"#).summary == "invalid_spec")
        #expect(
            await fixture.run(
                #"{"title":"X","root":"t","elements":{"t":{"type":"Text"}},"extra":1}"#
            ).summary == "invalid_spec")
        #expect(
            await fixture.run(
                #"{"title":"X","root":"t","elements":{"t":{"type":"Text"}},"state":3}"#
            )
            .summary == "invalid_spec")
        #expect(
            await fixture.run(#"{"title":7,"root":"t","elements":{}}"#).summary
                == "invalid_arguments")
        #expect(fixture.viewHost.creates == 0)
    }

    @Test("No view host answers unavailable")
    func unavailable() async throws {
        let fixture = try await ShowViewFixture(mode: .allow, installsHost: false)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run(tableArguments)
        #expect(outcome.summary == "unavailable")
        #expect(outcome.output.contains(GeneratedViewCopy.unavailable))
    }

    @Test("node replaces an existing view's spec; reset restores its state")
    func updateAndReset() async throws {
        let fixture = try await ShowViewFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = await fixture.run(tableArguments)
        let card = try #require(fixture.views.first)
        let update = await fixture.run(
            #"{"title":"Failing tests","node":"Failing tests","root":"t","elements":{"t":{"type":"Text","props":{"text":"y"},"children":[]}}}"#
        )
        #expect(!update.isError, Comment(rawValue: update.output))
        #expect(update.summary == "1 element")
        #expect(fixture.views.count == 1)
        #expect(fixture.viewHost.updates.count == 1)
        #expect(fixture.board.notice?.message == "Rafu (voice) changed Failing tests")

        let reset = await fixture.run(
            #"{"title":"Failing tests","node":"\#(card.id.rawValue.uuidString)","reset":true,"root":"","elements":{}}"#
        )
        #expect(!reset.isError, Comment(rawValue: reset.output))
        #expect(reset.summary == "reset")
        #expect(fixture.viewHost.updates.last == .reset)

        let noNode = await fixture.run(#"{"title":"X","reset":true}"#)
        #expect(noNode.summary == "invalid_arguments")
        let notAView = await fixture.run(
            #"{"title":"X","node":"Plan","root":"t","elements":{"t":{"type":"Text"}}}"#)
        #expect(notAView.isError)
    }

    @Test("Streaming: the skeleton finishes into one card and one undo step")
    func streamingFinish() async throws {
        let fixture = try await ShowViewFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let handle = try #require(
            VoiceToolExecutor.beginShowView(title: "Failing tests", host: fixture.host)
                as? FakeViewStreamHandle)
        #expect(fixture.views.count == 1)
        for piece in [#"{"title":"Failing tests","#, #""root":"card","#, #""elements":{}"#] {
            handle.push(piece)
        }
        fixture.host.streams["call_1"] = handle
        let outcome = await fixture.run(tableArguments, callID: "call_1")
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(handle.pushes == 3)
        #expect(handle.finished)
        #expect(!handle.cancelled)
        #expect(fixture.host.streams.isEmpty)
        #expect(fixture.views.count == 1)
        #expect(fixture.views.first?.id == handle.cardID)
        #expect(fixture.viewHost.creates == 0)
        #expect(fixture.host.boardEffects == ["1 added"])
        #expect(fixture.host.undoLedger.undo(on: fixture.board))
        #expect(fixture.views.isEmpty)
    }

    @Test("Streaming: a refused or invalid call leaves no skeleton")
    func streamingCancel() async throws {
        let fixture = try await ShowViewFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let first = try #require(
            VoiceToolExecutor.beginShowView(title: "View", host: fixture.host)
                as? FakeViewStreamHandle)
        fixture.host.streams["call_1"] = first
        let shape = await fixture.run(#"{"title":"Empty"}"#, callID: "call_1")
        #expect(shape.summary == "invalid_spec")
        #expect(first.cancelled)
        #expect(fixture.views.isEmpty)

        let second = try #require(
            VoiceToolExecutor.beginShowView(title: "View", host: fixture.host)
                as? FakeViewStreamHandle)
        fixture.host.streams["call_2"] = second
        let invalid = await fixture.run(
            #"{"title":"B","root":"b","elements":{"b":{"type":"Bad","props":{},"children":[]}}}"#,
            callID: "call_2")
        #expect(invalid.summary == "invalid_spec")
        #expect(second.finished)
        #expect(fixture.views.isEmpty)
    }

    @Test("Streaming start does nothing in Off or without a host")
    func streamingStartRefusals() async throws {
        let off = try await ShowViewFixture(mode: .off)
        defer { TestDefaultsSuite.remove(off.suite) }
        #expect(VoiceToolExecutor.beginShowView(title: "View", host: off.host) == nil)
        #expect(off.views.isEmpty)
        let bare = try await ShowViewFixture(mode: .allow, installsHost: false)
        defer { TestDefaultsSuite.remove(bare.suite) }
        #expect(VoiceToolExecutor.beginShowView(title: "View", host: bare.host) == nil)
    }

    @Test("The streamed title is read only before the spec keys")
    func streamTitle() {
        #expect(
            VoiceViewStreamTitle.title(in: #"{"title":"Tests by suite","root""#) == "Tests by suite"
        )
        #expect(VoiceViewStreamTitle.title(in: #"{ "title" : "Esc \"q\"" }"#) == #"Esc "q""#)
        #expect(VoiceViewStreamTitle.title(in: #"{"title":"Unfinished"#) == nil)
        #expect(
            VoiceViewStreamTitle.title(in: #"{"root":"c","elements":{"c":{"props":{"title":"X"}}"#)
                == nil)
        #expect(VoiceViewStreamTitle.isPastTitle(#"{"root":"#))
        #expect(!VoiceViewStreamTitle.isPastTitle(#"{"title":"A"#))
    }
}

// MARK: Session streaming

@Suite("Voice show_view streaming")
@MainActor
struct VoiceShowViewStreamingTests {
    @Test("Started, two deltas, done: the skeleton gets pushes before the call finishes it")
    func sessionStreams() async throws {
        let scratch = ShowViewScratchFolder()
        let suite = TestDefaultsSuite.name("dev.rafu.show-view-session")
        defer { TestDefaultsSuite.remove(suite) }
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.show-view-session-restore"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "Streaming"))
        board.setAgentControlMode(.ask)
        let viewHost = FakeGeneratedViewHost()
        let transport = ScriptedLiveTransport()
        let audio = FakeVoiceAudio()
        var dependencies = VoiceSession.Dependencies(
            makeTransport: { _ in transport }, openAIKey: { "test-key" },
            requestMicrophone: { true }, makeAudio: { (audio, audio) },
            preferences: VoicePreferences(suiteName: suite), costSuiteName: suite)
        dependencies.target = { VoiceTarget(session: workspace, board: board) }
        dependencies.workspaces = { [workspace] }
        dependencies.runsClock = false
        dependencies.startTimeout = .seconds(5)
        dependencies.closeTimeout = .seconds(5)
        dependencies.viewHost = { viewHost }
        let voice = VoiceSession(dependencies: dependencies)
        voice.toggleLatched()
        try await waitUntil { voice.blobState == .listeningLatched }

        transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","name":"show_view","arguments":""}}}"#
        )
        transport.push(
            #"{"type":"response.event","event":{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"title\":\"Failing tests\","}}"#
        )
        transport.push(
            #"{"type":"response.event","event":{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\"root\":\"t\",\"elements\":{\"t\":{\"type\":\"Text\",\"props\":{\"text\":\"x\"},\"children\":[]}}}"}}"#
        )
        try await waitUntil { viewHost.handles.first?.pushes == 2 }
        let handle = try #require(viewHost.handles.first)
        #expect(handle.title == "Failing tests")
        #expect(!handle.finished)
        #expect(board.cards.count == 1)

        transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"show_view","arguments":"{\"title\":\"Failing tests\",\"root\":\"t\",\"elements\":{\"t\":{\"type\":\"Text\",\"props\":{\"text\":\"x\"},\"children\":[]}}}"}}}"#
        )
        transport.push(#"{"type":"response.event","event":{"type":"response.completed"}}"#)
        try await waitUntil { !transport.sent(type: "response.create").isEmpty }
        #expect(handle.finished)
        #expect(!handle.cancelled)
        #expect(viewHost.creates == 0)
        #expect(board.cards.count == 1)
        let row = try #require(voice.timeline.rows(lane: .tool).first)
        #expect(row.title == "show_view")
        #expect(row.detail.hasPrefix("1 element; deltas: 2, "))
        #expect(!row.detail.contains("Failing"))
        await voice.close()
    }

    @Test("Without deltas the call creates the card on completion and reports zero deltas")
    func sessionWithoutDeltas() async throws {
        let scratch = ShowViewScratchFolder()
        let suite = TestDefaultsSuite.name("dev.rafu.show-view-session")
        defer { TestDefaultsSuite.remove(suite) }
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.show-view-session-restore"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "No deltas"))
        board.setAgentControlMode(.allow)
        let viewHost = FakeGeneratedViewHost()
        let transport = ScriptedLiveTransport()
        let audio = FakeVoiceAudio()
        var dependencies = VoiceSession.Dependencies(
            makeTransport: { _ in transport }, openAIKey: { "test-key" },
            requestMicrophone: { true }, makeAudio: { (audio, audio) },
            preferences: VoicePreferences(suiteName: suite), costSuiteName: suite)
        dependencies.target = { VoiceTarget(session: workspace, board: board) }
        dependencies.workspaces = { [workspace] }
        dependencies.runsClock = false
        dependencies.startTimeout = .seconds(5)
        dependencies.closeTimeout = .seconds(5)
        dependencies.viewHost = { viewHost }
        let voice = VoiceSession(dependencies: dependencies)
        voice.toggleLatched()
        try await waitUntil { voice.blobState == .listeningLatched }

        // Today's GPT-Live shape: only the finished call arrives.
        transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_2","name":"show_view","arguments":"{\"title\":\"Coverage\",\"root\":\"t\",\"elements\":{\"t\":{\"type\":\"Text\",\"props\":{\"text\":\"x\"},\"children\":[]}}}"}}}"#
        )
        transport.push(#"{"type":"response.event","event":{"type":"response.completed"}}"#)
        try await waitUntil { !transport.sent(type: "response.create").isEmpty }
        let row = try #require(voice.timeline.rows(lane: .tool).first)
        #expect(row.detail == "1 element; deltas: 0")
        #expect(viewHost.handles.isEmpty)
        #expect(viewHost.creates == 1)
        #expect(board.cards.count == 1)

        // A started item that never finishes is cancelled when the response ends.
        transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.added","item":{"id":"fc_9","type":"function_call","name":"show_view"}}}"#
        )
        transport.push(
            #"{"type":"response.event","event":{"type":"response.function_call_arguments.delta","item_id":"fc_9","delta":"{\"root\":\"t\","}}"#
        )
        try await waitUntil { viewHost.handles.count == 1 }
        #expect(board.cards.count == 2)
        transport.push(#"{"type":"response.event","event":{"type":"response.completed"}}"#)
        try await waitUntil { viewHost.handles.first?.cancelled == true }
        #expect(board.cards.count == 1)
        await voice.close()
    }

    @Test("Closing the session cancels a skeleton that never finished")
    func closeCancels() async throws {
        let scratch = ShowViewScratchFolder()
        let suite = TestDefaultsSuite.name("dev.rafu.show-view-session")
        defer { TestDefaultsSuite.remove(suite) }
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.show-view-session-restore"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "Close"))
        board.setAgentControlMode(.allow)
        let viewHost = FakeGeneratedViewHost()
        let transport = ScriptedLiveTransport()
        let audio = FakeVoiceAudio()
        var dependencies = VoiceSession.Dependencies(
            makeTransport: { _ in transport }, openAIKey: { "test-key" },
            requestMicrophone: { true }, makeAudio: { (audio, audio) },
            preferences: VoicePreferences(suiteName: suite), costSuiteName: suite)
        dependencies.target = { VoiceTarget(session: workspace, board: board) }
        dependencies.workspaces = { [workspace] }
        dependencies.runsClock = false
        dependencies.startTimeout = .seconds(5)
        dependencies.closeTimeout = .seconds(5)
        dependencies.viewHost = { viewHost }
        let voice = VoiceSession(dependencies: dependencies)
        voice.toggleLatched()
        try await waitUntil { voice.blobState == .listeningLatched }
        transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"show_view"}}}"#
        )
        transport.push(
            #"{"type":"response.event","event":{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"title\":\"Half\",\"root\":"}}"#
        )
        try await waitUntil { board.cards.count == 1 }
        await voice.close()
        #expect(viewHost.handles.first?.cancelled == true)
        #expect(board.cards.isEmpty)
    }
}

/// Bounded: yields until `condition` holds.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting")
    throw CancellationError()
}
