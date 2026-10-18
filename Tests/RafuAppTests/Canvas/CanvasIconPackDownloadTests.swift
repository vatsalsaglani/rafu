import CryptoKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas icon pack downloads")
struct CanvasIconPackDownloadTests {
    @Test("Every pinned source is HTTPS on its vendor's own host, with a hash and a size")
    func pinnedSources() {
        #expect(
            Set(CanvasIconPackDownloads.sources.map(\.vendor)) == [.aws, .azure, .googleCloud])
        for source in CanvasIconPackDownloads.sources {
            #expect(CanvasIconPackDownloads.isAllowed(source.url, vendor: source.vendor))
            #expect(source.sha256?.count == 64)
            #expect(source.approximateBytes < CanvasIconPackDownloads.maximumBytes)
        }
    }

    @Test("Other hosts, schemes, ports, credentials and vendors are refused")
    func allowlist() throws {
        func allowed(_ text: String, _ vendor: CanvasIconPackVendor = .aws) throws -> Bool {
            CanvasIconPackDownloads.isAllowed(try #require(URL(string: text)), vendor: vendor)
        }
        #expect(try allowed("https://d1.awsstatic.com/a.zip"))
        #expect(try !allowed("http://d1.awsstatic.com/a.zip"))
        #expect(try !allowed("https://d1.awsstatic.com.evil.example/a.zip"))
        #expect(try !allowed("https://user:pw@d1.awsstatic.com/a.zip"))
        #expect(try !allowed("https://d1.awsstatic.com:8443/a.zip"))
        #expect(try !allowed("https://services.google.com/a.zip", .aws))
        #expect(try allowed("https://services.google.com/a.zip", .googleCloud))
        #expect(try !allowed("https://arch-center.azureedge.net/a.zip", .custom))
    }

    @Test("A failure message points at Import Icon Pack and the vendor page")
    func failureMessage() {
        let message = CanvasIconPackDownloads.failureMessage(for: .azure)
        #expect(message.contains("Import Icon Pack"))
        #expect(message.contains("learn.microsoft.com"))
    }

    @Test("Redirects are refused before contacting an unapproved destination")
    func redirectPolicy() async throws {
        let policy = CanvasIconPackRedirectPolicy(vendor: .aws)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = try #require(URL(string: "https://d1.awsstatic.com/icons.zip"))
        let task = session.dataTask(with: source)
        let response = try #require(
            HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        for destination in [
            "https://unapproved.example/icons.zip", "http://d1.awsstatic.com/icons.zip",
            "https://services.google.com/icons.zip", "https://user:secret@aws.amazon.com/icons.zip",
            "http://127.0.0.1/private", "https://aws.amazon.com:8443/icons.zip",
        ] {
            let request = URLRequest(url: try #require(URL(string: destination)))
            let redirect = await policy.urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: request)
            #expect(redirect == nil)
        }
        let allowed = URLRequest(url: try #require(URL(string: "https://aws.amazon.com/icons.zip")))
        let redirect = await policy.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: allowed)
        #expect(redirect?.url == allowed.url)
        #expect(redirect?.httpShouldHandleCookies == false)
    }

    @Test("Hashes print as lowercase hex")
    func hex() {
        let digest = SHA256.hash(data: Data("abc".utf8))
        #expect(
            CanvasIconPackDownloads.hex(digest)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
