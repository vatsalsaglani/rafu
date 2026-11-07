import CoreGraphics
import Foundation
import Observation

/// What a generated view's image should show.
enum RemoteImageState {
    case notAllowed(reason: String)
    case needsConsent(host: String)
    case loading
    case image(CGImage)
    case failed(String)
}

/// The consent card's question, and the card's answer.
struct RemoteImageConsentRequest: Equatable {
    /// Lowercase punycode.
    let host: String
    /// The exact-host pattern for `host`.
    let hostPattern: HostPattern
    /// `*.example.com`, when the host has a registrable parent below a public suffix.
    let parentPattern: HostPattern?
}

enum RemoteImageConsentOutcome: Equatable {
    case cancel
    /// Allow every image host in this Ensemble.
    case allowEnsemble
    /// Add a pattern to the trust list.
    case trust(HostPattern)
}

/// The per-Ensemble engine for images from the web. It owns the loader and
/// the cache, decides each request with `RemoteImageDecision`, and tells the
/// views to look again by bumping `revision`.
///
/// `state(for:pixelSize:cardID:)` is called while a view draws. It starts at
/// most one load per image, never changes observed state, and returns at once.
/// Nothing is fetched before the decision allows it.
@MainActor
@Observable
final class RemoteImageProvider {
    let boardID: CanvasID
    @ObservationIgnored private weak var board: CanvasBoardState?
    @ObservationIgnored let trust: RemoteImageTrustModel
    @ObservationIgnored let cache: RemoteImageCache
    @ObservationIgnored private let loader: RemoteImageLoader
    @ObservationIgnored private let presenter: ConsentPresenter
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var failureOrder: [String] = []
    @ObservationIgnored private var cardURLs: [CanvasCardID: Set<String>] = [:]
    @ObservationIgnored private var trustTask: Task<Void, Never>?
    @ObservationIgnored private var isAsking = false
    @ObservationIgnored private var scopes: [CanvasCardID: RafuCardRemoteImages] = [:]

    /// Shows the consent card and reports the answer once.
    typealias ConsentPresenter =
        @MainActor (
            RemoteImageConsentRequest, @escaping @MainActor (RemoteImageConsentOutcome) -> Void
        ) -> Void

    private var localRevision = 0
    /// Grows on every change a view must read again: a finished load, a
    /// revoked grant, a changed setting or trust list.
    var revision: Int { localRevision &+ trust.generation }

    init(
        board: CanvasBoardState,
        trust: RemoteImageTrustModel = .shared,
        loader: RemoteImageLoader = RemoteImageLoader(),
        cache: RemoteImageCache = RemoteImageCache(),
        revocation: RemoteImageRevocation = .shared,
        presenter: @escaping ConsentPresenter = RemoteImageConsentCard.present
    ) {
        self.boardID = board.id
        self.board = board
        self.trust = trust
        self.loader = loader
        self.cache = cache
        self.presenter = presenter
        revocation.register(self)
    }

    isolated deinit {
        for task in inFlight.values { task.cancel() }
        let loader = loader
        Task { await loader.invalidate() }
    }

    // MARK: State

    func state(for url: URL, pixelSize: CGSize, cardID: CanvasCardID) -> RemoteImageState {
        trust.startLoadingIfNeeded()
        guard trust.isLoaded else { return .loading }
        let host: String
        switch RemoteImageFetchPolicy.classify(url) {
        case .allowed(let allowedHost): host = allowedHost
        case .rejected(let reason): return .notAllowed(reason: reason)
        }
        switch decision(for: host) {
        case .deny(let reason):
            return .notAllowed(reason: reason)
        case .ask:
            return .needsConsent(host: host)
        case .allow(let grant):
            let pixels = Self.pixelBucket(pixelSize)
            let key = Self.cacheKey(url, pixels: pixels)
            if let image = cache.image(for: key) { return .image(image) }
            if let message = failures[key] { return .failed(message) }
            if inFlight[key] != nil { return .loading }
            var urls = cardURLs[cardID] ?? []
            if !urls.contains(url.absoluteString) {
                guard urls.count < RemoteImageFetchPolicy.maxImagesPerCard else {
                    return .failed("Too many images in one view.")
                }
                urls.insert(url.absoluteString)
                cardURLs[cardID] = urls
            }
            start(url: url, host: host, pixels: pixels, key: key, grant: grant)
            return .loading
        }
    }

    func decision(for host: String) -> RemoteImageDecision {
        RemoteImageDecision.evaluate(
            host: host, mode: trust.mode, patterns: trust.patterns, ensemble: boardID,
            ensembleConsented: board?.remoteImageConsent?.allowed == true)
    }

    /// The longest side to decode, rounded up to 128, 256, 512 or 1,024, so
    /// resizing a card does not fetch the same image again.
    nonisolated static func pixelBucket(_ size: CGSize) -> Int {
        let longest = max(size.width, size.height)
        for bucket in [128, 256, 512] where longest <= CGFloat(bucket) { return bucket }
        return 1_024
    }

