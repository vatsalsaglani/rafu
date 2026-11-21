import Foundation
import Testing

@testable import RafuApp

/// A fake `.app` folder: `Contents/Resources` and the app root, each
/// optionally holding a `Rafu_RafuApp.bundle` directory.
private struct FakeApp {
    let root: URL
    var resources: URL { root.appendingPathComponent("Contents/Resources", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-bundle-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    func addBundle(in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                RafuResourceBundleLocator.bundleName, isDirectory: true),
            withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test("The locator finds the bundle in Contents/Resources")
func locatorFindsTheBundleInResources() throws {
    let app = try FakeApp()
    defer { app.remove() }
    try app.addBundle(in: app.resources)

    let found = RafuResourceBundleLocator.locate(in: [app.resources, app.root])

    #expect(
        found?.deletingLastPathComponent().standardizedFileURL == app.resources.standardizedFileURL)
}

@Test("The locator prefers Contents/Resources over the app root")
func locatorPrefersResourcesOverRoot() throws {
    let app = try FakeApp()
    defer { app.remove() }
    try app.addBundle(in: app.resources)
    try app.addBundle(in: app.root)

    let found = RafuResourceBundleLocator.locate(in: [app.resources, app.root])

    #expect(
        found?.deletingLastPathComponent().standardizedFileURL == app.resources.standardizedFileURL)
}

@Test("The locator still finds a flat bundle at the app root")
func locatorFallsBackToTheAppRoot() throws {
    let app = try FakeApp()
    defer { app.remove() }
    try app.addBundle(in: app.root)

    let found = RafuResourceBundleLocator.locate(in: [app.resources, app.root])

    #expect(found?.deletingLastPathComponent().standardizedFileURL == app.root.standardizedFileURL)
}

@Test("The locator returns nil when no directory holds the bundle, and skips nil entries")
func locatorReturnsNilWhenNothingMatches() throws {
    let app = try FakeApp()
    defer { app.remove() }

    #expect(RafuResourceBundleLocator.locate(in: [nil, app.resources, app.root]) == nil)
}

@Test("A plain file with the bundle name is not a bundle")
func locatorIgnoresAFileWithTheBundleName() throws {
    let app = try FakeApp()
    defer { app.remove() }
    let file = app.resources.appendingPathComponent(RafuResourceBundleLocator.bundleName)
    try Data().write(to: file)

    #expect(RafuResourceBundleLocator.locate(in: [app.resources]) == nil)
}

@Test("Bundle.rafuResources resolves Rafu's own resources under swift test")
@MainActor
func rafuResourcesResolvesGrammarQueries() {
    let url = Bundle.rafuResources.url(
        forResource: "highlights", withExtension: "scm", subdirectory: "Grammars/Swift")
    #expect(url != nil)
}
