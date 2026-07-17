import Foundation

nonisolated enum GitHunkPatchBuilder {
    static func patch(for hunk: GitDiffHunk, in diff: GitFileDiff) throws -> String {
        guard !diff.isBinary else { throw GitHunkPatchBuilderError.binaryDiff }

        let boundaries = lineBoundaries(in: diff.rawPatch)
        let hunkBoundaries = boundaries.filter(\.isHunk)
        guard let firstHunk = hunkBoundaries.first else {
            throw GitHunkPatchBuilderError.missingHunks
        }
        guard hunkBoundaries.indices.contains(hunk.id) else {
            throw GitHunkPatchBuilderError.invalidHunk(hunk.id)
        }

        let selected = hunkBoundaries[hunk.id]
        let selectedHeader = line(at: selected.index, in: diff.rawPatch)
        guard selectedHeader == hunk.header else {
            throw GitHunkPatchBuilderError.hunkMismatch
        }

        let selectedEnd =
            boundaries.first { boundary in
                boundary.index > selected.index
                    && (boundary.isHunk || boundary.isFileHeader)
            }?.index ?? diff.rawPatch.endIndex

        return String(diff.rawPatch[..<firstHunk.index])
            + String(diff.rawPatch[selected.index..<selectedEnd])
    }

    private static func lineBoundaries(in patch: String) -> [PatchBoundary] {
        var boundaries: [PatchBoundary] = []
        var lineStart = patch.startIndex

        while lineStart < patch.endIndex {
            let suffix = patch[lineStart...]
            if suffix.hasPrefix("@@ ") {
                boundaries.append(PatchBoundary(index: lineStart, kind: .hunk))
            } else if suffix.hasPrefix("diff --git ") {
                boundaries.append(PatchBoundary(index: lineStart, kind: .fileHeader))
            }

            guard let newline = patch[lineStart...].firstIndex(of: "\n") else { break }
            lineStart = patch.index(after: newline)
        }

        return boundaries
    }

    private static func line(at start: String.Index, in patch: String) -> String {
        let end = patch[start...].firstIndex(of: "\n") ?? patch.endIndex
        return String(patch[start..<end])
    }
}

private nonisolated struct PatchBoundary {
    nonisolated enum Kind: Equatable {
        case fileHeader
        case hunk
    }

    let index: String.Index
    let kind: Kind

    var isFileHeader: Bool { kind == .fileHeader }
    var isHunk: Bool { kind == .hunk }
}

nonisolated enum GitHunkPatchBuilderError: LocalizedError, Equatable {
    case binaryDiff
    case hunkMismatch
    case invalidHunk(Int)
    case missingHunks

    var errorDescription: String? {
        switch self {
        case .binaryDiff:
            "Binary diffs do not support hunk staging."
        case .hunkMismatch:
            "The selected hunk no longer matches the captured diff. Refresh the diff and try again."
        case .invalidHunk:
            "The selected hunk is not present in the captured diff."
        case .missingHunks:
            "The captured diff does not contain a textual hunk."
        }
    }
}
