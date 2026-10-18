import Foundation
import Testing

@testable import RafuCore

private typealias Fixtures = AgentHandoffFixtures

// MARK: Formats and digest

@Test func handoffDetectsImageFormatsByMagicBytes() {
    #expect(AgentHandoffImageFormat.detect(Fixtures.pngData()) == .png)
    #expect(AgentHandoffImageFormat.detect(Fixtures.jpegData()) == .jpeg)
    #expect(AgentHandoffImageFormat.detect(Fixtures.gifData()) == .gif)
    #expect(AgentHandoffImageFormat.detect(Fixtures.webpData()) == .webp)
    #expect(AgentHandoffImageFormat.detect(Data("<svg></svg>".utf8)) == nil)
    #expect(AgentHandoffImageFormat.detect(Data()) == nil)
    // RIFF without WEBP is not WebP.
    #expect(AgentHandoffImageFormat.detect(Data("RIFF....WAVEfmt ".utf8)) == nil)
}

@Test func handoffSHA256MatchesKnownVectors() {
    #expect(
        AgentHandoffDigest.sha256Hex(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
        AgentHandoffDigest.sha256Hex(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

// MARK: Decoder

@Test func handoffDecodesBase64ImageAndHashesIt() throws {
    let data = Fixtures.pngData()
    let result = AgentHandoffImageDecoder.decode(base64: data.base64EncodedString())
    guard case .image(let image) = result else {
        Issue.record("expected an image, got \(result)")
        return
    }
    #expect(image.format == .png)
    #expect(image.data == data)
    #expect(image.sha256 == AgentHandoffDigest.sha256Hex(data))
}

@Test func handoffSkipsBadBase64() {
    #expect(AgentHandoffImageDecoder.decode(base64: "!!!") == .skipped(.badEncoding))
    #expect(AgentHandoffImageDecoder.decode(base64: "") == .skipped(.badEncoding))
}

@Test func handoffSkipsImagesOverTheSizeLimit() {
    var big = Fixtures.pngData()
    big.append(Data(repeating: 1, count: 100))
    let text = big.base64EncodedString()
    #expect(AgentHandoffImageDecoder.decode(base64: text, maximumBytes: 50) == .skipped(.tooLarge))
    #expect(AgentHandoffImageDecoder.verify(big, maximumBytes: 50) == .skipped(.tooLarge))
    // At the limit it still passes.
    if case .skipped = AgentHandoffImageDecoder.decode(base64: text, maximumBytes: big.count) {
        Issue.record("an image at the limit must pass")
    }
}

@Test func handoffSkipsWrongMagicBytes() {
    let text = Data("this is plain text, not an image".utf8).base64EncodedString()
    #expect(AgentHandoffImageDecoder.decode(base64: text) == .skipped(.unsupportedType))
}

@Test func handoffClassifiesCodexImageReferences() {
    let png = Fixtures.pngData().base64EncodedString()
    #expect(
        AgentHandoffImageExtractor.classify(reference: "data:image/png;base64,\(png)")
            == .base64(png))
    #expect(AgentHandoffImageExtractor.classify(reference: "data:image/png,rawtext") == .unusable)
    #expect(AgentHandoffImageExtractor.classify(reference: "https://example.com/a.png") == .remote)
    #expect(
        AgentHandoffImageExtractor.classify(reference: "/tmp/a.png") == .localFile("/tmp/a.png"))
    #expect(
        AgentHandoffImageExtractor.classify(reference: "file:///tmp/a%20b.png")
            == .localFile("/tmp/a b.png"))
    #expect(AgentHandoffImageExtractor.classify(reference: "relative/a.png") == .unusable)
}

@Test func handoffDecodesLocalFilesWithTheSameChecks() throws {
    let folder = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: folder) }
    let good = folder.appendingPathComponent("good.png")
    try Fixtures.pngData().write(to: good)
    let text = folder.appendingPathComponent("fake.png")
    try Data("not an image".utf8).write(to: text)
    guard case .image = AgentHandoffImageDecoder.decode(localFile: good.path) else {
        Issue.record("expected the local PNG to decode")
        return
    }
    #expect(AgentHandoffImageDecoder.decode(localFile: text.path) == .skipped(.unsupportedType))
    #expect(
        AgentHandoffImageDecoder.decode(localFile: folder.appendingPathComponent("no.png").path)
            == .skipped(.missingFile))
    #expect(AgentHandoffImageDecoder.decode(localFile: folder.path) == .skipped(.unreadable))
    #expect(AgentHandoffImageDecoder.decode(.remote) == .skipped(.remoteURL))
}

// MARK: Claude Code loader

