import Foundation

/// Turns text into one lowercase ASCII host: parsed by Foundation, IDNA
/// normalised to `xn--` labels, then checked label by label. Foundation does
/// the IDNA step (verified on macOS 27: `bücher.example` becomes
/// `xn--bcher-kva.example`); Rafu has no IDNA code of its own.
nonisolated enum HostNormalizer {
    /// The longest host, in bytes.
    static let maxHostBytes = 253
    static let maxLabelBytes = 63

    /// `host` as lowercase punycode, or nil when it is not a plain host name:
    /// anything with a scheme, userinfo, port, path, query, fragment, escape,
    /// space, underscore, empty label, label over 63 bytes, a label that
    /// starts or ends with a hyphen, or a name over 253 bytes. One trailing
    /// dot is removed. Names with one label are accepted here; callers that
    /// need two labels check the count.
    static func normalize(_ raw: String) -> String? {
        var text = raw
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        // Characters that would let Foundation read a different URL part.
        let forbidden = Set<Character>(["/", "\\", "?", "#", "@", ":", "%", "[", "]", " ", "*"])
        guard
            !text.contains(where: {
                forbidden.contains($0) || $0.isWhitespace
                    || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            })
        else { return nil }
        guard let url = URL(string: "https://\(text)/"),
            url.user() == nil, url.password() == nil, url.port == nil,
            url.path() == "/", url.query() == nil, url.fragment() == nil,
            var host = url.host(percentEncoded: false)
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        host = host.lowercased()
        return isValidASCIIHost(host) ? host : nil
    }

    /// Lowercase letters, digits and hyphens in 1...63 byte labels, 253 bytes
    /// at most, no label starting or ending with a hyphen.
    static func isValidASCIIHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= maxHostBytes else { return false }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = label.utf8
            guard (1...maxLabelBytes).contains(bytes.count),
                bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-"),
                bytes.allSatisfy({
                    ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                        || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                        || $0 == UInt8(ascii: "-")
                })
            else { return false }
        }
        return true
    }

    /// True when the host is an IPv4 or IPv6 literal in any spelling the URL
    /// loader could read as an address: dotted decimal, short forms such as
    /// `127.1`, a bare integer, or a `0x` hex part. A real top-level domain is
    /// never all digits and never starts with `0x`.
    static func looksLikeIPAddress(_ host: String) -> Bool {
        if host.contains(":") || host.hasPrefix("[") { return true }
        guard let last = host.split(separator: ".").last else { return false }
        if last.allSatisfy(\.isASCIIDigit) { return true }
        if last.hasPrefix("0x") { return true }
        var address = in_addr()
        return host.withCString { inet_aton($0, &address) } != 0
    }
}

extension Character {
    fileprivate nonisolated var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

/// One entry of the image host trust list: an exact host, or one leading
/// wildcard on a parent domain. Never a regular expression, a path, a port,
/// a scheme or an address.
nonisolated struct HostPattern: Hashable, Sendable {
    enum Kind: Sendable { case exact, wildcard }

    let kind: Kind
    /// The exact host, or the parent domain of a wildcard. Lowercase punycode.
    let base: String

    /// The text that is stored and shown: `images.example.com` or
    /// `*.example.com`.
    var text: String { kind == .exact ? base : "*." + base }

    enum Rejection: Error, Equatable, Sendable {
        case empty
        case notAHost
        case ipAddress
        case localName
        case singleLabel
        case invalidHost
        case badWildcard
        case publicSuffix(String)

        /// The reason shown under the Add field.
        var message: String {
            switch self {
            case .empty:
                "Enter a host such as images.example.com or *.example.com"
            case .notAHost:
                "Enter only a host name. A scheme, path, port or user name is not allowed"
            case .ipAddress:
                "IP addresses are not allowed"
            case .localName:
                "Local names are not allowed"
            case .singleLabel:
                "Enter a host with at least two parts, such as example.com"
            case .invalidHost:
                "This is not a valid host name"
            case .badWildcard:
                "Use one * and only as the first part, such as *.example.com"
            case .publicSuffix(let suffix):
                "*.\(suffix) is a public suffix. Name a domain below it"
            }
        }
    }

    /// Parses and validates `raw`. A leading `*.` makes a wildcard; its base
    /// must not be a public suffix (`*.com`, `*.co.uk`, `*.github.io`).
    static func parse(
        _ raw: String, suffixes: any PublicSuffixProviding
    ) throws(Rejection) -> HostPattern {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        if trimmed.contains("[") || trimmed.contains("]") { throw .ipAddress }
        let delimiters: Set<Character> = ["/", ":", "?", "#", "@", "\\", "%"]
        if trimmed.contains(where: { delimiters.contains($0) }) {
            // A bare IPv6 address, or an address with a port, is still an address.
            let head = String(trimmed.prefix { !delimiters.contains($0) }).lowercased()
            let colons = trimmed.count(where: { $0 == ":" })
            if (colons >= 2 && !trimmed.contains("/")) || HostNormalizer.looksLikeIPAddress(head) {
                throw .ipAddress
            }
            throw .notAHost
        }
        let isWildcard = trimmed.hasPrefix("*.")
        let rest = isWildcard ? String(trimmed.dropFirst(2)) : trimmed
        if rest.contains("*") { throw .badWildcard }
        guard let host = HostNormalizer.normalize(rest) else {
            // Distinguish a bad host from an address for the message.
            if HostNormalizer.looksLikeIPAddress(rest.lowercased()) { throw .ipAddress }
            throw .invalidHost
        }
        if HostNormalizer.looksLikeIPAddress(host) { throw .ipAddress }
        if RemoteImageFetchPolicy.isLocalName(host) { throw .localName }
        if isWildcard {
            guard !suffixes.isPublicSuffix(host) else { throw .publicSuffix(host) }
            return HostPattern(kind: .wildcard, base: host)
        }
        guard host.contains(".") else { throw .singleLabel }
        return HostPattern(kind: .exact, base: host)
    }

    /// True when `host` (already parsed, normalised and lowercase, as
    /// `RemoteImageFetchPolicy.classify` returns it) is covered. A wildcard
    /// covers any depth below its base and never the base itself.
    func matches(host: String) -> Bool {
        switch kind {
        case .exact: host == base
        case .wildcard: host.hasSuffix("." + base) && host.utf8.count > base.utf8.count + 1
        }
    }

    /// The wildcard the consent card offers for `host`: `*.` plus its
    /// registrable domain, or nil when the host is the registrable domain
    /// itself (or a public suffix). `raw.githubusercontent.com` offers
    /// `*.githubusercontent.com`; `example.com` offers nothing.
    static func parentOffer(
        for host: String, suffixes: any PublicSuffixProviding
    ) -> HostPattern? {
        guard let registrable = suffixes.registrableDomain(of: host), registrable != host,
            !suffixes.isPublicSuffix(registrable)
        else { return nil }
        return HostPattern(kind: .wildcard, base: registrable)
    }

    /// "star dot example dot com", for VoiceOver.
    var spoken: String { RemoteImageSpeech.spoken(text) }
}

/// Spells a host for VoiceOver: `*.git-hub.com` becomes
/// "star dot git dash hub dot com".
nonisolated enum RemoteImageSpeech {
    static func spoken(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for character in text {
            switch character {
            case ".":
                flush()
                words.append("dot")
            case "*":
                flush()
                words.append("star")
            case "-":
                flush()
                words.append("dash")
            default: current.append(character)
            }
        }
        flush()
        return words.joined(separator: " ")
    }
}
