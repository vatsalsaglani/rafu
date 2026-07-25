import Foundation

/// Parses one `.rafu/workflows/<stem>.md` pipeline file. Accepted shape:
///
/// ```
/// ---
/// name: Ship a change
/// steps:
///   - advisor
///   - implementor <- brief.md [gate]
///   - documentor <- brief.md, patch.diff
/// ---
/// ```
///
/// Step grammar: `- <agentName>`, then an optional `<- artifact[, artifact…]`
/// input list, then an optional `[gate]` marker requesting a user gate after
/// that step. Extra whitespace anywhere is tolerated; unknown frontmatter
/// keys are ignored; a step line that matches nothing throws with its line
/// number.
///
/// `[gate:remote]` is the opt-in variant: the same user gate, but one the
/// author explicitly marks safe to approve from a notification without first
/// reading the artifact in Rafu. It defaults OFF — a plain `[gate]` only ever
/// offers "Open Run" remotely (C7).
///
/// `[gate]` — not `!gate`. `!` is YAML's tag indicator, and ADR 0018 commits
/// these files to being human-readable, committable, and readable by other
/// tooling; a leading `!` would make an otherwise YAML-shaped document parse
/// as a tagged node in anything that does run a real YAML engine over it.
nonisolated enum ConductorWorkflowFileParser {
    static let gateMarker = "[gate]"
    /// Opt-in remote-approval gate. Deliberately a distinct marker rather than
    /// a modifier on `[gate]`, so approving from a notification is never
    /// something a workflow gains by accident.
    static let remoteGateMarker = "[gate:remote]"
    static let artifactArrow = "<-"

    /// - Parameter defaultName: the file's stem, used when frontmatter has
    ///   no `name`.
    static func parse(_ text: String, defaultName: String) throws -> ConductorWorkflowDefinition {
        let all = ConductorFrontmatter.lines(of: text)
        let block = try ConductorFrontmatter.block(in: all)

        var name: String?
        var steps: [ConductorWorkflowDefinition.Step] = []
        var inStepList = false

        for line in block.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("-") {
                guard inStepList else {
                    throw ConductorParseError.malformedStep(line: line.number)
                }
                steps.append(try step(from: trimmed, line: line.number))
                continue
            }

            guard let scalar = try ConductorFrontmatter.scalar(line) else { continue }
            if scalar.key == "steps" {
                // `steps:` with an inline value is not the supported shape —
                // only the flat one-line-per-step list below it is.
                guard scalar.value.isEmpty else {
                    throw ConductorParseError.malformedStep(line: line.number)
                }
                inStepList = true
                continue
            }
            inStepList = false
            if scalar.key == "name", !scalar.value.isEmpty {
                name = scalar.value
            }
        }

        guard !steps.isEmpty else {
            throw ConductorParseError.workflowHasNoSteps(line: block.closingLineNumber)
        }
        return ConductorWorkflowDefinition(name: name ?? defaultName, steps: steps)
    }

    private static func step(
        from trimmed: String, line: Int
    ) throws -> ConductorWorkflowDefinition.Step {
        var remainder = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)

        var gateAfter = false
        var safeToApproveRemotely = false
        // Checked BEFORE the plain marker: "[gate:remote]" does not end with
        // "[gate]", but testing the plain one first would still be a
        // maintenance trap if either literal ever changes.
        if remainder.hasSuffix(remoteGateMarker) {
            gateAfter = true
            safeToApproveRemotely = true
            remainder = String(remainder.dropLast(remoteGateMarker.count))
                .trimmingCharacters(in: .whitespaces)
        } else if remainder.hasSuffix(gateMarker) {
            gateAfter = true
            remainder = String(remainder.dropLast(gateMarker.count))
                .trimmingCharacters(in: .whitespaces)
        }

        var inputArtifacts: [String] = []
        if let arrow = remainder.range(of: artifactArrow) {
            let listText = String(remainder[arrow.upperBound...])
            remainder = String(remainder[remainder.startIndex..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            inputArtifacts =
                listText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !inputArtifacts.isEmpty else {
                throw ConductorParseError.malformedStep(line: line)
            }
        }

        let agentName = ConductorFrontmatter.unquoted(remainder)
        guard !agentName.isEmpty else {
            throw ConductorParseError.malformedStep(line: line)
        }
        // `[gate]` is a SUFFIX marker and `<-` a separator, so either one
        // still sitting inside the name means the line was written in an
        // order this grammar does not accept (`- advisor [gate] <- brief.md`).
        // Accepting it would silently bind the step to an agent literally
        // named "advisor [gate]", drop the gate, and surface much later as an
        // unrelated "unknown agent" failure mid-run.
        guard
            !agentName.contains(gateMarker),
            !agentName.contains(remoteGateMarker),
            !agentName.contains(artifactArrow),
            !agentName.contains("[")
        else {
            throw ConductorParseError.malformedStep(line: line)
        }
        return ConductorWorkflowDefinition.Step(
            agentName: agentName,
            inputArtifacts: inputArtifacts,
            gateAfter: gateAfter,
            safeToApproveRemotely: safeToApproveRemotely)
    }
}
