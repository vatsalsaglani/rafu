import Foundation
import Testing

@testable import RafuApp

@Suite("Image host patterns")
struct HostPatternTests {
    private let suffixes = TestSuffixes.list

    private func parse(_ text: String) throws -> HostPattern {
        try HostPattern.parse(text, suffixes: suffixes)
    }

    private func rejection(_ text: String) -> HostPattern.Rejection? {
        do {
            _ = try HostPattern.parse(text, suffixes: suffixes)
            return nil
        } catch { return error }
    }

    @Test("An exact host matches only itself")
    func exactMatch() throws {
        let pattern = try parse("images.example.com")
        #expect(pattern.kind == .exact)
        #expect(pattern.matches(host: "images.example.com"))
        #expect(!pattern.matches(host: "example.com"))
        #expect(!pattern.matches(host: "a.images.example.com"))
        #expect(!pattern.matches(host: "images.example.com.evil.com"))
    }

    @Test("A wildcard matches any depth below its base and never the base")
    func wildcardMatch() throws {
        let pattern = try parse("*.example.com")
        #expect(pattern.kind == .wildcard)
        #expect(pattern.text == "*.example.com")
        #expect(pattern.matches(host: "a.example.com"))
        #expect(pattern.matches(host: "a.b.example.com"))
        #expect(!pattern.matches(host: "example.com"))
        #expect(!pattern.matches(host: "badexample.com"))
        #expect(!pattern.matches(host: "example.com.evil.com"))
    }

    @Test("Case, a trailing dot and Unicode are normalised before matching")
    func normalisation() throws {
        #expect(try parse("Images.Example.COM.").text == "images.example.com")
        #expect(try parse("  *.Example.com  ").text == "*.example.com")
        // Foundation does the IDNA step (macOS 15 and later).
        #expect(try parse("bücher.example").text == "xn--bcher-kva.example")
        #expect(try parse("*.BÜCHER.example").text == "*.xn--bcher-kva.example")
        #expect(try parse("xn--bcher-kva.example").text == "xn--bcher-kva.example")
    }

    @Test("Addresses and local names are refused")
    func addressesAndLocalNames() {
        for text in [
            "127.0.0.1", "10.0.0.5", "[::1]", "::1", "2001:db8::1", "0x7f.1", "127.1",
            "2130706433", "192.168.1.1:8080",
        ] {
            #expect(rejection(text) == .ipAddress, "\(text)")
        }
        #expect(rejection("localhost") == .localName)
        #expect(rejection("printer.local") == .localName)
        #expect(rejection("*.local") == .localName)
        #expect(rejection("*.localhost") == .localName)
    }

    @Test("A bare public suffix is never allowed as a wildcard")
    func publicSuffixWildcards() {
        #expect(rejection("*.com") == .publicSuffix("com"))
        #expect(rejection("*.co.uk") == .publicSuffix("co.uk"))
        #expect(rejection("*.github.io") == .publicSuffix("github.io"))
        #expect(rejection("*.uk") == .publicSuffix("uk"))
        // An unknown last label is a suffix under the default rule.
        #expect(rejection("*.nosuchtld") == .publicSuffix("nosuchtld"))
        // A domain below a suffix is fine, at any depth.
        #expect(throws: Never.self) { _ = try parse("*.example.co.uk") }
        #expect(throws: Never.self) { _ = try parse("*.cdn.example.com") }
    }

    @Test("Paths, ports, schemes, userinfo, escapes and spaces are refused")
    func notAHost() {
        for text in [
            "https://example.com", "example.com/path", "example.com:8080", "user@example.com",
            "example.com?x=1", "example.com#top", "example.com\\x", "ex%41mple.com",
        ] {
            #expect(rejection(text) == .notAHost, "\(text)")
        }
        #expect(rejection("exa mple.com") == .invalidHost)
        #expect(rejection("") == .empty)
        #expect(rejection("   ") == .empty)
    }

