import Foundation
import Testing

@testable import RafuApp

private struct StubResolver: LanguageServerResolving {
    let entries: [String: ResolvedLanguageServer]

    func resolve(languageID: String) -> ResolvedLanguageServer? {
        entries[languageID]
    }
}

private func makeResolvedServer(named name: String) -> ResolvedLanguageServer {
    ResolvedLanguageServer(
        serverName: name,
        launch: LanguageServerLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: nil,
            currentDirectoryURL: nil),
        initializationOptions: nil,
        rssCeilingBytes: nil
    )
}

@Suite("Dynamic language server resolver")
struct DynamicLanguageServerResolverTests {
    @Test("An empty box declines every languageID")
    func emptyBoxDeclines() {
        let box = LanguageServerResolverBox()
        let resolver = DynamicLanguageServerResolver(box: box)
        #expect(resolver.resolve(languageID: "swift") == nil)
    }

    @Test("Setting a resolver into the box makes it resolve immediately")
    func settingResolverResolves() {
        let box = LanguageServerResolverBox()
        let resolver = DynamicLanguageServerResolver(box: box)
        box.set(StubResolver(entries: ["swift": makeResolvedServer(named: "swift")]))

        #expect(resolver.resolve(languageID: "swift")?.serverName == "swift")
        #expect(resolver.resolve(languageID: "rust") == nil)
    }

    @Test("Swapping the box's contents changes what the same resolver resolves")
    func swappingBoxChangesResolution() {
        let box = LanguageServerResolverBox()
        let resolver = DynamicLanguageServerResolver(box: box)

        box.set(StubResolver(entries: ["swift": makeResolvedServer(named: "first")]))
        #expect(resolver.resolve(languageID: "swift")?.serverName == "first")

        box.set(StubResolver(entries: ["swift": makeResolvedServer(named: "second")]))
        #expect(resolver.resolve(languageID: "swift")?.serverName == "second")

        box.set(nil)
        #expect(resolver.resolve(languageID: "swift") == nil)
    }
}