    nonisolated static func cacheKey(_ url: URL, pixels: Int) -> String {
        "\(pixels)|\(url.absoluteString)"
    }

    // MARK: Loading

    private func start(url: URL, host: String, pixels: Int, key: String, grant: RemoteImageGrant) {
        let loader = loader
        inFlight[key] = Task { [weak self] in
            let outcome: Result<CGImage, any Error>
            do {
                let image = try await loader.load(
                    url: url, pixels: pixels,
                    authorizeRedirect: { [weak self] target in
                        await self?.authorizesRedirect(to: target, from: host) ?? false
                    })
                outcome = .success(image)
            } catch {
                outcome = .failure(error)
            }
            self?.finish(key: key, host: host, outcome: outcome)
        }
    }

    /// A redirect may go to the same host, or to a host the trust list or the
    /// global setting allows. Consent for the Ensemble covers the host the
    /// user was shown, not other hosts.
    func authorizesRedirect(to target: URL, from originalHost: String) -> Bool {
        guard case .allowed(let host) = RemoteImageFetchPolicy.classify(target) else {
            return false
        }
        guard case .allow(let grant) = decision(for: host) else { return false }
        if case .ensemble = grant { return host == originalHost }
        return true
    }

    private func finish(key: String, host: String, outcome: Result<CGImage, any Error>) {
        inFlight[key] = nil
        switch outcome {
        case .success(let image):
            // The grant may have gone while the image loaded.
            if case .allow(let grant) = decision(for: host) {
                cache.insert(image, key: key, grant: grant, host: host)
            }
        case .failure(let error):
            if error is CancellationError { return }
            remember(
                failure: (error as? RemoteImageLoadError)?.message
                    ?? "The image could not be loaded.", key: key)
        }
        localRevision &+= 1
    }

    private func remember(failure message: String, key: String) {
        if failures[key] == nil { failureOrder.append(key) }
        failures[key] = message
        while failureOrder.count > RemoteImageFetchPolicy.maxRememberedFailures {
            failures[failureOrder.removeFirst()] = nil
        }
    }

    /// Cancels loads that run now (the Ensemble was hidden). They start again
    /// when a view asks for them.
    func cancelInFlight() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Returns when the last trust-list write and every load that runs now have ended. For tests: it needs no
    /// sleep, so a test never waits on a timer.
    func waitForLoads() async {
        await trustTask?.value
        while let task = inFlight.values.first { await task.value }
    }

    /// Forgets the image count of a card that no longer exists.
    func releaseCard(_ id: CanvasCardID) {
        cardURLs[id] = nil
        scopes[id] = nil
    }

    // MARK: Revocation

    /// Drops cached images whose grant satisfies `matches`, cancels loads that
    /// the grant allowed, forgets failures, and tells views to look again.
    func dropCached(where matches: (RemoteImageGrant) -> Bool) {
        cache.drop(where: matches)
        // A load in flight may belong to the dropped grant; cancel all, the
        // views start the allowed ones again.
        cancelInFlight()
        failures.removeAll()
        failureOrder.removeAll()
        localRevision &+= 1
    }

    // MARK: Consent

    /// The "Allow…" press. Shows the consent card for `url`'s host. One card
    /// at a time per Ensemble; a press while one is open does nothing.
    func requestConsent(for url: URL) {
        guard !isAsking, case .allowed(let host) = RemoteImageFetchPolicy.classify(url),
            decision(for: host) == .ask
        else { return }
        isAsking = true
        let request = RemoteImageConsentRequest(
            host: host, hostPattern: HostPattern(kind: .exact, base: host),
            parentPattern: trust.parentOffer(for: host))
        presenter(request) { [weak self] outcome in
            self?.isAsking = false
            self?.handle(outcome)
        }
    }

    private func handle(_ outcome: RemoteImageConsentOutcome) {
        switch outcome {
        case .cancel:
            return
        case .allowEnsemble:
            guard let board else { return }
            do {
                try RemoteImageConsentWriter.grant(on: board)
            } catch {
                board.showNotice("Rafu could not save your choice for images from the web.")
            }
            localRevision &+= 1
        case .trust(let pattern):
            trustTask = Task { [weak self] in
                guard let self else { return }
                if !(await trust.add(pattern, source: .confirm)) {
                    board?.showNotice(
                        trust.writeProblem
                            ?? "Rafu could not save your choice for images from the web.")
                }
            }
        }
    }

    /// The user revoked this Ensemble's consent (the Agent control panel).
    func revokeConsent() {
        guard let board else { return }
        do { try RemoteImageConsentWriter.revoke(on: board) } catch {
            board.showNotice("Rafu could not change images from the web for this Ensemble.")
            return
        }
        dropCached { $0 == .ensemble(boardID) }
    }

    // MARK: Per card

    /// The object a generated view card puts in its environment
    /// (`\.jrRemoteImageProvider`). One per card, kept for the card's life.
    func scoped(to card: CanvasCardID) -> RafuCardRemoteImages {
        if let existing = scopes[card] { return existing }
        let created = RafuCardRemoteImages(engine: self, cardID: card)
        scopes[card] = created
        return created
    }
}
