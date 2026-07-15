import Foundation

/// How `LanguageServerManager` finds a language server for a given LSP
/// `languageID`. Increment C2 ships only `NoLanguageServersResolver`
/// (declines every languageID); C3 plugs the curated/user catalog in here
/// with zero changes to the manager.
nonisolated protocol LanguageServerResolving: Sendable {
    func resolve(languageID: String) -> ResolvedLanguageServer?
}

/// Everything `LanguageServerManager` needs to spawn and negotiate with one
/// language server, resolved for a specific languageID.
nonisolated struct ResolvedLanguageServer: Sendable {
    let serverName: String
    let launch: LanguageServerLaunchSpecification
    let initializationOptions: JSONValue?

    /// Overrides `LanguageServerLifecycleBounds.defaultRSSCeilingBytes` for
    /// this server specifically; `nil` defers to the bounds default.
    let rssCeilingBytes: UInt64?
}

/// The default resolver for every languageID this lane doesn't have a
/// catalog for yet — declines silently, exactly like an unavailable
/// capability or a not-yet-ready session.
nonisolated struct NoLanguageServersResolver: LanguageServerResolving {
    func resolve(languageID: String) -> ResolvedLanguageServer? { nil }
}

/// How `LanguageServerManager` turns a `ResolvedLanguageServer` into a
/// running, initialized session. Mirrors C1's injected-`JSONRPCConnection`
/// pattern one level up, so the manager is fully testable over
/// `InMemoryLanguageServerTransport` without a real process.
nonisolated protocol LanguageServerSpawning: Sendable {
    func spawn(resolved: ResolvedLanguageServer, rootURI: String) async throws
        -> SpawnedLanguageServer
}

/// One freshly spawned and initialized language server, handed back to
/// `LanguageServerManager` to supervise.
nonisolated struct SpawnedLanguageServer: Sendable {
    let session: LanguageServerSession

    /// `nil` when the transport couldn't report a pid (e.g. the process
    /// exited between spawn and the pid read) — the manager simply skips
    /// `ProcessResourceRegistry` registration in that case.
    let pid: pid_t?

    /// Suspends until this server's underlying process has exited. The
    /// sole death detector `LanguageServerManager`'s supervision task
    /// relies on — the RSS watchdog never infers death from a missing
    /// resident-memory sample.
    let awaitTermination: @Sendable () async -> Void
}

/// The production spawner: a real process over stdio.
nonisolated struct ProcessLanguageServerSpawner: LanguageServerSpawning {
    func spawn(resolved: ResolvedLanguageServer, rootURI: String) async throws
        -> SpawnedLanguageServer
    {
        let transport = LanguageServerProcessTransport(specification: resolved.launch)
        try await transport.startProcess()
        let pid = await transport.processIdentifier
        let connection = JSONRPCConnection(transport: transport)
        let session = LanguageServerSession(
            connection: connection,
            serverName: resolved.serverName,
            rootURI: rootURI,
            initializationOptions: resolved.initializationOptions
        )
        try await session.initialize()
        return SpawnedLanguageServer(
            session: session,
            pid: pid,
            awaitTermination: { _ = await transport.exitStatus() }
        )
    }
}
