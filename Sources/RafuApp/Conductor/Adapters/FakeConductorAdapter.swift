import Foundation

/// A REAL adapter that drives `/bin/echo` instead of an agent CLI — the one
/// adapter in C0 that actually works end to end.
///
/// It exists so C1's run engine (worktree lifecycle, PTY execution, handoff
/// capture, diff gate) can be built and tested without any vendor CLI
/// installed, and so the argv-only invariant has something concrete to
/// assert against. It is deliberately NOT in `ConductorAdapterRegistry.all`:
/// a user must never be able to pick it. Consumers that want it inject it
/// through their `adapters:` parameter.
///
/// `id` is an init parameter so a test (or C1) can substitute the fake for a
/// specific provider and exercise the registry-driven paths unchanged.
nonisolated struct FakeConductorAdapter: ConductorCLIAdapter {
    let id: ConductorCLIID
    let defaultEnabled: Bool
    let supportsModelDiscovery: Bool

    /// Absolute by construction — a PTY child inherits no `PATH` (see
    /// `TerminalProcessSpec.resolvedLaunch()`).
    static let executableURL = URL(fileURLWithPath: "/bin/echo")

    static let curatedModelChoices = [
        ConductorModelChoice(id: "fake-fast", displayName: "Fake (fast)", source: .curated),
        ConductorModelChoice(id: "fake-deep", displayName: "Fake (deep)", source: .curated),
    ]

    static let discoveredModelChoices = [
        ConductorModelChoice(
            id: "fake-discovered", displayName: "Fake (discovered)", source: .discovered)
    ]

    init(
        id: ConductorCLIID = .claudeCode,
        defaultEnabled: Bool = true,
        supportsModelDiscovery: Bool = true
    ) {
        self.id = id
        self.defaultEnabled = defaultEnabled
        self.supportsModelDiscovery = supportsModelDiscovery
    }

    func probe() async -> AdapterProbe {
        AdapterProbe(installed: true, executableURL: Self.executableURL, version: "fake-1.0")
    }

    /// The fake has no account, so it reports the same shape a real adapter
    /// uses to send the user to the vendor's CLI — never a credential.
    func authStatus() async -> AdapterAuthStatus {
        .notAuthenticated(hint: "run `fake login` in a terminal")
    }

    func curatedModels() -> [ConductorModelChoice] { Self.curatedModelChoices }

    func discoverModels() async -> [ConductorModelChoice]? {
        supportsModelDiscovery ? Self.discoveredModelChoices : nil
    }

    /// The prompt is ONE argv element. It is never concatenated into a shell
    /// string, so metacharacters in repo text (`;`, `$( )`, backticks) reach
    /// the child verbatim and unexpanded — the argv-only invariant this
    /// adapter exists to make testable.
    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        var arguments = ["--model", model.isEmpty ? Self.curatedModelChoices[0].id : model]
        arguments.append("--autonomy")
        arguments.append(autonomy.rawValue)
        arguments.append(prompt)
        return AdapterInvocation(
            executableURL: Self.executableURL,
            arguments: arguments,
            environment: RafuConductorEnvironment.childEnvironment(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory))
    }
}
