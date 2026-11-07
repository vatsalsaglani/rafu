import Foundation
import Observation

/// The main-actor face of the image settings: the mode, the trust list (as
/// parsed patterns, ready for synchronous matching) and the loaded Public
/// Suffix List. One shared instance serves Settings and every Ensemble's
/// provider. Construction does no file I/O; `ensureLoaded()` reads the list.
@MainActor
@Observable
final class RemoteImageTrustModel {
    static let shared = RemoteImageTrustModel()

    private(set) var mode: CanvasRemoteImageMode
    private(set) var entries: [ImageTrustEntry] = []
    private(set) var patterns: [HostPattern] = []
    private(set) var isLoaded = false
    private(set) var canUndo = false
    /// Set when entries were skipped or the file was unreadable.
    private(set) var loadNote: String?
    /// The Public Suffix List, once loaded.
    private(set) var suffixes: PublicSuffixList?
    /// Bumps on every change a provider must react to.
    private(set) var generation = 0
    /// The last write failure, shown in Settings.
    var writeProblem: String?

    @ObservationIgnored private let store: ImageTrustStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadSuffixes: @Sendable () async -> PublicSuffixList
    @ObservationIgnored private let revocation: RemoteImageRevocation
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        fileURL: URL = CanvasRemoteImagePreference.trustFileURL(),
        defaults: UserDefaults = .standard,
        loadSuffixes: @escaping @Sendable () async -> PublicSuffixList = {
            await PublicSuffixResource.loadBundled()
        },
        revocation: RemoteImageRevocation = .shared
    ) {
        self.store = ImageTrustStore(fileURL: fileURL)
        self.defaults = defaults
        self.loadSuffixes = loadSuffixes
        self.revocation = revocation
        self.mode = CanvasRemoteImagePreference.mode(defaults)
    }

    // MARK: Loading

    /// Starts the one load, if it has not started. Safe to call from a view.
    func startLoadingIfNeeded() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in await self?.load() }
    }

    /// Loads the Public Suffix List and the trust list once.
    func ensureLoaded() async {
        startLoadingIfNeeded()
        await loadTask?.value
    }

    private func load() async {
        let list = await loadSuffixes()
        let report = await store.load(suffixes: list)
        suffixes = list
        apply(report.entries)
        var notes: [String] = []
        if report.fileWasUnreadable {
            notes.append(
                "The saved list could not be read. Rafu kept it as image-trust.invalid.json and started an empty list."
            )
        }
        if report.skipped > 0 {
            notes.append("\(report.skipped) saved entries were not valid and were skipped.")
        }
        loadNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        isLoaded = true
        generation &+= 1
    }

    private func apply(_ list: [ImageTrustEntry]) {
        let removed = Set(entries.map(\.pattern)).subtracting(list.map(\.pattern))
        entries = list
        patterns = list.compactMap { entry in
            suffixes.flatMap { try? HostPattern.parse(entry.pattern, suffixes: $0) }
        }
        for pattern in removed { revocation.dropPattern(pattern) }
        generation &+= 1
    }

    private func refreshUndo() async {
        canUndo = await store.canUndo
    }

    // MARK: Mode

    func setMode(_ newMode: CanvasRemoteImageMode) {
        guard newMode != mode else { return }
        let old = mode
        mode = newMode
        CanvasRemoteImagePreference.setMode(newMode, in: defaults)
        if newMode == .off {
            revocation.dropAll()
        } else if old == .always {
            revocation.dropGlobal()
        }
        generation &+= 1
    }

    // MARK: Editing

    /// The wildcard the consent card offers for `host`.
    func parentOffer(for host: String) -> HostPattern? {
        suffixes.flatMap { HostPattern.parentOffer(for: host, suffixes: $0) }
    }

    @discardableResult
    func add(_ pattern: HostPattern, source: ImageTrustEntry.Source) async -> Bool {
        await ensureLoaded()
        do {
            apply(try await store.add(pattern, source: source))
            writeProblem = nil
            await refreshUndo()
            return true
        } catch {
            writeProblem =
                error == .full
                ? "The list is full. Remove a host to add another."
                : "Rafu could not save the list."
            return false
        }
    }

    func remove(_ pattern: String) async {
        await ensureLoaded()
        await mutate { try await $0.remove(pattern: pattern) }
    }

    func removeAll() async {
        await ensureLoaded()
        await mutate { try await $0.removeAll() }
    }

    func undo() async {
        await ensureLoaded()
        await mutate { try await $0.undoLast() }
    }

    private func mutate(
        _ operation: (ImageTrustStore) async throws -> [ImageTrustEntry]
    ) async {
        do {
            apply(try await operation(store))
            writeProblem = nil
        } catch {
            writeProblem = "Rafu could not save the list."
        }
        await refreshUndo()
    }
}
