import Foundation

/// Checks the tool list in the model request that Codex sends (the probe's
/// capture step). Codex shows no tool list in its `--json` stream and the
/// stream is not a full audit log, so the probe reads the request that
/// Codex would send to the model, through a loopback listener, and accepts
/// only the checked tools:
///
/// - top-level tools (from each `input[]` item of type `additional_tools`,
///   with `namespace` names as a prefix, and any top-level `tools`): exactly
///   `functions.exec`, `functions.wait`, `functions.request_user_input` and
///   `functions.request_user_input_async`;
/// - nested tools in the `exec` description (each
///   `declare const tools: { <name>(`): exactly `apply_patch`,
///   `list_mcp_resources`, `list_mcp_resource_templates`,
///   `read_mcp_resource` and `clock__curr_time`;
/// - no message text with `<skills_instructions>`.
///
/// A request in another shape is unreadable: the probe fails closed.
public enum MeetingCodexToolListCheck {
    public enum Verdict: Hashable, Sendable {
        case passed
        /// The request is readable, and its tools are not the checked ones.
        case differentTools
        case unreadable
    }

    public static let checkedTools: Set<String> = [
        "functions.exec", "functions.wait", "functions.request_user_input",
        "functions.request_user_input_async",
    ]
    public static let checkedNestedTools: Set<String> = [
        "apply_patch", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource",
        "clock__curr_time",
    ]
    static let nestedMark = "declare const tools: { "
    static let skillsMark = "<skills_instructions>"

    public static func check(_ body: Data) -> Verdict {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let input = request["input"] as? [Any]
        else { return .unreadable }

        var tools: [(name: String, tool: [String: Any])] = []
        var sawToolList = false
        if let topLevel = request["tools"] {
            guard let list = topLevel as? [Any], collect(list, prefix: "", into: &tools) else {
                return .unreadable
            }
            sawToolList = true
        }
        var skills = false
        for case let item as [String: Any] in input {
            switch item["type"] as? String {
            case "additional_tools":
                guard let list = item["tools"] as? [Any], collect(list, prefix: "", into: &tools)
                else { return .unreadable }
                sawToolList = true
            case "message":
                if messageText(item).contains(where: { $0.contains(skillsMark) }) { skills = true }
            default:
                break
            }
        }
        guard sawToolList, !tools.isEmpty else { return .unreadable }

        let names = tools.map(\.name)
        guard names.count == checkedTools.count, Set(names) == checkedTools else {
            return .differentTools
        }
        guard let exec = tools.first(where: { $0.name == "functions.exec" })?.tool,
            let description = exec["description"] as? String
        else { return .unreadable }
        guard let nested = nestedNames(in: description), !nested.isEmpty else {
            return .unreadable
        }
        guard nested.count == checkedNestedTools.count, Set(nested) == checkedNestedTools,
            !skills
        else { return .differentTools }
        return .passed
    }

    /// Adds each tool of `list` with its full name. False when a tool has no
    /// name.
    private static func collect(
        _ list: [Any], prefix: String, into tools: inout [(name: String, tool: [String: Any])]
    ) -> Bool {
        for case let tool as [String: Any] in list {
            guard let name = tool["name"] as? String, !name.isEmpty else { return false }
            if tool["type"] as? String == "namespace" {
                guard let inner = tool["tools"] as? [Any],
                    collect(inner, prefix: prefix + name + ".", into: &tools)
                else { return false }
            } else {
                tools.append((prefix + name, tool))
            }
        }
        return true
    }

    /// The text parts of one message item.
    private static func messageText(_ item: [String: Any]) -> [String] {
        if let text = item["content"] as? String { return [text] }
        guard let parts = item["content"] as? [Any] else { return [] }
        return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }
    }

    /// The name after each `declare const tools: { `, up to `(`. Nil when
    /// one mark is not followed by a name and `(`.
    static func nestedNames(in description: String) -> [String]? {
        var names: [String] = []
        var rest = description[...]
        while let mark = rest.range(of: nestedMark) {
            let after = rest[mark.upperBound...]
            let name = after.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            guard !name.isEmpty, after.dropFirst(name.count).first == "(" else { return nil }
            names.append(String(name))
            rest = after
        }
        return names
    }
}
