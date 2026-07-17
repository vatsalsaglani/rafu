import Foundation

/// One language server process's LSP session, wrapping an injected
/// `JSONRPCConnection`: the handshake, capability gating, document-sync
/// bookkeeping (a `DocumentTextMirror` per open document), and the
/// navigation request surface (`definition`/`declaration`/`references`/
/// `hover`/`documentSymbols`). A bare `actor` — like `JSONRPCConnection` —
/// because it needs its own isolation domain independent of the app's
/// `MainActor` default, not the RafuApp target's default `MainActor`
/// isolation `LanguageServerSession` would otherwise inherit.
///
/// Declining (returning `nil`) is the normal, silent outcome for an
/// unavailable feature, a not-yet-ready session, a per-request timeout, or
/// any connection failure — lane 2's navigation provider (C5) falls through
/// to the next tier on `nil` rather than surfacing an error. Only an
/// authoritative empty/none answer from the server (a legal LSP `null`) is
/// distinguished from decline, and only where the caller can act on that
/// distinction (`[Location]` empty vs. declined; `DocumentSymbolResult`).
actor LanguageServerSession {
    /// The session's lifecycle. `.idle` and `.ready` both accept navigation
    /// requests — `.idle` only records that zero requests are currently in
    /// flight, which is what a future idle-shutdown policy (C2) will key
    /// off; C1 never starts a shutdown timer itself.
    nonisolated enum State: Sendable, Equatable {
        case spawned
        case initializing
        case ready
        case idle
        case shuttingDown
        case dead
    }

    nonisolated enum SessionError: Error, Sendable, Equatable {
        /// `initialize()` did not receive a response within `handshakeTimeout`.
        case handshakeTimedOut
    }

    private let connection: JSONRPCConnection
    /// Readable outside the actor for the navigation tier label ("via
    /// <serverName>"). Safe as synchronous cross-actor access: an immutable
    /// `let` of a `Sendable` type is implicitly `nonisolated`.
    let serverName: String
    private let rootURI: String
    private let initializationOptions: JSONValue?
    private let requestTimeout: Duration
    private let handshakeTimeout: Duration

    private(set) var state: State = .spawned
    private(set) var capabilities: ServerCapabilities?
    private(set) var negotiatedEncoding: PositionEncoding = .utf16
    private(set) var isWarmingUp = false

    private var mirrors: [String: DocumentTextMirror] = [:]
    private var documentVersions: [String: Int] = [:]
    private var inFlightRequestCount = 0
    private var monitorTask: Task<Void, Never>?

    init(
        connection: JSONRPCConnection,
        serverName: String,
        rootURI: String,
        initializationOptions: JSONValue?,
        requestTimeout: Duration = .seconds(2),
        handshakeTimeout: Duration = .seconds(15)
    ) {
        self.connection = connection
        self.serverName = serverName
        self.rootURI = rootURI
        self.initializationOptions = initializationOptions
        self.requestTimeout = requestTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: - Handshake

    /// Starts the connection's read loop and performs the `initialize` /
    /// `initialized` handshake, bounded by `handshakeTimeout` (C0's
    /// `JSONRPCConnection.sendRequest` never times out on its own). On
    /// success, stores the server's capabilities and negotiated position
    /// encoding, starts `monitorNotifications()`, and moves to `.ready`. On
    /// any failure — including expiry — tears the connection down, moves to
    /// `.dead`, and rethrows.
    func initialize() async throws {
        guard state == .spawned else { return }
        state = .initializing
        await connection.start()

        let params = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: ClientInfo(name: "Rafu", version: nil),
            rootUri: rootURI,
            capabilities: ClientCapabilities(
                general: GeneralClientCapabilities(positionEncodings: ["utf-16", "utf-8"]),
                window: WindowClientCapabilities(workDoneProgress: true)
            ),
            initializationOptions: initializationOptions
        )

        do {
            let result = try await performHandshakeRequest(params: params)
            capabilities = result.capabilities
            negotiatedEncoding = PositionEncoding(rawLSPValue: result.capabilities.positionEncoding)
            try await connection.sendNotification(
                method: "initialized", params: InitializedParams())
            monitorTask = Task { [weak self] in await self?.monitorNotifications() }
            state = .ready
        } catch {
            await forceTeardownToDead()
            throw error
        }
    }

    /// Races `initialize`'s request against `handshakeTimeout`, taking
    /// whichever finishes first and cancelling the other — the same
    /// take-first-cancel-the-rest shape as `runRequestWithTimeout(_:params:)`,
    /// except this one rethrows instead of declining, since a failed
    /// handshake has no server to fall back to.
    private func performHandshakeRequest(params: InitializeParams) async throws -> InitializeResult
    {
        let connection = connection
        let handshakeTimeout = handshakeTimeout
        let outcome = await withTaskGroup(of: Result<InitializeResult, any Error>.self) {
            group -> Result<InitializeResult, any Error> in
            group.addTask {
                do {
                    let result: InitializeResult = try await connection.sendRequest(
                        method: "initialize", params: params)
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: handshakeTimeout)
                return .failure(SessionError.handshakeTimedOut)
            }
            guard let first = await group.next() else {
                return .failure(SessionError.handshakeTimedOut)
            }
            group.cancelAll()
            return first
        }
        return try outcome.get()
    }

    /// Drains `$/progress` notifications to maintain `isWarmingUp`. Any
    /// other server-to-client notification (e.g. `publishDiagnostics`) is
    /// intentionally ignored — C1 has no consumer for them yet. When the
    /// notification stream ends (the connection tore itself down, e.g. the
    /// server process died), moves to `.dead` unless a graceful
    /// `shutdown()` is already in progress.
    private func monitorNotifications() async {
        for await notification in connection.notifications {
            guard notification.method == "$/progress" else { continue }
            updateWarmingUp(fromProgressParams: notification.params)
        }
        guard state != .shuttingDown, state != .dead else { return }
        await forceTeardownToDead()
    }

    /// Decodes `params` as `ProgressParams<WorkDoneProgressValue>` via a
    /// round-trip through `JSONValue`'s own `Codable` conformance — the same
    /// re-encode-then-decode trick used everywhere a loosely-typed
    /// `JSONValue` needs to be read as a concrete type. Any decode failure
    /// (a `$/progress` shape this session doesn't recognize) is dropped
    /// silently rather than surfaced.
    private func updateWarmingUp(fromProgressParams params: JSONValue?) {
        guard let params, let data = try? JSONEncoder().encode(params) else { return }
        guard
            let progress = try? JSONDecoder().decode(
                ProgressParams<WorkDoneProgressValue>.self, from: data)
        else { return }
        switch progress.value {
        case .begin: isWarmingUp = true
        case .report: break
        case .end: isWarmingUp = false
        }
    }

    // MARK: - Document synchronization

    /// Records a local mirror of `text` and, unless the server declined
    /// `didOpen`/`didClose` notifications via `openClose: false`, notifies
    /// it. The mirror is recorded even when the notification isn't sent, so
    /// `didChange`/`resync`/nav requests keyed on this `uri` still work.
    func didOpen(uri: String, languageID: String, text: String) async {
        guard isNavigable else { return }
        mirrors[uri] = DocumentTextMirror(text: text)
        documentVersions[uri] = 1
        guard syncOpenClose else { return }
        let params = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(uri: uri, languageId: languageID, version: 1, text: text)
        )
        try? await connection.sendNotification(method: "textDocument/didOpen", params: params)
    }

    /// Applies one `DocumentEditDelta` to `uri`'s mirror and sends the
    /// matching `didChange` notification. Dropped silently if there is no
    /// mirror for `uri` — C2 guarantees `didOpen` always precedes
    /// `didChange` for a live document, so this only guards against a
    /// stray/late call racing a `didClose`.
    ///
    /// When the negotiated sync kind is `.incremental`, maps `delta.range`
    /// (a pre-edit UTF-16 `NSRange`) to an LSP `LSPRange` using the
    /// *current* (pre-edit) mirror, and extracts the replacement substring
    /// from `newFullText` at the post-edit UTF-16 span
    /// `[delta.range.location, delta.range.location + delta.replacementLength)`.
    /// If that mapping or extraction can't be done exactly (an
    /// out-of-bounds or mid-surrogate index — a sign the mirror has
    /// drifted from the real document), falls back to sending `newFullText`
    /// in full for this one change rather than sending a corrupt range.
    /// Either way, the mirror is replaced with `newFullText` afterward, so
    /// drift can never accumulate across calls.
    func didChange(uri: String, delta: DocumentEditDelta, newFullText: String) async {
        guard isNavigable else { return }
        guard let mirror = mirrors[uri], let version = documentVersions[uri] else { return }

        let contentChange = contentChange(for: mirror, delta: delta, newFullText: newFullText)
        let newVersion = version + 1
        mirrors[uri] = DocumentTextMirror(text: newFullText)
        documentVersions[uri] = newVersion

        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: newVersion),
            contentChanges: [contentChange]
        )
        try? await connection.sendNotification(method: "textDocument/didChange", params: params)
    }

    /// An external reload (the file changed on disk and the document was
    /// replaced wholesale, not edited keystroke-by-keystroke): replaces the
    /// mirror and always sends a full-text `didChange`, regardless of the
    /// negotiated sync kind — there is no previous-mirror range to diff
    /// against. Dropped silently if there is no mirror for `uri`, matching
    /// `didChange`.
    func resync(uri: String, fullText: String) async {
        guard isNavigable else { return }
        guard let version = documentVersions[uri] else { return }

        let newVersion = version + 1
        mirrors[uri] = DocumentTextMirror(text: fullText)
        documentVersions[uri] = newVersion

        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: newVersion),
            contentChanges: [.full(text: fullText)]
        )
        try? await connection.sendNotification(method: "textDocument/didChange", params: params)
    }

    /// Drops `uri`'s mirror and, unless the server declined `didClose`
    /// notifications, notifies it.
    func didClose(uri: String) async {
        guard isNavigable else { return }
        guard mirrors[uri] != nil else { return }
        mirrors.removeValue(forKey: uri)
        documentVersions.removeValue(forKey: uri)
        guard syncOpenClose else { return }
        let params = DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri))
        try? await connection.sendNotification(method: "textDocument/didClose", params: params)
    }

    private func contentChange(
        for mirror: DocumentTextMirror, delta: DocumentEditDelta, newFullText: String
    ) -> TextDocumentContentChangeEvent {
        guard effectiveSyncKind == .incremental else {
            return .full(text: newFullText)
        }
        let start = delta.range.location
        let end = delta.range.location + delta.range.length
        guard
            let startPosition = mirror.position(
                forUTF16Offset: start, encoding: negotiatedEncoding),
            let endPosition = mirror.position(forUTF16Offset: end, encoding: negotiatedEncoding),
            let replacementText = Self.utf16Substring(
                of: newFullText, from: start, to: start + delta.replacementLength)
        else {
            return .full(text: newFullText)
        }
        return .incremental(
            range: LSPRange(start: startPosition, end: endPosition), text: replacementText)
    }

    /// Extracts `text`'s UTF-16 span `[start, end)` as a `String`. Locates
    /// each boundary with a `unicodeScalars` walk (mirroring
    /// `DocumentTextMirror`'s own conversions) rather than reconstructing a
    /// `String.Index` from a raw `Int` offset — the standard library has no
    /// infallible way to do that — so a desynced delta (an offset that's
    /// out of range, or lands inside a surrogate pair) is detected as `nil`
    /// instead of trapping.
    private static func utf16Substring(of text: String, from start: Int, to end: Int) -> String? {
        guard start >= 0, end >= start else { return nil }
        guard let startIndex = utf16Index(in: text, forOffset: start),
            let endIndex = utf16Index(in: text, forOffset: end)
        else { return nil }
        return String(text[startIndex..<endIndex])
    }

    /// Walks `text.unicodeScalars` from the start, accumulating UTF-16
    /// length, until it reaches `target`. `nil` if `target` is out of range
    /// or falls strictly inside a scalar's UTF-16 span instead of exactly
    /// on a boundary.
    private static func utf16Index(in text: String, forOffset target: Int) -> String.Index? {
        guard target >= 0 else { return nil }
        var utf16Accumulator = 0
        var index = text.startIndex
        while index < text.endIndex {
            if utf16Accumulator == target { return index }
            let width = Unicode.UTF16.width(text.unicodeScalars[index])
            if utf16Accumulator + width > target { return nil }
            utf16Accumulator += width
            index = text.unicodeScalars.index(after: index)
        }
        return utf16Accumulator == target ? index : nil
    }

    /// Whether the negotiated `textDocumentSync` wants `didOpen`/`didClose`
    /// notifications. Defaults to `true` when the server didn't declare
    /// `textDocumentSync` at all.
    private var syncOpenClose: Bool {
        capabilities?.textDocumentSync?.openClose ?? true
    }

    /// The negotiated sync kind, with `.none` folded into `.full` per the
    /// LSP spec's guidance that a server advertising `.none` still expects
    /// full-document `didChange` payloads (it only opts out of `didOpen`/
    /// `didClose`, which is `openClose`'s job, not `change`'s). Defaults to
    /// `.full` when the server didn't declare `textDocumentSync` at all —
    /// the conservative choice when the negotiated kind is unknown.
    private var effectiveSyncKind: TextDocumentSyncKind {
        guard let kind = capabilities?.textDocumentSync?.effectiveKind else { return .full }
        return kind == .none ? .full : kind
    }

    // MARK: - Navigation

    /// `nil` = decline (unavailable capability, not-ready session, timeout,
    /// or any request/connection failure) — the caller falls through to the
    /// next navigation tier. An empty array is an authoritative "no
    /// definition here" answer from the server.
    func definition(uri: String, utf16Offset: Int) async -> [Location]? {
        guard isNavigable, capabilities?.definitionProvider?.isEnabled == true else { return nil }
        guard let position = position(forUTF16Offset: utf16Offset, in: uri) else { return nil }
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: position)
        let result: LocationsResult? = await runRequestWithTimeout(
            method: "textDocument/definition", params: params)
        return result?.locations
    }

    /// See `definition(uri:utf16Offset:)` — identical shape, `declarationProvider`.
    func declaration(uri: String, utf16Offset: Int) async -> [Location]? {
        guard isNavigable, capabilities?.declarationProvider?.isEnabled == true else { return nil }
        guard let position = position(forUTF16Offset: utf16Offset, in: uri) else { return nil }
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: position)
        let result: LocationsResult? = await runRequestWithTimeout(
            method: "textDocument/declaration", params: params)
        return result?.locations
    }

    /// See `definition(uri:utf16Offset:)` — identical decline/empty
    /// semantics, `referencesProvider`.
    func references(uri: String, utf16Offset: Int, includeDeclaration: Bool) async -> [Location]? {
        guard isNavigable, capabilities?.referencesProvider?.isEnabled == true else { return nil }
        guard let position = position(forUTF16Offset: utf16Offset, in: uri) else { return nil }
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: ReferenceContext(includeDeclaration: includeDeclaration)
        )
        let result: LocationsResult? = await runRequestWithTimeout(
            method: "textDocument/references", params: params)
        return result?.locations
    }

    /// `nil` covers both decline and the server's own authoritative "no
    /// hover info here" `null` answer — `Hover?` has no third state to
    /// distinguish them, and both fall through to the next tier the same
    /// way.
    func hover(uri: String, utf16Offset: Int) async -> Hover? {
        guard isNavigable, capabilities?.hoverProvider?.isEnabled == true else { return nil }
        guard let position = position(forUTF16Offset: utf16Offset, in: uri) else { return nil }
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri), position: position)
        let result: HoverResult? = await runRequestWithTimeout(
            method: "textDocument/hover", params: params)
        guard case .hover(let hover) = result else { return nil }
        return hover
    }

    /// Unlike the other nav entry points, returns the whole
    /// `DocumentSymbolResult` union rather than unwrapping it — the caller
    /// can still distinguish "no symbols" (`.none`/an empty array) from
    /// decline (`nil`) this way.
    func documentSymbols(uri: String) async -> DocumentSymbolResult? {
        guard isNavigable, capabilities?.documentSymbolProvider?.isEnabled == true else {
            return nil
        }
        let params = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri))
        return await runRequestWithTimeout(method: "textDocument/documentSymbol", params: params)
    }

    private var isNavigable: Bool {
        state == .ready || state == .idle
    }

    private func position(forUTF16Offset offset: Int, in uri: String) -> Position? {
        mirrors[uri]?.position(forUTF16Offset: offset, encoding: negotiatedEncoding)
    }

    /// Races `sendRequest` against `requestTimeout`, taking whichever
    /// finishes first and cancelling the other (the loser's cancellation
    /// propagates into C0's `$/cancelRequest`). Every path that can end a
    /// request — success, server error, connection failure, or timeout —
    /// collapses to `nil` here; only the nav entry points' capability gates
    /// and result-union types distinguish decline from an authoritative
    /// empty answer.
    private func runRequestWithTimeout<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String, params: Params
    ) async -> Result? {
        beginRequest()
        defer { endRequest() }
        let connection = connection
        let requestTimeout = requestTimeout
        return await withTaskGroup(of: Result?.self) { group in
            group.addTask {
                try? await connection.sendRequest(method: method, params: params)
            }
            group.addTask {
                try? await Task.sleep(for: requestTimeout)
                return nil
            }
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            return first
        }
    }

    /// `.idle` is entered only when a request completes and leaves the
    /// in-flight count at zero — not merely whenever the count happens to
    /// be zero — so the session starts (and stays) `.ready` immediately
    /// after `initialize()` until the first request's completion flips it.
    private func beginRequest() {
        inFlightRequestCount += 1
        if state == .idle { state = .ready }
    }

    private func endRequest() {
        inFlightRequestCount -= 1
        if inFlightRequestCount == 0, state == .ready { state = .idle }
    }

    // MARK: - Shutdown

    /// The graceful LSP shutdown sequence: `shutdown` request, `exit`
    /// notification, then tears down the underlying connection. Idempotent
    /// — a second call (or a call after `forceTeardownToDead()` already ran,
    /// e.g. the server died first) is a no-op.
    func shutdown() async {
        guard state != .shuttingDown, state != .dead else { return }
        state = .shuttingDown
        monitorTask?.cancel()
        monitorTask = nil
        let shutdownReply: JSONValue? = try? await connection.sendRequest(
            method: "shutdown", params: Optional<JSONValue>.none)
        _ = shutdownReply
        try? await connection.sendNotification(method: "exit", params: Optional<JSONValue>.none)
        await connection.teardown()
        state = .dead
    }

    /// The unilateral counterpart to `shutdown()`: used when there is no
    /// server left to negotiate with (a failed handshake, or the
    /// notification stream ending on its own — the server process died or
    /// closed its transport). Idempotent.
    private func forceTeardownToDead() async {
        guard state != .dead else { return }
        state = .dead
        monitorTask?.cancel()
        monitorTask = nil
        await connection.teardown()
    }
}
