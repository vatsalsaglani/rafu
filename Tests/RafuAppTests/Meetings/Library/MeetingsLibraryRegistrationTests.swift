import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meetings library registration")
struct MeetingsLibraryRegistrationTests {
    @MainActor
    @Test("The library registers a store at the given root and the store reaches only that root")
    func registersStore() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-registration-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "Library", directoryHint: .isDirectory)

        let feature = MeetingsFeature(availability: .available)
        #expect(feature.store == nil)
        feature.registerLibraryParts(rootDirectory: root)
        #expect(feature.registeredKinds == [.store])
        let store = try #require(feature.store)
        // Making the store touched no file.
        #expect(!FileManager.default.fileExists(atPath: root.path))

        #expect(store is MeetingStore)
        #expect(store is any MeetingLibraryServicing)

        let created = try await store.create(title: "Registered", startDate: Date())
        #expect(try await store.list().map(\.id) == [created.id])
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: created.id.uuidString).path))
        let markdown = try await store.exportMarkdown(of: created.id)
        #expect(markdown.hasPrefix("# Registered\n"))
    }

    @MainActor
    @Test("The default registration uses the app-data root of the current identity")
    func defaultRegistrationIsLazy() {
        // Registering the default store makes the object only. No file is
        // touched, so launching the app never writes into the app data.
        let feature = MeetingsFeature(availability: .available)
        feature.registerLibraryParts()
        #expect(feature.registeredKinds == [.store])
        #expect(feature.store is MeetingStore)
        let expected = MeetingStore.defaultRootDirectory().path
        #expect(expected.contains("/Meetings/Library"))
        #expect(!expected.contains("/.rafu/"))
    }

    @Test("Export file names and Markdown never need a workspace")
    func exportNeedsNoWorkspace() {
        let name = MeetingMarkdownExporter.suggestedFileName(
            title: "Weekly sync", startDate: Date(timeIntervalSince1970: 1_795_428_900),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        #expect(name == "Weekly sync 2026-11-23.md")
    }
}
