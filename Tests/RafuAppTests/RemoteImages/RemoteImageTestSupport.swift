import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

@testable import RafuApp

/// A small Public Suffix List for tests that need no bundled file.
enum TestSuffixes {
    static let list = PublicSuffixList(
        contents: """
            // a comment
            com
            uk
            co.uk
            io
            github.io
            jp
            *.ck
            !www.ck
            *.kawasaki.jp
            !city.kawasaki.jp
            """)
}

/// A temporary directory for one test.
struct TestDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(
            path: "rafu-remote-images-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    var trustFile: URL { url.appending(path: "image-trust.json", directoryHint: .notDirectory) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Images made with ImageIO, for the stub server.
enum TestImages {
    static func cgImage(width: Int = 8, height: Int = 8) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encoded(_ type: UTType, width: Int = 8, height: Int = 8) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static var png: Data { encoded(.png) }
    static var jpeg: Data { encoded(.jpeg) }
    static var gif: Data { encoded(.gif) }
    static let svg = Data(
        #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#
            .utf8)
}

/// One stub web server for one test. Requests are routed by host name, so
/// tests that run in parallel never meet: each test uses its own host.
final class StubImageServer: Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// A redirect target: the stub answers 302 with this `Location`.
        var redirect: URL?
    }

    struct Seen: Sendable {
        var url: URL
        var headers: [String: String]
    }

    let host: String
    private let replies = Mutex<[String: Reply]>([:])
    private let log = Mutex<[Seen]>([])

    init() {
        host = "img-\(UUID().uuidString.prefix(8).lowercased()).example.com"
        StubImageProtocol.servers.withLock { $0[host] = self }
    }

    deinit {
        let host = host
        StubImageProtocol.servers.withLock { $0[host] = nil }
    }

    func url(_ path: String = "/a.png") -> URL { URL(string: "https://\(host)\(path)")! }

    func reply(_ path: String, _ reply: Reply) {
        replies.withLock { $0[path] = reply }
    }

    var hits: Int { log.withLock { $0.count } }
    var requests: [Seen] { log.withLock { $0 } }

    fileprivate func respond(to request: URLRequest) -> Reply {
        log.withLock {
            $0.append(
                Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:]))
        }
        return replies.withLock { $0[request.url?.path ?? ""] } ?? Reply(status: 404)
    }

    /// A session configuration whose only network is the stub servers.
    static func configuration() -> URLSessionConfiguration {
        let configuration = RemoteImageLoader.makeConfiguration(version: "test")
        configuration.protocolClasses = [StubImageProtocol.self]
        return configuration
    }

    /// A loader that resolves every host to a public address.
    static func loader(
        resolver: @escaping RemoteImageLoader.Resolver = { _ in ["93.184.216.34"] }
    ) -> RemoteImageLoader {
        RemoteImageLoader(configuration: configuration(), resolver: resolver)
    }
}

final class StubImageProtocol: URLProtocol {
    static let servers = Mutex<[String: StubImageServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let server = Self.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.respond(to: request)
        if let target = reply.redirect {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
