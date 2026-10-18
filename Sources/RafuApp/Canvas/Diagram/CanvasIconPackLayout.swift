import Foundation

/// Pure rules for importing a vendor icon download: which vendor a folder
/// tree comes from, how its file names become icon names, and which archive
/// entries and files are safe. Paths are `/`-separated and relative to the
/// extracted root.
nonisolated enum CanvasIconPackLayout {
    /// One icon chosen from a source tree.
    struct Candidate: Equatable, Sendable {
        let sourcePath: String
        let entry: CanvasIconPackEntry
        let fileExtension: String
    }

    static let imageExtensions: Set<String> = ["svg", "png"]

    // MARK: Paths

    /// True for a file that may hold an icon: SVG or PNG, not hidden, not an
    /// AppleDouble or `__MACOSX` artefact.
    static func isIconPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty else { return false }
        guard !parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else {
            return false
        }
        return imageExtensions.contains(fileExtension(of: name))
    }

    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    // MARK: Vendor detection

    /// The vendor with the most layout hints; `.custom` when none match.
    static func detectVendor(paths: [String]) -> CanvasIconPackVendor {
        var counts: [CanvasIconPackVendor: Int] = [:]
        for path in paths where isIconPath(path) {
            if let vendor = vendorHint(path) { counts[vendor, default: 0] += 1 }
        }
        let ordered: [CanvasIconPackVendor] = [.aws, .azure, .googleCloud]
        var best: (vendor: CanvasIconPackVendor, count: Int) = (.custom, 0)
        for vendor in ordered where (counts[vendor] ?? 0) > best.count {
            best = (vendor, counts[vendor] ?? 0)
        }
        return best.vendor
    }

    static func vendorHint(_ path: String) -> CanvasIconPackVendor? {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        let folders = parts.dropLast().map { $0.lowercased() }
        if name.hasPrefix("Arch_") || name.hasPrefix("Res_") || name.hasPrefix("Arch-Category_")
            || folders.contains(where: {
                $0.hasPrefix("architecture-service-icons") || $0.hasPrefix("resource-icons")
                    || $0.hasPrefix("architecture-group-icons")
            })
        {
            return .aws
        }
        if isAzureFileName(name) || folders.contains(where: { $0.contains("azure") }) {
            return .azure
        }
        let lowerName = name.lowercased()
        if folders.contains(where: {
            $0.contains("google") || $0.contains("gcp") || $0.contains("core-products")
        }) || stem(of: lowerName).contains("-512-color") {
            return .googleCloud
        }
        return nil
    }

    /// "10021-icon-service-Virtual-Machine.svg"
    static func isAzureFileName(_ name: String) -> Bool {
        let digits = name.prefix(while: \.isNumber)
        return !digits.isEmpty && name.dropFirst(digits.count).hasPrefix("-icon-service-")
    }

    // MARK: Names

    static func displayName(fileName: String, vendor: CanvasIconPackVendor) -> String {
        var base = strippingScaleSuffix(stem(of: fileName))
        switch vendor {
        case .aws:
            for prefix in ["Arch-Category_", "Arch_", "Res_"] where base.hasPrefix(prefix) {
                base.removeFirst(prefix.count)
                break
            }
            base = strippingSuffixTokens(base, separator: "_")
        case .azure:
            if isAzureFileName(base + ".svg") {
                let digits = base.prefix(while: \.isNumber).count
                base.removeFirst(digits + "-icon-service-".count)
            }
        case .googleCloud, .custom, .common:
            base = strippingSuffixTokens(base, separator: "-")
            base = strippingSuffixTokens(base, separator: "_")
        }
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
        let name = words.map(titleCased).joined(separator: " ")
        return String(name.prefix(CanvasDiagramLimits.textScalars)).isEmpty
            ? "Icon" : String(name.prefix(CanvasDiagramLimits.textScalars))
    }

    /// "Arch_AWS-Lambda_64@5x" -> "Arch_AWS-Lambda_64".
    static func strippingScaleSuffix(_ stem: String) -> String {
        guard let at = stem.lastIndex(of: "@") else { return stem }
        let tail = stem[stem.index(after: at)...].lowercased()
        guard tail.count >= 2, tail.hasSuffix("x"), tail.dropLast().allSatisfy(\.isNumber) else {
            return stem
        }
        return String(stem[..<at])
    }

    /// Drops trailing size and theme tokens: "_48", "_Light", "-512", "-color", "-24px".
    static func strippingSuffixTokens(_ text: String, separator: Character) -> String {
        var parts = text.split(separator: separator, omittingEmptySubsequences: false)
            .map(String.init)
        let noise: Set<String> = [
            "light", "dark", "color", "colour", "mono", "icon", "rgb", "cmyk",
        ]
        while parts.count > 1, let last = parts.last {
            let lower = last.lowercased()
            let isSize =
                !lower.isEmpty
                && (lower.allSatisfy(\.isNumber)
                    || (lower.hasSuffix("px") && lower.dropLast(2).allSatisfy(\.isNumber)
                        && lower.count > 2))
            guard isSize || noise.contains(lower) || lower.isEmpty else { break }
            parts.removeLast()
        }
        return parts.joined(separator: String(separator))
    }

    /// Lowercase words become title case; short ones become acronyms
    /// ("ai" -> "AI"); words with capitals keep them ("BigQuery").
    static func titleCased(_ word: String) -> String {
        guard word == word.lowercased() else { return word }
        let special: [String: String] = [
            "iot": "IoT", "ai": "AI", "ml": "ML", "api": "API", "dns": "DNS", "vm": "VM",
            "vpn": "VPN", "sql": "SQL", "cdn": "CDN", "and": "and", "for": "for", "of": "of",
        ]
        if let known = special[word] { return known }
        if word.count <= 2, word.allSatisfy(\.isLetter) { return word.uppercased() }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    static func category(path: String, vendor: CanvasIconPackVendor, name: String) -> String {
        let folders = path.split(separator: "/").dropLast().map(String.init)
        let ignored: Set<String> = ["svg", "png", "icons", "icon", "assets", "color", "mono"]
        for folder in folders.reversed() {
            let lower = folder.lowercased()
            if vendor == .aws {
                if lower.hasPrefix("arch-category") || lower.hasPrefix("category-icons") {
                    return "Categories"
                }
                if lower.hasPrefix("architecture-group") { return "Groups" }
            }
            if ignored.contains(lower) || lower.contains("icons")
                || lower.allSatisfy({ $0.isNumber || $0 == "x" })
            {
                continue
            }
            var value = folder
            if vendor == .aws {
                guard lower.hasPrefix("arch_") || lower.hasPrefix("res_") else { continue }
                value = String(folder.drop(while: { $0 != "_" }).dropFirst())
                // Size folders: "Arch_32", "Res_48_Light".
                if value.first?.isNumber == true { continue }
            }
            let words = value.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
                .map(String.init)
            let title = words.map(titleCased).joined(separator: " ")
            if title.isEmpty || title.caseInsensitiveCompare(name) == .orderedSame { continue }
            return String(title.prefix(60))
        }
        return vendor == .custom ? "Icons" : vendor.title
    }

    static func keywords(name: String, category: String, vendor: CanvasIconPackVendor) -> [String] {
        var words = CanvasIconSearch.words(CanvasIconSearch.normalized(name))
        let nameWords = words
        words += CanvasIconSearch.words(CanvasIconSearch.normalized(category))
        switch vendor {
        case .aws: words.append("aws")
        case .azure: words.append("azure")
        case .googleCloud: words += ["gcp", "google"]
        case .common, .custom: break
        }
        if nameWords.count >= 2 { words.append(String(nameWords.compactMap(\.first))) }
        var seen = Set<String>()
        return
            words
            .filter { !$0.isEmpty && $0.utf8.count <= CanvasDiagramLimits.keywordBytes }
            .filter { seen.insert($0).inserted }
            .prefix(CanvasDiagramLimits.keywordsPerIcon).map { $0 }
    }

    // MARK: Candidates

    /// One entry per (category, name), preferring SVG, then a light variant,
    /// then the size closest to 64. Ordered by category then name, bounded.
    static func candidates(paths: [String], vendor: CanvasIconPackVendor) -> [Candidate] {
        struct Pick {
            let path: String
            let name: String
            let category: String
            let ext: String
            let rank: Int
        }
        var picks: [String: Pick] = [:]
        for path in paths where isIconPath(path) {
            let fileName = String(path.split(separator: "/").last ?? "")
            let ext = fileExtension(of: fileName)
            let product = vendor == .googleCloud ? productFolder(path) : nil
            let name = product ?? displayName(fileName: fileName, vendor: vendor)
            let category =
                product != nil
                ? vendor.title : category(path: path, vendor: vendor, name: name)
            let rank = preference(fileName: fileName, ext: ext)
            let key = "\(category.lowercased())\u{1F}\(name.lowercased())"
            if let existing = picks[key],
                existing.rank > rank || (existing.rank == rank && existing.path <= path)
            {
                continue
            }
            picks[key] = Pick(path: path, name: name, category: category, ext: ext, rank: rank)
        }
        let ordered = picks.values.sorted {
            ($0.category, $0.name, $0.path) < ($1.category, $1.name, $1.path)
        }
        var used = Set<String>()
        var result: [Candidate] = []
        for pick in ordered.prefix(CanvasDiagramLimits.iconsPerPack) {
            var id = CanvasDiagramText.slug("\(pick.category) \(pick.name)")
            if used.contains(id) {
                var suffix = 2
                while used.contains("\(id)-\(suffix)") { suffix += 1 }
                id = "\(id)-\(suffix)"
            }
            used.insert(id)
            let entry = CanvasIconPackEntry(
                id: id, name: pick.name, category: pick.category,
                keywords: keywords(name: pick.name, category: pick.category, vendor: vendor),
                symbol: nil, file: "\(id).\(pick.ext)")
            result.append(Candidate(sourcePath: pick.path, entry: entry, fileExtension: pick.ext))
        }
        return result
    }

    /// Google Cloud ships "<Product>/SVG/<File>-512-color.svg": the folder
    /// holds the product's real name ("Cloud Storage", not "Cloud_Storage").
    static func productFolder(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let format = parts[parts.count - 2].lowercased()
        let product = parts[parts.count - 3]
        guard format == "svg" || format == "png", !product.lowercased().contains("icons"),
            CanvasDiagramText.isValid(product, allowsEmpty: false)
        else { return nil }
        return String(product.prefix(CanvasDiagramLimits.textScalars))
    }

    static func preference(fileName: String, ext: String) -> Int {
        var rank = ext == "svg" ? 1_000 : 0
        let lower = fileName.lowercased()
        if lower.contains("_dark") || lower.contains("-dark") { rank -= 200 }
        let numbers = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if let size = numbers.last(where: { [16, 24, 32, 48, 64, 128, 256, 512].contains($0) }) {
            rank += 100 - min(99, abs(size - 64))
        }
        return rank
    }
}

