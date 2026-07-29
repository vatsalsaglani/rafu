import Foundation

/// Presentation-only boundary for one Ensemble run terminal. The renderer is
/// deliberately not a run-engine dependency: it receives PTY bytes, returns
/// bytes for terminal display and `output.log`, and has no callback into run
/// state or evidence completion.
@MainActor
protocol ConductorRunOutputRendering: AnyObject {
    func render(_ slice: ArraySlice<UInt8>) throws -> Data
    func finish() throws -> Data
}

/// Turns Claude Code's newline-delimited `stream-json` output into compact,
/// readable terminal lines. It recognizes only verified event shapes. Unknown
/// or malformed lines stay byte-for-byte raw so vendor schema changes stay
/// visible evidence instead of silently changing run behavior.
@MainActor
final class ConductorRunTerminalOutputRenderer: ConductorRunOutputRendering {
    /// A normal stream-json event is far smaller than this. If a child emits
    /// an unbroken oversized line, pass it through raw instead of retaining
    /// unbounded main-actor memory while waiting for a newline.
    private static let maximumBufferedLineBytes = 64 * 1_024

    private var pending = Data()
    private var isPassingThroughUnterminatedLine = false

    func render(_ slice: ArraySlice<UInt8>) throws -> Data {
        if isPassingThroughUnterminatedLine {
            return try renderPassThroughLine(slice)
        }
        pending.append(contentsOf: slice)
        var rendered = renderCompleteLines()
        if pending.count > Self.maximumBufferedLineBytes {
            rendered.append(pending)
            pending.removeAll(keepingCapacity: false)
            isPassingThroughUnterminatedLine = true
        }
        return rendered
    }

    func finish() throws -> Data {
        guard !pending.isEmpty else { return Data() }
        defer { pending.removeAll(keepingCapacity: false) }
        return renderLine(pending)
    }

    private func renderCompleteLines() -> Data {
        var rendered = Data()
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineEnd = pending.index(after: newlineIndex)
            rendered.append(renderLine(pending[..<lineEnd]))
            pending.removeSubrange(..<lineEnd)
        }
        return rendered
    }

    /// Once an oversized line has started raw, it stays raw through its own
    /// newline. The bytes after that newline start a fresh, eligible line.
    private func renderPassThroughLine(_ slice: ArraySlice<UInt8>) throws -> Data {
        let raw = Data(slice)
        guard let newlineIndex = raw.firstIndex(of: 0x0A) else { return raw }

        let lineEnd = raw.index(after: newlineIndex)
        var rendered = Data(raw[..<lineEnd])
        isPassingThroughUnterminatedLine = false
        let remainder = raw[lineEnd...]
        if !remainder.isEmpty {
            rendered.append(try render(ArraySlice(remainder)))
        }
        return rendered
    }

    private func renderLine(_ rawLine: Data) -> Data {
        let content: Data
        let lineEnding: String
        if rawLine.suffix(2) == Data([0x0D, 0x0A]) {
            content = rawLine.dropLast(2)
            lineEnding = "\r\n"
        } else if rawLine.last == 0x0A {
            content = rawLine.dropLast()
            lineEnding = "\n"
        } else {
            content = rawLine
            lineEnding = ""
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: content),
            let event = object as? [String: Any],
            let line = presentationLine(for: event)
        else {
            return rawLine
        }
        return Data((line + lineEnding).utf8)
    }

    private func presentationLine(for event: [String: Any]) -> String? {
        guard let type = event["type"] as? String else { return nil }
        switch type {
        case "system":
            return initLine(for: event)
        case "assistant":
            return assistantLine(for: event)
        case "rate_limit_event":
            return rateLimitLine(for: event)
        case "result":
            return resultLine(for: event)
        default:
            // The schema is intentionally not a run protocol. A new event is
            // more honest as raw evidence than as a guessed status message.
            return nil
        }
    }

    private func initLine(for event: [String: Any]) -> String? {
        guard event["subtype"] as? String == "init",
            let model = event["model"] as? String,
            let permissionMode = stringValue(
                event["permissionMode"] ?? event["permission_mode"])
        else {
            return nil
        }
        return "initialized: \(model) (permission: \(permissionMode))"
    }

    private func assistantLine(for event: [String: Any]) -> String? {
        guard let message = event["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else {
            return nil
        }

        if let text = content.compactMap({ block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }).first(where: { !$0.isEmpty }) {
            // The requested user-visible answer is evidence. Do not trim,
            // summarize, or otherwise change assistant text.
            return text
        }

        if let tool = content.first(where: { $0["type"] as? String == "tool_use" }),
            let name = tool["name"] as? String
        {
            let target = primaryToolTarget(in: tool["input"] as? [String: Any] ?? [:])
            return target.map { "tool: \(name) \($0)" } ?? "tool: \(name)"
        }

        if content.contains(where: { $0["type"] as? String == "thinking" })
            || tokenCount(in: message["usage"]) != nil
            || tokenCount(in: event["thinking_tokens"]) != nil
        {
            return "thinking…"
        }
        return nil
    }

    private func rateLimitLine(for event: [String: Any]) -> String? {
        guard let rateLimitInfo = event["rate_limit_info"] as? [String: Any],
            let status = rateLimitInfo["status"] as? String
        else {
            return nil
        }
        return "rate limit: \(status)"
    }

    private func resultLine(for event: [String: Any]) -> String? {
        guard let durationMilliseconds = numberValue(event["duration_ms"]),
            let cost = numberValue(event["total_cost_usd"])
        else {
            return nil
        }
        let outcome = event["is_error"] as? Bool == true ? "failed" : "completed"
        return "result: \(outcome) in \(duration(durationMilliseconds)); cost \(costUSD(cost))"
    }

    private func primaryToolTarget(in input: [String: Any]) -> String? {
        let pathKeys = ["file_path", "path", "notebook_path", "filename"]
        for key in pathKeys {
            guard let value = input[key] as? String, !value.isEmpty else { continue }
            let lastPathComponent = URL(fileURLWithPath: value).lastPathComponent
            return shortened(lastPathComponent.isEmpty ? value : lastPathComponent)
        }
        for key in ["command", "query", "pattern", "url", "prompt"] {
            guard let value = input[key] as? String, !value.isEmpty else { continue }
            return shortened(value)
        }
        return nil
    }

    private func shortened(_ value: String, limit: Int = 96) -> String {
        let singleLine =
            value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    private func tokenCount(in value: Any?) -> Int? {
        numberValue(value).map { Int($0) }
            ?? (value as? [String: Any]).flatMap { numberValue($0["thinking_tokens"]) }.map {
                Int($0)
            }
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func duration(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 {
            return "\(Int(milliseconds.rounded())) ms"
        }
        return String(format: "%.1f s", milliseconds / 1_000)
    }

    private func costUSD(_ value: Double) -> String {
        var amount = String(format: "%.4f", value)
        while amount.contains(".") && amount.last == "0" {
            amount.removeLast()
        }
        if amount.last == "." { amount.append("0") }
        return "$\(amount)"
    }
}
