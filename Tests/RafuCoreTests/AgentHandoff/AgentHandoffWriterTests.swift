import Foundation
import Testing

@testable import RafuCore

private typealias Fixtures = AgentHandoffFixtures

// MARK: Names

@Test func handoffSlugKeepsLowercaseWordsAndDashes() {
    #expect(AgentHandoffWriter.slug("Fix the Login bug!") == "fix-the-login-bug")
    #expect(AgentHandoffWriter.slug("  --Ünïcode  über-alles ") == "unicode-uber-alles")
    #expect(AgentHandoffWriter.slug("日本語") == "session")
    #expect(AgentHandoffWriter.slug("") == "session")
    #expect(AgentHandoffWriter.slug("../../etc/passwd") == "etc-passwd")
    let long = AgentHandoffWriter.slug(String(repeating: "word ", count: 30))
    #expect(long.count <= 40)
    #expect(!long.hasSuffix("-"))
}

@Test func handoffFolderNameStartsWithTheMinuteStamp() {
    let utc = TimeZone(identifier: "UTC")!
    // 2026-10-18 14:30:00 UTC
    let date = Date(timeIntervalSince1970: 1_792_333_800)
    #expect(
        AgentHandoffWriter.folderName(date: date, title: "Fix login", timeZone: utc)
            == "2026-10-18-1430-fix-login")
    let early = Date(timeIntervalSince1970: 1_767_225_660)  // 2026-01-01 00:01 UTC
    #expect(
        AgentHandoffWriter.folderName(date: early, title: "x", timeZone: utc)
            == "2026-01-01-0001-x")
}

// MARK: Writing

@Test func handoffWritesMarkdownAndImagesInOneFolder() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let result = try AgentHandoffWriter.write(
        markdown: "# hello\n",
        images: [AgentHandoffImageData(name: "image-01.png", data: Fixtures.pngData())],
        projectRoot: project, baseName: "2026-10-18-1430-fix")
    #expect(result.folderName == "2026-10-18-1430-fix")
    #expect(result.folderURL.deletingLastPathComponent().path.hasSuffix(".rafu/handoffs"))
    #expect(try String(contentsOf: result.markdownURL, encoding: .utf8) == "# hello\n")
    #expect(try Data(contentsOf: result.imageURLs[0]) == Fixtures.pngData())
    #expect(result.markdownURL.lastPathComponent == "HANDOFF.md")
}

@Test func handoffNeverReusesAnExistingFolder() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let first = try AgentHandoffWriter.write(
        markdown: "one", images: [], projectRoot: project, baseName: "2026-10-18-1430-fix")
    let second = try AgentHandoffWriter.write(
        markdown: "two", images: [], projectRoot: project, baseName: "2026-10-18-1430-fix")
    let third = try AgentHandoffWriter.write(
        markdown: "three", images: [], projectRoot: project, baseName: "2026-10-18-1430-fix")
    #expect(first.folderName == "2026-10-18-1430-fix")
    #expect(second.folderName == "2026-10-18-1430-fix-2")
    #expect(third.folderName == "2026-10-18-1430-fix-3")
    #expect(try String(contentsOf: first.markdownURL, encoding: .utf8) == "one")
}

@Test func handoffRefusesToWriteThroughALinkThatLeavesTheProject() throws {
    let project = try Fixtures.temporaryProject()
    let outside = try Fixtures.temporaryProject()
    defer {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
        at: project.appendingPathComponent(".rafu"), withDestinationURL: outside)
    #expect(throws: AgentHandoffWriteError.outsideProject) {
        try AgentHandoffWriter.write(
            markdown: "x", images: [], projectRoot: project, baseName: "2026-10-18-1430-x")
    }
    let leaked = try FileManager.default.contentsOfDirectory(atPath: outside.path)
    #expect(leaked.isEmpty)
}

@Test func handoffRefusesAHandoffsFolderLinkedOutsideTheProject() throws {
    let project = try Fixtures.temporaryProject()
    let outside = try Fixtures.temporaryProject()
    defer {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: outside)
    }
    let rafu = project.appendingPathComponent(".rafu")
    try FileManager.default.createDirectory(at: rafu, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: rafu.appendingPathComponent("handoffs"), withDestinationURL: outside)
    #expect(throws: AgentHandoffWriteError.outsideProject) {
        try AgentHandoffWriter.write(
            markdown: "x", images: [], projectRoot: project, baseName: "2026-10-18-1430-x")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func handoffRefusesUnsafeNames() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    for name in ["../escape", "a/b", "", "Upper", "-lead", "with space"] {
        #expect(throws: AgentHandoffWriteError.invalidFileName) {
            try AgentHandoffWriter.write(
                markdown: "x", images: [], projectRoot: project, baseName: name)
        }
    }
    #expect(throws: AgentHandoffWriteError.invalidFileName) {
        try AgentHandoffWriter.write(
            markdown: "x", images: [AgentHandoffImageData(name: "../x.png", data: Data())],
            projectRoot: project, baseName: "ok")
    }
    #expect(throws: AgentHandoffWriteError.invalidFileName) {
        try AgentHandoffWriter.write(
            markdown: "x", images: [AgentHandoffImageData(name: "image-01.svg", data: Data())],
            projectRoot: project, baseName: "ok")
    }
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".rafu").path))
}

