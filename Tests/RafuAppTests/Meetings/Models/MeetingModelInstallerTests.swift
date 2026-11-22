import CryptoKit
import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

/// A transport that never uses the network. Each remote path has a scripted
/// behaviour.
nonisolated final class FakeModelTransport: MeetingModelTransport {
    enum Behaviour: Sendable {
        case bytes(Data)
        case fail(MeetingModelTransportError)
        /// Waits until the task is cancelled.
        case hang
    }

    private let behaviours: [String: Behaviour]
    private let calls = Mutex<[String]>([])
    let started: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation

    init(behaviours: [String: Behaviour]) {
        self.behaviours = behaviours
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var callCount: Int { calls.withLock { $0.count } }
    var calledPaths: [String] { calls.withLock { $0 } }

    func download(
        from url: URL, to destination: URL, maximumBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let path = url.path
        calls.withLock { $0.append(path) }
        startedContinuation.yield(path)
        let key = behaviours.keys.first { path.hasSuffix("/" + $0) }
        switch key.flatMap({ behaviours[$0] }) {
        case .bytes(let data):
            if Int64(data.count) > maximumBytes {
                try data.prefix(Int(maximumBytes)).write(to: destination)
                throw MeetingModelTransportError.tooLarge
            }
            try data.write(to: destination)
            onBytes(Int64(data.count))
        case .fail(let error):
            try Data("partial".utf8).write(to: destination)
            throw error
        case .hang:
            let (never, _) = AsyncStream<Void>.makeStream()
            for await _ in never {}
            throw CancellationError()
        case nil:
            throw MeetingModelTransportError.httpStatus(404)
        }
    }
}

nonisolated final class RecordingMeetingDiagnostics: MeetingDiagnosticsRecording {
    private let storage = Mutex<[MeetingDiagnosticEvent]>([])
    var events: [MeetingDiagnosticEvent] { storage.withLock { $0 } }
    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        storage.withLock { $0.append(event) }
    }
}

