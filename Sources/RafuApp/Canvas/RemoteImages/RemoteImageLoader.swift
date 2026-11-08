import CoreGraphics
import Foundation
import ImageIO
import OSLog
import Synchronization

/// Why a remote image did not load. `message` is the short text the card shows.
nonisolated enum RemoteImageLoadError: Error, Equatable, Sendable {
    case rejected(String)
    case tooLarge
    case unsupportedType
    case imageTooLarge
    case decodeFailed
    case badStatus(Int)
    case timedOut
    case networkFailed
    case redirectRefused(String)

    var message: String {
        switch self {
        case .rejected(let reason): reason
        case .tooLarge: "The image is larger than 2 MB."
        case .unsupportedType: "Unsupported image type."
        case .imageTooLarge: "The image has too many pixels."
        case .decodeFailed: "The image could not be read."
        case .badStatus(let code): "The server answered \(code)."
        case .timedOut: "The image host did not answer in time."
        case .networkFailed: "The image could not be loaded."
        case .redirectRefused(let reason): reason
        }
    }
}

/// Loads one image at a time per call, for one Ensemble: an ephemeral
/// `URLSession` (no cookies, no credentials, no cache), https only, redirects
/// only to hosts the caller still allows, a size cap, an image-type check by
/// sniffing the first bytes, and an ImageIO thumbnail decode. At most four
/// loads run at once; the rest wait.
///
/// A host name is resolved before the connection and refused when any answer
/// is a private, loopback or link-local address. `URLSession` resolves again
/// when it connects, so a hostile DNS server could still answer differently
/// the second time. This window is accepted (ADR: remote images) and is
/// narrowed by checking every redirect target the same way.
actor RemoteImageLoader {
    typealias Resolver = @Sendable (String) async -> [String]
    typealias RedirectAuthorizer = @Sendable (URL) async -> Bool

    private static let logger = Logger(
        subsystem: "dev.vatsalsaglani.rafu", category: "RemoteImages")

    private let configuration: URLSessionConfiguration
    private let resolver: Resolver
    private let limit: Int
    private var session: URLSession?
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// - Parameters:
    ///   - configuration: tests pass an ephemeral configuration with a stub
    ///     `URLProtocol`. The default is `makeConfiguration()`.
    ///   - resolver: numeric addresses for a host. Tests pass a fixed answer.
    init(
        configuration: URLSessionConfiguration = RemoteImageLoader.makeConfiguration(),
        resolver: @escaping Resolver = RemoteImageLoader.resolveWithGetaddrinfo,
        limit: Int = RemoteImageFetchPolicy.maxConcurrent
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.limit = limit
    }

    /// An ephemeral configuration with nothing shared: no cookies, no
    /// credentials, no URL cache, no connectivity wait.
    nonisolated static func makeConfiguration(version: String = appVersion)
        -> URLSessionConfiguration
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = RemoteImageFetchPolicy.requestTimeout
        configuration.timeoutIntervalForResource = RemoteImageFetchPolicy.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = RemoteImageFetchPolicy.maxConcurrent
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Rafu/\(version)",
            "Accept": "image/png,image/jpeg,image/gif,image/webp",
        ]
        return configuration
    }

    nonisolated static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev"
    }

    /// Cancels every request and ends the session. The loader makes a new
    /// session if it is used again.
    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    // MARK: Load

    /// Fetches and decodes `url` to a thumbnail whose longest side is
    /// `pixels` at most (clamped to 64...1,024).
    ///
    /// - Parameter authorizeRedirect: asked for each redirect target; the
    ///   redirect is refused when it answers false.
    func load(
        url: URL, pixels: Int, authorizeRedirect: @escaping RedirectAuthorizer
    ) async throws -> CGImage {
        guard case .allowed(let host) = RemoteImageFetchPolicy.classify(url) else {
            throw RemoteImageLoadError.rejected(Self.rejectionReason(for: url))
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard RemoteImageFetchPolicy.allPublic(await resolver(host)) else {
            throw RemoteImageLoadError.rejected("The image host is not a public address.")
        }
        try Task.checkCancellation()
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: RemoteImageFetchPolicy.requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        // No Referer, no Cookie, no Authorization: nothing is added.
        let collector = RemoteImageFetchCollector(
            resolver: resolver, authorizeRedirect: authorizeRedirect)
        let task = currentSession().dataTask(with: request)
        task.delegate = collector
        Self.logger.debug("fetch start host=\(host, privacy: .public)")
        let data: Data
        do {
            data = try await collector.run(task)
        } catch let error as RemoteImageLoadError {
            Self.logger.debug(
                "fetch failed host=\(host, privacy: .public) reason=\(error.message, privacy: .public)"
            )
            throw error
        }
        Self.logger.debug("fetch done host=\(host, privacy: .public) bytes=\(data.count)")
        try Task.checkCancellation()
        return try await Self.decode(data, pixels: pixels)
    }

    private static func rejectionReason(for url: URL) -> String {
        if case .rejected(let reason) = RemoteImageFetchPolicy.classify(url) { return reason }
        return "The address is not allowed."
    }

    private func currentSession() -> URLSession {
        if let session { return session }
        let created = URLSession(configuration: configuration)
        session = created
        return created
    }

    // MARK: Concurrency limit

    private func acquire() async throws {
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Loads running now. For tests.
    var activeCount: Int { active }

    // MARK: Decode

    /// Decodes the first frame as an ImageIO thumbnail. The full image is
    /// never decoded: untrusted data gets a pixel-count check first.
    @concurrent
    static func decode(_ data: Data, pixels: Int) async throws -> CGImage {
        let longest = min(1_024, max(64, pixels))
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) >= 1,
            let type = CGImageSourceGetType(source) as String?,
            ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"]
                .contains(type)
        else { throw RemoteImageLoadError.decodeFailed }
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw RemoteImageLoadError.decodeFailed }
        guard width <= RemoteImageFetchPolicy.maxPixels / height else {
            throw RemoteImageLoadError.imageTooLarge
        }
        try Task.checkCancellation()
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: longest,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw RemoteImageLoadError.decodeFailed }
        // The cache counts 4 bytes per pixel; redraw a deep image to 8 bits.
        guard image.bitsPerPixel > 32 else { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RemoteImageLoadError.decodeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let redrawn = context.makeImage() else { throw RemoteImageLoadError.decodeFailed }
        return redrawn
    }

    // MARK: Resolution

    /// Numeric IPv4 and IPv6 answers for `host`, or none. The blocking call
    /// runs on a global queue, not on a cooperative thread.
    static let resolveWithGetaddrinfo: Resolver = { host in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
                    if let address = entry.pointee.ai_addr {
                        if entry.pointee.ai_family == AF_INET {
                            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                var raw = $0.pointee.sin_addr
                                inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count))
                            }
                        } else if entry.pointee.ai_family == AF_INET6 {
                            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                                var raw = $0.pointee.sin6_addr
                                inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count))
                            }
                        }
                    }
                    let text = String(
                        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self)
                    if !text.isEmpty { addresses.append(text) }
                    cursor = entry.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// The per-request delegate: follows at most two https redirects to hosts the
