import Foundation
import Observation
import RafuCore

/// The app-wide Agent History index. It does nothing until a History
/// navigator asks for it (`loadIfNeeded`), then keeps the summaries in
/// memory. Rescans are incremental (the scanner reuses unchanged files) and
/// run on the scanner actor, never on the main actor.
///
/// Privacy: read-only. Nothing is uploaded, and no title, path, or message
/// text is logged.
@MainActor
@Observable
final class AgentHistoryStore {
    static let shared = AgentHistoryStore()

    nonisolated static let showsClaudeCodeKey = "agentHistory.showClaudeCode"
    nonisolated static let showsCodexKey = "agentHistory.showCodex"

    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    private(set) var index: AgentHistoryIndex = .empty
    private(set) var phase: Phase = .idle
    private(set) var lastScanDate: Date?
    let locations: AgentHistoryLocations

    @ObservationIgnored private let scanner = AgentHistoryScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    /// A rescan on first show of a navigator is skipped when the last one is
    /// newer than this.
    @ObservationIgnored private let freshness: TimeInterval = 30

    init(
        locations: AgentHistoryLocations = .resolve(),
        defaults: UserDefaults = .standard
    ) {
        self.locations = locations
        self.defaults = defaults
    }

    var showsClaudeCode: Bool { defaults.object(forKey: Self.showsClaudeCodeKey) as? Bool ?? true }
    var showsCodex: Bool { defaults.object(forKey: Self.showsCodexKey) as? Bool ?? true }
    var isScanning: Bool { phase == .scanning }

    /// The first show of a History navigator, or a re-show after a while.
    func loadIfNeeded() {
        if phase == .scanning { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < freshness { return }
        refresh()
    }

    /// An explicit rescan (the Refresh button or a Settings change).
    func refresh() {
        scanTask?.cancel()
        let options = AgentHistoryScanner.Options(
            locations: locations, includesClaudeCode: showsClaudeCode, includesCodex: showsCodex)
        phase = .scanning
        let scanner = scanner
        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.scan(options)
                guard let self, !Task.isCancelled else { return }
                self.index = result.index
                self.lastScanDate = Date()
                self.phase = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.phase = .failed("The agent history folders could not be read.")
            }
        }
    }
}