@Test func handoffRefusesAMissingProject() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
    #expect(throws: AgentHandoffWriteError.projectUnavailable) {
        try AgentHandoffWriter.write(
            markdown: "x", images: [], projectRoot: missing, baseName: "ok")
    }
}

// MARK: .gitignore

@Test func handoffGitignoreOffersNothingOutsideAGitRepository() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    #expect(AgentHandoffWriter.gitignoreState(projectRoot: project) == .notGitRepository)
}

@Test func handoffGitignoreAppendIsIdempotentAndKeepsOtherLines() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let file = project.appendingPathComponent(".gitignore")
    // No trailing newline, mixed line endings: both stay as they were.
    let original = "build/\r\n*.log\n# keep"
    try Data(original.utf8).write(to: file)

    #expect(AgentHandoffWriter.gitignoreState(projectRoot: project) == .needsEntry)
    #expect(try AgentHandoffWriter.appendGitignoreEntry(projectRoot: project))
    let once = try String(contentsOf: file, encoding: .utf8)
    #expect(once == original + "\n.rafu/handoffs/\n")
    #expect(AgentHandoffWriter.gitignoreState(projectRoot: project) == .alreadyIgnored)

    #expect(try !AgentHandoffWriter.appendGitignoreEntry(projectRoot: project))
    #expect(try String(contentsOf: file, encoding: .utf8) == once)
}

@Test func handoffGitignoreCreatesTheFileWhenMissing() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(try AgentHandoffWriter.appendGitignoreEntry(projectRoot: project))
    #expect(
        try String(
            contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
            == ".rafu/handoffs/\n")
}

@Test func handoffGitignoreRecognisesBroaderLines() throws {
    for line in [".rafu/", "/.rafu", ".rafu/handoffs", "/.rafu/handoffs/", "  .rafu/  "] {
        let project = try Fixtures.temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("a\n\(line)\nb\n".utf8).write(to: project.appendingPathComponent(".gitignore"))
        #expect(AgentHandoffWriter.gitignoreState(projectRoot: project) == .alreadyIgnored)
        #expect(try !AgentHandoffWriter.appendGitignoreEntry(projectRoot: project))
    }
}

@Test func handoffGitignoreRefusesALinkOutsideTheProject() throws {
    let project = try Fixtures.temporaryProject()
    let outside = try Fixtures.temporaryProject()
    defer {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: outside)
    }
    let target = outside.appendingPathComponent("shared-ignore")
    try Data("keep\n".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: project.appendingPathComponent(".gitignore"), withDestinationURL: target)
    #expect(throws: AgentHandoffWriteError.outsideProject) {
        try AgentHandoffWriter.appendGitignoreEntry(projectRoot: project)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep\n")
}

// MARK: Attachments

@Test func handoffClassifiesAttachments() throws {
    let project = try Fixtures.temporaryProject()
    let outside = try Fixtures.temporaryProject()
    defer {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: outside)
    }
    let source = project.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: source.appendingPathComponent("App.swift"))
    try Data("x".utf8).write(to: outside.appendingPathComponent("spec.pdf"))
    try FileManager.default.createSymbolicLink(
        at: project.appendingPathComponent("escape.pdf"),
        withDestinationURL: outside.appendingPathComponent("spec.pdf"))

    let result = AgentHandoffAttachments.classify(
        [
            project.path + "/Sources/App.swift",
            "Sources/App.swift",
            outside.path + "/spec.pdf",
            "escape.pdf",
            "docs/gone.md",
            project.path + "/docs/gone2.md",
        ], projectRoot: project, workingDirectory: project.path)
    #expect(
        result == [
            AgentHandoffAttachment(path: "Sources/App.swift", status: .inProject),
            AgentHandoffAttachment(path: outside.path + "/spec.pdf", status: .outsideProject),
            // A link that leaves the project counts as outside.
            AgentHandoffAttachment(path: project.path + "/escape.pdf", status: .outsideProject),
            AgentHandoffAttachment(path: "docs/gone.md", status: .missing),
            AgentHandoffAttachment(path: "docs/gone2.md", status: .missing),
        ])
}

@Test func handoffAttachmentListIsBounded() throws {
    let project = try Fixtures.temporaryProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let many = (0..<250).map { "missing/file-\($0).txt" }
    let result = AgentHandoffAttachments.classify(
        many, projectRoot: project, workingDirectory: nil)
    #expect(result.count == AgentHandoffAttachments.maximumCount)
}

