import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting library: root and workspace separation")
struct MeetingStoreRootAndPrivacyTests {
    @Test("The default root comes from RafuAppIdentity and keeps Rafu and Lightning apart")
    func defaultRoot() {
        let base = URL(fileURLWithPath: "/tmp/rafu-root-test", isDirectory: true)
        let release = MeetingStore.defaultRootDirectory(identity: .release, baseDirectory: base)
        let lightning = MeetingStore.defaultRootDirectory(identity: .lightning, baseDirectory: base)
        #expect(release.path == "/tmp/rafu-root-test/Rafu/Meetings/Library")
        #expect(lightning.path == "/tmp/rafu-root-test/Rafu Lightning/Meetings/Library")
        #expect(release != lightning)
        #expect(
            release
                == RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "Meetings/Library", directoryHint: .isDirectory))
    }

    @Test("A store takes its root from the caller and writes nowhere else")
    func rootIsInjected() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let defaultRoot = MeetingStore.defaultRootDirectory()
        let before = try? FileManager.default.contentsOfDirectory(atPath: defaultRoot.path)
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.audioFolder(for: created.id)
        let snapshot = try await store.makeAgentSnapshot(of: created.id)
        defer { snapshot.remove() }
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
        // The real app data is as it was.
        let after = try? FileManager.default.contentsOfDirectory(atPath: defaultRoot.path)
        #expect(after == before)
        #expect(!fixture.root.path.hasPrefix(defaultRoot.path))
    }

    @Test("No meeting path is below a workspace root")
    func meetingPathsAreNotBelowAWorkspace() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        // A workspace is some folder that the user opened. Make two: a
        // sibling of the library and the parent of the library's parent.
        let workspace = fixture.base.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: workspace.appending(path: "main.swift"))
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns([LibrarySample.turn(1)], to: created.id, expectedVersion: 1)
        let audio = try await store.audioFolder(for: created.id)
        let snapshot = try await store.makeAgentSnapshot(of: created.id)
        defer { snapshot.remove() }

        let workspacePrefix = workspace.standardizedFileURL.path + "/"
        for url in [audio, snapshot.folder, snapshot.transcriptURL, fixture.folder(of: created.id)]
        {
            #expect(!(url.standardizedFileURL.path + "/").hasPrefix(workspacePrefix), "\(url.path)")
        }
        // The default root is in the app data of the current user, not in
        // the folder of this repository or of the test process.
        let appData = RafuAppIdentity.defaultApplicationSupportBaseDirectory.standardizedFileURL
            .path
        #expect(
            MeetingStore.defaultRootDirectory().standardizedFileURL.path.hasPrefix(appData + "/"))
        // A workspace walk finds none of the meeting files.
        let walked = FileManager.default.enumerator(atPath: workspace.path)?.allObjects as? [String]
        #expect(walked == ["main.swift"])
    }

    @Test("No public API of the library takes or returns a workspace path")
    func noWorkspaceInPublicAPI() throws {
        let sources = try Self.sources(in: ["Library", "Export"])
        #expect(sources.count >= 8)
        // The only public declarations that mention a URL are these: the
        // audio folder for capture code, and the snapshot folder.
        let allowedURLDeclarations: Set<String> = [
            "public var folder: URL",
            "public init(meeting: MeetingID, folder: URL) {",
            "public var transcriptURL: URL {",
            "public var overviewURL: URL {",
            "public func audioFolder(for meeting: MeetingID) async throws -> URL {",
        ]
        for (name, source) in sources {
            for rawLine in source.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                // No workspace word in any code line.
                #expect(!line.lowercased().contains("workspace"), "\(name): \(line)")
                // No file path string parameter or return in a public member.
                if line.hasPrefix("public "), line.contains("URL") {
                    #expect(
                        allowedURLDeclarations.contains { line.hasPrefix($0) }, "\(name): \(line)")
                }
                // The store never reads the user's home or a project directory.
                #expect(!line.contains("currentDirectoryPath"), "\(name): \(line)")
                #expect(!line.contains("homeDirectoryForCurrentUser"), "\(name): \(line)")
                #expect(!line.contains("FileManager.default.urls("), "\(name): \(line)")
            }
        }
        // The identity is the only constructor of the root.
        let store = try #require(sources.first { $0.0 == "MeetingStore.swift" }?.1)
        #expect(store.contains("identity.applicationSupportRoot(baseDirectory: baseDirectory)"))
    }

    @Test("The library source holds no @unchecked Sendable and no UI import")
    func sourcePolicy() throws {
        for (name, source) in try Self.sources(in: ["Library", "Export"]) {
            #expect(!source.contains("@unchecked Sendable"), "\(name)")
            #expect(!source.contains("import SwiftUI"), "\(name)")
            #expect(!source.contains("import AppKit"), "\(name)")
        }
    }

    private static func sources(
        in folders: [String], file: StaticString = #filePath
    ) throws -> [(String, String)] {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        var result: [(String, String)] = []
        for folder in folders {
            let url = directory.appending(path: "Sources/RafuCore/Meetings/\(folder)")
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".swift") }.sorted()
            for name in names {
                result.append(
                    (name, try String(contentsOf: url.appending(path: name), encoding: .utf8)))
            }
        }
        return result
    }
}
