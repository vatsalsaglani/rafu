import Foundation
import RafuCore

nonisolated enum WorkspaceLocationLoader {
    /// Use the editor's UTF-8 and file-size boundary; keep both I/O and the
    /// line/column scan off MainActor. A navigation request retains one range,
    /// never an extra full document snapshot after this function returns.
    @concurrent
    static func range(
        at url: URL, location: SourceLocation,
        fileService: WorkspaceFileService = WorkspaceFileService()
    ) async throws -> NSRange {
        let text = try await fileService.readText(at: url)
        try Task.checkCancellation()
        let offset = LineColumnIndex.utf16Offset(
            line: location.line, column: location.column, in: text)
        try Task.checkCancellation()
        return NSRange(location: offset, length: 0)
    }
}