@Test func handoffCollectsAttachmentPathsOnceInOrder() {
    let turns = [
        [Fixtures.prompt("a", paths: ["x.swift", "y.swift"])],
        [Fixtures.prompt("b", paths: ["y.swift", "z.swift"])],
    ]
    #expect(AgentHandoffAttachments.paths(in: turns) == ["x.swift", "y.swift", "z.swift"])
}

// MARK: Launch

@Test func handoffClaudeArgumentsAreExecutablePlusOnePrompt() throws {
    let arguments = try #require(
        AgentHandoffLaunch.arguments(
            target: .claudeCode, source: .codex, title: "Fix \"quoted\" title",
            handoffPath: ".rafu/handoffs/2026-10-18-1430-fix/HANDOFF.md",
            imagePaths: ["/p/.rafu/handoffs/x/image-01.png"]))
    #expect(arguments.count == 2)
    #expect(arguments[0] == "claude")
    let prompt = arguments[1]
    #expect(prompt.hasPrefix("Read .rafu/handoffs/2026-10-18-1430-fix/HANDOFF.md. "))
    #expect(prompt.contains("It is a Codex session about \"Fix 'quoted' title\"."))
    #expect(prompt.contains("Continue the task from where it stopped."))
    #expect(prompt.contains("Images referenced there are in the same folder."))
    #expect(prompt.contains("\"/p/.rafu/handoffs/x/image-01.png\""))
    #expect(!prompt.contains("\n"))
}

@Test func handoffCodexArgumentsCarryOneImageFlagPerFile() throws {
    let arguments = try #require(
        AgentHandoffLaunch.arguments(
            target: .codex, source: .claudeCode, title: "Title",
            handoffPath: ".rafu/handoffs/x/HANDOFF.md",
            imagePaths: ["/p/image-01.png", "/p/image-02.jpg"]))
    #expect(arguments[0] == "codex")
    #expect(arguments[1].hasPrefix("Read .rafu/handoffs/x/HANDOFF.md. It is a Claude Code session"))
    #expect(
        Array(arguments.dropFirst(2)) == [
            "--image", "/p/image-01.png", "--image", "/p/image-02.jpg",
        ])
    // The paths are flags, not prompt text.
    #expect(!arguments[1].contains("image-01"))
}

@Test func handoffCodexListsAPathWithACommaInThePrompt() throws {
    let arguments = try #require(
        AgentHandoffLaunch.arguments(
            target: .codex, source: .claudeCode, title: "T", handoffPath: "HANDOFF.md",
            imagePaths: ["/p,q/image-01.png", "/p/image-02.png"]))
    #expect(Array(arguments.dropFirst(2)) == ["--image", "/p/image-02.png"])
    #expect(arguments[1].contains("\"/p,q/image-01.png\""))
}

@Test func handoffPromptStaysUnderFourKilobytes() throws {
    let longTitle = String(repeating: "title ", count: 500)
    let paths = (0..<20).map {
        "/some/long/project/path/" + String(repeating: "d", count: 300) + "/image-\($0).png"
    }
    for target in AgentHistoryProvider.allCases {
        let arguments = try #require(
            AgentHandoffLaunch.arguments(
                target: target, source: .codex, title: longTitle,
                handoffPath: ".rafu/handoffs/x/HANDOFF.md", imagePaths: paths))
        let prompt = arguments[1]
        #expect(prompt.utf8.count <= AgentHandoffLaunch.maximumPromptBytes)
        #expect(!prompt.contains("\n"))
    }
    let claude = try #require(
        AgentHandoffLaunch.arguments(
            target: .claudeCode, source: .codex, title: "T", handoffPath: "HANDOFF.md",
            imagePaths: paths))
    #expect(claude[1].contains("more in the same folder"))
}

@Test func handoffRefusesAnUnusableHandoffPath() {
    #expect(
        AgentHandoffLaunch.arguments(
            target: .claudeCode, source: .codex, title: "T", handoffPath: "",
            imagePaths: []) == nil)
    #expect(
        AgentHandoffLaunch.arguments(
            target: .claudeCode, source: .codex, title: "T",
            handoffPath: String(repeating: "a", count: 5_000), imagePaths: []) == nil)
    #expect(
        AgentHandoffLaunch.arguments(
            target: .claudeCode, source: .codex, title: "T", handoffPath: "a\nb",
            imagePaths: []) == nil)
}

@Test func handoffShellLineQuotesEveryArgument() throws {
    let line = try #require(
        AgentHandoffLaunch.shellLine(["codex", "it's $(bad) `x`", "--image", "/p/a b.png"]))
    #expect(line == "codex 'it'\\''s $(bad) `x`' --image '/p/a b.png'")
    #expect(AgentHandoffLaunch.shellLine(["codex", "two\nlines"]) == nil)
    #expect(AgentHandoffLaunch.shellLine([]) == nil)
}