@Suite("Meeting model installer")
struct MeetingModelInstallerTests {
    private static let files: [(path: String, data: Data)] = [
        ("config.json", Data(#"{"a":1}"#.utf8)),
        ("Bundle.mlmodelc/coremldata.bin", Data(repeating: 7, count: 300)),
        ("Bundle.mlmodelc/weights/weight.bin", Data((0..<5000).map { UInt8($0 % 251) })),
    ]

    private static func entry() -> MeetingModelCatalogEntry {
        let revision = String(repeating: "b", count: 40)
        return MeetingModelCatalogEntry(
            id: .speakerKit, displayName: "Fake", licenseName: "Fake Licence",
            licenseURL: "https://example.invalid/licence", attribution: "Fake attribution",
            repository: "example/fake", revision: revision,
            files: files.map { file in
                MeetingModelFile(
                    repository: "example/fake", revision: revision,
                    remotePath: "remote/\(file.path)", localPath: file.path,
                    bytes: Int64(file.data.count),
                    sha256: SHA256.hash(data: file.data).map { String(format: "%02x", $0) }
                        .joined())
            })
    }

    private static func goodBehaviours() -> [String: FakeModelTransport.Behaviour] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.path, .bytes($0.data)) })
    }

    private struct Harness {
        let root: URL
        let transport: FakeModelTransport
        let diagnostics = RecordingMeetingDiagnostics()
        let installer: MeetingModelInstaller
        let entry = MeetingModelInstallerTests.entry()

        init(behaviours: [String: FakeModelTransport.Behaviour]) throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "rafu-model-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
            transport = FakeModelTransport(behaviours: behaviours)
            installer = MeetingModelInstaller(
                modelsRoot: root, transport: transport, diagnostics: diagnostics,
                entries: [MeetingModelInstallerTests.entry()])
        }

        var installFolder: URL {
            MeetingModelInstallFiles.installFolder(modelsRoot: root, entry: entry)
        }

        var stagingContents: [String] {
            let staging = root.appending(path: MeetingModelInstallFiles.stagingFolderName)
            return (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("Install: downloads, checks, writes the licence files, and renames into place")
    func installSucceeds() async throws {
        let harness = try Harness(behaviours: Self.goodBehaviours())
        defer { harness.cleanUp() }
        #expect(await harness.installer.installedFolder(for: .speakerKit) == nil)

        let updates = harness.installer.stateUpdates(for: .speakerKit)
        let result = await harness.installer.install(.speakerKit)
        #expect(result == .installed(revision: harness.entry.revision))

        let folder = try #require(await harness.installer.installedFolder(for: .speakerKit))
        #expect(folder.standardizedFileURL == harness.installFolder.standardizedFileURL)
        #expect(try Self.mode(of: folder) == 0o700)
        let notice = try String(contentsOf: folder.appending(path: "NOTICE"), encoding: .utf8)
        #expect(notice == "Fake attribution\n")
        let license = try String(
            contentsOf: folder.appending(path: "LICENSE.txt"), encoding: .utf8)
        #expect(license.contains("Fake Licence"))
        try MeetingModelVerifier.verify(folder: folder, entry: harness.entry)
        #expect(harness.stagingContents.isEmpty)
        #expect(harness.transport.calledPaths.allSatisfy { $0.contains("/resolve/") })

        var seen: [MeetingModelInstallState] = []
        for await state in updates {
            seen.append(state)
            if state.isInstalled { break }
        }
        #expect(seen.first == .notInstalled(bytes: harness.entry.totalBytes))
        #expect(seen.contains(.verifying))
        #expect(seen.contains { if case .downloading = $0 { true } else { false } })
        #expect(seen.last == .installed(revision: harness.entry.revision))

        let events = harness.diagnostics.events
        #expect(
            events.first
                == .modelDownloadStarted(
                    model: .speakerKit, expectedBytes: harness.entry.totalBytes))
        guard case .modelDownloadFinished(_, let bytes, _, let checksum, let install) = events.last
        else {
            Issue.record("no finish event")
            return
        }
        #expect(bytes == harness.entry.totalBytes)
        #expect(checksum == .matched)
        #expect(install == .installed)
    }

    @Test("A second install is a no-op")
    func secondInstallIsNoOp() async throws {
        let harness = try Harness(behaviours: Self.goodBehaviours())
        defer { harness.cleanUp() }
        _ = await harness.installer.install(.speakerKit)
        let calls = harness.transport.callCount
        let again = await harness.installer.install(.speakerKit)
        #expect(again == .installed(revision: harness.entry.revision))
        #expect(harness.transport.callCount == calls)

        // A new installer on the same folder sees the install at once.
        let fresh = MeetingModelInstaller(
            modelsRoot: harness.root, transport: harness.transport,
            entries: [harness.entry])
        #expect(fresh.state(for: .speakerKit) == .installed(revision: harness.entry.revision))
    }

    @Test("One wrong byte: the staged folder is removed and nothing is visible")
    func wrongByte() async throws {
        var behaviours = Self.goodBehaviours()
        var bad = Self.files[2].data
        bad[100] ^= 0xFF
        behaviours["Bundle.mlmodelc/weights/weight.bin"] = .bytes(bad)
        let harness = try Harness(behaviours: behaviours)
        defer { harness.cleanUp() }
        let result = await harness.installer.install(.speakerKit)
        #expect(result == .failed(.checksumMismatch))
        #expect(await harness.installer.installedFolder(for: .speakerKit) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.installFolder.path))
        #expect(harness.stagingContents.isEmpty)
        guard
            case .modelDownloadFinished(_, _, _, let checksum, let install) = harness.diagnostics
                .events.last
        else {
            Issue.record("no finish event")
            return
        }
        #expect(checksum == .mismatched)
        #expect(install == .removedAfterBadFile)
    }

    @Test("A file larger than the catalog size stops the install")
    func tooLarge() async throws {
        var behaviours = Self.goodBehaviours()
        behaviours["Bundle.mlmodelc/coremldata.bin"] = .bytes(Data(repeating: 7, count: 301))
        let harness = try Harness(behaviours: behaviours)
        defer { harness.cleanUp() }
        #expect(await harness.installer.install(.speakerKit) == .failed(.tooLarge))
        #expect(harness.stagingContents.isEmpty)
        #expect(await harness.installer.installedFolder(for: .speakerKit) == nil)
    }

    @Test("A failure in the middle leaves no visible folder and no staging folder")
    func failureInTheMiddle() async throws {
        var behaviours = Self.goodBehaviours()
        behaviours["Bundle.mlmodelc/coremldata.bin"] = .fail(.transferFailed)
        let harness = try Harness(behaviours: behaviours)
        defer { harness.cleanUp() }
        let result = await harness.installer.install(.speakerKit)
        #expect(result == .failed(.downloadFailed))
        #expect(harness.installer.state(for: .speakerKit) == .failed(.downloadFailed))
        #expect(harness.transport.callCount == 2)
        #expect(!FileManager.default.fileExists(atPath: harness.installFolder.path))
        #expect(harness.stagingContents.isEmpty)
        #expect(MeetingModelInstallFailure.downloadFailed.message.contains("download failed"))
    }

    @Test("Cancel removes the staging folder and returns to not installed")
    func cancel() async throws {
        var behaviours = Self.goodBehaviours()
        behaviours["Bundle.mlmodelc/coremldata.bin"] = .hang
        let harness = try Harness(behaviours: behaviours)
        defer { harness.cleanUp() }
        let installer = harness.installer
        let install = Task { await installer.install(.speakerKit) }
        for await path in harness.transport.started where path.hasSuffix("coremldata.bin") {
            break
        }
        #expect(harness.stagingContents.count == 1)
        await installer.cancelInstall(.speakerKit)
        let result = await install.value
        #expect(result == .notInstalled(bytes: harness.entry.totalBytes))
        #expect(harness.stagingContents.isEmpty)
        #expect(await installer.installedFolder(for: .speakerKit) == nil)
        guard case .modelDownloadFinished(_, _, _, _, let outcome) = harness.diagnostics.events.last
        else {
            Issue.record("no finish event")
            return
        }
        #expect(outcome == .cancelled)
    }

    @Test("Cancelling the caller's task cancels the install")
    func callerCancellation() async throws {
        var behaviours = Self.goodBehaviours()
        behaviours["config.json"] = .hang
        let harness = try Harness(behaviours: behaviours)
        defer { harness.cleanUp() }
        let installer = harness.installer
        let install = Task { await installer.install(.speakerKit) }
        for await _ in harness.transport.started { break }
        install.cancel()
        #expect(await install.value == .notInstalled(bytes: harness.entry.totalBytes))
        #expect(harness.stagingContents.isEmpty)
    }

    @Test("Remove deletes the installed model")
    func remove() async throws {
        let harness = try Harness(behaviours: Self.goodBehaviours())
        defer { harness.cleanUp() }
        _ = await harness.installer.install(.speakerKit)
        #expect(await harness.installer.installedFolder(for: .speakerKit) != nil)
        try await harness.installer.remove(.speakerKit)
        #expect(await harness.installer.installedFolder(for: .speakerKit) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.root.appending(path: "speakerkit-pyannote").path))
        #expect(
            harness.installer.state(for: .speakerKit)
                == .notInstalled(bytes: harness.entry.totalBytes))
    }

    @Test("A folder without the marker is not installed")
    func noMarkerNoFolder() async throws {
        let harness = try Harness(behaviours: Self.goodBehaviours())
        defer { harness.cleanUp() }
        try FileManager.default.createDirectory(
            at: harness.installFolder, withIntermediateDirectories: true)
        #expect(await harness.installer.installedFolder(for: .speakerKit) == nil)
        // An install replaces the unchecked folder.
        #expect(
            await harness.installer.install(.speakerKit)
                == .installed(revision: harness.entry.revision))
    }

    @Test("Nothing downloads without an explicit install call")
    func noDownloadWithoutInstall() async throws {
        let harness = try Harness(behaviours: Self.goodBehaviours())
        defer { harness.cleanUp() }
        _ = harness.installer.state(for: .speakerKit)
        let updates = harness.installer.stateUpdates(for: .speakerKit)
        _ = await harness.installer.installedFolder(for: .speakerKit)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .notInstalled(bytes: harness.entry.totalBytes))
        #expect(harness.transport.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.root.path))
    }

    @Test("Source scan: the only download path is install(_:)")
    func sourceScan() throws {
        let folder = Self.packageRoot().appending(path: "Sources/RafuApp/Meetings/Models")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }
        var downloadCalls: [String] = []
        for name in names {
            let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            if name != "MeetingModelTransport.swift" {
                #expect(!text.contains("URLSession("), "\(name)")
                #expect(!text.contains("URLSession.shared"), "\(name)")
            }
            if text.contains("transport.download(") { downloadCalls.append(name) }
            #expect(!text.contains("Timer"), "\(name)")
            if name != "MeetingModelInstaller.swift" {
                #expect(!text.contains(".install("), "\(name)")
            }
        }
        #expect(downloadCalls == ["MeetingModelInstaller.swift"])
        let installer = try String(
            contentsOf: folder.appending(path: "MeetingModelInstaller.swift"), encoding: .utf8)
        // The installer's init starts no task.
        let initBody = try #require(installer.range(of: "init(")).upperBound
        let defaultRoot = try #require(installer.range(of: "static func defaultModelsRoot"))
            .lowerBound
        #expect(!installer[initBody..<defaultRoot].contains("Task"))
        // The one place that makes the download job is install(_:).
        #expect(installer.components(separatedBy: "InstallJob(").count == 2)
        let installStart = try #require(installer.range(of: "func install(_ model")).lowerBound
        let jobAt = try #require(installer.range(of: "InstallJob(")).lowerBound
        let cancelStart = try #require(installer.range(of: "func cancelInstall")).lowerBound
        #expect(installStart < jobAt && jobAt < cancelStart)
    }

    @MainActor
    @Test("The installer registers as the model locator")
    func registration() {
        let feature = MeetingsFeature()
        feature.registerModelCatalogParts()
        #expect(feature.registeredKinds.contains(.modelLocator))
        #expect(feature.modelInstaller != nil)
        #expect(
            feature.modelInstaller?.modelsRoot.path.hasSuffix("/Meetings/Models") == true)
    }

    private static func packageRoot(file: StaticString = #filePath) -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }
}
