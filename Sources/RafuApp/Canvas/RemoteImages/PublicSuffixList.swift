import Foundation

/// What the host trust list needs from the Public Suffix List. A protocol so
/// tests can inject a tiny list.
nonisolated protocol PublicSuffixProviding: Sendable {
    /// True when `host` (lowercase, punycode) is a public suffix. A host with
    /// one label is always one: the PSL default rule is `*`.
    func isPublicSuffix(_ host: String) -> Bool
    /// The public suffix plus one label, or nil when `host` is a public suffix.
    func registrableDomain(of host: String) -> String?
}

/// The Public Suffix List (https://publicsuffix.org, MPL-2.0), parsed once.
/// Both the ICANN and the PRIVATE sections count: `github.io` is a suffix.
nonisolated struct PublicSuffixList: PublicSuffixProviding {
    private let rules: Set<String>
    private let wildcardParents: Set<String>
    private let exceptions: Set<String>

    /// Parses the text of a `public_suffix_list.dat` file.
    init(contents: String) {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        // Work on UTF-8 bytes: the file has about 16,000 lines.
        for line in contents.utf8.split(separator: UInt8(ascii: "\n")) {
            // A rule ends at the first whitespace; `//` starts a comment.
            guard let first = line.first, first != UInt8(ascii: "/"), first > UInt8(ascii: " ")
            else { continue }
            let bytes = line.prefix { $0 > UInt8(ascii: " ") }
            var rule = String(decoding: bytes, as: UTF8.self).lowercased()
            var isException = false
            if rule.hasPrefix("!") {
                isException = true
                rule.removeFirst()
            }
            if !rule.utf8.allSatisfy({ $0 < 0x80 }) {
                // A Unicode rule is matched in its punycode form.
                guard let ascii = HostNormalizer.normalize(rule) else { continue }
                rule = ascii
            }
            if isException {
                exceptions.insert(rule)
            } else if rule.hasPrefix("*.") {
                wildcards.insert(String(rule.dropFirst(2)))
            } else {
                rules.insert(rule)
            }
        }
        self.rules = rules
        self.wildcardParents = wildcards
        self.exceptions = exceptions
    }

    /// The number of labels in the public suffix of `labels`.
    private func suffixLabelCount(_ labels: [Substring]) -> Int {
        let count = labels.count
        // An exception rule wins: the suffix is the rule minus its first label.
        for index in 0..<count {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) { return count - index - 1 }
        }
        // Otherwise the longest matching rule (the leftmost match) wins.
        for index in 0..<count {
            let candidate = labels[index...].joined(separator: ".")
            if rules.contains(candidate) { return count - index }
            if index + 1 < count,
                wildcardParents.contains(labels[(index + 1)...].joined(separator: "."))
            {
                return count - index
            }
        }
        // The default rule `*`: the last label is the suffix.
        return 1
    }

    func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        return suffixLabelCount(labels) >= labels.count
    }

    func registrableDomain(of host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        let suffixCount = suffixLabelCount(labels)
        guard labels.count > suffixCount else { return nil }
        return labels[(labels.count - suffixCount - 1)...].joined(separator: ".")
    }
}

/// Loads the list that ships in the app bundle (`Resources/PublicSuffix`).
nonisolated enum PublicSuffixResource {
    /// Reads and parses the bundled file off the main actor. An empty list
    /// (only the PSL default rule `*`) if the resource is missing.
    ///
    /// `Bundle.module` is main-actor isolated in the default-isolated app
    /// target, so only the URL is resolved there.
    @concurrent
    static func loadBundled() async -> PublicSuffixList {
        let url = await MainActor.run {
            Bundle.module.url(
                forResource: "public_suffix_list", withExtension: "dat",
                subdirectory: "PublicSuffix")
        }
        guard let url, let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return PublicSuffixList(contents: "") }
        return PublicSuffixList(contents: text)
    }
}
