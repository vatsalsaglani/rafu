import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

@Suite("Remote image loader")
struct RemoteImageLoaderTests {
    private func load(
        _ server: StubImageServer, path: String = "/a.png", pixels: Int = 256,
        loader: RemoteImageLoader = StubImageServer.loader(),
        authorize: @escaping RemoteImageLoader.RedirectAuthorizer = { _ in true }
    ) async throws -> CGImage {
        try await loader.load(url: server.url(path), pixels: pixels, authorizeRedirect: authorize)
    }

    private func failure(_ work: () async throws -> CGImage) async -> RemoteImageLoadError? {
        do {
            _ = try await work()
            return nil
        } catch { return error as? RemoteImageLoadError }
    }

    @Test("A PNG, a JPEG and a GIF load")
    func formats() async throws {
        let server = StubImageServer()
        server.reply("/a.png", .init(body: TestImages.png))
        server.reply("/a.jpg", .init(body: TestImages.jpeg))
        server.reply("/a.gif", .init(body: TestImages.gif))
        for path in ["/a.png", "/a.jpg", "/a.gif"] {
            let image = try await load(server, path: path)
            #expect(image.width > 0 && image.width <= 256)
        }
        #expect(server.hits == 3)
    }

    @Test("The decode is a thumbnail no larger than the requested side")
    func thumbnail() async throws {
        let server = StubImageServer()
        server.reply("/big.png", .init(body: TestImages.encoded(.png, width: 900, height: 600)))
        let image = try await load(server, path: "/big.png", pixels: 128)
        #expect(max(image.width, image.height) <= 128)
        // Below the clamp, 64 px is the smallest side asked for.
        let small = try await load(server, path: "/big.png", pixels: 1)
        #expect(max(small.width, small.height) <= 64)
    }

    @Test("The request has no cookie, no referer, no authorization, and the fixed user agent")
    func requestHeaders() async throws {
        let server = StubImageServer()
        server.reply("/a.png", .init(body: TestImages.png))
        _ = try await load(server)
        let seen = try #require(server.requests.first)
        let headers = Dictionary(
            uniqueKeysWithValues: seen.headers.map { ($0.key.lowercased(), $0.value) })
        #expect(headers["cookie"] == nil)
        #expect(headers["referer"] == nil)
        #expect(headers["authorization"] == nil)
        #expect(headers["user-agent"] == "Rafu/test")
    }

