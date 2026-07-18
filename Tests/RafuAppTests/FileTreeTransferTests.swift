import Foundation
import Testing

@testable import RafuApp

@Suite("File tree import / move / paste plumbing")
struct FileTreeTransferTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Importing picks unique names instead of overwriting")
    func importUniqueNames() async throws {
        let outside = try makeTempDirectory()
        let workspace = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: workspace)
        }
        let source = outside.appending(path: "notes.txt")
        try Data("v1".utf8).write(to: source)
        try Data("existing".utf8).write(to: workspace.appending(path: "notes.txt"))

        let service = WorkspaceFileService()
        let first = try await service.importItem(at: source, into: workspace)
        #expect(first.lastPathComponent == "notes 2.txt")
        let second = try await service.importItem(at: source, into: workspace)
        #expect(second.lastPathComponent == "notes 3.txt")
        // Original is untouched (copy, not move).
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Moving refuses a folder into itself or its descendant")
    func moveIntoSelfRefused() async throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = workspace.appending(path: "A", directoryHint: .isDirectory)
        let nested = folder.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let service = WorkspaceFileService()
        await #expect(throws: WorkspaceFileError.self) {
            _ = try await service.move(folder, into: folder)
        }
        await #expect(throws: WorkspaceFileError.self) {
            _ = try await service.move(folder, into: nested)
        }
    }

    @Test("Moving into the current parent is a no-op; collisions throw")
    func moveNoOpAndCollision() async throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        let target = workspace.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("clash".utf8).write(to: target.appending(path: "a.txt"))

        let service = WorkspaceFileService()
        // Same parent → returns the source untouched.
        let unchanged = try await service.move(file, into: workspace)
        #expect(unchanged == file)
        // Destination name collision → refuses rather than overwrites.
        await #expect(throws: WorkspaceFileError.self) {
            _ = try await service.move(file, into: target)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Moving into another folder relocates the item")
    func moveRelocates() async throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appending(path: "a.txt")
        try Data("a".utf8).write(to: file)
        let target = workspace.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let moved = try await WorkspaceFileService().move(file, into: target)
        #expect(moved.lastPathComponent == "a.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("writeData lands pasted bytes under a unique name")
    func writeDataUnique() async throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let service = WorkspaceFileService()
        let first = try await service.writeData(
            Data([1, 2, 3]), named: "Screenshot.png", into: workspace)
        let second = try await service.writeData(
            Data([4, 5]), named: "Screenshot.png", into: workspace)
        #expect(first.lastPathComponent == "Screenshot.png")
        #expect(second.lastPathComponent == "Screenshot 2.png")
    }
}

@Suite("AI completion prompt shaping")
struct AICompletionPromptBuilderTests {
    @Test("Prompt bounds the context window around the caret")
    func promptBounds() {
        let prefix = String(repeating: "q", count: 5_000)
        let suffix = String(repeating: "z", count: 5_000)
        let prompt = AICompletionPromptBuilder.prompt(
            prefix: prefix, suffix: suffix, fileName: "notes.txt")
        #expect(prompt.contains("<CURSOR>"))
        #expect(prompt.contains("notes.txt"))
        let prefixCount = prompt.filter { $0 == "q" }.count
        let suffixCount = prompt.filter { $0 == "z" }.count
        #expect(prefixCount == AICompletionPromptBuilder.maximumPrefixCharacters)
        #expect(suffixCount == AICompletionPromptBuilder.maximumSuffixCharacters)
    }

    @Test("Sanitize strips a wrapping markdown fence")
    func sanitizeStripsFence() {
        let raw = "```swift\nlet x = 1\nlet y = 2\n```"
        #expect(AICompletionPromptBuilder.sanitize(raw) == "let x = 1\nlet y = 2")
    }

    @Test("Sanitize drops leading newlines and trailing whitespace")
    func sanitizeTrims() {
        #expect(AICompletionPromptBuilder.sanitize("\n\nfoo()  \n") == "foo()")
    }

    @Test("Sanitize returns nil for empty or whitespace-only replies")
    func sanitizeEmpty() {
        #expect(AICompletionPromptBuilder.sanitize("") == nil)
        #expect(AICompletionPromptBuilder.sanitize("\n\n") == nil)
        #expect(AICompletionPromptBuilder.sanitize("```\n```") == nil)
    }

    @Test("Sanitize caps runaway replies at a line boundary")
    func sanitizeCaps() {
        let line = String(repeating: "x", count: 200)
        let raw = ([line, line, line, line, line]).joined(separator: "\n")
        let sanitized = AICompletionPromptBuilder.sanitize(raw)
        let expectedMax = AICompletionPromptBuilder.maximumSuggestionCharacters
        #expect(sanitized != nil)
        #expect((sanitized?.count ?? .max) <= expectedMax)
        #expect(sanitized?.hasSuffix(line) == true)
    }
}