/// caller still allows, stops past the size cap, sniffs the type from the
/// first bytes, and refuses every authentication challenge except TLS trust.
/// One instance serves exactly one request.
nonisolated final class RemoteImageFetchCollector: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var data = Data()
        var redirects = 0
        var failure: RemoteImageLoadError?
        var continuation: CheckedContinuation<Data, any Error>?
        var finished = false
    }

    private let state = Mutex(State())
    private let resolver: RemoteImageLoader.Resolver
    private let authorizeRedirect: RemoteImageLoader.RedirectAuthorizer

    init(
        resolver: @escaping RemoteImageLoader.Resolver,
        authorizeRedirect: @escaping RemoteImageLoader.RedirectAuthorizer
    ) {
        self.resolver = resolver
        self.authorizeRedirect = authorizeRedirect
    }

    /// Starts `task` and returns its body. Cancelling the caller cancels the task.
    func run(_ task: URLSessionDataTask) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func fail(_ error: RemoteImageLoadError) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        let count = state.withLock {
            $0.redirects += 1
            return $0.redirects
        }
        guard count <= RemoteImageFetchPolicy.maxRedirects else {
            fail(.redirectRefused("The image redirects too many times."))
            return nil
        }
        guard let url = request.url, url.scheme?.lowercased() == "https",
            case .allowed(let host) = RemoteImageFetchPolicy.classify(url)
        else {
            fail(.redirectRefused("The image redirects to an address that is not allowed."))
            return nil
        }
        guard await authorizeRedirect(url) else {
            fail(.redirectRefused("The image redirects to a host you have not allowed."))
            return nil
        }
        guard RemoteImageFetchPolicy.allPublic(await resolver(host)) else {
            fail(.redirectRefused("The image redirects to a private address."))
            return nil
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Referer")
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        next.httpShouldHandleCookies = false
        return next
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        if state.withLock({ $0.failure != nil }) { return .cancel }
        guard let http = response as? HTTPURLResponse else {
            fail(.networkFailed)
            return .cancel
        }
        guard (200..<300).contains(http.statusCode) else {
            fail(.badStatus(http.statusCode))
            return .cancel
        }
        if response.expectedContentLength > Int64(RemoteImageFetchPolicy.maxBytes) {
            fail(.tooLarge)
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let abort: Bool = state.withLock { state in
            guard state.failure == nil else { return true }
            let before = state.data.count
            state.data.append(data)
            if state.data.count > RemoteImageFetchPolicy.maxBytes {
                state.failure = .tooLarge
                state.data = Data()
                return true
            }
            // Check the type once, as soon as the first 12 bytes are here.
            if before < Self.sniffLength, state.data.count >= Self.sniffLength,
                !Self.looksLikeSupportedImage(state.data)
            {
                state.failure = .unsupportedType
                state.data = Data()
                return true
            }
            return false
        }
        if abort { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // No password, no client certificate, no credential of any kind.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let outcome: (CheckedContinuation<Data, any Error>?, Result<Data, any Error>) =
            state.withLock { state in
                guard !state.finished else { return (nil, .failure(CancellationError())) }
                state.finished = true
                let continuation = state.continuation
                state.continuation = nil
                if let failure = state.failure { return (continuation, .failure(failure)) }
                if let error {
                    let code = (error as? URLError)?.code
                    if code == .cancelled { return (continuation, .failure(CancellationError())) }
                    if code == .timedOut {
                        return (continuation, .failure(RemoteImageLoadError.timedOut))
                    }
                    return (continuation, .failure(RemoteImageLoadError.networkFailed))
                }
                if !Self.looksLikeSupportedImage(state.data) {
                    return (continuation, .failure(RemoteImageLoadError.unsupportedType))
                }
                return (continuation, .success(state.data))
            }
        outcome.0?.resume(with: outcome.1)
    }

    // MARK: Sniffing

    static let sniffLength = 12

    /// PNG, JPEG, GIF87a/89a, or RIFF....WEBP. Nothing else: not SVG, not
    /// HTML, not BMP, not TIFF.
    static func looksLikeSupportedImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return true
        }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return true
        }
        return false
    }
}
