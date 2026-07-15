import Foundation

/// The LSP rung of the navigation ladder: resolves definition / declaration /
/// references / hover through a trusted, running language server, labeling its
/// answers `"via <serverName>"`. Declines (returns `nil`) on every failure —
/// no session for the language, session not ready, the server lacks the
/// capability, a request or the whole answer times out, or the target file
/// can't be read — so the ladder falls through to the syntactic and text
/// tiers. A server still performing initial analysis returns state `.indexing`
/// rather than a misleadingly-empty `.ready`.
///
/// This type is NOT registered in `NavigationLadder` here: that one-line wiring
/// (above the syntactic tier) is the post-merge integration step, since the
/// ladder lives behind the lane-1 navigation contract.
nonisolated struct LSPNavigationProvider: NavigationTierProvider {
    /// Looks up the running session for a `languageID`. Production is
    /// `LanguageIntelligenceCoordinator.session(forLanguageID:)`; tests inject
    /// a closure returning a session wired over an in-memory transport.
    typealias SessionSource = @Sendable (_ languageID: String) async -> LanguageServerSession?

    private let sessionSource: SessionSource
    private let rootURL: URL
    private let answerTimeout: Duration
    private let maximumTargetFileBytes: Int

    /// Provenance only. The protocol's synchronous `tier` has no request
    /// context, so it can't know which server would answer; the real,
    /// per-answer label (`.lsp(serverName:)` with the live server name) is
    /// built inside `answer(_:)`. `NavigationLadder.resolve` reads the
    /// *answer's* tier, never this constant.
    var tier: NavigationTier { .lsp(serverName: "language server") }

    init(
        rootURL: URL,
        answerTimeout: Duration = .seconds(3),
        maximumTargetFileBytes: Int = 2 * 1_024 * 1_024,
        sessionSource: @escaping SessionSource
    ) {
        self.rootURL = rootURL
        self.answerTimeout = answerTimeout
        self.maximumTargetFileBytes = maximumTargetFileBytes
        self.sessionSource = sessionSource
    }

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        try Task.checkCancellation()

        guard let session = await sessionSource(request.languageID) else { return nil }
        let state = await session.state
        guard state == .ready || state == .idle else { return nil }

        // `serverName` is an immutable `let` of a `Sendable` type on the
        // session actor, so this read is synchronous and race-free.
        let serverName = session.serverName

        if await session.isWarmingUp {
            return NavigationAnswer(
                tier: .lsp(serverName: serverName), candidates: [], state: .indexing)
        }

        let encoding = await session.negotiatedEncoding

        do {
            return try await withTimeout(answerTimeout) {
                try await self.resolve(
                    request, session: session, serverName: serverName, encoding: encoding)
            }
        } catch is CancellationError {
            // Preserve the ladder's cancellation semantics: a superseded
            // request must propagate cancellation, never be swallowed.
            throw CancellationError()
        } catch {
            // Any other failure — timeout, connection error surfaced as a
            // throw, an unexpected decode — is a decline, never surfaced to
            // the UI.
            return nil
        }
    }

    // MARK: - Kind routing

    private func resolve(
        _ request: NavigationRequest, session: LanguageServerSession, serverName: String,
        encoding: PositionEncoding
    ) async throws -> NavigationAnswer? {
        let uri = fileURI(forPath: request.documentURL.path)

        switch request.kind {
        case .hover:
            guard let hover = await session.hover(uri: uri, utf16Offset: request.position),
                let text = flattenedHover(hover.contents)
            else { return nil }
            let candidate = SymbolCandidate(
                relativePath: relativePath(forTargetPath: request.documentURL.path),
                range: NSRange(location: request.position, length: 0),
                name: request.symbolName ?? "",
                kindLabel: "hover",
                previewLine: text)
            return NavigationAnswer(
                tier: .lsp(serverName: serverName), candidates: [candidate], state: .ready)

        case .definition:
            let locations = await session.definition(uri: uri, utf16Offset: request.position)
            return try locationAnswer(
                locations, request: request, serverName: serverName, encoding: encoding)

        case .declaration:
            let locations = await session.declaration(uri: uri, utf16Offset: request.position)
            return try locationAnswer(
                locations, request: request, serverName: serverName, encoding: encoding)

        case .references:
            let locations = await session.references(
                uri: uri, utf16Offset: request.position, includeDeclaration: true)
            return try locationAnswer(
                locations, request: request, serverName: serverName, encoding: encoding)
        }
    }

    /// `nil` locations = the session declined (return `nil`, fall through). A
    /// non-`nil` (even empty) array is authoritative: map each `Location`,
    /// skipping any target that can't be read, and answer `.ready`.
    private func locationAnswer(
        _ locations: [Location]?, request: NavigationRequest, serverName: String,
        encoding: PositionEncoding
    ) throws -> NavigationAnswer? {
        guard let locations else { return nil }
        try Task.checkCancellation()

        var candidates: [SymbolCandidate] = []
        for location in locations {
            try Task.checkCancellation()
            if let candidate = candidate(from: location, encoding: encoding, request: request) {
                candidates.append(candidate)
            }
        }
        return NavigationAnswer(
            tier: .lsp(serverName: serverName), candidates: candidates, state: .ready)
    }

    // MARK: - Location → SymbolCandidate

    /// Reads the target file (bounded, `file://` only, UTF-8) and converts an
    /// LSP `Location` into a `SymbolCandidate`. Returns `nil` — skipping the
    /// candidate — for a non-file URI, a missing / non-regular / oversized /
    /// non-UTF-8 file. Never traps and never throws except for cooperative
    /// cancellation.
    private func candidate(
        from location: Location, encoding: PositionEncoding, request: NavigationRequest
    ) -> SymbolCandidate? {
        guard let path = filePath(forURI: location.uri) else { return nil }
        let fileURL = URL(fileURLWithPath: path)

        guard
            let resourceValues = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey,
            ]),
            resourceValues.isRegularFile == true,
            let size = resourceValues.fileSize, size <= maximumTargetFileBytes
        else { return nil }

        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        let mirror = DocumentTextMirror(text: text)
        return SymbolCandidate(
            relativePath: relativePath(forTargetPath: path),
            range: nsRange(from: location.range, in: mirror, encoding: encoding),
            name: request.symbolName ?? "",
            kindLabel: kindLabel(for: request.kind),
            previewLine: previewLine(from: mirror, line: location.range.start.line))
    }

    /// Converts an LSP `LSPRange` (line/character in the negotiated encoding)
    /// to an `NSRange` (UTF-16 offset) using a fresh mirror of the target
    /// file's on-disk text. Falls back to a zero-length range at the target
    /// line's start when the server's position lands past our on-disk text or
    /// inside a multi-unit scalar — so navigation still lands on the right
    /// line rather than dropping the candidate.
    private func nsRange(
        from range: LSPRange, in mirror: DocumentTextMirror, encoding: PositionEncoding
    ) -> NSRange {
        guard let start = mirror.utf16Offset(for: range.start, encoding: encoding) else {
            let lineCount = mirror.lineStartsUTF16.count
            let line = min(max(range.start.line, 0), lineCount - 1)
            return NSRange(location: mirror.lineStartsUTF16[line], length: 0)
        }
        guard let end = mirror.utf16Offset(for: range.end, encoding: encoding), end >= start else {
            return NSRange(location: start, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    /// The trimmed, length-bounded text of one line, for the peek preview.
    private func previewLine(from mirror: DocumentTextMirror, line: Int) -> String {
        guard line >= 0, line < mirror.lineStartIndices.count else { return "" }
        let start = mirror.lineStartIndices[line]
        let end =
            line + 1 < mirror.lineStartIndices.count
            ? mirror.lineStartIndices[line + 1] : mirror.text.endIndex
        var lineText = String(mirror.text[start..<end])
        while lineText.hasSuffix("\n") || lineText.hasSuffix("\r") { lineText.removeLast() }
        lineText = lineText.trimmingCharacters(in: .whitespaces)
        return String(lineText.prefix(Self.maximumPreviewCharacters))
    }

    /// The target path relative to the workspace root, or the absolute
    /// standardized path for an out-of-workspace target (a stdlib / SDK jump).
    private func relativePath(forTargetPath path: String) -> String {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let targetComponents = target.pathComponents
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count,
            Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return target.path
        }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    // MARK: - Hover flattening

    /// Flattens `Hover.contents` to a single trimmed, bounded preview line.
    /// `nil` when there's no usable text (an empty hover is a decline, not an
    /// empty answer).
    private func flattenedHover(_ contents: HoverContents) -> String? {
        let raw: String
        switch contents {
        case .markup(let markup):
            raw = markup.value
        case .markedString(let marked):
            raw = markedStringText(marked)
        case .markedStrings(let markedStrings):
            raw = markedStrings.map(markedStringText).joined(separator: "\n")
        }
        let firstLine =
            raw
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let text = firstLine?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return String(text.prefix(Self.maximumPreviewCharacters))
    }

    private func markedStringText(_ marked: MarkedString) -> String {
        switch marked {
        case .plain(let text): return text
        case .languageValue(_, let value): return value
        }
    }

    private func kindLabel(for kind: NavigationTargetKind) -> String {
        switch kind {
        case .definition: return "definition"
        case .declaration: return "declaration"
        case .references: return "reference"
        case .hover: return "hover"
        }
    }

    private static let maximumPreviewCharacters = 240

    // MARK: - Timeout race

    private struct TimeoutError: Error {}

    /// Races `operation` against `timeout`, taking whichever finishes first and
    /// cancelling the loser (its cancellation propagates into the session's
    /// own `$/cancelRequest`). Throws `TimeoutError` when the timer wins.
    private func withTimeout(
        _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> NavigationAnswer?
    ) async throws -> NavigationAnswer? {
        try await withThrowingTaskGroup(of: NavigationAnswer?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError() }
            return result
        }
    }
}
