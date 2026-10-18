import Foundation
import RafuCore

/// One hook invocation: read bounded stdin, normalize, add the parent PID
/// chain, and write one spool file. Every failure is silent; the caller
/// exits 0 either way.
enum AgentEventHelper {
    static func run(arguments: [String]) {
        guard arguments.count >= 2, arguments.count <= 3,
            let provider = AgentHookProvider(rawValue: arguments[1])
        else { return }
        let spool: URL
        if arguments.count == 3 {
            spool = URL(fileURLWithPath: arguments[2], isDirectory: true)
            guard AgentTrackingPaths.isSpoolDirectory(spool) else { return }
        } else {
            spool = AgentTrackingPaths(identity: .release).spool
        }
        guard let payload = readStandardInput(limit: AgentHookEvent.maximumPayloadBytes),
            var event = try? AgentHookEvent(provider: provider, payload: payload)
        else { return }
        event.ancestorProcessIDs = ProcessAncestry.parentChain(
            limit: AgentHookEvent.maximumAncestors)
        try? AgentHookSpool.write(event, to: spool)
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