@Test func handoffClaudeLoaderPlacesMessageAndToolResultImages() async throws {
    let png = Fixtures.pngData()
    let jpeg = Fixtures.jpegData()
    let url = try Fixtures.file([
        Fixtures.claudeUser("first prompt"),
        Fixtures.claudeAssistant([
            ["type": "thinking", "thinking": "SECRET THOUGHT"],
            ["type": "text", "text": "Looking."],
            [
                "type": "tool_use", "id": "t1", "name": "Read",
                "input": ["file_path": "Sources/App.swift"],
            ],
        ]),
        Fixtures.claudeToolResult(id: "t1", text: "file body", images: [jpeg]),
        Fixtures.claudeUser("second prompt @docs/notes.md", images: [png, png]),
        Fixtures.claudeAssistant([["type": "text", "text": "Done."]]),
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let conversation = try AgentHandoffLoader.load(fileURL: url, provider: .claudeCode)
    #expect(conversation.turns.count == 2)
    #expect(!conversation.items.contains { $0.kind == .thinking })
    #expect(!conversation.items.contains { $0.text.contains("SECRET THOUGHT") })

    let toolResult = try #require(conversation.items.first { $0.kind == .toolResult })
    #expect(toolResult.images.count == 1)
    #expect(toolResult.images[0].isToolResult)
    let secondPrompt = try #require(
        conversation.items.first { $0.text.contains("second prompt") })
    #expect(secondPrompt.images.count == 2)
    #expect(secondPrompt.attachmentPaths == ["docs/notes.md"])
    let toolCall = try #require(conversation.items.first { $0.kind == .toolCall })
    #expect(toolCall.attachmentPaths == ["Sources/App.swift"])

    let summary = AgentHistorySessionSummary(
        key: AgentHistorySessionKey(provider: .claudeCode, sessionID: "s1"), title: "t",
        projectPath: nil, startedAt: nil, updatedAt: nil, gitBranch: nil, messageCount: 0,
        isMessageCountEstimated: false, fileURL: url, fileSize: 0,
        modificationDate: Date(timeIntervalSince1970: 0))
    let refs = conversation.items.flatMap(\.images)
    let results = await AgentHandoffLoader.decodeImages(refs, session: summary)
    #expect(results.count == 3)
    guard case .image(let first) = results[secondPrompt.images[0].id],
        case .image(let second) = results[secondPrompt.images[1].id],
        case .image(let fromTool) = results[toolResult.images[0].id]
    else {
        Issue.record("expected three decoded images")
        return
    }
    #expect(first.format == .png)
    #expect(first.sha256 == second.sha256)
    #expect(fromTool.format == .jpeg)
    #expect(fromTool.data == jpeg)
}

@Test func handoffClaudeFileAttachmentEntriesJoinTheNextEntry() throws {
    let url = try Fixtures.file([
        Fixtures.line([
            "type": "attachment",
            "attachment": [
                "type": "file", "filename": "/work/alpha/src/main.swift",
                "displayPath": "src/main.swift", "content": ["type": "file"],
            ],
        ]),
        Fixtures.claudeUser("look at it"),
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let conversation = try AgentHandoffLoader.load(fileURL: url, provider: .claudeCode)
    #expect(conversation.items.count == 1)
    #expect(conversation.items[0].attachmentPaths == ["/work/alpha/src/main.swift"])
}

@Test func handoffClaudeRemoteAndBrokenImagesAreMarkedSkipped() throws {
    let url = try Fixtures.file([
        Fixtures.line([
            "type": "user", "timestamp": "2026-01-02T10:00:00.000Z",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": ["type": "url", "url": "https://example.com/a.png"],
                    ],
                    ["type": "image", "source": ["type": "base64", "data": ""]],
                    ["type": "text", "text": "two bad images"],
                ],
            ],
        ])
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let conversation = try AgentHandoffLoader.load(fileURL: url, provider: .claudeCode)
    let refs = conversation.items.flatMap(\.images)
    #expect(refs.map(\.knownSkip) == [.remoteURL, .badEncoding])
}

@Test func handoffClaudeMarksOversizeImagesWithoutDecoding() throws {
    let huge = String(repeating: "A", count: 8 << 20)
    let url = try Fixtures.file([
        Fixtures.line([
            "type": "user", "timestamp": "2026-01-02T10:00:00.000Z",
            "message": [
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "data": huge]],
                    ["type": "text", "text": "big"],
                ],
            ],
        ])
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let conversation = try AgentHandoffLoader.load(fileURL: url, provider: .claudeCode)
    let ref = try #require(conversation.items.flatMap(\.images).first)
    #expect(ref.knownSkip == .tooLarge)
    #expect((ref.estimatedBytes ?? 0) > AgentHandoffImageLimits.maximumDecodedBytes)
}

// MARK: Codex loader

@Test func handoffCodexLoaderReadsDataURLsFilesAndToolImages() async throws {
    let png = Fixtures.pngData(salt: 1)
    let folder = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: folder) }
    let local = folder.appendingPathComponent("shot.png")
    try Fixtures.pngData(salt: 2).write(to: local)

    let url = try Fixtures.file([
        Fixtures.codexMessage(
            role: "user", text: "see these",
            imageURLs: [
                Fixtures.dataURL(png), local.path, "https://example.com/x.png",
            ]),
        Fixtures.line([
            "timestamp": "2026-02-03T08:00:04.000Z", "type": "response_item",
            "payload": [
                "type": "reasoning", "summary": [["type": "summary_text", "text": "SECRET"]],
            ],
        ]),
        Fixtures.line([
            "timestamp": "2026-02-03T08:00:05.000Z", "type": "response_item",
            "payload": [
                "type": "function_call", "name": "view_image", "call_id": "c1",
                "arguments": "{\"file_path\":\"notes/a.md\"}",
            ],
        ]),
        Fixtures.line([
            "timestamp": "2026-02-03T08:00:06.000Z", "type": "response_item",
            "payload": [
                "type": "function_call_output", "call_id": "c1",
                "output": [["type": "input_image", "image_url": Fixtures.dataURL(png)]],
            ],
        ]),
        Fixtures.codexMessage(role: "assistant", text: "ok"),
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let conversation = try AgentHandoffLoader.load(fileURL: url, provider: .codex)
    #expect(!conversation.items.contains { $0.text.contains("SECRET") })
    let prompt = try #require(conversation.items.first { $0.role == .user && $0.kind == .message })
    #expect(prompt.images.count == 3)
    #expect(prompt.images[2].knownSkip == .remoteURL)
    #expect(prompt.images[1].location == .localFile(path: local.path))
    let call = try #require(conversation.items.first { $0.kind == .toolCall })
    #expect(call.attachmentPaths == ["notes/a.md"])
    let output = try #require(conversation.items.first { $0.kind == .toolResult })
    #expect(output.images.count == 1)

    let summary = AgentHistorySessionSummary(
        key: AgentHistorySessionKey(provider: .codex, sessionID: "s1"), title: "t",
        projectPath: nil, startedAt: nil, updatedAt: nil, gitBranch: nil, messageCount: 0,
        isMessageCountEstimated: false, fileURL: url, fileSize: 0,
        modificationDate: Date(timeIntervalSince1970: 0))
    let results = await AgentHandoffLoader.decodeImages(
        conversation.items.flatMap(\.images), session: summary)
    guard case .image(let fromURL) = results[prompt.images[0].id],
        case .image(let fromFile) = results[prompt.images[1].id],
        case .image(let fromOutput) = results[output.images[0].id]
    else {
        Issue.record("expected three decoded images")
        return
    }
    #expect(fromURL.sha256 == fromOutput.sha256)
    #expect(fromURL.sha256 != fromFile.sha256)
    #expect(results[prompt.images[2].id] == .skipped(.remoteURL))
}

@Test func handoffLoaderKeepsOnlyTheNewestItems() throws {
    var lines: [String] = []
    for index in 0..<20 {
        lines.append(Fixtures.claudeUser("prompt \(index)"))
        lines.append(Fixtures.claudeAssistant([["type": "text", "text": "reply \(index)"]]))
    }
    let url = try Fixtures.file(lines)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let conversation = try AgentHandoffLoader.load(
        fileURL: url, provider: .claudeCode, maximumItems: 10)
    #expect(conversation.items.count == 10)
    #expect(conversation.droppedLeadingItems == 30)
    #expect(conversation.isTrimmedAtStart)
    #expect(conversation.items.last?.text == "reply 19")
}

@Test func handoffLoaderReadsOnlyTheTailOfAHugeFile() throws {
    var lines: [String] = []
    for index in 0..<50 {
        lines.append(Fixtures.claudeUser("prompt \(index)"))
    }
    let url = try Fixtures.file(lines)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let conversation = try AgentHandoffLoader.load(
        fileURL: url, provider: .claudeCode, maximumBytes: 2_000)
    #expect(conversation.readFromTail)
    #expect(conversation.items.count < 50)
    #expect(conversation.items.last?.text == "prompt 49")
    // The cut first line is dropped, never half-parsed.
    #expect(conversation.skippedLineCount == 0)
}

@Test func handoffMentionsFindOnlyPathLikeTokens() {
    let text = "ask @claude about @src/App.swift, and (@docs/a.md). mail me@example.com @v2.0"
    #expect(AgentHandoffMentions.paths(in: text) == ["src/App.swift", "docs/a.md"])
}
