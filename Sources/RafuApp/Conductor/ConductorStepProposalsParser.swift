import Foundation

/// Parses a completed step's handoff artifact for an OPTIONAL `proposes:`
/// frontmatter list (C8-04). Shares `ConductorFrontmatter`'s tiny,
/// dependency-free scanning grammar with `ConductorAgentFileParser`/
/// `ConductorWorkflowFileParser` — same `---` fences, same `key:` then
/// `- item` list continuation shape as `steps:` in a workflow file — but is
/// deliberately its OWN parser: an artifact is arbitrary agent-authored
/// Markdown, not a `.rafu/agents|workflows` definition file, and a malformed
/// one must never fail an otherwise-completed step.
///
/// Every entry point here is pure and NEVER throws: the caller
/// (`ConductorWorkflowController.readProposals(at:)`) already bounds the file
/// read itself; this type only has to tolerate whatever bytes made it through
/// that bound.
nonisolated enum ConductorStepProposalsParser {
    /// A over-cap proposals list is truncated to this many entries, the last
    /// becoming `"… (truncated)"` (advisor A6) — never silently dropped and
    /// never unbounded.
    static let maximumEntries = 16
    static let maximumEntryCharacters = 200
    static let truncationMarker = "… (truncated)"

    /// Returns `nil` for: no frontmatter at all, a `proposes:` key with an
    /// inline (scalar) value rather than a list, or no `proposes:` key.
    /// Returns a non-empty, capped, per-entry-bounded list otherwise.
    static func parse(_ text: String) -> [String]? {
        let allLines = ConductorFrontmatter.lines(of: text)
        guard let block = try? ConductorFrontmatter.block(in: allLines) else { return nil }

        var entries: [String] = []
        var inProposesList = false
        for line in block.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("-") {
                guard inProposesList else { continue }
                let item = ConductorFrontmatter.unquoted(
                    String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                guard !item.isEmpty else { continue }
                entries.append(String(item.prefix(maximumEntryCharacters)))
                continue
            }

            // A line this build's tiny grammar cannot parse as `key: value`
            // (e.g. a nested/foreign frontmatter shape) simply ends whatever
            // list was open — never a thrown parse failure.
            guard let scalar = try? ConductorFrontmatter.scalar(line) else {
                inProposesList = false
                continue
            }
            if scalar.key == "proposes" {
                // `proposes: something` inline is a SCALAR, not the
                // supported list shape — reject the whole field rather than
                // silently reading one entry from it.
                inProposesList = scalar.value.isEmpty
                continue
            }
            inProposesList = false
        }

        guard !entries.isEmpty else { return nil }
        guard entries.count > maximumEntries else { return entries }
        return Array(entries.prefix(maximumEntries - 1)) + [truncationMarker]
    }
}
