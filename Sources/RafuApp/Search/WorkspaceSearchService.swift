import Foundation

actor WorkspaceSearchService {
    func search(_ request: WorkspaceSearchRequest) async throws -> WorkspaceSearchResult {
        try await scan(request, replacementTemplate: nil).result
    }

    func previewReplacement(
        _ request: WorkspaceSearchRequest,
        replacement: String
    ) async throws -> WorkspaceReplacementPreview {
        let scan = try await scan(request, replacementTemplate: replacement)
        return WorkspaceReplacementPreview(
            files: scan.replacements,
            replacementCount: scan.replacements.reduce(0) { $0 + $1.edits.count },
            isTruncated: scan.result.isTruncated
        )
    }

    func apply(_ preview: WorkspaceReplacementPreview) async throws -> WorkspaceReplacementReport {
        var prepared: [PreparedWrite] = []
        prepared.reserveCapacity(preview.files.count)

        for file in preview.files {
            try Task.checkCancellation()
            let data = try Data(contentsOf: file.fileURL, options: [.mappedIfSafe])
            let currentVersion = try version(for: file.fileURL, data: data)
            guard currentVersion == file.expectedVersion else {
                throw WorkspaceSearchError.replacementConflict(relativePath: file.relativePath)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceSearchError.unreadableText(relativePath: file.relativePath)
            }

            let mutable = NSMutableString(string: text)
            for edit in file.edits.reversed() {
                guard NSMaxRange(edit.range) <= mutable.length,
                    mutable.substring(with: edit.range) == edit.original
                else {
                    throw WorkspaceSearchError.replacementConflict(relativePath: file.relativePath)
                }
                mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            prepared.append(
                PreparedWrite(
                    fileURL: file.fileURL,
                    relativePath: file.relativePath,
                    expectedVersion: file.expectedVersion,
                    data: Data((mutable as String).utf8),
                    replacementCount: file.edits.count
                ))
        }

        var changedFiles: [URL] = []
        var replacementCount = 0
        for write in prepared {
            try Task.checkCancellation()
            let currentData = try Data(contentsOf: write.fileURL, options: [.mappedIfSafe])
            guard try version(for: write.fileURL, data: currentData) == write.expectedVersion else {
                throw WorkspaceSearchError.replacementConflict(relativePath: write.relativePath)
            }
            try write.data.write(to: write.fileURL, options: .atomic)
            changedFiles.append(write.fileURL)
            replacementCount += write.replacementCount
        }
        return WorkspaceReplacementReport(
            changedFiles: changedFiles,
            replacementCount: replacementCount
        )
    }

    private func scan(
        _ request: WorkspaceSearchRequest,
        replacementTemplate: String?
    ) async throws -> ScanOutput {
        try Task.checkCancellation()
        let presentationRootURL = request.rootURL.standardizedFileURL
        let rootURL = presentationRootURL.resolvingSymlinksInPath()
        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw WorkspaceSearchError.invalidRoot }
        guard !request.query.isEmpty else {
            return ScanOutput(
                result: WorkspaceSearchResult(
                    groups: [],
                    totalMatchCount: 0,
                    isTruncated: false,
                    statistics: WorkspaceSearchStatistics()
                ),
                replacements: []
            )
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else { throw WorkspaceSearchError.invalidRoot }

        let pattern = TextSearchPattern(
            query: request.query,
            replacementTemplate: replacementTemplate ?? "",
            options: request.options
        )
        let includeGlobs = request.includeGlobs.compactMap(WorkspaceSearchGlob.init(pattern:))
        let excludeGlobs = request.excludeGlobs.compactMap(WorkspaceSearchGlob.init(pattern:))
        var groups: [WorkspaceSearchFileGroup] = []
        var replacements: [WorkspaceReplacementFilePreview] = []
        var statistics = WorkspaceSearchStatistics()
        var totalMatches = 0
        var isTruncated = false

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relativePath = relativePath(
                for: url.resolvingSymlinksInPath().standardizedFileURL,
                rootURL: rootURL
            )
            let presentationURL = presentationRootURL.appending(path: relativePath)

            if values?.isSymbolicLink == true {
                statistics.skippedSymlinks += 1
                enumerator.skipDescendants()
                continue
            }
            if isIgnored(
                url: url,
                relativePath: relativePath,
                request: request
            ) {
                statistics.skippedIgnoredItems += 1
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if excludeGlobs.contains(where: { $0.matches(relativePath: relativePath) }) {
                statistics.skippedIgnoredItems += 1
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { continue }
            // Includes never prune directories: a directory that misses an
            // include glob can still contain files that match it.
            if !includeGlobs.isEmpty,
                !includeGlobs.contains(where: { $0.matches(relativePath: relativePath) })
            {
                statistics.skippedIgnoredItems += 1
                continue
            }

            statistics.visitedFiles += 1
            if statistics.visitedFiles > max(0, request.limits.maximumFiles) {
                isTruncated = true
                break
            }
            if let size = values?.fileSize, size > request.limits.maximumFileBytes {
                statistics.skippedLargeFiles += 1
                continue
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                statistics.skippedUnreadableFiles += 1
                continue
            }
            guard !isBinary(data), let text = String(data: data, encoding: .utf8) else {
                statistics.skippedBinaryFiles += 1
                continue
            }
            statistics.searchedFiles += 1

            let perFileLimit = min(
                max(0, request.limits.maximumMatchesPerFile),
                max(0, max(0, request.limits.maximumTotalMatches) - totalMatches)
            )
            if perFileLimit == 0 {
                isTruncated = true
                break
            }
            let candidateMatches = try pattern.matches(in: text, limit: perFileLimit + 1)
            let fileIsTruncated = candidateMatches.count > perFileLimit
            let acceptedMatches = Array(candidateMatches.prefix(perFileLimit))
            guard !acceptedMatches.isEmpty else { continue }

            let version = try version(for: presentationURL, data: data)
            let searchMatches = acceptedMatches.map {
                searchMatch(
                    from: $0,
                    text: text,
                    maximumPreviewCharacters: max(0, request.limits.maximumPreviewCharacters)
                )
            }
            groups.append(
                WorkspaceSearchFileGroup(
                    fileURL: presentationURL,
                    relativePath: relativePath,
                    version: version,
                    matches: searchMatches,
                    isTruncated: fileIsTruncated
                ))

            if replacementTemplate != nil {
                let edits = acceptedMatches.map {
                    replacementEdit(
                        from: $0,
                        text: text,
                        maximumPreviewCharacters: max(0, request.limits.maximumPreviewCharacters)
                    )
                }
                replacements.append(
                    WorkspaceReplacementFilePreview(
                        fileURL: presentationURL,
                        relativePath: relativePath,
                        expectedVersion: version,
                        edits: edits
                    ))
            }

            totalMatches += acceptedMatches.count
            if fileIsTruncated || totalMatches >= max(0, request.limits.maximumTotalMatches) {
                isTruncated = true
                break
            }
        }

        groups.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        replacements.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return ScanOutput(
            result: WorkspaceSearchResult(
                groups: groups,
                totalMatchCount: totalMatches,
                isTruncated: isTruncated,
                statistics: statistics
            ),
            replacements: replacements
        )
    }

    private func isIgnored(
        url: URL,
        relativePath: String,
        request: WorkspaceSearchRequest
    ) -> Bool {
        if request.ignoredPathComponents.contains(url.lastPathComponent) { return true }
        return request.ignoredRelativePathPrefixes.contains { prefix in
            relativePath == prefix || relativePath.hasPrefix(prefix + "/")
        }
    }

    private func isBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    private func version(for url: URL, data: Data) throws -> WorkspaceFileVersion {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return WorkspaceFileVersion(
            byteCount: data.count,
            modificationDate: values.contentModificationDate,
            contentFingerprint: fingerprint(data)
        )
    }

    private func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func searchMatch(
        from match: TextSearchMatch,
        text: String,
        maximumPreviewCharacters: Int
    ) -> WorkspaceSearchMatch {
        let details = lineDetails(
            for: match.range,
            in: text,
            maximumPreviewCharacters: maximumPreviewCharacters
        )
        return WorkspaceSearchMatch(
            range: match.range,
            line: details.line,
            column: details.column,
            preview: details.preview
        )
    }

    private func replacementEdit(
        from match: TextSearchMatch,
        text: String,
        maximumPreviewCharacters: Int
    ) -> WorkspaceReplacementEdit {
        let source = text as NSString
        let details = lineDetails(
            for: match.range,
            in: text,
            maximumPreviewCharacters: maximumPreviewCharacters
        )
        let original = source.substring(with: match.range)
        let replacedLine = (details.fullPreview as NSString).replacingCharacters(
            in: details.rangeInFullPreview,
            with: match.replacement
        )
        return WorkspaceReplacementEdit(
            range: match.range,
            original: original,
            replacement: match.replacement,
            line: details.line,
            originalPreview: details.preview,
            replacementPreview: clipped(replacedLine, maximum: maximumPreviewCharacters)
        )
    }

    private func lineDetails(
        for range: NSRange,
        in text: String,
        maximumPreviewCharacters: Int
    ) -> LineDetails {
        let source = text as NSString
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let prefix = source.substring(to: range.location)
        let line = prefix.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        let column = range.location - lineRange.location + 1
        let fullLine = source.substring(with: lineRange).trimmingCharacters(
            in: .newlines
        )
        let rangeInLine = NSRange(
            location: range.location - lineRange.location,
            length: min(
                range.length,
                max(0, (fullLine as NSString).length - (range.location - lineRange.location)))
        )
        return LineDetails(
            line: line,
            column: column,
            preview: clipped(fullLine, maximum: maximumPreviewCharacters),
            fullPreview: fullLine,
            rangeInFullPreview: rangeInLine
        )
    }

    private func clipped(_ text: String, maximum: Int) -> String {
        guard text.count > maximum else { return text }
        return String(text.prefix(maximum)) + "…"
    }
}

private nonisolated struct ScanOutput: Sendable {
    let result: WorkspaceSearchResult
    let replacements: [WorkspaceReplacementFilePreview]
}

private nonisolated struct PreparedWrite: Sendable {
    let fileURL: URL
    let relativePath: String
    let expectedVersion: WorkspaceFileVersion
    let data: Data
    let replacementCount: Int
}

private nonisolated struct LineDetails: Sendable {
    let line: Int
    let column: Int
    let preview: String
    let fullPreview: String
    let rangeInFullPreview: NSRange
}
