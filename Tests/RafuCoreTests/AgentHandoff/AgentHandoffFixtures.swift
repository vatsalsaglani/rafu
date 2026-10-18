import Foundation

@testable import RafuCore

// Synthetic fixtures for the agent handoff tests. Every value is invented.
// Image bytes are a valid magic-byte header plus filler, never a real image.

enum AgentHandoffFixtures {
    static func pngData(salt: UInt8 = 0) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, salt])
    }

    static func jpegData(salt: UInt8 = 0) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, salt])
    }

    static func gifData() -> Data {
        Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00])
    }

    static func webpData() -> Data {
        Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56])
    }

    /// One JSON object as one line, with sorted keys.
    static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func file(_ lines: [String]) throws -> URL {
        try AgentHistoryFixtures.temporaryFile(lines.joined(separator: "\n") + "\n")
    }

    // MARK: Claude Code

    static func imageBlock(_ data: Data, media: String = "image/png") -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": media, "data": data.base64EncodedString()],
        ]
    }

    static func claudeUser(
        _ text: String?, images: [Data] = [], timestamp: String = "2026-01-02T10:00:00.000Z"
    ) -> String {
        var content: [[String: Any]] = images.map { imageBlock($0) }
        if let text { content.append(["type": "text", "text": text]) }
        return line([
            "type": "user", "timestamp": timestamp, "cwd": "/work/alpha",
            "sessionId": "s1", "message": ["role": "user", "content": content],
        ])
    }

    static func claudeAssistant(
        _ blocks: [[String: Any]], timestamp: String = "2026-01-02T10:00:01.000Z"
    )
        -> String
    {
        line([
            "type": "assistant", "timestamp": timestamp, "cwd": "/work/alpha",
            "sessionId": "s1", "message": ["role": "assistant", "content": blocks],
        ])
    }

    static func claudeToolResult(id: String, text: String, images: [Data] = []) -> String {
        var inner: [[String: Any]] = [["type": "text", "text": text]]
        inner += images.map { imageBlock($0) }
        return line([
            "type": "user", "timestamp": "2026-01-02T10:00:02.000Z", "cwd": "/work/alpha",
            "sessionId": "s1",
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": id, "content": inner]],
            ],
        ])
    }

    // MARK: Codex

    static func codexMessage(
        role: String, text: String?, imageURLs: [String] = [],
        timestamp: String = "2026-02-03T08:00:03.000Z"
    ) -> String {
        var content: [[String: Any]] = imageURLs.map {
            ["type": "input_image", "image_url": $0]
        }
        if let text {
            content.append(["type": role == "user" ? "input_text" : "output_text", "text": text])
        }
        return line([
            "timestamp": timestamp, "type": "response_item",
            "payload": ["type": "message", "role": role, "content": content],
        ])
    }

    static func dataURL(_ data: Data, media: String = "image/png") -> String {
        "data:\(media);base64,\(data.base64EncodedString())"
    }

    // MARK: Items

    static func prompt(_ text: String, images: [AgentHandoffImageRef] = [], paths: [String] = [])
        -> AgentHandoffItem
    {
        AgentHandoffItem(
            role: .user, kind: .message, text: text, images: images, attachmentPaths: paths)
    }

    static func reply(_ text: String, images: [AgentHandoffImageRef] = []) -> AgentHandoffItem {
        AgentHandoffItem(role: .assistant, kind: .message, text: text, images: images)
    }

    static func tool(_ name: String, _ preview: String) -> AgentHandoffItem {
        AgentHandoffItem(
            role: .assistant, kind: .toolCall, text: preview, detail: nil, toolName: name)
    }

    static func toolResult(
        _ name: String, _ output: String, images: [AgentHandoffImageRef] = []
    ) -> AgentHandoffItem {
        AgentHandoffItem(
            role: .user, kind: .toolResult, text: output, detail: output, toolName: name,
            images: images)
    }

    static func ref(_ id: Int, tool: Bool = false) -> AgentHandoffImageRef {
        AgentHandoffImageRef(
            id: id, location: .localFile(path: "/nowhere/\(id).png"), isToolResult: tool)
    }

    static func decoded(_ data: Data) -> AgentHandoffImageResult {
        AgentHandoffImageDecoder.verify(data, maximumBytes: 1 << 20)
    }

    static func metadata(
        source: AgentHistoryProvider = .claudeCode, target: AgentHistoryProvider = .codex,
        title: String = "Fix the login bug"
    ) -> AgentHandoffMetadata {
        AgentHandoffMetadata(
            source: source, target: target, title: title, originalFolder: "/work/alpha",
            branch: "main", startedAt: Date(timeIntervalSince1970: 1_767_348_000),
            endedAt: Date(timeIntervalSince1970: 1_767_351_600))
    }

    static func temporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
}
