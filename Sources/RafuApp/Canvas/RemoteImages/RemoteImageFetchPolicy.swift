import Foundation

/// The fixed limits and the syntactic URL checks for images from the web.
/// Pure and nonisolated; the loader applies the network-level checks.
nonisolated enum RemoteImageFetchPolicy {
    /// Seconds to wait for data before a request fails.
    static let requestTimeout: TimeInterval = 8
    /// Seconds for the whole transfer.
    static let resourceTimeout: TimeInterval = 15
    /// `https` redirects one request may follow.
    static let maxRedirects = 2
    /// The most encoded bytes one image may have.
    static let maxBytes = 2 * 1_024 * 1_024
    /// The most pixels one image may have before Rafu refuses to decode it.
    static let maxPixels = 64 * 1_024 * 1_024
    /// Images in flight at once, per Ensemble.
    static let maxConcurrent = 4
    /// Different images one generated view may ask for.
    static let maxImagesPerCard = 20
    /// Decoded images one Ensemble keeps, in bytes (the `CanvasImagePool` limit).
    static let cacheByteLimit = 8 * 1_024 * 1_024
    /// Failed loads one Ensemble remembers.
    static let maxRememberedFailures = 64

    enum Classification: Equatable, Sendable {
        /// An `https` URL for a public-looking host name. `host` is lowercase
        /// punycode.
        case allowed(host: String)
        case rejected(reason: String)
    }

    /// The syntactic check: https only, no user name, port 443 only, a real
    /// two-part host name; no IP literal, `localhost`, `.local` name or other
    /// local name. Names that resolve to a private address are refused later
    /// by the loader.
    static func classify(_ url: URL) -> Classification {
        guard url.scheme?.lowercased() == "https" else {
            return .rejected(reason: "Only https images load.")
        }
        guard url.user() == nil, url.password() == nil else {
            return .rejected(reason: "Addresses with a user name do not load.")
        }
        guard url.port == nil || url.port == 443 else {
            return .rejected(reason: "Only the standard https port loads.")
        }
        guard let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else {
            return .rejected(reason: "The address has no host.")
        }
        if rawHost.contains(":") || rawHost.hasPrefix("[") {
            return .rejected(reason: "IP addresses do not load.")
        }
        guard let host = HostNormalizer.normalize(rawHost) else {
            return .rejected(reason: "The host name is not valid.")
        }
        if HostNormalizer.looksLikeIPAddress(host) {
            return .rejected(reason: "IP addresses do not load.")
        }
        if isLocalName(host) {
            return .rejected(reason: "Local names do not load.")
        }
        guard host.contains(".") else {
            return .rejected(reason: "Local names do not load.")
        }
        return .allowed(host: host)
    }

    /// `localhost` and the names that only mean this network.
    static func isLocalName(_ host: String) -> Bool {
        if host == "localhost" || host == "local" { return true }
        for suffix in [".localhost", ".local", ".internal", ".localdomain", ".home.arpa"]
        where host.hasSuffix(suffix) {
            return true
        }
        return false
    }

    // MARK: Resolved addresses

    /// True when `address` (a numeric IPv4 or IPv6 string) may be a public
    /// internet host. Loopback, RFC 1918, link-local, CGNAT (100.64/10),
    /// IPv6 unique-local and link-local, multicast, documentation, reserved
    /// and unspecified ranges are not.
    static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return isPublicIPv4(value)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return isPublicIPv6(bytes)
        }
        return false
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let blocked: [(UInt32, Int)] = [
            (0x0000_0000, 8),  // "this network"
            (0x0A00_0000, 8),  // 10/8
            (0x6440_0000, 10),  // 100.64/10 carrier-grade NAT
            (0x7F00_0000, 8),  // loopback
            (0xA9FE_0000, 16),  // 169.254/16 link-local
            (0xAC10_0000, 12),  // 172.16/12
            (0xC000_0000, 24),  // 192.0.0/24
            (0xC000_0200, 24),  // 192.0.2/24 documentation
            (0xC0A8_0000, 16),  // 192.168/16
            (0xC612_0000, 15),  // 198.18/15 benchmarking
            (0xC633_6400, 24),  // 198.51.100/24 documentation
            (0xCB00_7100, 24),  // 203.0.113/24 documentation
            (0xE000_0000, 4),  // multicast
            (0xF000_0000, 4),  // reserved and broadcast
        ]
        for (base, bits) in blocked {
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            if value & mask == base & mask { return false }
        }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let leadingZeros = bytes.prefix(10).allSatisfy { $0 == 0 }
        // ::, ::1, and IPv4-compatible or IPv4-mapped (::ffff:a.b.c.d) forms.
        if leadingZeros {
            if bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPublicIPv4(embeddedIPv4(bytes, at: 12))
            }
            return false
        }
        // 64:ff9b::/96 (NAT64) carries an IPv4 address in the last 4 bytes.
        if bytes.prefix(12).elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isPublicIPv4(embeddedIPv4(bytes, at: 12))
        }
        // 2002::/16 (6to4) carries one in bytes 2...5.
        if bytes[0] == 0x20, bytes[1] == 0x02 { return isPublicIPv4(embeddedIPv4(bytes, at: 2)) }
        if bytes[0] & 0xFE == 0xFC { return false }  // fc00::/7 unique-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10 link-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false }  // fec0::/10 site-local
        if bytes[0] == 0xFF { return false }  // multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return false  // 2001:db8::/32 documentation
        }
        return true
    }

    private static func embeddedIPv4(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
    }

    /// True when every answer for a host is public and there is at least one.
    /// A host with one private answer is refused.
    static func allPublic(_ addresses: [String]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
    }
}
