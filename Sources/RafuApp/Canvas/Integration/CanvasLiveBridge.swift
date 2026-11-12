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
    typealias ActivityBegin =
        @MainActor (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
    typealias ActivityEnd = @MainActor (any NSObjectProtocol) -> Void
    /// `codex queue` for one message: executable, endpoint, thread, text. A test seam.
    typealias CodexSend = @Sendable (String, String, String, String) async throws -> Void
    @ObservationIgnored private let beginActivity: ActivityBegin
    @ObservationIgnored private let endActivity: ActivityEnd
    @ObservationIgnored private let channelPrompt: CanvasChannelPromptConfirmer
    /// True when Rafu started, or was told it started, an agent CLI in the node.
    /// With a bound Codex route it marks a peer as still starting.
    @ObservationIgnored private let expectsAgent: @MainActor (CanvasCardID) -> Bool
    @ObservationIgnored private let sendToCodex: CodexSend
    /// Held only while at least one terminal has a live agent route. See `updateActivity`.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    /// `beginActivity` and `endActivity` are test seams; the defaults use `ProcessInfo`.
    init(
        location: (@MainActor (UUID) -> Location?)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        beginActivity: @escaping ActivityBegin = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
        },
        endActivity: @escaping ActivityEnd = { ProcessInfo.processInfo.endActivity($0) },
        channelPrompt: CanvasChannelPromptConfirmer = .shared,
        expectsAgent: @escaping @MainActor (CanvasCardID) -> Bool = { card in
            let center = CanvasAgentCenter.shared
            return center.creator(of: card)?.agent != nil || center.launchedAgent(of: card) != nil
        },
        sendToCodex: @escaping CodexSend = { executable, endpoint, thread, text in
            try await CanvasCodexSession.send(
                executable: executable, endpoint: endpoint, threadID: thread, text: text)
        }
    ) {
        resolveLocation = location
        self.now = now
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.channelPrompt = channelPrompt
        self.expectsAgent = expectsAgent
        self.sendToCodex = sendToCodex
    }
    private enum SuspensionReason: String {
        case sessionChanged
        case transportLost

        var status: String {
            switch self {
            case .sessionChanged: "Session changed. Run codex again to reconnect."
            case .transportLost: "Connection lost. Run codex again to reconnect."
            }
        }

        var notice: String {
            switch self {
            case .sessionChanged:
                "Codex changed sessions. Run codex again in its terminal to reconnect."
            case .transportLost:
                "Codex lost its terminal connection. Run codex again in its terminal to reconnect."
            }
        }
    }

    /// A route with a live agent is fresh for this long after its last request.
    private static let routeFreshness: TimeInterval = 15

    /// True while a running agent owns the terminal's route. A suspended route is
    /// dead by definition. A stale one belongs to an agent that stopped talking.
    private func routeHeld(_ endpoint: Endpoint) -> Bool {
        !endpoint.suspended && (endpoint.clientID != nil || endpoint.endpoint != nil)
            && now().timeIntervalSince(endpoint.lastSeen) < Self.routeFreshness
    }

    /// A message for a peer that is still starting waits here, per target
    /// terminal, in send order. It is never saved and never logged.
    private struct HeldMessage {
        let message: CanvasBridgeMessage
        let sourceController: UUID
        /// The target card's id, to find the route again at delivery time.
        let destination: String
        let queuedAt: Date
        /// The earliest time to try again after a Codex delivery refusal.
        var notBefore: Date
    }
    @ObservationIgnored private var held: [UUID: [HeldMessage]] = [:]
    @ObservationIgnored private var flushing: Set<UUID> = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// At most this many messages wait for one peer.
    static let heldLimit = 8
    /// A held message the peer never took is dropped after this long, and the
    /// link then shows Failed: the peer did not come up.
    static let heldLifetime: TimeInterval = 120
    /// A Codex delivery refusal this soon after the client connected is a start-up
    /// race, not a failure: Rafu tries again every `retryInterval`.
    static let codexStartupGrace: TimeInterval = 45
    static let retryInterval: TimeInterval = 3

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
        /// When the current client registered, and whether any client ever did on
        /// this capability. A terminal that never had a client may still be starting.
        var connectedSince: Date?
        var everConnected = false
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
            if launch.pathMayBeReordered {
                // A soft notice, not a failure: the launch still proceeds. Only a
                // shell with no private startup hook of its own (environmentOnly)
                // reaches here, so PATH order after the user's own startup files
                // is not guaranteed the way it is for every other shell.
                notice =
                    "Agent links are on. If your startup files change PATH, the claude and codex commands can start without Rafu."
            }
            revision &+= 1
            return launch
        } catch {
            guard !Task.isCancelled, controller.generation == generation, isCurrent() else {
                return nil
            }
            notice = "Agent links are not available. Start a new terminal to try again."
            revision &+= 1
            return nil
        }
    }

    /// Installs one private terminal capability without starting a process.
    func install(controller: WorkspaceTerminalController, token: String) {
        endpoints = endpoints.filter { $0.value.controller?.id != controller.id }
        endpoints[token] = Endpoint(
            controller: controller, generation: controller.generation, lastSeen: now())
        updateActivity()
        revision &+= 1
    }

    /// Keeps the process out of App Nap while an agent route exists. A napping
    /// app answers the stdio bridge late, so overnight agent updates would time
    /// out. `.userInitiatedAllowingIdleSystemSleep` stops App Nap and automatic
    /// termination but never keeps the Mac or the display awake; the user's own
    /// power settings still decide that. A client that dies without unregistering
    /// keeps the activity until its terminal closes.
    private func updateActivity() {
        let needed = endpoints.values.contains {
            $0.controller != nil && ($0.clientID != nil || $0.endpoint != nil) && !$0.suspended
        }
        if needed, activity == nil {
            activity = beginActivity(
                .userInitiatedAllowingIdleSystemSleep, "Ensemble agent links are connected")
        } else if !needed, let held = activity {
            endActivity(held)
            activity = nil
        }
    }

    func remove(_ controller: WorkspaceTerminalController) {
        channelPrompt.cancel(controllerID: controller.id)
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
        held[controller.id] = nil
        for (target, queue) in held {
            let kept = queue.filter { $0.sourceController != controller.id }
            held[target] = kept.isEmpty ? nil : kept
        }
        scheduleExpiry()
        updateActivity()
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
        purgeUnroutableHeld()
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
            return "Codex: ask it to list Ensemble connections"
        }
        return "\(endpoint.provider == "claude" ? "Claude" : "Codex") connected"
    }

    private static let unregistered = CanvasBridgeResponse(
        error: CanvasBridgeResponse.unregisteredMessage, code: CanvasBridgeResponse.unregisteredCode
    )

    private func clearSuspensionNotice() {
        if notice == SuspensionReason.sessionChanged.notice
            || notice == SuspensionReason.transportLost.notice
        {
            notice = nil
        }
    }

    /// Cancels in-flight Codex queue processes for a terminal and waits for them.
    /// Callers store their state first, so a re-entrant request sees it.
    private func cancelDeliveries(for token: String) async {
        let pending = deliveries.values.filter {
            $0.sourceToken == token || $0.targetToken == token
        }
        for delivery in pending { delivery.task.cancel() }
        for delivery in pending { _ = await delivery.task.result }
    }

    func handle(_ request: CanvasBridgeRequest) async -> CanvasBridgeResponse {
        guard UUID(uuidString: request.clientID) != nil,
            var source = endpoints[request.token], let controller = source.controller,
            source.generation == controller.generation, location(of: controller.id) != nil
        else { return .init(error: "This terminal session is no longer available.") }
        guard
            [
                "bind", "suspend", "release", "register", "list", "send", "receive", "unregister",
                "tool", CanvasChannelPrompt.launchOperation,
            ].contains(request.operation)
        else {
            return .init(error: "Unsupported bridge request.")
        }
        if request.operation == CanvasChannelPrompt.launchOperation {
            return recordClaudeLaunch(request, controller: controller, source: source)
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
            updateActivity()
            revision &+= 1
            // Revoke first, then stop in-flight queue processes before the TUI can navigate.
            await cancelDeliveries(for: request.token)
            return .init()
        }
        if let provider = request.provider, let registered = source.provider,
            source.clientID == request.clientID, provider != registered
        {
            return .init(error: "The session provider cannot change.")
        }
        // A finished run must be able to leave, and a new run to take over, even
        // when the route is suspended. A suspended route is dead by definition.
        if request.operation == "release" {
            guard request.provider == "codex", let route = request.endpoint,
                source.endpoint == route
            else { return .init(error: "This terminal cannot release that Codex session.") }
            source.clientID = nil
            source.connectedSince = nil
            source.provider = nil
            source.threadID = nil
            source.endpoint = nil
            source.executable = nil
            source.inbox = []
            source.suspended = false
            source.lastSeen = now()
            endpoints[request.token] = source
            clearSuspensionNotice()
            updateActivity()
            revision &+= 1
            await cancelDeliveries(for: request.token)
            return .init()
        }
        if request.operation == "bind" {
            let bindError = "This terminal cannot bind that Codex session."
            guard request.provider == "codex", let thread = request.threadID,
                UUID(uuidString: thread) != nil,
                Self.validCodexRoute(endpoint: request.endpoint, executable: request.executable)
            else { return .init(error: bindError) }
            if source.endpoint == request.endpoint {
                // The same supervisor run: keep the one thread it prepared.
                guard !source.suspended, source.threadID == nil || source.threadID == thread
                else { return .init(error: bindError) }
            } else {
                // A new supervisor run replaces a dead, stale or suspended route,
                // and never a live agent.
                guard !(source.provider != nil && routeHeld(source)) else {
                    return .init(
                        error:
                            "Another agent is already connected in this terminal. Exit it first, or start a new terminal."
                    )
                }
                source.clientID = nil
                source.inbox = []
                source.suspended = false
                source.suspensionReason = .sessionChanged
                clearSuspensionNotice()
            }
            source.provider = "codex"
            source.threadID = thread
            source.endpoint = request.endpoint
            source.executable = request.executable
            source.lastSeen = now()
            endpoints[request.token] = source
            updateActivity()
            revision &+= 1
            // The thread is known now: a message held for it can go.
            scheduleFlush(for: controller.id)
            return .init()
        }
        if request.operation == "unregister" {
            guard source.clientID == request.clientID else { return Self.unregistered }
            source.clientID = nil
            source.connectedSince = nil
            source.inbox = []
            source.threadID = nil
            source.lastSeen = now()
            endpoints[request.token] = source
            updateActivity()
            revision &+= 1
            return .init()
        }
        if source.suspended && request.operation != "register" {
            return .init(error: source.suspensionReason.status)
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
            let fresh = now().timeIntervalSince(source.lastSeen) < Self.routeFreshness
            if source.suspended {
                // Only another agent may take over a dead route, never its owner.
                guard source.clientID != request.clientID,
                    request.provider != "codex" || request.endpoint != source.endpoint, !fresh
                else { return .init(error: source.suspensionReason.status) }
                source.suspended = false
                source.suspensionReason = .sessionChanged
                clearSuspensionNotice()
            }
            // The old agent must not retake a route a new supervisor just bound.
            if request.provider == "codex", source.endpoint != nil,
                request.endpoint != source.endpoint, fresh
            {
                return .init(error: "Another agent is already connected in this terminal.")
            }
            guard source.clientID == nil || source.clientID == request.clientID || !fresh else {
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
            if source.clientID != request.clientID { source.connectedSince = now() }
            source.everConnected = true
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
            updateActivity()
            revision &+= 1
            // The peer just connected: messages held while it started go out now.
            scheduleFlush(for: controller.id)
            return .init(peers: peers(for: controller.id))
        }
        guard source.clientID == request.clientID else { return Self.unregistered }
        source.lastSeen = now()
        endpoints[request.token] = source
        switch request.operation {
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
            // The heartbeat also retries held messages.
            scheduleFlush(for: controller.id)
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
                        "This link is paused. Resume it in Rafu Ensemble. Do not restart the terminals."
                )
            }
            guard let route = liveRoute(from: controller.id, cardID: destinationID),
                let sourceCard = location(of: controller.id)?.card
            else {
                return .init(error: "Connect two live terminal nodes before sending a message.")
            }
            let message = CanvasBridgeMessage(
                id: UUID().uuidString, source: sourceCard.id.rawValue.uuidString, text: text)
            guard let encoded = try? JSONEncoder().encode(message), encoded.count <= 24 * 1_024
            else {
                return .init(error: "The message is too large after JSON encoding.")
            }
            let targetToken = endpoints.first(where: { $0.value.controller?.id == route.target })?
                .key
            guard let targetToken, hasLiveEndpoint(route.target) else {
                // Still starting: hold the message and send it when the peer connects.
                guard peerIsStarting(route, token: targetToken) else {
                    return .init(error: "Connect two live terminal nodes before sending a message.")
                }
                return hold(message, route: route, source: controller.id)
            }
            // Messages already held for this peer go first, so the order stays.
            if held[route.target]?.isEmpty == false {
                return hold(message, route: route, source: controller.id)
            }
            let outcome = await deliver(
                message, sourceToken: request.token, targetToken: targetToken)
            switch outcome {
            case .accepted:
                return accepted(route)
            case .rateLimited:
                recordFailure(route, "Message limit reached. Wait one minute.")
                return .init(error: "Message limit reached. Wait one minute.")
            case .inboxFull:
                recordFailure(route, "The destination inbox is full.")
                return .init(error: "The destination inbox is full.")
            case .notReady:
                return hold(message, route: route, source: controller.id)
            case .refused(let retryable):
                if retryable, withinStartupGrace(targetToken) {
                    return hold(
                        message, route: route, source: controller.id,
                        notBefore: now().addingTimeInterval(Self.retryInterval))
                }
                notice = "Codex could not accept the message. Check its terminal."
                recordFailure(route, "Codex could not accept the message. Check its terminal.")
                return .init(error: notice)
            case .cancelled:
                return .init(
                    error: "Message delivery stopped because the session changed or closed.")
            }
        default: return .init(error: "Unsupported bridge request.")
        }
    }

    // MARK: Delivery and held messages

    private enum DeliveryOutcome: Equatable {
        case accepted
        case rateLimited
        case inboxFull
        /// A Codex peer that has no thread or route yet (it is still starting).
        case notReady
        case cancelled
        /// Codex's queue command failed. A timeout may still have delivered, so it
        /// is not retryable.
        case refused(retryable: Bool)
    }

    /// Hands one message to the target terminal's agent. It records no link
    /// state: callers decide what each outcome means.
    private func deliver(
        _ message: CanvasBridgeMessage, sourceToken: String, targetToken: String
    ) async -> DeliveryOutcome {
        guard var target = endpoints[targetToken] else { return .cancelled }
        sentAt.removeAll { now().timeIntervalSince($0) > 60 }
        guard sentAt.count < 20 else { return .rateLimited }
        if target.provider == "claude" {
            guard target.inbox.count < 16 else { return .inboxFull }
            target.inbox.append(message)
            endpoints[targetToken] = target
            sentAt.append(now())
            return .accepted
        }
        guard let threadID = target.threadID, let endpoint = target.endpoint,
            let executable = target.executable, endpoint.hasPrefix("unix:///"),
            executable.hasPrefix("/")
        else { return .notReady }
        let reservation = now()
        sentAt.append(reservation)
        let deliveryID = UUID()
        let send = sendToCodex
        let text = "Ensemble message from \(message.source):\n\(message.text)"
        let task = Task { try await send(executable, endpoint, threadID, text) }
        deliveries[deliveryID] = Delivery(
            sourceToken: sourceToken, targetToken: targetToken, task: task)
        defer { deliveries.removeValue(forKey: deliveryID) }
        do {
            try await task.value
        } catch {
            if let index = sentAt.firstIndex(of: reservation) { sentAt.remove(at: index) }
            if task.isCancelled { return .cancelled }
            return .refused(
                retryable: (error as? CanvasCodexSession.SessionError) == .deliveryFailed)
        }
        return .accepted
    }

    private func noteAccepted(_ route: LiveRoute) {
        notice = "Message queued. The receiving agent has not acknowledged it."
        recordAccepted(route)
        revision &+= 1
    }

    private func accepted(_ route: LiveRoute) -> CanvasBridgeResponse {
        noteAccepted(route)
        var delivery = CanvasAgentToolResult(
            message: "Queued for the receiving agent. It has not acknowledged the message yet.")
        delivery.delivered = true
        return .init(toolResult: delivery)
    }

    /// True while the peer terminal runs and an agent is expected in it, but no
    /// client has connected there yet. A quit agent, a suspended route and a
    /// plain shell are not starting: their senders get an error.
    private func peerIsStarting(_ route: LiveRoute, token: String?) -> Bool {
        let endpoint = token.flatMap { endpoints[$0] }
        if endpoint?.suspended == true || endpoint?.everConnected == true { return false }
        return expectsAgent(route.targetCard) || endpoint?.provider != nil
    }

    private func withinStartupGrace(_ token: String) -> Bool {
        guard let since = endpoints[token]?.connectedSince else { return false }
        return now().timeIntervalSince(since) < Self.codexStartupGrace
    }

    /// Queues a message behind the ones already waiting for the same peer.
    private func hold(
        _ message: CanvasBridgeMessage, route: LiveRoute, source: UUID, notBefore: Date? = nil
    ) -> CanvasBridgeResponse {
        var queue = held[route.target] ?? []
        guard queue.count < Self.heldLimit else {
            return .init(
                error:
                    "\(Self.heldLimit) messages already wait for that peer to connect. Wait until list_connections shows it connected, then send again."
            )
        }
        let current = now()
        queue.append(
            HeldMessage(
                message: message, sourceController: source,
                destination: route.targetCard.rawValue.uuidString, queuedAt: current,
                notBefore: notBefore ?? current))
        held[route.target] = queue
        scheduleExpiry()
        revision &+= 1
        // A connected peer with an older queue ahead of this message takes it at once.
        scheduleFlush(for: route.target)
        var result = CanvasAgentToolResult(
            message:
                "Held: that peer is not connected yet. Rafu sends the message when it connects, within \(Int(Self.heldLifetime / 60)) minutes. Do not send it again."
        )
        result.delivered = false
        return .init(toolResult: result)
    }

    private func scheduleFlush(for target: UUID) {
        guard let head = held[target]?.first, now() >= head.notBefore,
            !flushing.contains(target)
        else { return }
        flushing.insert(target)
        Task { [weak self] in await self?.flushHeld(target) }
    }

    /// Sends the held messages for `target` in order, stopping at the first one
    /// the peer cannot take yet. Never records a failure for a start-up wait.
    private func flushHeld(_ target: UUID) async {
        defer { flushing.remove(target) }
        while let next = held[target]?.first {
            guard now() >= next.notBefore else { return }
            // The sender or the link can be gone since the message was held.
            guard let route = liveRoute(from: next.sourceController, cardID: next.destination),
                route.target == target, hasLiveEndpoint(next.sourceController),
                let sourceToken = endpoints.first(where: {
                    $0.value.controller?.id == next.sourceController
                })?.key
            else {
                removeHeld(next.message.id, from: target)
                continue
            }
            guard hasLiveEndpoint(target),
                let targetToken = endpoints.first(where: { $0.value.controller?.id == target })?.key
            else { return }
            let outcome = await deliver(
                next.message, sourceToken: sourceToken, targetToken: targetToken)
            switch outcome {
            case .accepted:
                removeHeld(next.message.id, from: target)
                noteAccepted(route)
            case .cancelled:
                removeHeld(next.message.id, from: target)
            case .rateLimited, .inboxFull, .notReady:
                return
            case .refused(let retryable):
                if retryable, withinStartupGrace(targetToken) {
                    retryHeld(next.message.id, in: target, after: Self.retryInterval)
                    return
                }
                removeHeld(next.message.id, from: target)
                notice = "Codex could not accept the message. Check its terminal."
                recordFailure(route, "Codex could not accept the message. Check its terminal.")
            }
        }
    }

    private func removeHeld(_ id: String, from target: UUID) {
        let kept = (held[target] ?? []).filter { $0.message.id != id }
        held[target] = kept.isEmpty ? nil : kept
        scheduleExpiry()
        revision &+= 1
    }

    private func retryHeld(_ id: String, in target: UUID, after delay: TimeInterval) {
        guard let index = held[target]?.firstIndex(where: { $0.message.id == id }) else { return }
        held[target]?[index].notBefore = now().addingTimeInterval(delay)
    }

    /// Drops held messages whose Live link is gone (paused, removed, or a card
    /// that left the board), like the inbox of a disabled link.
    private func purgeUnroutableHeld() {
        for (target, queue) in held {
            let kept = queue.filter {
                liveRoute(from: $0.sourceController, cardID: $0.destination) != nil
            }
            held[target] = kept.isEmpty ? nil : kept
        }
        scheduleExpiry()
    }

    /// Number of messages waiting for the peer terminal. A count, never a body.
    func heldMessageCount(for controllerID: UUID) -> Int { held[controllerID]?.count ?? 0 }

    /// Drops held messages the peer never took in `heldLifetime`, and marks their
    /// links Failed: this is a real failure. One timer calls it; a test calls it
    /// after it moves the clock.
    func expireHeldMessages() {
        let current = now()
        for (target, queue) in held {
            let expired = queue.filter {
                current.timeIntervalSince($0.queuedAt) >= Self.heldLifetime
            }
            guard !expired.isEmpty else { continue }
            for message in expired {
                recordFailure(
                    liveRoute(from: message.sourceController, cardID: message.destination),
                    "The peer did not connect in time. Send the message again.")
            }
            let kept = queue.filter { current.timeIntervalSince($0.queuedAt) < Self.heldLifetime }
            held[target] = kept.isEmpty ? nil : kept
        }
        scheduleExpiry()
        revision &+= 1
    }

    /// One timer, for the oldest held message. There is no polling.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let oldest = held.values.flatMap({ $0 }).map(\.queuedAt).min() else { return }
        let wait = max(0, oldest.addingTimeInterval(Self.heldLifetime).timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.expireHeldMessages()
        }
    }

    // MARK: Agent tools (X4)

    /// Rafu's own `claude` launcher announces a start that carries the Rafu
    /// channel flag. This is the only trigger for `CanvasChannelPromptConfirmer`.
    /// The launcher sends no terminal content, and a launch announcement from any
    /// other provider is ignored.
    ///
    /// The wrapper sends this before `execve`, so no Claude client is registered
    /// yet. A `launch` while a Claude client is bound and fresh (the same
    /// freshness rule as `register`) is refused: an agent in the terminal can read
    /// the token and must not be able to open a new watch for its own Claude.
    private func recordClaudeLaunch(
        _ request: CanvasBridgeRequest, controller: WorkspaceTerminalController,
        source: Endpoint
    ) -> CanvasBridgeResponse {
        guard request.provider == "claude", let place = location(of: controller.id) else {
            return .init()
        }
        if source.clientID != nil,
            now().timeIntervalSince(source.lastSeen) < Self.routeFreshness
        {
            return .init(error: "Another agent is already connected in this terminal.")
        }
        let board = place.board
        channelPrompt.recordLaunch(
            controllerID: controller.id,
            hooks: .init(
                mode: { [weak board] in board?.agentControlMode ?? .off },
                settingOn: { CanvasChannelPromptPreference.isOn() },
                read: { [weak controller] in
                    controller?.recentOutputLines(maxLines: 40, fullViewport: true)
                },
                sendReturn: { [weak controller] in controller?.sendReturn() ?? false },
                notice: { [weak board] message, tone in board?.showNotice(message, tone: tone) }
            ))
        return .init()
    }

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

    /// The Codex thread id the bridge captured for the terminal, if a live
    /// Codex client registered there. `agent_configure` resumes it.
    func codexThreadID(controllerID: UUID) -> String? {
        guard hasLiveEndpoint(controllerID) else { return nil }
        let endpoint = endpoints.values.first { $0.controller?.id == controllerID }
        guard endpoint?.provider == "codex" else { return nil }
        return endpoint?.threadID
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
        let targetCard: CanvasCardID
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
            edge: edge, board: source.board, sourceCard: source.card.id, targetCard: card.id,
            target: target)
    }

    private func liveTarget(from controllerID: UUID, cardID: String) -> UUID? {
        liveRoute(from: controllerID, cardID: cardID)?.target
    }
}
