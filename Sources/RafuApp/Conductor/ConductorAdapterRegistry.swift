import Foundation

/// The seven-CLI roster (conductor/README.md), in the SAME order as
/// `ConductorCLIID`'s case list — mirroring `UsageProviderRegistry` exactly.
/// Settings, role pickers, and the run engine all iterate `all`; nothing in
/// Rafu switches on `ConductorCLIID` to reach an adapter, which is what lets
/// C2–C4 rewrite one stub file each without touching a shared file.
///
/// `FakeConductorAdapter` is deliberately ABSENT from `all`: it is a real
/// echo adapter for tests and for C1's run-engine work, not a roster entry a
/// user could pick. Consumers that need it inject it through their
/// `adapters:` parameter instead.
nonisolated enum ConductorAdapterRegistry {
    static let all: [any ConductorCLIAdapter] = [
        ClaudeCodeAdapter(),
        CodexAdapter(),
        OpenCodeAdapter(),
        ClineAdapter(),
        KimiAdapter(),
        GeminiCLIAdapter(),
        CursorAdapter(),
    ]

    static func adapter(for id: ConductorCLIID) -> (any ConductorCLIAdapter)? {
        all.first { $0.id == id }
    }
}

/// The invocation every C0 STUB adapter returns until its owning phase
/// (C2–C4) replaces it. `/usr/bin/false` is deliberate: an unimplemented
/// adapter that somehow reached a run must FAIL the step, never exit cleanly
/// and let the engine record work that did not happen.
///
/// A real adapter never calls this.
nonisolated enum ConductorStubInvocation {
    /// Absolute — a PTY child inherits no `PATH` (see
    /// `TerminalProcessSpec.resolvedLaunch()`).
    static let unimplementedExecutableURL = URL(fileURLWithPath: "/usr/bin/false")

    static func placeholder(runDirectory: URL, handoffDirectory: URL) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: unimplementedExecutableURL,
            arguments: [],
            environment: RafuConductorEnvironment.childEnvironment(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory))
    }
}
