import Foundation

/// A role's CLI adapter, resolved once at the start of a run/step: the
/// adapter object itself plus what its `probe()` found. Both C1's
/// single-role controller and C5's `ConductorWorkflowController` resolve
/// through this so "is this CLI actually installed" is asked, and answered,
/// exactly once per role per run.
nonisolated struct ConductorResolvedAdapter: Sendable {
    let adapter: any ConductorCLIAdapter
    let executableURL: URL
    let version: String?
}

/// The shared primitive behind a role's process launch: resolve its adapter,
/// build the pure process specification, and produce the manifest binding —
/// the exact steps C1's single-role `start()` used to perform inline, now
/// reused unchanged by C5's multi-step pipeline controller.
nonisolated struct ConductorRoleLaunchService: Sendable {
    /// The one async step: probe the adapter and confirm it is actually
    /// installed. Throws `ConductorRunError.adapterUnavailable` — never
    /// returns a resolved value for an adapter that is not usable — so every
    /// caller can treat a successful `resolve` as "safe to invoke".
    func resolve(_ adapter: any ConductorCLIAdapter) async throws -> ConductorResolvedAdapter {
        let probe = await adapter.probe()
        guard probe.installed, let executableURL = probe.executableURL else {
            throw ConductorRunError.adapterUnavailable
        }
        return ConductorResolvedAdapter(
            adapter: adapter, executableURL: executableURL, version: probe.version)
    }

    /// Pure and synchronous — never spawns. Maps a resolved adapter, prompt,
    /// and evidence layout onto the terminal seam's process specification.
    func specification(
        role: ConductorAgentDefinition,
        prompt: String,
        evidence: ConductorRunEvidence,
        plan: ConductorWorkspacePlan,
        resolved: ConductorResolvedAdapter,
        roleBadge: String
    ) -> TerminalProcessSpec {
        let invocation = resolved.adapter.invocation(
            prompt: prompt,
            model: role.model,
            autonomy: role.autonomy,
            workingDirectory: plan.executionRoot,
            runDirectory: evidence.runDirectory,
            handoffDirectory: evidence.handoffDirectory)
        return TerminalProcessSpec(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            currentDirectoryPath: plan.executionRoot.path,
            environment: invocation.environment,
            roleBadge: roleBadge,
            outputLogURL: evidence.logsDirectory.appending(
                path: "output.log", directoryHint: .notDirectory),
            // Role plus vendor, so the Resources surface names what is actually
            // consuming memory instead of an anonymous "Terminal N" (C7).
            resourceAttribution: "\(role.name) • \(role.provider.displayName)")
    }

    static func binding(
        role: ConductorAgentDefinition,
        resolved: ConductorResolvedAdapter
    ) -> ConductorRunManifest.AgentBinding {
        ConductorRunManifest.AgentBinding(
            provider: role.provider,
            model: role.model,
            autonomy: role.autonomy,
            adapterVersion: resolved.version)
    }
}

/// What a completed step's process exit means once its handoff artifact has
/// been checked (ADR 0018: exit zero AND an artifact present, never exit
/// code alone).
nonisolated enum ConductorStepOutcome: Equatable, Sendable {
    case completed
    case processFailed(Int32?)
    case missingArtifact

    static func of(exitCode: Int32?, artifactExists: Bool) -> ConductorStepOutcome {
        guard exitCode == 0 else { return .processFailed(exitCode) }
        return artifactExists ? .completed : .missingArtifact
    }
}

/// Builds the prompt handed to a role's CLI. `singleRole` reproduces C1's
/// exact prompt body; `step` is C5's pipeline variant, which additionally
/// lists earlier steps' artifacts by absolute path so a downstream role reads
/// them itself rather than having their content inlined into argv.
nonisolated enum ConductorPromptComposer {
    static func singleRole(role: ConductorAgentDefinition, taskPrompt: String) throws -> String {
        let task = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw ConductorRunError.emptyTaskPrompt }
        let rolePrompt = role.promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            \(rolePrompt)

            Task:
            \(task)

            Write the required handoff artifact to \
            $\(RafuConductorEnvironment.handoff)/\(role.handoffArtifact).
            """
    }

    /// `inputs` are ABSOLUTE paths only — never artifact content. A step with
    /// no declared inputs omits the "Input artifacts" section entirely, so
    /// its prompt is otherwise identical in shape to `singleRole`'s.
    static func step(
        role: ConductorAgentDefinition,
        taskPrompt: String,
        inputs: [(name: String, url: URL)]
    ) -> String {
        let rolePrompt = role.promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [rolePrompt, "Task:\n\(task)"]
        if !inputs.isEmpty {
            let list = inputs.map { "- \($0.name): \($0.url.path)" }.joined(separator: "\n")
            sections.append("Input artifacts (read these files before you begin):\n\(list)")
        }
        sections.append(
            "Write the required handoff artifact to "
                + "$\(RafuConductorEnvironment.handoff)/\(role.handoffArtifact)."
        )
        return sections.joined(separator: "\n\n")
    }
}
