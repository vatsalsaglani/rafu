import Foundation
import Observation
import RafuCore

/// Live capability state is window/terminal scoped and is never saved in a board.
@Observable @MainActor
final class CanvasLiveBridge {
    static let shared = CanvasLiveBridge()
    typealias Location = (session: WorkspaceSession, board: CanvasBoardState, card: CanvasCard)
    @ObservationIgnored private let resolveLocation: (@MainActor (UUID) -> Location?)?
    @ObservationIgnored private let now: @MainActor () -> Date

    init(
        location: (@MainActor (UUID) -> Location?)? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        resolveLocation = location
        self.now = now
    }
    private enum SuspensionReason: String {
        case sessionChanged
        case transportLost

        var status: String {
            switch self {
            case .sessionChanged: "Session changed. Restart this terminal to reconnect."
            case .transportLost: "Connection lost. Restart this terminal to reconnect."
            }
        }

        var notice: String {
            switch self {
            case .sessionChanged: "Codex changed sessions. Restart its terminal to reconnect."
            case .transportLost:
                "Codex lost its terminal connection. Restart its terminal to reconnect."
            }
        }
    }

    private struct Endpoint {
        weak var controller: WorkspaceTerminalController?
        let generation: Int
        var clientID: String?
        var provider: String?
        var threadID: String?
        var endpoint: String?
        var executable: String?
        var lastSeen = Date()
        var inbox: [CanvasBridgeMessage] = []
        var suspended = false
        var suspensionReason: SuspensionReason = .sessionChanged
    }
    @ObservationIgnored private var endpoints: [String: Endpoint] = [:]
    @ObservationIgnored private var directories: [UUID: URL] = [:]
    private struct SessionLinkPermission: Hashable {
        let board: ObjectIdentifier
        let edge: UUID
    }
    private final class PermissionBoard {
        weak var board: CanvasBoardState?
        init(_ board: CanvasBoardState) { self.board = board }
    }
    @ObservationIgnored private var enabledEdges: [SessionLinkPermission: PermissionBoard] = [:]
    private struct Delivery {
        let sourceToken: String
        let targetToken: String
        let task: Task<Void, Error>
    }
    @ObservationIgnored private var deliveries: [UUID: Delivery] = [:]
    @ObservationIgnored private var sentAt: [Date] = []
    /// Per-link runtime state for the redesigned edges. Like the permission set
    /// it is window scoped and never saved; it holds counts and a refusal
    /// reason, never message bodies.
    private struct LinkRuntime {
        weak var board: CanvasBoardState?
        var activity = CanvasLinkActivity()
        var failure: String?
    }
    @ObservationIgnored private var linkRuntime: [SessionLinkPermission: LinkRuntime] = [:]
    private(set) var revision = 0
    /// Changes when a message is accepted on any link (badge count, dot).
    private(set) var activityRevision = 0
    /// The latest accepted message: connection and direction only, no body.
    private(set) var lastMessageEvent: CanvasLinkMessageEvent?
    private(set) var notice: String?

    func prepare(
        _ controller: WorkspaceTerminalController,
        isCurrent: @MainActor () -> Bool
    ) async -> CanvasTerminalBootstrap? {
        guard location(of: controller.id) != nil, isCurrent(), !Task.isCancelled else { return nil }
        let generation = controller.generation
        let token = UUID().uuidString + UUID().uuidString
        let shellPath = controller.shell.path
        let loginArguments = controller.shell.loginArguments
        let cliURL = CLIInstaller().source
        let socketURL = LauncherIPCSocketPath.resolve()
        do {
            let launch = try await CanvasTerminalBootstrap.prepare(
                shellPath: shellPath, loginArguments: loginArguments,
                token: token, cliURL: cliURL, socketURL: socketURL)
            guard !Task.isCancelled, controller.generation == generation,
                location(of: controller.id) != nil, isCurrent()
            else {
                Task.detached { try? FileManager.default.removeItem(at: launch.directory) }
                return nil
            }
            install(controller: controller, token: token)
            directories[controller.id] = launch.directory
            revision &+= 1
            return launch
        } catch {
            guard !Task.isCancelled, controller.generation == generation, isCurrent() else {
                return nil
            }
            notice = "Session bridge unavailable. Use a new zsh or bash Canvas terminal."
            revision &+= 1
            return nil
        }
    }

