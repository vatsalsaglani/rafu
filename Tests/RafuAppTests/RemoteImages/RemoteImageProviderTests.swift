import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// One Ensemble's provider with its own trust model, defaults, stub server and
/// a consent presenter that records requests and answers from the test.
@MainActor
final class ProviderRig {
    let directory = TestDirectory()
    let defaultsName = TestDefaultsSuite.name("remote-images")
    let revocation = RemoteImageRevocation()
    let server = StubImageServer()
    let board: CanvasBoardState
    let trust: RemoteImageTrustModel
    let provider: RemoteImageProvider
    var consentRequests: [RemoteImageConsentRequest] = []
    var answer: RemoteImageConsentOutcome = .cancel
    let card = CanvasCardID()

    init(
        mode: CanvasRemoteImageMode = .ask, board: CanvasBoardState? = nil,
        trust sharedTrust: RemoteImageTrustModel? = nil
    ) {
        let defaults = UserDefaults(suiteName: defaultsName)!
        CanvasRemoteImagePreference.setMode(mode, in: defaults)
        let board = board ?? CanvasBoardState(document: CanvasDocument(title: "Images"))
        self.board = board
        let trust =
            sharedTrust
            ?? RemoteImageTrustModel(
                fileURL: directory.trustFile, defaults: defaults,
                loadSuffixes: { TestSuffixes.list }, revocation: revocation)
        self.trust = trust
        let box = PresenterBox()
        provider = RemoteImageProvider(
            board: board, trust: trust, loader: StubImageServer.loader(),
            revocation: revocation,
            presenter: { request, reply in box.present(request, reply) })
        box.rig = self
    }

    deinit {
        directory.remove()
        TestDefaultsSuite.remove(defaultsName)
    }

    func state(_ url: URL? = nil, pixels: CGFloat = 200) -> RemoteImageState {
        provider.state(
            for: url ?? server.url(), pixelSize: CGSize(width: pixels, height: pixels), cardID: card
        )
    }

    /// Loads the trust model, then asks for the state.
    func readyState(_ url: URL? = nil) async -> RemoteImageState {
        await trust.ensureLoaded()
        return state(url)
    }

    @MainActor
    final class PresenterBox {
        weak var rig: ProviderRig?
        func present(
            _ request: RemoteImageConsentRequest,
            _ reply: @escaping @MainActor (RemoteImageConsentOutcome) -> Void
        ) {
            rig?.consentRequests.append(request)
            reply(rig?.answer ?? .cancel)
        }
    }
}

extension RemoteImageState {
    var label: String {
        switch self {
        case .notAllowed: "notAllowed"
        case .needsConsent: "needsConsent"
        case .loading: "loading"
        case .image: "image"
        case .failed: "failed"
        }
    }
}