    @Test("The session keeps no cookies, credentials or cache")
    func configuration() {
        let configuration = RemoteImageLoader.makeConfiguration(version: "1.2")
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == 8)
        #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == "Rafu/1.2")
    }

    @Test("A body over 2 MB is cut, with or without a Content-Length")
    func sizeCap() async throws {
        let big = TestImages.png + Data(repeating: 0, count: 3 * 1_024 * 1_024)
        let server = StubImageServer()
        server.reply("/chunked.png", .init(body: big))
        server.reply(
            "/length.png", .init(headers: ["Content-Length": String(big.count)], body: big))
        for path in ["/chunked.png", "/length.png"] {
            #expect(await failure { try await load(server, path: path) } == .tooLarge)
        }
        // One byte under the cap still loads.
        let fits = TestImages.png + Data(repeating: 0, count: 1_900_000)
        server.reply("/fits.png", .init(body: fits))
        _ = try await load(server, path: "/fits.png")
    }

    @Test("SVG, HTML and BMP are refused by their first bytes")
    func unsupportedTypes() async {
        let server = StubImageServer()
        server.reply("/a.svg", .init(headers: ["Content-Type": "image/png"], body: TestImages.svg))
        server.reply("/a.html", .init(body: Data("<html><body>hello world</body></html>".utf8)))
        server.reply("/a.bmp", .init(body: Data("BM".utf8) + Data(repeating: 0, count: 64)))
        server.reply("/tiny", .init(body: Data([0x89, 0x50])))
        for path in ["/a.svg", "/a.html", "/a.bmp", "/tiny"] {
            #expect(
                await failure { try await load(server, path: path) } == .unsupportedType, "\(path)")
        }
    }

    @Test("A PNG header with a broken body fails to decode")
    func brokenImage() async {
        let server = StubImageServer()
        server.reply("/bad.png", .init(body: Data(TestImages.png.prefix(40))))
        let error = await failure { try await load(server, path: "/bad.png") }
        #expect(error == .decodeFailed)
    }

    @Test("A non-2xx answer fails")
    func status() async {
        let server = StubImageServer()
        server.reply("/gone.png", .init(status: 404, body: TestImages.png))
        #expect(await failure { try await load(server, path: "/gone.png") } == .badStatus(404))
        #expect(await failure { try await load(server, path: "/unset.png") } == .badStatus(404))
    }

    @Test("Hosts that are not public are refused before any request")
    func privateResolution() async {
        let server = StubImageServer()
        server.reply("/a.png", .init(body: TestImages.png))
        let loopback = StubImageServer.loader(resolver: { _ in ["127.0.0.1"] })
        let mixed = StubImageServer.loader(resolver: { _ in ["93.184.216.34", "10.0.0.2"] })
        let none = StubImageServer.loader(resolver: { _ in [] })
        for loader in [loopback, mixed, none] {
            let error = await failure { try await load(server, loader: loader) }
            guard case .rejected = error else {
                Issue.record("not refused: \(String(describing: error))")
                continue
            }
        }
        #expect(server.hits == 0)
    }

    @Test("Addresses, http and local names never reach the network")
    func syntacticRejection() async {
        let loader = StubImageServer.loader()
        for text in [
            "http://example.com/a.png", "https://127.0.0.1/a.png", "https://localhost/a.png",
            "https://x.local/a.png",
        ] {
            do {
                _ = try await loader.load(
                    url: URL(string: text)!, pixels: 64, authorizeRedirect: { _ in true })
                Issue.record("\(text) loaded")
            } catch {
                guard case RemoteImageLoadError.rejected = error else {
                    Issue.record("\(text): \(error)")
                    continue
                }
            }
        }
    }

    @Test("A redirect to another allowed host is followed; the target sees no referer")
    func followsRedirect() async throws {
        let first = StubImageServer()
        let second = StubImageServer()
        first.reply("/a.png", .init(redirect: second.url("/b.png")))
        second.reply("/b.png", .init(body: TestImages.png))
        _ = try await load(first)
        #expect(first.hits == 1)
        #expect(second.hits == 1)
        let seen = try #require(second.requests.first)
        #expect(seen.headers.keys.allSatisfy { $0.lowercased() != "referer" })
    }

    @Test("A redirect to a host the caller does not allow is refused")
    func untrustedRedirect() async {
        let first = StubImageServer()
        let second = StubImageServer()
        first.reply("/a.png", .init(redirect: second.url("/b.png")))
        second.reply("/b.png", .init(body: TestImages.png))
        let secondHost = second.host
        let error = await failure {
            try await load(first, authorize: { $0.host != secondHost })
        }
        guard case .redirectRefused = error else {
            Issue.record("not refused: \(String(describing: error))")
            return
        }
        #expect(second.hits == 0)
    }

    @Test("A redirect to http, to an address, or to a private resolution is refused")
    func badRedirects() async {
        let first = StubImageServer()
        let second = StubImageServer()
        for target in [
            "http://example.com/b.png", "https://127.0.0.1/b.png", "https://x.local/b.png",
        ] {
            first.reply("/a.png", .init(redirect: URL(string: target)!))
            let error = await failure { try await load(first) }
            guard case .redirectRefused = error else {
                Issue.record("\(target) not refused: \(String(describing: error))")
                continue
            }
        }
        first.reply("/a.png", .init(redirect: second.url("/b.png")))
        second.reply("/b.png", .init(body: TestImages.png))
        let privateOnSecond = StubImageServer.loader(resolver: { host in
            host == second.host ? ["192.168.0.9"] : ["93.184.216.34"]
        })
        let error = await failure { try await load(first, loader: privateOnSecond) }
        guard case .redirectRefused = error else {
            Issue.record("private target not refused: \(String(describing: error))")
            return
        }
        #expect(second.hits == 0)
    }

    @Test("Two redirects are followed; a third is refused")
    func redirectLimit() async throws {
        let one = StubImageServer()
        let two = StubImageServer()
        let three = StubImageServer()
        let four = StubImageServer()
        one.reply("/a.png", .init(redirect: two.url("/a.png")))
        two.reply("/a.png", .init(redirect: three.url("/a.png")))
        three.reply("/a.png", .init(redirect: four.url("/a.png")))
        four.reply("/a.png", .init(body: TestImages.png))
        // one -> two -> three is two redirects; three answers 302 again.
        let error = await failure { try await load(one) }
        guard case .redirectRefused = error else {
            Issue.record("not refused: \(String(describing: error))")
            return
        }
        #expect(four.hits == 0)
        // Two redirects reach the image.
        three.reply("/a.png", .init(body: TestImages.png))
        _ = try await load(one)
    }

    @Test("At most four loads run at once")
    func concurrencyLimit() async throws {
        let server = StubImageServer()
        server.reply("/a.png", .init(body: TestImages.png))
        let gate = ResolverGate()
        let loader = StubImageServer.loader(resolver: { _ in
            await gate.arrive()
            return ["93.184.216.34"]
        })
        let url = server.url()
        let tasks = (0..<6).map { _ in
            Task { try await loader.load(url: url, pixels: 64, authorizeRedirect: { _ in true }) }
        }
        await gate.waitForArrivals(4)
        // Four hold a slot (inside the resolver); two wait.
        #expect(await loader.activeCount == 4)
        await gate.openAll()
        for task in tasks { _ = try await task.value }
        #expect(await loader.activeCount == 0)
        #expect(await gate.maxArrived == 6)
    }

    @Test("Cancelling a waiting load frees its place")
    func cancelWaiting() async throws {
        let server = StubImageServer()
        server.reply("/a.png", .init(body: TestImages.png))
        let gate = ResolverGate()
        let loader = RemoteImageLoader(
            configuration: StubImageServer.configuration(),
            resolver: { _ in
                await gate.arrive()
                return ["93.184.216.34"]
            }, limit: 1)
        let url = server.url()
        let first = Task {
            try await loader.load(url: url, pixels: 64, authorizeRedirect: { _ in true })
        }
        await gate.waitForArrivals(1)
        let second = Task {
            try await loader.load(url: url, pixels: 64, authorizeRedirect: { _ in true })
        }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await gate.openAll()
        _ = try await first.value
        #expect(await loader.activeCount == 0)
    }

    @Test("The sniffer accepts the four formats and nothing else")
    func sniffing() {
        func sniff(_ bytes: [UInt8]) -> Bool {
            RemoteImageFetchCollector.looksLikeSupportedImage(Data(bytes))
        }
        let pad = [UInt8](repeating: 0, count: 8)
        #expect(sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + pad))
        #expect(sniff([0xFF, 0xD8, 0xFF, 0xE0] + pad))
        #expect(sniff(Array("GIF89a".utf8) + pad))
        #expect(sniff(Array("GIF87a".utf8) + pad))
        #expect(sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8 ".utf8)))
        #expect(!sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8)))
        #expect(!sniff(Array("<svg xmlns=\"x\">".utf8)))
        #expect(!sniff(Array("<?xml version".utf8)))
        #expect(!sniff(Array("BM".utf8) + pad + pad))
        #expect(!sniff([0x89, 0x50]))
    }
}

/// Holds resolver calls until the test opens the gate.
actor ResolverGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var open = false
    private(set) var maxArrived = 0

    func arrive() async {
        maxArrived += 1
        let ready = arrivalWaiters.filter { maxArrived >= $0.0 }
        arrivalWaiters.removeAll { maxArrived >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        if maxArrived >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func openAll() {
        open = true
        let all = waiting
        waiting.removeAll()
        for continuation in all { continuation.resume() }
    }
}
