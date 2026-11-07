import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

@Suite("Remote image revocation")
@MainActor
struct RemoteImageRevocationTests {
    @Test("Removing a pattern drops the images it allowed in both Ensembles")
    func removePattern() async throws {
        // Two Ensembles (two windows' worth of boards) share one trust model and
        // one revocation registry; each has its own provider.
        let first = ProviderRig()
        let server = first.server
        server.reply("/a.png", .init(body: TestImages.png))
        let second = CanvasBoardState(document: CanvasDocument(title: "Second"))
        let secondProvider = RemoteImageProvider(
            board: second, trust: first.trust, loader: StubImageServer.loader(),
            revocation: first.revocation, presenter: { _, _ in })
        let pattern = HostPattern(kind: .wildcard, base: "example.com")
        await first.trust.add(pattern, source: .settings)
        _ = first.state()
        _ = secondProvider.state(
            for: server.url(), pixelSize: CGSize(width: 64, height: 64), cardID: CanvasCardID())
        await first.provider.waitForLoads()
        await secondProvider.waitForLoads()
        #expect(first.provider.cache.count == 1)
        #expect(secondProvider.cache.count == 1)
        #expect(first.state().label == "image")

        let revisions = (first.provider.revision, secondProvider.revision)
        await first.trust.remove("*.example.com")
        #expect(first.provider.cache.count == 0)
        #expect(secondProvider.cache.count == 0)
        #expect(first.provider.revision > revisions.0)
        #expect(secondProvider.revision > revisions.1)
        #expect(first.state().label == "needsConsent")
        #expect(
            secondProvider.state(
                for: server.url(), pixelSize: CGSize(width: 64, height: 64), cardID: CanvasCardID()
            ).label == "needsConsent")
    }

    @Test("A pattern grant is dropped by its pattern only")
    func otherGrantsStay() async throws {
        let rig = ProviderRig()
        rig.server.reply("/a.png", .init(body: TestImages.png))
        try RemoteImageConsentWriter.grant(on: rig.board)
        _ = await rig.readyState()
        await rig.provider.waitForLoads()
        #expect(rig.provider.cache.count == 1)
        rig.revocation.dropPattern("*.unrelated.com")
        // The pattern drop cancels loads and forgets failures but keeps images
        // that another grant allowed.
        #expect(rig.provider.cache.count == 1)
        rig.revocation.dropEnsemble(rig.board.id)
        #expect(rig.provider.cache.count == 0)
    }

    @Test("Switching to Off drops everything, in every Ensemble, and stops requests")
    func switchOff() async throws {
        let rig = ProviderRig(mode: .always)
        rig.server.reply("/a.png", .init(body: TestImages.png))
        _ = await rig.readyState()
        await rig.provider.waitForLoads()
        #expect(rig.provider.cache.count == 1)
        rig.trust.setMode(.off)
        #expect(rig.provider.cache.count == 0)
        let hits = rig.server.hits
        if case .notAllowed = rig.state() {} else { Issue.record("expected notAllowed") }
        #expect(rig.server.hits == hits)
        #expect(
            CanvasRemoteImagePreference.mode(UserDefaults(suiteName: rig.defaultsName)!) == .off)
    }

    @Test("Leaving Always allow drops the images that only the global setting allowed")
    func leaveAlways() async throws {
        let rig = ProviderRig(mode: .always)
        rig.server.reply("/a.png", .init(body: TestImages.png))
        _ = await rig.readyState()
        await rig.provider.waitForLoads()
        rig.trust.setMode(.ask)
        #expect(rig.provider.cache.count == 0)
        #expect(rig.state().label == "needsConsent")
    }

    @Test("The registry holds providers weakly")
    func weakRegistry() {
        let registry = RemoteImageRevocation()
        var board: CanvasBoardState? = CanvasBoardState(document: CanvasDocument(title: "x"))
        var provider: RemoteImageProvider? = RemoteImageProvider(
            board: board!, loader: StubImageServer.loader(), revocation: registry,
            presenter: { _, _ in })
        #expect(registry.liveProviders.count == 1)
        #expect(registry.provider(for: board!.id) === provider)
        provider = nil
        board = nil
        #expect(registry.liveProviders.isEmpty)
    }
}
