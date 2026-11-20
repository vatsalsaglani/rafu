import Foundation
import RafuCore

/// One hook invocation: read bounded stdin, normalize, add the parent PID
/// chain, and write one spool file. Every failure is silent; the caller
/// exits 0 either way.
///
/// The answer mode (`rafu-agent-events claude <spool> --answer`) is a separate
/// hook entry for Claude Code's `PermissionRequest` only. It writes the event
/// with a bounded request summary, then waits for Rafu's answer and prints the
/// decision JSON. It prints nothing, and so leaves Claude's own dialog in
/// charge, when Rafu is not watching, the tool is not one it summarizes, Rafu
/// sends `dismiss`, or the wait times out. It never logs a command, a path, or
/// an answer.
enum AgentEventHelper {
    /// The command-line flag that selects the answer mode.
    static let answerFlag = "--answer"

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
        if answering {
            // Not watched means nobody can answer. A tool Rafu does not
            // summarize stays with Claude's own dialog.
            guard event.hookEventName == "PermissionRequest", event.requestSummary != nil,
                channel.isWatched
            else { return }
        }
        event.ancestorProcessIDs = ProcessAncestry.parentChain(
            limit: AgentHookEvent.maximumAncestors)
        do {
            try AgentHookSpool.write(event, to: spool)
        } catch {
            return
        }
        guard answering else { return }
        if let output = channel.wait(eventID: event.id).output {
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
