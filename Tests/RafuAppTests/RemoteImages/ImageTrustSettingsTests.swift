import Foundation
import Testing

@testable import RafuApp

@Suite("Images from the web settings")
@MainActor
struct ImageTrustSettingsTests {
    @Test("Building the section does no file I/O")
    func constructionIsQuiet() {
        let directory = TestDirectory()
        defer { directory.remove() }
        let name = TestDefaultsSuite.name("image-settings")
        defer { TestDefaultsSuite.remove(name) }
        let model = RemoteImageTrustModel(
            fileURL: directory.trustFile, defaults: UserDefaults(suiteName: name)!,
            loadSuffixes: { TestSuffixes.list }, revocation: RemoteImageRevocation())
        _ = ImageTrustSettingsSection(model: model)
        #expect(!model.isLoaded)
        #expect(model.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
    }

    @Test("Loading reads the list; the mode persists in its own defaults")
    func loadAndMode() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let name = TestDefaultsSuite.name("image-settings")
        defer { TestDefaultsSuite.remove(name) }
        let defaults = UserDefaults(suiteName: name)!
        let model = RemoteImageTrustModel(
            fileURL: directory.trustFile, defaults: defaults,
            loadSuffixes: { TestSuffixes.list }, revocation: RemoteImageRevocation())
        #expect(model.mode == .ask)
        await model.ensureLoaded()
        #expect(model.isLoaded)
        await model.add(
            try HostPattern.parse("*.example.com", suffixes: TestSuffixes.list), source: .settings)
        #expect(model.entries.map(\.pattern) == ["*.example.com"])
        #expect(model.patterns.first?.kind == .wildcard)
        #expect(model.canUndo)
        model.setMode(.always)
        #expect(CanvasRemoteImagePreference.mode(defaults) == .always)
        #expect(defaults.string(forKey: CanvasRemoteImagePreference.modeKey) == "always")
        await model.undo()
        #expect(model.entries.isEmpty)
        #expect(!model.canUndo)
    }

    @Test("The Add button follows the validator")
    func addState() throws {
        let suffixes = TestSuffixes.list
        let existing = [ImageTrustEntry(pattern: "example.net", addedAt: Date(), source: .settings)]
        func state(_ text: String, loaded: Bool = true) -> ImageTrustAddState {
            ImageTrustAddState.evaluate(text, suffixes: loaded ? suffixes : nil, existing: existing)
        }
        #expect(state("") == .empty)
        #expect(!state("").canAdd)
        #expect(state("images.example.com").canAdd)
        #expect(state("*.example.com").canAdd)
        #expect(state("*.com") == .invalid("*.com is a public suffix. Name a domain below it"))
        #expect(state("10.0.0.1") == .invalid("IP addresses are not allowed"))
        #expect(!state("*.com").canAdd)
        #expect(state("EXAMPLE.net.") == .duplicate)
        #expect(!state("example.net").canAdd)
        #expect(state("example.net").message == "This host is already on the list")
        // Until the Public Suffix List is loaded nothing can be added.
        #expect(state("images.example.com", loaded: false) == .loading)
        #expect(!state("images.example.com", loaded: false).canAdd)
        #expect(state("images.example.com").message == nil)
    }

    @Test("The mode has three values and the default is Ask")
    func modes() {
        #expect(CanvasRemoteImageMode.allCases.map(\.title) == ["Off", "Ask", "Always allow"])
        #expect(CanvasRemoteImagePreference.defaultMode == .ask)
        let name = TestDefaultsSuite.name("image-mode")
        defer { TestDefaultsSuite.remove(name) }
        let defaults = UserDefaults(suiteName: name)!
        #expect(CanvasRemoteImagePreference.mode(defaults) == .ask)
        defaults.set("nonsense", forKey: CanvasRemoteImagePreference.modeKey)
        #expect(CanvasRemoteImagePreference.mode(defaults) == .ask)
    }

    @Test("The trust file lives in the app's own folder, per variant")
    func fileLocation() {
        let base = URL(fileURLWithPath: "/tmp/base")
        let lightning = CanvasRemoteImagePreference.trustFileURL(
            identity: .lightning, baseDirectory: base)
        let release = CanvasRemoteImagePreference.trustFileURL(
            identity: .release, baseDirectory: base)
        #expect(lightning.lastPathComponent == "image-trust.json")
        #expect(lightning != release)
    }
}
