import Foundation
import Testing

@testable import RafuApp

@Suite("Remote image fetch policy")
struct RemoteImageFetchPolicyTests {
    private func classify(_ text: String) -> RemoteImageFetchPolicy.Classification {
        RemoteImageFetchPolicy.classify(URL(string: text)!)
    }

    @Test("An https URL with a public-looking host is allowed, as lowercase punycode")
    func allowed() {
        #expect(
            classify("https://Images.Example.com/a.png") == .allowed(host: "images.example.com"))
        #expect(
            classify("https://images.example.com:443/a.png") == .allowed(host: "images.example.com")
        )
        #expect(classify("https://bücher.example/a.png") == .allowed(host: "xn--bcher-kva.example"))
    }

    @Test("Only https; no http, file, data or ftp")
    func schemes() {
        for text in [
            "http://example.com/a.png", "file:///tmp/a.png", "data:image/png;base64,AAAA",
            "ftp://example.com/a.png",
        ] {
            guard case .rejected = classify(text) else {
                Issue.record("\(text) was allowed")
                continue
            }
        }
    }

    @Test("IP literals in every spelling, localhost, .local and single-label names are refused")
    func localAndAddresses() {
        for text in [
            "https://127.0.0.1/a.png", "https://10.1.2.3/a.png", "https://[::1]/a.png",
            "https://[fe80::1]/a.png", "https://0x7f.0.0.1/a.png", "https://127.1/a.png",
            "https://2130706433/a.png", "https://localhost/a.png", "https://foo.localhost/a.png",
            "https://printer.local/a.png", "https://intranet/a.png", "https://nas.internal/a.png",
        ] {
            guard case .rejected = classify(text) else {
                Issue.record("\(text) was allowed")
                continue
            }
        }
    }

    @Test("User names and other ports are refused")
    func userAndPort() {
        guard case .rejected = classify("https://user:pw@example.com/a.png") else {
            Issue.record("userinfo was allowed")
            return
        }
        guard case .rejected = classify("https://example.com:8443/a.png") else {
            Issue.record("port 8443 was allowed")
            return
        }
    }

    @Test("Private, loopback, link-local, CGNAT and unique-local addresses are not public")
    func addressRanges() {
        for address in [
            "127.0.0.1", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
            "169.254.1.1", "100.64.0.1", "100.127.255.255", "0.0.0.0", "224.0.0.1",
            "255.255.255.255", "198.18.0.1", "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1",
            "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::7f00:1",
            "2002:7f00:1::1", "2001:db8::1",
        ] {
            #expect(!RemoteImageFetchPolicy.isPublicAddress(address), "\(address)")
        }
        for address in [
            "93.184.216.34", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:2800:220:1::1",
            "::ffff:8.8.8.8",
        ] {
            #expect(RemoteImageFetchPolicy.isPublicAddress(address), "\(address)")
        }
        #expect(!RemoteImageFetchPolicy.isPublicAddress("not an address"))
    }

    @Test("A host with one private answer is refused; no answer is refused")
    func mixedAnswers() {
        #expect(RemoteImageFetchPolicy.allPublic(["93.184.216.34", "2606:2800:220:1::1"]))
        #expect(!RemoteImageFetchPolicy.allPublic(["93.184.216.34", "10.0.0.1"]))
        #expect(!RemoteImageFetchPolicy.allPublic([]))
    }

    @Test("The fixed limits")
    @MainActor
    func limits() {
        #expect(RemoteImageFetchPolicy.maxBytes == 2 * 1_024 * 1_024)
        #expect(RemoteImageFetchPolicy.maxRedirects == 2)
        #expect(RemoteImageFetchPolicy.maxConcurrent == 4)
        #expect(RemoteImageFetchPolicy.maxImagesPerCard == 20)
        #expect(RemoteImageFetchPolicy.requestTimeout == 8)
        #expect(RemoteImageFetchPolicy.cacheByteLimit == CanvasImagePool.byteLimit)
    }
}
