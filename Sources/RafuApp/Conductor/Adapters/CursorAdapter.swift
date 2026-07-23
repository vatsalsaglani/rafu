import Foundation

/// Cursor CLI adapter — STUB. C4 owns the real implementation
/// (`docs/plans/phases/conductor/C4-adapters-gemini-cursor.md`); C0 lands only a compiling,
/// honestly-degrading shell so `ConductorAdapterRegistry` is complete and
/// C4 rewrites exactly this one file with no shared-file edits.
///
/// Every answer here is the truthful "we have not implemented this yet"
/// answer, never an optimistic guess: not installed, sign-in status unknown,
/// no curated models, no discovery, and an invocation that cannot succeed.

/// Best-effort tier (conductor/README.md): the user may not have active
/// access, so this adapter must degrade honestly rather than pretend.
nonisolated struct CursorAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.cursor
    /// Enabling only makes the CLI selectable; nothing runs without a
    /// visible, user-initiated run (ADR 0018).
    let defaultEnabled = true
    /// C4 flips this once it verifies a real listing command.
    let supportsModelDiscovery = false

    func probe() async -> AdapterProbe { .notInstalled }

    func authStatus() async -> AdapterAuthStatus { .unknown }

    func curatedModels() -> [ConductorModelChoice] { [] }

    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        ConductorStubInvocation.placeholder(
            runDirectory: runDirectory, handoffDirectory: handoffDirectory)
    }
}
