// The mend: one honest line after the agent's weave
struct CommitScope {
    let files: [WorkspacePath]
    let redactedCount: Int

    var payload: String {
        files
            .filter { !$0.isSensitive }
            .map(\.diffText)
            .joined(separator: "\n")
    }

    static let payloadLimit = 24_000
}

// Nothing is sent until you preview the exact payload.
let scope = CommitScope.staged(in: repository)
try await provider.draft(scope, style: .conventional)
