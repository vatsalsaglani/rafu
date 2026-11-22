import Foundation
import RafuCore

/// One hook invocation: read bounded stdin, normalize, add the parent PID
/// chain, and write one spool file. Every failure is silent; the caller
/// exits 0 either way.
///
/// The answer mode (`rafu-agent-events claude <spool> --answer`) is a separate
/// hook entry for Claude Code's `PermissionRequest` only. While Rafu watches,
/// it writes every request with a bounded request summary, so Up next can
/// show it. It waits for Rafu's answer only for a class Up next can answer (a
/// command, a file change, a tool call, a question set) and prints the
/// decision JSON; for a plan or an unclassified request it exits at once. It
/// prints nothing, and so leaves Claude's own dialog in charge, when Rafu is
/// not watching, the request is only shown, Rafu sends `dismiss`, the answer
/// does not fit the request (`ClaudeAnswerModeRequest`), or the wait times
/// out. It never logs a command, a path, a question, or an answer.
enum AgentEventHelper {
    /// The command-line flag that selects the answer mode. The same constant
    /// that Rafu writes into the answer hook entry.
    static let answerFlag = AgentHookConfiguration.answerFlag

    /// Whether `arguments` select the answer mode (the flag comes last).
    static func isAnswerMode(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && arguments.last == answerFlag
    }

    static func run(arguments: [String]) {
        let answering = isAnswerMode(arguments)
        let arguments = answering ? Array(arguments.dropLast()) : arguments
        guard arguments.count >= 2, arguments.count <= 3,
            let provider = AgentHookProvider(rawValue: arguments[1])
        else { return }
        let spool: URL
        if arguments.count == 3 {
            spool = URL(fileURLWithPath: arguments[2], isDirectory: true)
            guard AgentTrackingPaths.isSpoolDirectory(spool) else { return }
        } else {
            // The answer channel needs the spool it belongs to.
            guard !answering else { return }
            spool = AgentTrackingPaths(identity: .release).spool
        }
        if answering { guard provider == .claude else { return } }
        let channel = AgentAnswerChannel(spool: spool)
        // Read all of stdin first, so Claude's write never meets a closed pipe.
        guard let payload = readStandardInput(limit: AgentHookEvent.maximumPayloadBytes),
            var event = try? AgentHookEvent(
                provider: provider, payload: payload, includesRequestSummary: answering)
        else { return }
        var request: ClaudeAnswerModeRequest?
        if answering {
            // Not watched means nobody can show or answer it.
            guard event.hookEventName == "PermissionRequest", channel.isWatched,
                let kept = ClaudeAnswerModeRequest(event: event, payload: payload)
            else { return }
            request = kept
        }
        event.ancestorProcessIDs = ProcessAncestry.parentChain(
            limit: AgentHookEvent.maximumAncestors)
        do {
            try AgentHookSpool.write(event, to: spool)
        } catch {
            return
        }
        // A plan or an unclassified request is only shown: no wait.
        guard let request, request.waitsForAnswer else { return }
        if let output = request.output(for: channel.wait(eventID: event.id)) {
            FileHandle.standardOutput.write(output + Data("\n".utf8))
        }
    }

    /// All of stdin, or `nil` once it passes `limit` bytes.
    static func readStandardInput(limit: Int) -> Data? {
        var input = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
            input.append(chunk)
            if input.count > limit { return nil }
        }
        return input
    }
}