    @Test("Only one star, alone in the first label")
    func wildcardShape() {
        for text in ["*.*.example.com", "a.*.example.com", "*example.com", "ex*.example.com", "*"] {
            #expect(rejection(text) == .badWildcard, "\(text)")
        }
    }

    @Test("Label and host length, hyphens, empty labels and single labels")
    func hostShape() throws {
        #expect(rejection("a..example.com") == .invalidHost)
        #expect(rejection("-a.example.com") == .invalidHost)
        #expect(rejection("a-.example.com") == .invalidHost)
        #expect(rejection("a_b.example.com") == .invalidHost)
        #expect(rejection("example") == .singleLabel)
        let label63 = String(repeating: "a", count: 63)
        let label64 = String(repeating: "a", count: 64)
        #expect(throws: Never.self) { _ = try parse("\(label63).example.com") }
        #expect(rejection("\(label64).example.com") == .invalidHost)
        // 253 bytes is the longest host; 254 is refused.
        let long = [label63, label63, label63, String(repeating: "b", count: 57) + ".com"]
        let host253 = long.joined(separator: ".")
        #expect(host253.utf8.count == 253)
        #expect(throws: Never.self) { _ = try parse(host253) }
        #expect(rejection("c" + host253) == .invalidHost)
    }

    @Test("Every rejection has a reason for the Add field")
    func messages() {
        #expect(HostPattern.Rejection.ipAddress.message == "IP addresses are not allowed")
        #expect(HostPattern.Rejection.publicSuffix("com").message.contains("*.com"))
        #expect(!HostPattern.Rejection.empty.message.isEmpty)
    }

    @Test("A host that is itself below a private suffix gets no wildcard offer")
    func privateSuffixHost() async throws {
        // In the real list `githubusercontent.com` is a (private) public
        // suffix, so `raw.githubusercontent.com` is already registrable: only
        // the exact host can be trusted, and `*.githubusercontent.com` is refused.
        let bundled = await PublicSuffixResource.loadBundled()
        #expect(HostPattern.parentOffer(for: "raw.githubusercontent.com", suffixes: bundled) == nil)
        #expect(throws: HostPattern.Rejection.publicSuffix("githubusercontent.com")) {
            _ = try HostPattern.parse("*.githubusercontent.com", suffixes: bundled)
        }
        #expect(throws: HostPattern.Rejection.publicSuffix("cloudfront.net")) {
            _ = try HostPattern.parse("*.cloudfront.net", suffixes: bundled)
        }
        #expect(throws: Never.self) {
            _ = try HostPattern.parse("raw.githubusercontent.com", suffixes: bundled)
        }
        #expect(
            HostPattern.parentOffer(for: "a.b.example.com", suffixes: bundled)?.text
                == "*.example.com")
    }

    @Test("The parent offer is the registrable domain, and none for a registrable host")
    func parentOffer() throws {
        // The small test list has no private rules, so a deep host offers its parent.
        let raw = HostPattern.parentOffer(for: "raw.assets.example.com", suffixes: suffixes)
        #expect(raw?.text == "*.example.com")
        let cdn = HostPattern.parentOffer(for: "cdn.example.co.uk", suffixes: suffixes)
        #expect(cdn?.text == "*.example.co.uk")
        #expect(
            HostPattern.parentOffer(for: "a.b.example.com", suffixes: suffixes)?.text
                == "*.example.com")
        #expect(HostPattern.parentOffer(for: "example.com", suffixes: suffixes) == nil)
        // A host directly below a private suffix is registrable already.
        #expect(HostPattern.parentOffer(for: "user.github.io", suffixes: suffixes) == nil)
        #expect(HostPattern.parentOffer(for: "github.io", suffixes: suffixes) == nil)
    }

    @Test("Hosts are spelled out for VoiceOver")
    func speech() throws {
        #expect(try parse("*.example.com").spoken == "star dot example dot com")
        #expect(RemoteImageSpeech.spoken("a-b.example.com") == "a dash b dot example dot com")
    }
}
