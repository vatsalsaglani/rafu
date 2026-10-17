import Darwin
import Foundation
import Testing

@testable import RafuApp

@Suite(.serialized)
nonisolated struct WorkspaceFileBoundedReadTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test("A 6,722,977-byte UTF-8 file opens with the large-file guard")
    func reportedFileSizeOpensGuarded() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = 6_722_977
        var fixture = Data(repeating: 0x61, count: bytes)
        for index in stride(from: 79, to: bytes, by: 80) {
            fixture[index] = 0x0A
        }
        try fixture.write(to: url)

        let text = try await WorkspaceFileService().readText(at: url)

        #expect(text.utf8.count == bytes)
        #expect(Data(text.utf8) == fixture)
        #expect(
            await DocumentGuardPolicy.decide(for: text) == .guarded(reason: .tooLarge(bytes: bytes))
        )
    }

    @Test("The exact 16 MiB open limit succeeds; one extra byte fails")
    func openLimitBoundary() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let limit = WorkspaceFileService.maximumEditorBytes
        #expect(limit == 16 * 1_024 * 1_024)
        try Data(repeating: 0x61, count: limit).write(to: url)
        #expect(try await WorkspaceFileService().readText(at: url).utf8.count == limit)

        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([0x61]))
        do {
            _ = try await WorkspaceFileService().readText(at: url)
            Issue.record("An oversized file must fail")
        } catch WorkspaceFileError.fileTooLarge(let bytes) {
            #expect(bytes == limit + 1)
        }
    }

    @Test("The bounded reader rejects growth after a small metadata snapshot")
    func growthCannotBypassReadLimit() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x61]).write(to: url)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var initial = stat()
        #expect(fstat(reader.fileDescriptor, &initial) == 0)
        #expect(initial.st_size == 1)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        // A sparse extension avoids allocating a large fixture. The reader
        // must enforce its own cap rather than trust the earlier size of 1.
        try writer.truncate(atOffset: UInt64(WorkspaceFileService.maximumEditorBytes + 100))

        do {
            _ = try WorkspaceFileService.readBoundedData(from: reader)
            Issue.record("Growth beyond the cap must fail without a partial result")
        } catch WorkspaceFileError.fileTooLarge(let bytes) {
            #expect(bytes == WorkspaceFileService.maximumEditorBytes + 1)
            #expect(try reader.offset() == UInt64(WorkspaceFileService.maximumEditorBytes + 1))
        }
    }

    @Test("Empty files and UTF-8 across read chunks retain their complete text")
    func chunkBoundaryAndEmptyFile() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = WorkspaceFileService()
        try Data().write(to: url)
        #expect(try await service.readText(at: url) == "")
        let text = String(repeating: "a", count: 64 * 1_024 - 1) + "🙂\r\nરફૂ"
        try await service.writeText(text, to: url)
        #expect(try await service.readText(at: url) == text)
    }

    @Test("Invalid UTF-8 still fails instead of decoding with replacement characters")
    func invalidUTF8StillFails() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0xFE, 0x80]).write(to: url)
        do {
            _ = try await WorkspaceFileService().readText(at: url)
            Issue.record("Invalid UTF-8 must fail")
        } catch WorkspaceFileError.notUTF8 {
        }
    }

    @Test("Directories and named pipes fail the descriptor regular-file check")
    func nonregularFilesFailWithoutReading() async throws {
        let root = temporaryFile()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appending(path: "pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        for url in [root, pipe] {
            do {
                _ = try await WorkspaceFileService().readText(at: url)
                Issue.record("A nonregular file must fail")
            } catch WorkspaceFileError.notRegularFile {
            }
        }
    }

    @Test("A cancelled read returns cancellation before file access")
    func cancelledReadDoesNotOpenFile() async throws {
        let url = temporaryFile()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceFileService().readText(at: url)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled read must fail")
        } catch is CancellationError {
        }
    }
}