    /// Installs one private terminal capability without starting a process.
    func install(controller: WorkspaceTerminalController, token: String) {
        endpoints = endpoints.filter { $0.value.controller?.id != controller.id }
        endpoints[token] = Endpoint(
            controller: controller, generation: controller.generation, lastSeen: now())
        revision &+= 1
    }

    func remove(_ controller: WorkspaceTerminalController) {
        let tokens = Set(
            endpoints.compactMap { $0.value.controller?.id == controller.id ? $0.key : nil })
        for delivery in deliveries.values
        where tokens.contains(delivery.sourceToken) || tokens.contains(delivery.targetToken) {
            delivery.task.cancel()
        }
        endpoints = endpoints.filter { $0.value.controller?.id != controller.id }
        if let directory = directories.removeValue(forKey: controller.id) {
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
        revision &+= 1
    }

    func enable(_ edge: UUID, in board: CanvasBoardState) {
        // Weak identity prevents a later board from inheriting a recycled object address.
        enabledEdges = enabledEdges.filter { $0.value.board != nil }
        linkRuntime = linkRuntime.filter { $0.value.board != nil }
        let key = SessionLinkPermission(board: ObjectIdentifier(board), edge: edge)
        enabledEdges[key] = PermissionBoard(board)
        linkRuntime[key]?.failure = nil
        revision &+= 1
    }
    func disable(_ edge: UUID, in board: CanvasBoardState) {
        let key = SessionLinkPermission(board: ObjectIdentifier(board), edge: edge)
        enabledEdges.removeValue(forKey: key)
        linkRuntime[key]?.failure = nil
        revision &+= 1
    }
    func isEnabled(_ edge: UUID, in board: CanvasBoardState) -> Bool {
        _ = revision
        return enabledEdges[SessionLinkPermission(board: ObjectIdentifier(board), edge: edge)]?
            .board === board
    }

    // MARK: Per-link state, pause and resume (review 7.6)

    /// A new message link starts Paused: nothing calls `resume` for it until the
    /// user chooses to. `pause` and `resume` are the per-link forms of
    /// `disable` and `enable`.
    func pause(_ edge: UUID, in board: CanvasBoardState) { disable(edge, in: board) }
    func resume(_ edge: UUID, in board: CanvasBoardState) { enable(edge, in: board) }

    func pauseAll(in board: CanvasBoardState) {
        for edge in board.connections where edge.behavior == .session {
            disable(edge.id, in: board)
        }
    }

    func resumeAll(in board: CanvasBoardState) {
        for edge in board.connections where edge.behavior == .session {
            enable(edge.id, in: board)
        }
    }

    /// States of every message link on `board`, computed in one pass over the
    /// terminal capabilities. It only reads; it never changes observed state.
    func linkStates(in board: CanvasBoardState) -> [UUID: CanvasLinkState] {
        _ = revision
        let messageLinks = board.connections.filter { $0.behavior == .session }
        guard !messageLinks.isEmpty else { return [:] }
        let statuses = endpointStatuses(in: board)
        var result: [UUID: CanvasLinkState] = [:]
        for edge in messageLinks {
            let key = SessionLinkPermission(board: ObjectIdentifier(board), edge: edge.id)
            result[edge.id] = CanvasLinkStateMapper.resolve(
                isEnabled: isEnabled(edge.id, in: board),
                from: statuses[edge.from] ?? .missing, to: statuses[edge.to] ?? .missing,
                failure: linkRuntime[key]?.failure)
        }
        return result
    }

    func linkState(of edge: CanvasConnection, in board: CanvasBoardState) -> CanvasLinkState {
        linkStates(in: board)[edge.id] ?? .paused
    }

    func activity(of edge: UUID, in board: CanvasBoardState) -> CanvasLinkActivity {
        _ = activityRevision
        let key = SessionLinkPermission(board: ObjectIdentifier(board), edge: edge)
        guard let runtime = linkRuntime[key], runtime.board === board else {
            return CanvasLinkActivity()
        }
        return runtime.activity
    }

    static var burstPolicy: CanvasBurstPolicy {
        CanvasBurstPolicy(
            limit: RafuMotion.messageBurstLimit, window: RafuMotion.messageBurstWindow,
            travel: RafuMotion.messageTravel)
    }

    private func endpointStatuses(in board: CanvasBoardState) -> [CanvasCardID:
        CanvasLinkEndpointStatus]
    {
        var result: [CanvasCardID: CanvasLinkEndpointStatus] = [:]
        let current = now()
        for endpoint in endpoints.values {
            guard let controller = endpoint.controller,
                controller.generation == endpoint.generation,
                let place = location(of: controller.id), place.board === board
            else { continue }
            result[place.card.id] = Self.status(of: endpoint, at: current)
        }
        return result
    }

    private static func status(of endpoint: Endpoint, at date: Date) -> CanvasLinkEndpointStatus {
        if endpoint.suspended {
            return .suspended(
                endpoint.suspensionReason == .transportLost
                    ? .connectionLost : .conversationChanged)
        }
        guard endpoint.clientID != nil, date.timeIntervalSince(endpoint.lastSeen) < 15 else {
            return .notConnected
        }
        return .connected
    }

    private func recordFailure(_ route: LiveRoute?, _ reason: String) {
        guard let route else { return }
        let key = SessionLinkPermission(board: ObjectIdentifier(route.board), edge: route.edge.id)
        var runtime = linkRuntime[key] ?? LinkRuntime(board: route.board)
        runtime.board = route.board
        runtime.failure = reason
        linkRuntime[key] = runtime
        revision &+= 1
    }

    private func recordAccepted(_ route: LiveRoute?) {
        guard let route else { return }
        let key = SessionLinkPermission(board: ObjectIdentifier(route.board), edge: route.edge.id)
        var runtime = linkRuntime[key] ?? LinkRuntime(board: route.board)
        runtime.board = route.board
        runtime.failure = nil
        let direction: CanvasLinkDirection =
            route.sourceCard == route.edge.from ? .forward : .reverse
        let date = now()
        runtime.activity.record(direction: direction, at: date, policy: Self.burstPolicy)
        linkRuntime[key] = runtime
        lastMessageEvent = CanvasLinkMessageEvent(
            connectionID: route.edge.id, direction: direction, date: date)
        activityRevision &+= 1
        revision &+= 1
    }

    func status(for controllerID: UUID) -> String {
        _ = revision
        guard let endpoint = endpoints.values.first(where: { $0.controller?.id == controllerID }),
            endpoint.controller?.generation == endpoint.generation,
            location(of: controllerID) != nil
        else {
            return "Start a new terminal to enable the session bridge"
        }
        if endpoint.suspended {
            return endpoint.suspensionReason.status
        }
        guard endpoint.clientID != nil, now().timeIntervalSince(endpoint.lastSeen) < 15 else {
            return "Run claude or codex to connect"
        }
        if endpoint.provider == "codex", endpoint.threadID == nil {
            return "Codex: ask it to list Canvas connections"
        }
        return "\(endpoint.provider == "claude" ? "Claude" : "Codex") connected"
    }

    func handle(_ request: CanvasBridgeRequest) async -> CanvasBridgeResponse {
        guard UUID(uuidString: request.clientID) != nil,
            var source = endpoints[request.token], let controller = source.controller,
            source.generation == controller.generation, location(of: controller.id) != nil
        else { return .init(error: "This terminal session is no longer available.") }
        guard
            ["bind", "suspend", "register", "list", "send", "receive", "unregister", "tool"]
                .contains(
                    request.operation)
        else {
            return .init(error: "Unsupported bridge request.")
        }
        if request.operation == "suspend" {
            guard request.provider == "codex", source.provider == "codex",
                request.endpoint == source.endpoint
            else { return .init(error: "This terminal cannot suspend that Codex session.") }
            guard let reason = SuspensionReason(rawValue: request.reason ?? "sessionChanged") else {
                return .init(error: "Unsupported suspension reason.")
            }
            if !source.suspended { source.suspensionReason = reason }
            source.suspended = true
            source.inbox = []
            endpoints[request.token] = source
            notice = source.suspensionReason.notice
            revision &+= 1
            // Revoke first, then stop in-flight queue processes before the TUI can navigate.
            let pending = deliveries.values.filter {
                $0.sourceToken == request.token || $0.targetToken == request.token
            }
            for delivery in pending { delivery.task.cancel() }
            for delivery in pending { _ = await delivery.task.result }
            return .init()
        }
        guard !source.suspended else {
            return .init(error: source.suspensionReason.status)
        }
        if let provider = request.provider, let registered = source.provider,
            source.clientID == request.clientID, provider != registered
        {
            return .init(error: "The session provider cannot change.")
        }
        if request.operation == "bind" {
            guard request.provider == "codex", let thread = request.threadID,
                UUID(uuidString: thread) != nil,
                Self.validCodexRoute(endpoint: request.endpoint, executable: request.executable),
                source.threadID == nil
                    || (source.threadID == thread && source.endpoint == request.endpoint),
                source.clientID == nil
                    || (source.provider == "codex" && source.endpoint == request.endpoint)
            else { return .init(error: "This terminal cannot bind that Codex session.") }
            source.provider = "codex"
            source.threadID = thread
            source.endpoint = request.endpoint
            source.executable = request.executable
            source.lastSeen = now()
            endpoints[request.token] = source
            revision &+= 1
            return .init()
        }
        if request.operation == "register" {
            guard request.provider == "claude" || request.provider == "codex" else {
                return .init(error: "Unsupported session provider.")
            }
            if request.provider == "codex", request.endpoint != nil || request.executable != nil {
                guard
                    Self.validCodexRoute(endpoint: request.endpoint, executable: request.executable)
                else {
                    return .init(error: "Invalid Codex terminal route.")
                }
            }
            guard
                source.clientID == nil || source.clientID == request.clientID
                    || now().timeIntervalSince(source.lastSeen) > 15
            else {
                return .init(error: "Another agent is already connected in this terminal.")
            }
            if source.clientID != request.clientID {
                source.inbox = []
                if source.clientID != nil || source.provider != request.provider
                    || source.endpoint != request.endpoint
                {
                    source.threadID = nil
                }
            }
            source.clientID = request.clientID
            source.provider = request.provider
            if let threadID = request.threadID {
                guard UUID(uuidString: threadID) != nil else {
                    return .init(error: "Invalid session identity.")
                }
                source.threadID = threadID
            }
            source.endpoint = request.endpoint
            source.executable = request.executable
            source.lastSeen = now()
            endpoints[request.token] = source
            revision &+= 1
            return .init(peers: peers(for: controller.id))
        }
        guard source.clientID == request.clientID else {
            return .init(error: "Session is not registered.")
        }
        source.lastSeen = now()
        endpoints[request.token] = source
        switch request.operation {
        case "unregister":
            source.clientID = nil
            source.inbox = []
            source.threadID = nil
            endpoints[request.token] = source
            revision &+= 1
            return .init()
        case "list": return .init(peers: peers(for: controller.id))
        case "tool":
            guard let call = request.agentCall, let provider = source.provider,
                let place = location(of: controller.id)
            else { return .init(error: "Invalid Ensemble tool request.") }
            let token = request.token
            let clientID = request.clientID
            let caller = CanvasAgentCaller(
                session: place.session, board: place.board, card: place.card,
                controllerID: controller.id, provider: provider
            ) { [weak self] destination, text in
                guard let self else { return .init(error: "Ensemble connection unavailable.") }
                return await self.handle(
                    CanvasBridgeRequest(
                        token: token, operation: "send", clientID: clientID,
                        provider: provider, destination: destination, text: text))
            }
            return await CanvasAgentActions.handle(call, caller: caller)
        case "receive":
            guard source.provider == "claude" else { return .init() }
            source.inbox = source.inbox.filter { message in
                guard let sender = liveTarget(from: controller.id, cardID: message.source) else {
                    return false
                }
                return hasLiveEndpoint(sender)
            }
            // One bounded message per IPC response. Retain the rest for later heartbeats.
            let messages = source.inbox.isEmpty ? [] : [source.inbox.removeFirst()]
            endpoints[request.token] = source
            return .init(messages: messages)
        case "send":
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 16_384,
                let destination = request.destination, !destination.isEmpty,
                destination.utf8.count <= 256
            else { return .init(error: "Invalid destination or message size.") }
            let destinationID: String
            if destination.hasPrefix("@") {
                let matches = peers(for: controller.id).filter {
                    $0.connected && $0.provider != nil
                        && $0.mention?.lowercased() == destination.lowercased()
                }
                guard !matches.isEmpty else {
                    return .init(
                        error: "No connected agent matches that mention. Use list_connections.")
                }
                guard matches.count == 1 else {
                    return .init(
                        error:
                            "More than one connected agent uses that mention. Use its peer ID from list_connections."
                    )
                }
                destinationID = matches[0].id
            } else {
                destinationID = destination
            }
            if peers(for: controller.id).contains(where: {
                $0.id == destinationID && $0.linkState == "paused"
            }) {
                return .init(
                    error:
                        "This link is paused. Resume it in Rafu Canvas. Do not restart the terminals."
                )
            }
            guard let targetID = liveTarget(from: controller.id, cardID: destinationID),
                let targetToken = endpoints.first(where: { $0.value.controller?.id == targetID })?
                    .key,
                var target = endpoints[targetToken], hasLiveEndpoint(targetID),
                let sourceCard = location(of: controller.id)?.card
            else {
                return .init(error: "Connect two live terminal nodes before sending a message.")
            }
            let route = liveRoute(from: controller.id, cardID: destinationID)
            sentAt.removeAll { now().timeIntervalSince($0) > 60 }
            guard sentAt.count < 20 else {
                recordFailure(route, "Message limit reached. Wait one minute.")
                return .init(error: "Message limit reached. Wait one minute.")
            }
            let message = CanvasBridgeMessage(
                id: UUID().uuidString, source: sourceCard.id.rawValue.uuidString, text: text)
            guard let encoded = try? JSONEncoder().encode(message), encoded.count <= 24 * 1_024
            else {
                return .init(error: "The message is too large after JSON encoding.")
            }
            if target.provider == "claude" {
                guard target.inbox.count < 16 else {
                    recordFailure(route, "The destination inbox is full.")
                    return .init(error: "The destination inbox is full.")
                }
                target.inbox.append(message)
                endpoints[targetToken] = target
                sentAt.append(now())
            } else {
                guard let threadID = target.threadID, let endpoint = target.endpoint,
                    let executable = target.executable, endpoint.hasPrefix("unix:///"),
                    executable.hasPrefix("/")
                else {
                    let reason =
                        "Codex is waiting for its first Canvas tool call. Ask it to list Canvas connections."
                    recordFailure(route, reason)
                    return .init(error: reason)
                }
                let reservation = now()
                sentAt.append(reservation)
                let deliveryID = UUID()
                let task = Task {
                    try await CanvasCodexSession.send(
                        executable: executable, endpoint: endpoint,
                        threadID: threadID,
                        text: "Canvas message from \(sourceCard.id.rawValue.uuidString):\n\(text)")
                }
                deliveries[deliveryID] = Delivery(
                    sourceToken: request.token, targetToken: targetToken, task: task)
                defer { deliveries.removeValue(forKey: deliveryID) }
                do {
                    try await task.value
                } catch {
                    if let index = sentAt.firstIndex(of: reservation) { sentAt.remove(at: index) }
                    if task.isCancelled {
                        return .init(
                            error: "Message delivery stopped because the session changed or closed."
                        )
                    }
                    notice = "Codex could not accept the message. Check its terminal."
                    recordFailure(route, "Codex could not accept the message. Check its terminal.")
                    return .init(error: notice)
                }
            }
            notice = "Message queued. The receiving agent has not acknowledged it."
            recordAccepted(route)
            revision &+= 1
            return .init()
        default: return .init(error: "Unsupported bridge request.")
        }
    }

    // MARK: Agent tools (X4)

    /// True when a Live message link connects the caller's node to `cardID`.
    func hasLiveRoute(from controllerID: UUID, to cardID: String) -> Bool {
        guard let target = liveTarget(from: controllerID, cardID: cardID) else { return false }
        return hasLiveEndpoint(target)
    }

    /// True after the terminal's private bridge shell was prepared; the shell
    /// process starts in the same main-actor turn.
    func hasBootstrap(controllerID: UUID) -> Bool { directories[controllerID] != nil }

    /// The agent CLI connected in a terminal, if any.
    func connectedProvider(controllerID: UUID) -> String? {
        guard hasLiveEndpoint(controllerID) else { return nil }
        return endpoints.values.first { $0.controller?.id == controllerID }?.provider
    }

    private func location(of controllerID: UUID) -> Location? {
        if let resolveLocation { return resolveLocation(controllerID) }
        for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots() {
            for board in snapshot.session.canvas.boards.values {
                for card in board.cards {
                    if case .terminal(let groupID) = card.content,
                        snapshot.session.terminal.terminalGroup(groupID)?.panes.first?.sessionID
                            == controllerID
                    {
                        return (snapshot.session, board, card)
                    }
                }
            }
        }
        return nil
    }

    private func peers(for controllerID: UUID) -> [CanvasBridgePeer] {
        guard let source = location(of: controllerID) else { return [] }
        let states = linkStates(in: source.board)
        var seen = Set<CanvasCardID>()
        var peers: [CanvasBridgePeer] = source.board.connections.compactMap { edge in
            let other =
                edge.from == source.card.id ? edge.to : edge.to == source.card.id ? edge.from : nil
            guard let other, seen.insert(other).inserted,
                let card = source.board.cards.first(where: { $0.id == other })
            else { return nil }
            let targetID = liveTarget(from: controllerID, cardID: card.id.rawValue.uuidString)
            let connected = targetID.map { hasLiveEndpoint($0) } ?? false
            let provider =
                connected
                ? endpoints.values.first(where: {
                    $0.controller?.id == targetID
                })?.provider : nil
            return CanvasBridgePeer(
                id: card.id.rawValue.uuidString,
                title: String(String.UnicodeScalarView(card.title.unicodeScalars.prefix(40))),
                kind: card.content.kindName,
                connected: connected, provider: provider,
                mention: connected && provider != nil
                    ? CanvasBridgePeer.mention(for: card.title) : nil,
                linkState: states[edge.id]?.word.lowercased() ?? "related")
        }
        // Bound both the launcher response and the MCP result's second JSON encoding.
        if let encoded = try? JSONEncoder().encode(CanvasBridgeResponse(peers: peers)),
            encoded.count > 24 * 1_024
        {
            peers = peers.map { peer in
                var bounded = peer
                bounded.title = String(
                    String.UnicodeScalarView(peer.title.unicodeScalars.prefix(16)))
                return bounded
            }
        }
        if let encoded = try? JSONEncoder().encode(CanvasBridgeResponse(peers: peers)),
            encoded.count > 24 * 1_024
        {
            peers = peers.map { peer in
                var bounded = peer
                bounded.title = String(
                    String.UnicodeScalarView(peer.title.unicodeScalars.prefix(8)))
                return bounded
            }
        }
        return peers
    }

    private func hasLiveEndpoint(_ controllerID: UUID) -> Bool {
        endpoints.values.contains { endpoint in
            guard let controller = endpoint.controller else { return false }
            return controller.id == controllerID && controller.generation == endpoint.generation
                && !endpoint.suspended && endpoint.clientID != nil
                && now().timeIntervalSince(endpoint.lastSeen) < 15
                && location(of: controllerID) != nil
        }
    }

    private static func validCodexRoute(endpoint: String?, executable: String?) -> Bool {
        guard let endpoint, let executable, executable.hasPrefix("/"),
            URL(fileURLWithPath: executable).lastPathComponent == "codex",
            endpoint.hasPrefix("unix:///tmp/rafu-cdx-"), endpoint.hasSuffix("/socket")
        else { return false }
        let suffix = endpoint.dropFirst("unix:///tmp/rafu-cdx-".count).dropLast("/socket".count)
        return UUID(uuidString: String(suffix)) != nil
    }

    private struct LiveRoute {
        let edge: CanvasConnection
        let board: CanvasBoardState
        let sourceCard: CanvasCardID
        let target: UUID
    }

    private func liveRoute(from controllerID: UUID, cardID: String) -> LiveRoute? {
        guard let source = location(of: controllerID), let uuid = UUID(uuidString: cardID),
            let edge = source.board.connections.first(where: {
                $0.behavior == .session && isEnabled($0.id, in: source.board)
                    && (($0.from == source.card.id && $0.to.rawValue == uuid)
                        || ($0.to == source.card.id && $0.from.rawValue == uuid))
            }),
            let card = source.board.cards.first(where: {
                $0.id == (edge.from == source.card.id ? edge.to : edge.from)
            }), case .terminal(let groupID) = card.content,
            let target = source.session.terminal.terminalGroup(groupID)?.panes.first?.sessionID
        else { return nil }
        return LiveRoute(
            edge: edge, board: source.board, sourceCard: source.card.id, target: target)
    }

    private func liveTarget(from controllerID: UUID, cardID: String) -> UUID? {
        liveRoute(from: controllerID, cardID: cardID)?.target
    }
}
