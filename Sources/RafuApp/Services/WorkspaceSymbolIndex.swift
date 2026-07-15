import Foundation
import SwiftTreeSitter

/// One resolved workspace symbol, with its path already de-interned back to a
/// workspace-relative string. The palette's `#` mode and the syntactic
/// navigation provider consume this; the actor stores the more compact
/// `WorkspaceSymbol` (path interned to an `Int32`) internally.
nonisolated struct WorkspaceSymbolMatch: Sendable, Equatable {
    let name: String
    /// The `tags.scm` definition-kind suffix (function/method/class/…).
    let kind: String
    let relativePath: String
    /// UTF-16 range of the name inside its file.
    let range: NSRange
}

/// Background workspace symbol index backing the command palette's `#` mode
/// and the syntactic navigation tier. Mirrors `WorkspaceFileNameIndex`: an
/// actor so build and query run off-main automatically, fed by `git ls-files`
/// (`.gitignore`-aware) with a cancellable `FileManager` enumeration fallback,
/// then parsing only files whose grammar has a vendored `tags.scm` into
/// `(name, kind, path, range)` declarations.
///
/// Memory: paths are interned to `Int32` (`WorkspaceSymbol.pathIndex`) so the
/// per-symbol footprint stays small at the 500k global cap, and `shed()`
/// fully releases everything under memory pressure. Preview lines are NOT
/// stored; the navigation provider reads the matched file's line lazily when
/// it builds candidates.
actor WorkspaceSymbolIndex {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case building
        case ready(count: Int, isTruncated: Bool)
    }

    /// Global symbol cap. Above this the build stops and reports truncation.
    static let maximumSymbols = 500_000
    /// Files larger than this are skipped before any read (checked via
    /// `.fileSizeKey`) — a generated bundle should never dominate the index.
    static let maximumFileBytes = 512 * 1_024
    /// Per-file symbol cap, matching `WorkspaceSymbolExtractor.perFileLimit`.
    static let perFileSymbolLimit = WorkspaceSymbolExtractor.perFileLimit
    /// Bounds the non-git enumerator fallback the same way the filename index
    /// bounds its own enumeration.
    static let maximumFiles = WorkspaceFileNameIndex.maximumEntries

    private let runner = GitCommandRunner()
    private let fileService = WorkspaceFileService()

    /// Overridable only so tests can exercise the caps without materializing
    /// hundreds of thousands of symbols or a half-megabyte fixture file.
    private let symbolCap: Int
    private let fileByteCap: Int
    private let perFileLimit: Int

    /// Interned workspace-relative paths. `WorkspaceSymbol.pathIndex` indexes
    /// here. Incremental updates leave tombstone holes (a path whose
    /// `symbolsByPath` entry was removed); a full rebuild compacts them.
    private var paths: [String] = []
    private var pathIndexByPath: [String: Int32] = [:]
    private var symbolsByPath: [Int32: [WorkspaceSymbol]] = [:]
    private var totalSymbolCount = 0
    private(set) var state: State = .idle

    init(
        symbolCap: Int = WorkspaceSymbolIndex.maximumSymbols,
        fileByteCap: Int = WorkspaceSymbolIndex.maximumFileBytes,
        perFileLimit: Int = WorkspaceSymbolIndex.perFileSymbolLimit
    ) {
        self.symbolCap = symbolCap
        self.fileByteCap = fileByteCap
        self.perFileLimit = perFileLimit
    }

    var currentState: State { state }

    // MARK: - Build

    /// Rebuilds the index from scratch. Accumulates into locals and only
    /// publishes at the end, so a cancelled build leaves the prior
    /// paths/symbols/state untouched — the session always re-requests a fresh
    /// build for a superseded one.
    func build(rootURL: URL) async {
        state = .building
        do {
            try Task.checkCancellation()
            // Resolve the root once and use it for path collection, directory
            // listing, and file reads alike, so every stored relative path is
            // computed against the same (symlink-resolved) root. macOS's
            // `/var → /private/var` temp symlink otherwise garbles the prefix
            // when the enumerator resolves child URLs but a later listing does
            // not — the exact hazard `WorkspaceFileNameIndex` guards against.
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let relativePaths = try await collectPaths(rootURL: resolvedRoot)
            try await buildSymbols(rootURL: resolvedRoot, relativePaths: relativePaths)
        } catch is CancellationError {
            return
        } catch {
            publishEmpty()
        }
    }

    func reset() {
        paths = []
        pathIndexByPath = [:]
        symbolsByPath = [:]
        totalSymbolCount = 0
        state = .idle
    }

    /// Clears the index back to `.idle` under memory pressure. Identical to
    /// `reset()`; kept distinct so a pressure-driven shed reads clearly at its
    /// `WorkspaceSession.respondToMemoryPressure` call site.
    func shed() {
        reset()
    }

    private func buildSymbols(rootURL: URL, relativePaths: [String]) async throws {
        // Resolve every grammar's query + parser ONCE, up front, so the
        // per-file loop below has no `await` between iterations and the
        // reused non-`Sendable` `Parser`s never cross a suspension point.
        let grammars = await resolveGrammars()

        var newPaths: [String] = []
        var newPathIndexByPath: [String: Int32] = [:]
        var newSymbolsByPath: [Int32: [WorkspaceSymbol]] = [:]
        var total = 0
        var isTruncated = false
        var visited = 0

        for relativePath in relativePaths {
            visited += 1
            if visited.isMultiple(of: 2_000) { try Task.checkCancellation() }
            guard
                let grammarID = WorkspaceSymbolExtractor.grammarWithTags(
                    forRelativePath: relativePath),
                let grammar = grammars[grammarID]
            else { continue }

            let fileURL = rootURL.appending(path: relativePath)
            guard let text = readableText(at: fileURL) else { continue }

            let remaining = symbolCap - total
            if remaining <= 0 {
                isTruncated = true
                break
            }
            let extracted = WorkspaceSymbolExtractor.extractSymbols(
                text: text,
                query: grammar.query,
                parser: grammar.parser,
                limit: min(perFileLimit, remaining)
            )
            guard !extracted.isEmpty else { continue }

            let pathIndex = Int32(newPaths.count)
            newPaths.append(relativePath)
            newPathIndexByPath[relativePath] = pathIndex
            newSymbolsByPath[pathIndex] = extracted.map {
                WorkspaceSymbol(name: $0.name, kind: $0.kind, pathIndex: pathIndex, range: $0.range)
            }
            total += extracted.count
            if total >= symbolCap {
                isTruncated = true
                break
            }
        }

        paths = newPaths
        pathIndexByPath = newPathIndexByPath
        symbolsByPath = newSymbolsByPath
        totalSymbolCount = total
        state = .ready(count: total, isTruncated: isTruncated)
    }

    private func publishEmpty() {
        reset()
        state = .ready(count: 0, isTruncated: false)
    }

    // MARK: - Incremental updates

    /// Patches a ready index after a non-storm working-tree change: re-lists
    /// each changed directory level, re-extracts its grammar-covered files,
    /// and drops indexed files that no longer exist (a rename shows up as the
    /// old path pruned + the new path added). A storm bypasses this entirely —
    /// the session responds with a full `refreshWorkspace()` rebuild. A no-op
    /// unless the index is already `.ready`.
    func applyChanges(changedDirectoryRelativePaths dirs: Set<String>, rootURL: URL) async {
        guard case .ready(_, let wasTruncated) = state else { return }

        // Same resolved-root discipline as `build`, so incremental relative
        // paths match the ones stored at build time.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let grammars = await resolveGrammars()
        for dir in dirs {
            await applyDirectoryChange(dir, rootURL: resolvedRoot, grammars: grammars)
        }
        state = .ready(
            count: totalSymbolCount,
            isTruncated: wasTruncated || totalSymbolCount >= symbolCap
        )
    }

    private func applyDirectoryChange(
        _ directory: String,
        rootURL: URL,
        grammars: [GrammarLanguageID: ResolvedGrammar]
    ) async {
        let previouslyIndexed = indexedFiles(directlyIn: directory)

        let children: [WorkspaceFileNode]
        do {
            children = try await fileService.listDirectory(
                rootURL: rootURL, relativeDirectoryPath: directory)
        } catch {
            // The directory itself is gone: drop everything indexed under it.
            for path in previouslyIndexed { removeFile(path) }
            return
        }

        var seen: Set<String> = []
        for child in children where !child.isDirectory {
            // Build the relative key from the known directory plus the file
            // name rather than `WorkspaceFileService`'s naive prefix-drop:
            // `FileManager` hands back `/private/var` child URLs against a
            // `/var` root (macOS temp symlink), which would garble the drop.
            // `directory + "/" + name` matches the keys `build` stores.
            let relativePath =
                directory.isEmpty
                ? child.url.lastPathComponent
                : directory + "/" + child.url.lastPathComponent
            seen.insert(relativePath)
            guard
                let grammarID = WorkspaceSymbolExtractor.grammarWithTags(
                    forRelativePath: relativePath),
                let grammar = grammars[grammarID],
                let text = readableText(at: child.url)
            else {
                removeFile(relativePath)
                continue
            }
            let extracted = WorkspaceSymbolExtractor.extractSymbols(
                text: text, query: grammar.query, parser: grammar.parser, limit: perFileLimit)
            replaceFile(relativePath, with: extracted)
        }
        for path in previouslyIndexed where !seen.contains(path) { removeFile(path) }
    }

    private func indexedFiles(directlyIn directory: String) -> [String] {
        pathIndexByPath.keys.filter {
            (($0 as NSString).deletingLastPathComponent) == directory
        }
    }

    private func removeFile(_ relativePath: String) {
        guard let pathIndex = pathIndexByPath[relativePath] else { return }
        totalSymbolCount -= symbolsByPath[pathIndex]?.count ?? 0
        symbolsByPath[pathIndex] = nil
        pathIndexByPath[relativePath] = nil
        // `paths[pathIndex]` is left as a tombstone; it is never resolved
        // because its `symbolsByPath` entry is gone, and a full rebuild
        // compacts the array.
    }

    private func replaceFile(_ relativePath: String, with extracted: [ExtractedSymbol]) {
        let pathIndex = internedPathIndex(for: relativePath)
        totalSymbolCount -= symbolsByPath[pathIndex]?.count ?? 0
        guard !extracted.isEmpty else {
            symbolsByPath[pathIndex] = nil
            pathIndexByPath[relativePath] = nil
            return
        }
        symbolsByPath[pathIndex] = extracted.map {
            WorkspaceSymbol(name: $0.name, kind: $0.kind, pathIndex: pathIndex, range: $0.range)
        }
        totalSymbolCount += extracted.count
    }

    private func internedPathIndex(for relativePath: String) -> Int32 {
        if let existing = pathIndexByPath[relativePath] { return existing }
        let pathIndex = Int32(paths.count)
        paths.append(relativePath)
        pathIndexByPath[relativePath] = pathIndex
        return pathIndex
    }

    // MARK: - Query

    /// Exact-name lookup for the syntactic navigation provider: every stored
    /// declaration whose name equals `name` (case-sensitive), resolved to a
    /// workspace-relative path. Bounded scan, cancellable.
    func lookup(name: String) async throws -> [WorkspaceSymbolMatch] {
        var results: [WorkspaceSymbolMatch] = []
        var scanned = 0
        for (pathIndex, symbols) in symbolsByPath {
            for symbol in symbols {
                scanned += 1
                if scanned.isMultiple(of: 4_096) { try Task.checkCancellation() }
                guard symbol.name == name else { continue }
                results.append(resolve(symbol, pathIndex: pathIndex))
            }
        }
        return results
    }

    /// Ranks stored symbols against `term`, off-main and cancellable. An empty
    /// term returns the first `limit` symbols in a stable path order.
    ///
    /// Flattens all stored symbols into a transient `[WorkspaceSymbolMatch]`
    /// (bounded by the 500k cap, freed immediately) so the pure, testable
    /// `WorkspaceSymbolRanker` can own the scoring. A future optimization can
    /// score in place and resolve only the winners; the filename index's
    /// `rankFiles` establishes the equivalent full-scan-per-keystroke cost.
    func query(term: String, limit: Int) async throws -> [WorkspaceSymbolMatch] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return orderedPrefix(limit: limit) }
        return try await WorkspaceSymbolRanker.rank(
            query: needle, candidates: flattenedMatches(), limit: limit)
    }

    private func orderedPrefix(limit: Int) -> [WorkspaceSymbolMatch] {
        guard limit > 0 else { return [] }
        var results: [WorkspaceSymbolMatch] = []
        for pathIndex in symbolsByPath.keys.sorted() {
            for symbol in symbolsByPath[pathIndex] ?? [] {
                results.append(resolve(symbol, pathIndex: pathIndex))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    private func flattenedMatches() -> [WorkspaceSymbolMatch] {
        var matches: [WorkspaceSymbolMatch] = []
        matches.reserveCapacity(totalSymbolCount)
        for (pathIndex, symbols) in symbolsByPath {
            for symbol in symbols {
                matches.append(resolve(symbol, pathIndex: pathIndex))
            }
        }
        return matches
    }

    private func resolve(_ symbol: WorkspaceSymbol, pathIndex: Int32) -> WorkspaceSymbolMatch {
        WorkspaceSymbolMatch(
            name: symbol.name,
            kind: symbol.kind,
            relativePath: paths[Int(pathIndex)],
            range: symbol.range
        )
    }

    // MARK: - Grammar resolution

    /// Reference holder so a resolved grammar's non-`Sendable` `Parser` is
    /// reused, never copied, across the file loop.
    private final class ResolvedGrammar {
        let query: Query
        let parser: Parser

        init(query: Query, parser: Parser) {
            self.query = query
            self.parser = parser
        }
    }

    private func resolveGrammars() async -> [GrammarLanguageID: ResolvedGrammar] {
        var resolved: [GrammarLanguageID: ResolvedGrammar] = [:]
        for grammarID in WorkspaceSymbolExtractor.grammarsWithTags {
            guard let query = await GrammarRegistry.shared.tagsQuery(for: grammarID),
                let configuration = try? await GrammarRegistry.shared.configuration(for: grammarID)
            else { continue }
            let parser = Parser()
            guard (try? parser.setLanguage(configuration.language)) != nil else { continue }
            resolved[grammarID] = ResolvedGrammar(query: query, parser: parser)
        }
        return resolved
    }

    private func readableText(at fileURL: URL) -> String? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > fileByteCap { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            let text = String(data: data, encoding: .utf8),
            !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - Path collection (mirrors WorkspaceFileNameIndex)

    private func collectPaths(rootURL: URL) async throws -> [String] {
        try Task.checkCancellation()
        if let gitPaths = try await gitLSFilesPaths(rootURL: rootURL) {
            return gitPaths
        }
        return try await enumeratedPaths(rootURL: rootURL)
    }

    private func gitLSFilesPaths(rootURL: URL) async throws -> [String]? {
        let output = try await runner.run(
            arguments: [
                "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z",
            ],
            at: rootURL
        )
        guard output.terminationStatus == 0 else { return nil }
        return output.standardOutput.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }

    private func enumeratedPaths(rootURL: URL) async throws -> [String] {
        try Task.checkCancellation()
        let resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: resolvedRootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else { return [] }

        var paths: [String] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited.isMultiple(of: 2_000) { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if WorkspaceFileService.excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else {
                continue
            }
            guard paths.count < Self.maximumFiles else { break }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            paths.append(
                String(resolvedURL.path.dropFirst(resolvedRootURL.path.count)).trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")))
        }
        return paths
    }
}

/// Compact stored form of one declaration: the path is interned to an `Int32`
/// (`WorkspaceSymbolIndex.paths`) to keep the per-symbol footprint small at
/// the 500k cap. Resolved back to `WorkspaceSymbolMatch` at the query
/// boundary.
nonisolated struct WorkspaceSymbol: Sendable, Equatable {
    let name: String
    let kind: String
    let pathIndex: Int32
    /// UTF-16 range of the name inside its file.
    let range: NSRange
}

/// Fuzzy ranker for the palette's `#` workspace-symbol mode. NEW code,
/// deliberately separate from the pinned `CommandPaletteMatcher`: it scores
/// the symbol NAME only and breaks ties on shorter name, then name, then path.
/// Cancellable every 4,096 candidates, matching `rankFiles`.
nonisolated enum WorkspaceSymbolRanker {
    static func rank(
        query: String,
        candidates: [WorkspaceSymbolMatch],
        limit: Int
    ) async throws -> [WorkspaceSymbolMatch] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return Array(candidates.prefix(max(0, limit))) }

        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            guard let matchScore = score(needle: needle, name: candidate.name) else { continue }
            scored.append((matchScore, index))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsMatch = candidates[lhs.index]
            let rhsMatch = candidates[rhs.index]
            if lhsMatch.name.count != rhsMatch.name.count {
                return lhsMatch.name.count < rhsMatch.name.count
            }
            if lhsMatch.name != rhsMatch.name { return lhsMatch.name < rhsMatch.name }
            return lhsMatch.relativePath < rhsMatch.relativePath
        }
        return scored.prefix(max(0, limit)).map { candidates[$0.index] }
    }

    /// Scores `name` against an already-normalized `needle`, or `nil` when the
    /// needle is not a subsequence. Exact match, then a leading-anchored
    /// substring, then a gap-penalized subsequence — the same shape as the
    /// filename ranker, kept as separate code so the two never entangle.
    private static func score(needle: String, name: String) -> Int? {
        let candidate = normalized(name)
        if needle == candidate { return 10_000 }
        if let range = candidate.range(of: needle) {
            return 5_000 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        let needleCharacters = Array(needle)
        let candidateCharacters = Array(candidate)
        var needleIndex = 0
        var score = max(0, 200 - candidateCharacters.count)
        var previousMatchIndex: Int?

        for index in candidateCharacters.indices {
            guard needleIndex < needleCharacters.count,
                candidateCharacters[index] == needleCharacters[needleIndex]
            else { continue }

            if let previousMatchIndex {
                let gap = index - previousMatchIndex - 1
                score += gap == 0 ? 24 : max(1, 8 - gap)
            } else {
                score += index == 0 ? 32 : max(1, 12 - index)
            }
            if index == 0 || !candidateCharacters[index - 1].isLetter { score += 18 }
            previousMatchIndex = index
            needleIndex += 1
        }
        return needleIndex == needleCharacters.count ? score : nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { !$0.isWhitespace }
    }
}