@Suite("Remote image provider")
@MainActor
struct RemoteImageProviderTests {
    @Test("Nothing is fetched before consent, not even a HEAD")
    func noRequestBeforeConsent() async throws {
        let rig = ProviderRig()
        rig.server.reply("/a.png", .init(body: TestImages.png))
        for _ in 0..<5 { #expect(await rig.readyState().label == "needsConsent") }
        await rig.provider.waitForLoads()
        #expect(rig.server.hits == 0)
        if case .needsConsent(let host) = await rig.readyState() {
            #expect(host == rig.server.host)
        } else {
            Issue.record("expected needsConsent")
        }
    }

    @Test("After Ensemble consent the image loads; the server saw one request")
    func consentThenLoad() async throws {
        let rig = ProviderRig()
        rig.server.reply("/a.png", .init(body: TestImages.png))
        #expect(await rig.readyState().label == "needsConsent")
        let before = rig.provider.revision
        rig.answer = .allowEnsemble
        rig.provider.requestConsent(for: rig.server.url())
        #expect(rig.consentRequests.map(\.host) == [rig.server.host])
        #expect(rig.board.remoteImageConsent?.allowed == true)
        #expect(rig.board.remoteImageConsent?.grantedBy == "user")
        #expect(rig.provider.revision > before)
        #expect(rig.state().label == "loading")
        await rig.provider.waitForLoads()
        #expect(rig.state().label == "image")
        #expect(rig.server.hits == 1)
        // A second look is a cache hit.
        #expect(rig.state().label == "image")
        #expect(rig.server.hits == 1)
        // Consent for the Ensemble is one undo step.
        rig.board.performUndo()
        #expect(rig.board.remoteImageConsent == nil)
        #expect(rig.state().label == "needsConsent")
    }

    @Test("Always allow a host adds a pattern and loads without Ensemble consent")
    func trustFromTheCard() async throws {
        let rig = ProviderRig()
        rig.server.reply("/a.png", .init(body: TestImages.png))
        #expect(await rig.readyState().label == "needsConsent")
        rig.answer = .trust(HostPattern(kind: .exact, base: rig.server.host))
        rig.provider.requestConsent(for: rig.server.url())
        // The trust list is written off the main actor; wait for the write.
        await rig.provider.waitForLoads()
        #expect(rig.trust.entries.first?.source == .confirm)
        #expect(rig.board.remoteImageConsent == nil)
        #expect(rig.state().label == "loading")
        await rig.provider.waitForLoads()
        #expect(rig.state().label == "image")
    }

    @Test("The consent card offers the parent wildcard for a deep host only")
    func parentOffer() async throws {
        let rig = ProviderRig()
        _ = await rig.readyState()
        rig.provider.requestConsent(for: URL(string: "https://cdn.assets.example.com/a.png")!)
        rig.provider.requestConsent(for: URL(string: "https://example.com/a.png")!)
        #expect(rig.consentRequests.count == 2)
        #expect(rig.consentRequests[0].parentPattern?.text == "*.example.com")
        #expect(rig.consentRequests[1].parentPattern == nil)
    }

    @Test("One consent card at a time; Allow on a host that is already allowed does nothing")
    func oneCardAtATime() async throws {
        let rig = ProviderRig()
        _ = await rig.readyState()
        var held: (@MainActor (RemoteImageConsentOutcome) -> Void)?
        var shown = 0
        let provider = RemoteImageProvider(
            board: rig.board, trust: rig.trust, loader: StubImageServer.loader(),
            revocation: rig.revocation,
            presenter: { _, reply in
                shown += 1
                held = reply
            })
        provider.requestConsent(for: rig.server.url())
        provider.requestConsent(for: rig.server.url())
        #expect(shown == 1)
        held?(.cancel)
        provider.requestConsent(for: rig.server.url())
        #expect(shown == 2)
        held?(.allowEnsemble)
        provider.requestConsent(for: rig.server.url())
        #expect(shown == 2)
    }

    @Test("Off: a placeholder with a reason, no button, no request")
    func off() async throws {
        let rig = ProviderRig(mode: .off)
        rig.server.reply("/a.png", .init(body: TestImages.png))
        try RemoteImageConsentWriter.grant(on: rig.board)
        if case .notAllowed(let reason) = await rig.readyState() {
            #expect(reason == RemoteImageDecision.offReason)
        } else {
            Issue.record("expected notAllowed")
        }
        rig.provider.requestConsent(for: rig.server.url())
        #expect(rig.consentRequests.isEmpty)
        await rig.provider.waitForLoads()
        #expect(rig.server.hits == 0)
    }

    @Test("Always allow loads from any public host and sends no prompt")
    func always() async throws {
        let rig = ProviderRig(mode: .always)
        rig.server.reply("/a.png", .init(body: TestImages.png))
        #expect(await rig.readyState().label == "loading")
        await rig.provider.waitForLoads()
        #expect(rig.state().label == "image")
        #expect(rig.consentRequests.isEmpty)
    }

    @Test("Syntactically refused URLs never ask and never fetch")
    func refused() async throws {
        let rig = ProviderRig(mode: .always)
        for text in [
            "http://example.com/a.png", "https://127.0.0.1/a.png", "https://localhost/a.png",
            "https://printer.local/a.png",
        ] {
            #expect(await rig.readyState(URL(string: text)!).label == "notAllowed", "\(text)")
        }
        await rig.provider.waitForLoads()
        #expect(rig.server.hits == 0)
    }

    @Test("A failed load is remembered and shown, not retried")
    func failure() async throws {
        let rig = ProviderRig(mode: .always)
        rig.server.reply("/a.svg", .init(body: TestImages.svg))
        let url = rig.server.url("/a.svg")
        #expect(await rig.readyState(url).label == "loading")
        await rig.provider.waitForLoads()
        guard case .failed(let message) = rig.state(url) else {
            Issue.record("expected failed")
            return
        }
        #expect(message == "Unsupported image type.")
        _ = rig.state(url)
        #expect(rig.server.hits == 1)
    }

    @Test("A view asks for at most 20 different images")
    func perCardLimit() async throws {
        let rig = ProviderRig(mode: .always)
        await rig.trust.ensureLoaded()
        for index in 0..<20 {
            rig.server.reply("/\(index).png", .init(body: TestImages.png))
            #expect(rig.state(rig.server.url("/\(index).png")).label == "loading")
        }
        guard case .failed(let message) = rig.state(rig.server.url("/20.png")) else {
            Issue.record("expected failed")
            return
        }
        #expect(message == "Too many images in one view.")
        await rig.provider.waitForLoads()
        // Another card has its own count.
        #expect(
            rig.provider.state(
                for: rig.server.url("/20.png"), pixelSize: CGSize(width: 64, height: 64),
                cardID: CanvasCardID()
            ).label == "loading")
        await rig.provider.waitForLoads()
    }

