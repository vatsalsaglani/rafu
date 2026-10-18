import Foundation
import RafuCore
import Testing

@testable import RafuApp

// Synthetic sessions only. Image bytes are a magic-byte header, not an image.

private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func userLine(_ text: String, image: Data? = nil) -> String {
    var content: [[String: Any]] = []
    if let image {
        content.append([
            "type": "image",
            "source": [
                "type": "base64", "media_type": "image/png", "data": image.base64EncodedString(),
            ],
        ])
    }
    content.append(["type": "text", "text": text])
    return jsonLine([
        "type": "user", "timestamp": "2026-01-02T10:00:00.000Z", "cwd": "/work/alpha",
        "sessionId": "s1", "message": ["role": "user", "content": content],
    ])
}

private func replyLine(_ text: String) -> String {
    jsonLine([
        "type": "assistant", "timestamp": "2026-01-02T10:00:01.000Z", "cwd": "/work/alpha",
        "sessionId": "s1",
        "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
    ])
}

private struct Fixture {
    let summary: AgentHistorySessionSummary
    let project: URL
    let folder: URL

    func remove() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: project)
    }
}

/// 35 turns; the image sits in the first one, so the default last-30 range
/// leaves it out.
private func makeFixture(isGitRepository: Bool) throws -> Fixture {
    let manager = FileManager.default
    let folder = manager.temporaryDirectory
        .appendingPathComponent("handoff-model-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var lines: [String] = []
    for index in 0..<35 {
        lines.append(userLine("question \(index)", image: index == 0 ? pngHeader : nil))
        lines.append(replyLine("answer \(index)"))
    }
    let url = folder.appendingPathComponent("s1.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    let project = manager.temporaryDirectory
        .appendingPathComponent("handoff-project-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    if isGitRepository {
        try manager.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    let summary = AgentHistorySessionSummary(
        key: AgentHistorySessionKey(provider: .claudeCode, sessionID: "s1"), title: "Fix login",
        projectPath: "/work/alpha", startedAt: nil, updatedAt: nil, gitBranch: "main",
        messageCount: 70, isMessageCountEstimated: false, fileURL: url, fileSize: 1,
        modificationDate: Date(timeIntervalSince1970: 0))
    return Fixture(summary: summary, project: project, folder: folder)
}

@MainActor
private func loadedModel(_ fixture: Fixture) async -> AgentHandoffModel {
    let model = AgentHandoffModel(
        request: AgentHandoffRequest(
            summary: fixture.summary, target: .codex, origin: .history),
        projectRoot: fixture.project)
    model.load()
    await model.loadTask?.value
    await model.decodeTask?.value
    await model.attachmentTask?.value
    return model
}

@MainActor
@Test func handoffModelStartsWithTheAgreedDefaults() async throws {
    let fixture = try makeFixture(isGitRepository: true)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    #expect(model.phase == .ready)
    #expect(model.target == .codex)
    #expect(model.rangeChoice == .last)
    #expect(model.lastTurnCount == 30)
    #expect(model.includesToolCalls)
    #expect(!model.includesToolOutputs)
    #expect(model.totalTurnCount == 35)
    #expect(model.document?.includedTurnCount == 30)
    #expect(model.gitignoreState == .needsEntry)
    #expect(model.addsGitignore)
    #expect(model.canWrite)
    #expect(model.options.excludedImageIDs.isEmpty)
}

@MainActor
@Test func handoffModelOffersNoGitignoreOutsideAGitRepository() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    #expect(model.gitignoreState == .notGitRepository)
    #expect(!model.addsGitignore)
}

@MainActor
@Test func handoffModelDecodesImagesOnlyForTheChosenRange() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    #expect(model.imageRows.isEmpty)
    #expect(model.document?.imageFiles.isEmpty == true)

    model.rangeChoice = .all
    await model.decodeTask?.value
    #expect(model.document?.includedTurnCount == 35)
    #expect(model.imageRows.count == 1)
    guard case .ready(let image)? = model.imageRows.first?.status else {
        Issue.record("expected the image to be decoded")
        return
    }
    #expect(image.format == .png)
    #expect(model.document?.imageFiles.map(\.name) == ["image-01.png"])
    #expect(model.document?.markdown.contains("![image-01](image-01.png)") == true)
    #expect(model.isImageIncluded(model.imageRows[0].id))
}

@MainActor
@Test func handoffModelLeavesOutAnUncheckedImage() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    model.rangeChoice = .all
    await model.decodeTask?.value
    let id = try #require(model.imageRows.first?.id)
    model.setImage(id, included: false)
    #expect(!model.isImageIncluded(id))
    #expect(model.document?.imageFiles.isEmpty == true)
    #expect(model.document?.markdown.contains("left out in the review") == true)
    model.setImage(id, included: true)
    #expect(model.document?.imageFiles.count == 1)
}

@MainActor
@Test func handoffModelClampsTheTurnCountAndRerenders() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    model.lastTurnCount = 5
    #expect(model.document?.includedTurnCount == 5)
    model.lastTurnCount = 0
    #expect(model.lastTurnCount == 1)
    #expect(model.document?.includedTurnCount == 1)
    model.lastTurnCount = 9_999
    #expect(model.lastTurnCount == 500)
}

@MainActor
@Test func handoffModelReportsAMissingSessionFile() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.summary.fileURL)
    let model = await loadedModel(fixture)
    #expect(model.phase == .failed("Rafu could not read this session."))
    #expect(!model.canWrite)
}

@MainActor
@Test func handoffModelCannotWriteWithoutAProject() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = AgentHandoffModel(
        request: AgentHandoffRequest(
            summary: fixture.summary, target: .claudeCode, origin: .history),
        projectRoot: nil)
    model.load()
    await model.loadTask?.value
    #expect(!model.canWrite)
}

@MainActor
@Test func handoffModelNotesASessionFromAnotherFolder() async throws {
    let fixture = try makeFixture(isGitRepository: false)
    defer { fixture.remove() }
    let model = await loadedModel(fixture)
    // The session ran in /work/alpha; the project is a temporary folder.
    #expect(model.sessionRanElsewhere)
}

@Test func handoffProviderMapsFromTheAgentCLI() {
    #expect(AgentHistoryProvider(cli: .claudeCode) == .claudeCode)
    #expect(AgentHistoryProvider(cli: .codex) == .codex)
    #expect(AgentHistoryProvider(cli: .geminiCLI) == nil)
    #expect(AgentHistoryProvider(cli: nil) == nil)
}
