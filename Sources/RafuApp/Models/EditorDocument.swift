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
    /// Whether this document's editor is currently mounted (`loaded`) or has
    /// been released to a reload-from-disk state (`hibernated`). Observed so
    /// `EditorGroupView` mounts the editor only for loaded documents; the
    /// live `NSTextStorage` survives exactly as long as the editor is
    /// mounted. A dirty document is never hibernated (see
    /// `DocumentHibernationPolicy`), so its unsaved edits are always retained
    /// by the mounted view.
    enum LoadState: Sendable {
        case loaded
        case hibernated
    }

    let id: UUID
    var url: URL
    var isDirty = false
    var revision = 0
    var markdownMode: MarkdownPresentationMode
    var errorMessage: String?

    /// Drives whether the editor is mounted for this document. Starts loaded;
    /// `WorkspaceSession.updateHibernationStates()` flips it as the working
    /// set changes.
    private(set) var loadState: LoadState = .loaded

    /// Large-file guard decision computed once at document load by
    /// `CodeEditorView.Coordinator.load()`. Observed so `EditorDocumentView`
    /// can show the guard banner and so `suppressesSyntax` stays reactive.
    private(set) var guardState: DocumentGuardDecision = .normal

    /// Set by the guard banner's "Enable Highlighting" action. Resets to
    /// `false` whenever a fresh guard decision is applied (e.g. reload).
    private(set) var isGuardOverridden = false

    /// `true` while this document should skip syntax highlighting and the
    /// `@`-symbol scan: guarded and not yet overridden for this session.
    var suppressesSyntax: Bool {
        if case .guarded = guardState, !isGuardOverridden { return true }
        return false
    }

    /// Disk modification date recorded after the last in-app load or save.
    /// The workspace watcher only reloads a clean buffer when the file's
    /// current date differs, so Rafu's own writes never trigger a reload
    /// (which would wipe undo history).
    @ObservationIgnored
    var knownDiskModificationDate: Date?

    /// Editor selection and scroll position captured when the editor is
    /// dismantled (hibernation) and reapplied by the next `load()` so a
    /// remounted document restores its cursor and scroll instead of resetting
    /// to the top. Retained across hibernation but never observed and never
    /// the document's full text — only this small view state.
    @ObservationIgnored
    var restoredSelection: NSRange?

    @ObservationIgnored
    var restoredScrollFraction: CGFloat?

    /// Transient hand-off for a DIRTY buffer's live text across an
    /// app-triggered STRUCTURAL SwiftUI remount — splitting a group or
    /// moving a tab to another group reshapes `EditorLayoutTreeView`'s
    /// erased view tree, which tears down and rebuilds every `NSView` in the
    /// affected subtree, not only the tab that moved. An ordinary `NSView`
    /// cannot survive that kind of teardown, so `CodeEditorView.dismantleNSView`
    /// captures the live text here just before releasing the view, and the
    /// next `load()` seeds from it instead of reading disk, then clears it
    /// immediately. This is the one sanctioned place a buffer snapshot lives
    /// briefly outside TextKit, and only ever for a document that is already
    /// dirty — never observed, never a substitute for the mounted
    /// `NSTextStorage` being the live text's normal home.
    @ObservationIgnored
    var pendingDirtyText: String?

    /// Monotonic access rank assigned by `WorkspaceSession` whenever this
    /// document becomes the selected tab. Drives the newest-N grace in
    /// `DocumentHibernationPolicy`; not observed.
    @ObservationIgnored
    var accessSequence: Int = 0

    @ObservationIgnored
    var saveAction: (() -> Void)?

    /// Toggles the line comment on the current selection of the live editor.
    /// Set by the mounted `CodeEditorView`; `nil` when no text view backs
    /// this document.
    @ObservationIgnored
    var toggleCommentAction: (() -> Void)?

    @ObservationIgnored
    var selectNextOccurrenceAction: (() -> Void)?

    @ObservationIgnored
    var selectAllOccurrencesAction: (() -> Void)?

    @ObservationIgnored
    var addCaretAboveAction: (() -> Void)?

    @ObservationIgnored
    var addCaretBelowAction: (() -> Void)?

    /// Returns a value copy of the live editor text. Set by the mounted
    /// `CodeEditorView`; `nil` when no text view backs this document
    /// (bitmap previews, Markdown preview-only mode). Live text itself
    /// never enters SwiftUI observation.
    @ObservationIgnored
    var textSnapshotProvider: (() -> String)?

    /// Returns the live editor's current selection (UTF-16 `NSRange`,
    /// matching `NavigationRequest.position`). Set by the mounted
    /// `CodeEditorView` alongside `textSnapshotProvider`; `nil` under the
    /// same conditions. `WorkspaceSession.navigate(kind:)` reads both to
    /// build a caret-driven navigation request — never a substitute for the
    /// mounted `NSTextView` owning selection state.
    @ObservationIgnored
    var selectionProvider: (() -> NSRange)?

    /// One `AsyncStream` continuation per active `editDeltas()` subscriber,
    /// keyed by a fresh id minted for each call. Multicast: every
    /// subscriber (there may be several — e.g. the future syntax actor and
    /// the future LSP client) receives every delta.
    @ObservationIgnored
    private var editDeltaContinuations: [UUID: AsyncStream<DocumentEditDelta>.Continuation] = [:]

    /// Monotonic per-edit counter, independent of `revision` (which only
    /// increments on save and external reload, never per keystroke).
    @ObservationIgnored
    private var editVersion = 0

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

    /// Marks the document's editor as mounted. Called by the session when the
    /// working set keeps this document loaded.
    func markLoaded() {
        loadState = .loaded
    }

    /// Marks the document's editor as released. A no-op when the document is
    /// dirty: the data-safety invariant forbids releasing an unsaved buffer,
    /// so the mounted view keeps owning its live text.
    func markHibernated() {
        guard !isDirty else { return }
        loadState = .hibernated
    }

    /// Stores the editor's selection and scroll fraction so the next `load()`
    /// can restore them after a hibernation remount.
    func captureViewState(selection: NSRange?, scrollFraction: CGFloat?) {
        restoredSelection = selection
        restoredScrollFraction = scrollFraction
    }

    /// Clamps a possibly-stale selection to a text of `textLength` UTF-16
    /// units so restoring it onto reloaded content can never crash. `nil`
    /// passes through unchanged. Pure and extractable for unit testing.
    static func clampSelection(_ range: NSRange?, textLength: Int) -> NSRange? {
        guard let range else { return nil }
        let safeLength = max(textLength, 0)
        let location = min(max(range.location, 0), safeLength)
        let length = min(max(range.length, 0), safeLength - location)
        return NSRange(location: location, length: length)
    }

    /// Called once per load by `CodeEditorView.Coordinator.load()` with the
    /// freshly computed `DocumentGuardPolicy` decision. Clears any prior
    /// session override so a reloaded document re-evaluates from scratch.
    func applyGuardDecision(_ decision: DocumentGuardDecision) {
        guardState = decision
        isGuardOverridden = false
    }

    /// Invoked by the guard banner's "Enable Highlighting" button. Lifts the
    /// guard for the rest of this session; re-guards only on the next load.
    func overrideGuard() {
        isGuardOverridden = true
    }

    /// Mints a fresh multicast stream of this document's edit deltas. Each
    /// call registers a new subscriber under its own id; the stream ends
    /// when the subscriber's consuming task is cancelled. Used by
    /// `LanguageIntelligenceCoordinator` to observe live edits without
    /// putting document text in SwiftUI-observable state.
    func editDeltas() -> AsyncStream<DocumentEditDelta> {
        let id = UUID()
        return AsyncStream { continuation in
            editDeltaContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.editDeltaContinuations[id] = nil
                }
            }
        }
    }

    /// Records one buffer mutation and multicasts it to every open
    /// `editDeltas()` subscriber. Called from `CodeEditorView.Coordinator`'s
    /// `NSTextStorageDelegate` hook; never called during the initial
    /// document load.
    func recordEditDelta(editedRange: NSRange, changeInLength: Int) {
        editVersion += 1
        let delta = DocumentEditDelta(
            range: NSRange(
                location: editedRange.location,
                length: editedRange.length - changeInLength
            ),
            replacementLength: editedRange.length,
            version: editVersion
        )
        for continuation in editDeltaContinuations.values {
            continuation.yield(delta)
        }
    }
}