    @Test("A redirect to another host is followed only for trusted hosts")
    func redirectTrust() async throws {
        let rig = ProviderRig(mode: .ask)
        let other = StubImageServer()
        rig.server.reply("/a.png", .init(redirect: other.url("/b.png")))
        other.reply("/b.png", .init(body: TestImages.png))
        try RemoteImageConsentWriter.grant(on: rig.board)
        // Ensemble consent covers the host the user was shown, not the target.
        #expect(await rig.readyState().label == "loading")
        await rig.provider.waitForLoads()
        guard case .failed = rig.state() else {
            Issue.record("expected failed")
            return
        }
        #expect(other.hits == 0)
        // Trusting the target host lets the same redirect through.
        let again = ProviderRig(mode: .ask)
        let target = StubImageServer()
        again.server.reply("/a.png", .init(redirect: target.url("/b.png")))
        target.reply("/b.png", .init(body: TestImages.png))
        await again.trust.add(HostPattern(kind: .exact, base: again.server.host), source: .settings)
        await again.trust.add(HostPattern(kind: .exact, base: target.host), source: .settings)
        _ = await again.readyState()
        await again.provider.waitForLoads()
        #expect(again.state().label == "image")
        #expect(target.hits == 1)
    }

    @Test("Revoking the Ensemble consent drops its images and returns the placeholder")
    func revokeConsent() async throws {
        let rig = ProviderRig()
        rig.server.reply("/a.png", .init(body: TestImages.png))
        try RemoteImageConsentWriter.grant(on: rig.board)
        _ = await rig.readyState()
        await rig.provider.waitForLoads()
        #expect(rig.provider.cache.count == 1)
        let before = rig.provider.revision
        rig.provider.revokeConsent()
        #expect(rig.board.remoteImageConsent == nil)
        #expect(rig.provider.cache.count == 0)
        #expect(rig.provider.revision > before)
        #expect(rig.state().label == "needsConsent")
    }

    @Test("The consent write refuses a grantedBy other than user")
    func grantedByUser() throws {
        var document = CanvasDocument(title: "x")
        document.permissions = CanvasPermissions(
            remoteImages: CanvasRemoteImageConsent(
                allowed: true, grantedAt: Date(), grantedBy: "agent"))
        #expect(throws: CanvasError.invalidDocument) { try document.validate() }
        let board = CanvasBoardState(document: CanvasDocument(title: "x"))
        try RemoteImageConsentWriter.grant(on: board)
        #expect(try board.snapshot().permissions?.remoteImages?.grantedBy == "user")
        try RemoteImageConsentWriter.revoke(on: board)
        #expect(try board.snapshot().permissions == nil)
    }

    @Test("Pixel sizes round up to four buckets")
    func buckets() {
        #expect(RemoteImageProvider.pixelBucket(CGSize(width: 90, height: 40)) == 128)
        #expect(RemoteImageProvider.pixelBucket(CGSize(width: 129, height: 40)) == 256)
        #expect(RemoteImageProvider.pixelBucket(CGSize(width: 300, height: 500)) == 512)
        #expect(RemoteImageProvider.pixelBucket(CGSize(width: 5_000, height: 10)) == 1_024)
    }
}
