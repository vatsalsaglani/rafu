import Foundation
import Testing

@testable import RafuApp

@Suite("Public Suffix List")
struct PublicSuffixListTests {
    private let list = TestSuffixes.list

    @Test("Normal rules, wildcard rules and exception rules")
    func rules() {
        #expect(list.isPublicSuffix("com"))
        #expect(list.isPublicSuffix("co.uk"))
        #expect(list.isPublicSuffix("github.io"))
        #expect(!list.isPublicSuffix("example.com"))
        // `*.ck`: every second-level name under ck is a suffix.
        #expect(list.isPublicSuffix("anything.ck"))
        #expect(list.registrableDomain(of: "a.anything.ck") == "a.anything.ck")
        // `!www.ck`: the exception makes www.ck registrable.
        #expect(!list.isPublicSuffix("www.ck"))
        #expect(list.registrableDomain(of: "sub.www.ck") == "www.ck")
        // `*.kawasaki.jp` with `!city.kawasaki.jp`.
        #expect(list.isPublicSuffix("x.kawasaki.jp"))
        #expect(!list.isPublicSuffix("city.kawasaki.jp"))
        #expect(list.registrableDomain(of: "www.city.kawasaki.jp") == "city.kawasaki.jp")
    }

    @Test("The default rule: an unknown last label is a suffix")
    func defaultRule() {
        #expect(list.isPublicSuffix("nosuchtld"))
        #expect(list.registrableDomain(of: "a.b.nosuchtld") == "b.nosuchtld")
        #expect(list.registrableDomain(of: "nosuchtld") == nil)
    }

    @Test("Registrable domains")
    func registrable() {
        #expect(list.registrableDomain(of: "a.b.example.com") == "example.com")
        #expect(list.registrableDomain(of: "example.com") == "example.com")
        #expect(list.registrableDomain(of: "com") == nil)
        #expect(list.registrableDomain(of: "x.example.co.uk") == "example.co.uk")
        #expect(list.registrableDomain(of: "user.github.io") == "user.github.io")
    }

    @Test("The bundled file parses, and knows the private section")
    func bundled() async {
        // Reported for the handoff: the time to parse the file itself. No
        // assertion on it: a debug build on a busy machine says nothing
        // about a release build (about 15 ms measured in release).
        let clock = ContinuousClock()
        if let text = try? String(contentsOf: Self.listURL, encoding: .utf8) {
            let elapsed = clock.measure { _ = PublicSuffixList(contents: text) }
            print("PublicSuffixList parse of the bundled file (debug): \(elapsed)")
        }
        let bundled = await PublicSuffixResource.loadBundled()
        #expect(bundled.isPublicSuffix("com"))
        #expect(bundled.isPublicSuffix("co.uk"))
        #expect(bundled.isPublicSuffix("github.io"))
        // `githubusercontent.com` is in the private section: a suffix itself.
        #expect(bundled.isPublicSuffix("githubusercontent.com"))
        #expect(
            bundled.registrableDomain(of: "raw.githubusercontent.com")
                == "raw.githubusercontent.com")
        #expect(bundled.registrableDomain(of: "cdn.example.co.uk") == "example.co.uk")
        // An internationalised rule is matched in punycode.
        #expect(bundled.isPublicSuffix("xn--55qx5d.cn"))
    }

    private static var listURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/RafuApp/Resources/PublicSuffix/public_suffix_list.dat")
    }

    @Test("The bundled file is within its size note")
    func bundledSize() throws {
        let size =
            try FileManager.default.attributesOfItem(atPath: Self.listURL.path)[.size] as? Int
        #expect((size ?? 0) > 100_000)
        #expect((size ?? .max) < 400_000)
    }
}