/// Archive and file safety checks for imported icon packs.
nonisolated enum CanvasIconPackSafety {
    /// A ZIP entry name that stays inside the extraction folder.
    static func isSafeArchiveEntry(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1_024, !name.contains("\0"),
            !name.contains("\\"), !name.hasPrefix("/"), !name.hasPrefix("~"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        if name.count >= 2, name.dropFirst().first == ":" { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.contains { $0 == ".." || $0 == "." }
    }

    /// Parses the summary line of `zipinfo -t`:
    /// "123 files, 4567890 bytes uncompressed, 1234567 bytes compressed:  73.0%".
    static func zipTotals(_ output: String) -> (entries: Int, uncompressedBytes: Int64)? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 4,
                words[1].hasPrefix("file"),
                let entries = Int(words[0]),
                let index = words.firstIndex(where: { $0 == "uncompressed," }),
                index >= 2, words[index - 1] == "bytes",
                let bytes = Int64(words[index - 2])
            else { continue }
            return (entries, bytes)
        }
        return nil
    }

    /// PNG signature.
    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// An SVG document without scripts, event handlers, embedded HTML or
    /// external references.
    static func isAcceptableSVG(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        guard lower.contains("<svg") else { return false }
        let forbidden = [
            "<script", "javascript:", "<foreignobject", "<iframe", "<embed", "<object",
            "href=\"http", "href='http", "href=\"//", "href='//", "url(http", "@import",
            "<!entity", "<!doctype",
        ]
        if forbidden.contains(where: lower.contains) { return false }
        return !containsEventHandler(lower)
    }

    /// `onload=`, `onclick =` and similar attributes.
    static func containsEventHandler(_ lower: String) -> Bool {
        let text = lower.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var search = text[...]
        while let range = search.range(of: " on") {
            var index = range.upperBound
            var letters = 0
            while index < search.endIndex, search[index].isLetter {
                letters += 1
                index = search.index(after: index)
            }
            while index < search.endIndex, search[index] == " " {
                index = search.index(after: index)
            }
            if letters >= 3, index < search.endIndex, search[index] == "=" { return true }
            search = search[range.upperBound...]
        }
        return false
    }
}
