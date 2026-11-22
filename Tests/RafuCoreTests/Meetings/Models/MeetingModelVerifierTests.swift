import CryptoKit
import Foundation
import Testing

@testable import RafuCore

/// A small fake model: a few files with their real SHA-256.
struct FakeModelFixture {
    let files: [(path: String, data: Data)]

    static let standard = FakeModelFixture(files: [
        ("config.json", Data(#"{"a":1}"#.utf8)),
        ("Bundle.mlmodelc/coremldata.bin", Data(repeating: 7, count: 300)),
        ("Bundle.mlmodelc/weights/weight.bin", Data((0..<5000).map { UInt8($0 % 251) })),
    ])

    func entry(id: MeetingModelID = .speakerKit) -> MeetingModelCatalogEntry {
        MeetingModelCatalogEntry(
            id: id, displayName: "Fake", licenseName: "Fake Licence",
            licenseURL: "https://example.invalid/licence", attribution: "Fake attribution",
            repository: "example/fake", revision: String(repeating: "a", count: 40),
            files: files.map { file in
                MeetingModelFile(
                    repository: "example/fake", revision: String(repeating: "a", count: 40),
                    remotePath: "remote/\(file.path)", localPath: file.path,
                    bytes: Int64(file.data.count),
                    sha256: SHA256.hash(data: file.data).map { String(format: "%02x", $0) }
                        .joined())
            })
    }

    func write(to folder: URL) throws {
        for file in files {
            let url = folder.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }
}

@Suite("Meeting model verifier")
struct MeetingModelVerifierTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "rafu-model-verifier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A correct folder passes")
    func acceptsCorrectFolder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
    }

    @Test("Rafu's own files are allowed only when asked")
    func rafuFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try Data("x\n".utf8).write(to: folder.appending(path: "NOTICE"))
        try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        #expect(throws: MeetingModelVerificationError.unexpectedFile("NOTICE")) {
            try MeetingModelVerifier.verify(
                folder: folder, entry: fixture.entry(), allowRafuFiles: false)
        }
    }

    @Test("One wrong byte is refused")
    func oneWrongByte() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        let url = folder.appending(path: "Bundle.mlmodelc/weights/weight.bin")
        var data = try Data(contentsOf: url)
        data[2500] ^= 0x01
        try data.write(to: url)
        #expect(
            throws: MeetingModelVerificationError.checksumMismatch(
                "Bundle.mlmodelc/weights/weight.bin")
        ) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }
        #expect(MeetingModelVerificationError.checksumMismatch("x").checksumResult == .mismatched)
    }

    @Test("A larger file is refused by size")
    func oversize() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try Data(repeating: 7, count: 301).write(
            to: folder.appending(path: "Bundle.mlmodelc/coremldata.bin"))
        #expect(
            throws: MeetingModelVerificationError.wrongSize(
                "Bundle.mlmodelc/coremldata.bin", expected: 300, actual: 301)
        ) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }
    }

    @Test("A missing file is refused")
    func missingFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try FileManager.default.removeItem(at: folder.appending(path: "config.json"))
        #expect(throws: MeetingModelVerificationError.missingFile("config.json")) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }
    }

    @Test("An extra file is refused")
    func extraFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try Data("x".utf8).write(to: folder.appending(path: "Bundle.mlmodelc/extra.bin"))
        #expect(throws: MeetingModelVerificationError.unexpectedFile("Bundle.mlmodelc/extra.bin")) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }
    }

    @Test("A symbolic link is refused, also for a catalog path and for the folder")
    func symbolicLink() throws {
        let folder = try makeFolder()
        let outside = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: folder)
        try fixture.write(to: outside)
        let config = folder.appending(path: "config.json")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(
            at: config, withDestinationURL: outside.appending(path: "config.json"))
        #expect(throws: MeetingModelVerificationError.symbolicLink("config.json")) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }

        let linkedFolder = FileManager.default.temporaryDirectory.appending(
            path: "rafu-model-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: linkedFolder) }
        #expect(throws: MeetingModelVerificationError.symbolicLink(".")) {
            try MeetingModelVerifier.verify(folder: linkedFolder, entry: fixture.entry())
        }
    }

    @Test("A linked folder inside the tree is refused")
    func linkedSubfolder() throws {
        let folder = try makeFolder()
        let outside = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let fixture = FakeModelFixture.standard
        try fixture.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "Bundle.mlmodelc"),
            withDestinationURL: outside.appending(path: "Bundle.mlmodelc"))
        try Data(#"{"a":1}"#.utf8).write(to: folder.appending(path: "config.json"))
        #expect(throws: MeetingModelVerificationError.symbolicLink("Bundle.mlmodelc")) {
            try MeetingModelVerifier.verify(folder: folder, entry: fixture.entry())
        }
    }

    @Test("Path traversal in the catalog is refused before any file access")
    func pathTraversal() throws {
        for bad in ["../outside.bin", "/etc/hosts", "a/../../b", "a//b", "./a", "", "a\\b"] {
            #expect(!MeetingModelVerifier.isSafeRelativePath(bad), "\(bad)")
            var entry = FakeModelFixture.standard.entry()
            entry.files[0].localPath = bad
            #expect(throws: MeetingModelVerificationError.unsafePath(bad)) {
                try MeetingModelVerifier.verify(
                    folder: URL(fileURLWithPath: "/nonexistent"), entry: entry)
            }
        }
        #expect(MeetingModelVerifier.isSafeRelativePath("a/b.mlmodelc/weights/weight.bin"))
        var duplicate = FakeModelFixture.standard.entry()
        duplicate.files[1].localPath = duplicate.files[0].localPath
        #expect(throws: MeetingModelVerificationError.duplicatePath("config.json")) {
            try MeetingModelVerifier.checkCatalogPaths(duplicate)
        }
    }

    @Test("The verified marker must hold the pinned revision")
    func marker() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = FakeModelFixture.standard.entry()
        #expect(!MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry))
        let marker = folder.appending(path: MeetingModelInstallFiles.verifiedMarkerFileName)
        try Data("other\n".utf8).write(to: marker)
        #expect(!MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry))
        try Data(MeetingModelInstallFiles.markerText(for: entry).utf8).write(to: marker)
        #expect(MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry))
    }

    /// The manual check: a model folder made by hand from real models.
    /// Skipped unless `RAFU_MEETINGS_MODEL_DIR` is set. Each model whose folder
    /// `<dir>/<model id>` exists is verified against the catalog.
    @Test(
        "Real model folders pass (needs RAFU_MEETINGS_MODEL_DIR)",
        .enabled(if: ProcessInfo.processInfo.environment["RAFU_MEETINGS_MODEL_DIR"] != nil))
    func realModels() throws {
        let root = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["RAFU_MEETINGS_MODEL_DIR"]))
        var checked = 0
        for entry in MeetingModelCatalog.entries {
            let folder = root.appending(path: entry.id.rawValue, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            try MeetingModelVerifier.verify(folder: folder, entry: entry)
            checked += 1
        }
        #expect(checked > 0)
    }
}
