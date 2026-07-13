import Foundation
import Observation

enum MarkdownPresentationMode: String, CaseIterable, Codable, Sendable {
    case edit
    case preview
    case split

    var symbolName: String {
        switch self {
        case .edit: "pencil"
        case .preview: "eye"
        case .split: "rectangle.split.2x1"
        }
    }

    var title: String { rawValue.capitalized }
}

@Observable
@MainActor
final class EditorDocument: Identifiable {
    let id: UUID
    var url: URL
    var isDirty = false
    var revision = 0
    var markdownMode: MarkdownPresentationMode
    var errorMessage: String?

    /// Disk modification date recorded after the last in-app load or save.
    /// The workspace watcher only reloads a clean buffer when the file's
    /// current date differs, so Rafu's own writes never trigger a reload
    /// (which would wipe undo history).
    @ObservationIgnored
    var knownDiskModificationDate: Date?

    @ObservationIgnored
    var saveAction: (() -> Void)?

    /// Toggles the line comment on the current selection of the live editor.
    /// Set by the mounted `CodeEditorView`; `nil` when no text view backs
    /// this document.
    @ObservationIgnored
    var toggleCommentAction: (() -> Void)?

    /// Returns a value copy of the live editor text. Set by the mounted
    /// `CodeEditorView`; `nil` when no text view backs this document
    /// (bitmap previews, Markdown preview-only mode). Live text itself
    /// never enters SwiftUI observation.
    @ObservationIgnored
    var textSnapshotProvider: (() -> String)?

    init(url: URL) {
        id = UUID()
        self.url = url
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            // Markdown opens in the mode the user last picked; Edit by default.
            let stored = UserDefaults.standard.string(forKey: "markdownDefaultMode") ?? ""
            markdownMode = MarkdownPresentationMode(rawValue: stored) ?? .edit
        } else if ext == "svg" {
            // SVG opens rendered; the mode control switches to its source.
            markdownMode = .preview
        } else {
            markdownMode = .edit
        }
    }

    static let bitmapImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico",
    ]

    var displayName: String { url.lastPathComponent }
    var iconName: String { FileTypePresentation.symbol(for: url, isDirectory: false) }
    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
    var isSVG: Bool { url.pathExtension.lowercased() == "svg" }
    var isBitmapImage: Bool {
        Self.bitmapImageExtensions.contains(url.pathExtension.lowercased())
    }
    /// Documents that offer the Edit/Preview/Split mode control.
    var supportsPresentationModes: Bool { isMarkdown || isSVG }
}
