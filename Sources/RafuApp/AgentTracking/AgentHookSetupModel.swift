import Foundation
import Observation
import RafuCore
import os

/// Settings ▸ Agents ▸ Activity tracking. Connect and Disconnect are always
/// two steps: `prepare` reads the provider file and builds a reviewed
/// change; only `apply`, after the person confirms the sheet, writes. All
/// file work runs off the main actor.
///
/// The one thing that runs without a review is the helper refresh
/// (`refreshHelperAtLaunch`, and the end of `refresh()`). It replaces a
/// stale installed helper with the bundled one, only when a provider file
/// already refers to it. It never writes a provider file.
@MainActor
@Observable
final class AgentHookSetupModel {
    /// One provider's row state.
    enum Status: Equatable {
        case unknown
        case notConnected
        case connected
        /// Connected, and events arrived from a live session.
        case receiving
    }

    /// The providers offered, in row order.
    static let providers: [AgentHookProvider] = [.claude, .codex, .cursor]

    private(set) var statuses: [AgentHookProvider: Status] = [:]
    /// Claude Code's opt-in answer entry: `.unknown`, `.notConnected` or
    /// `.connected`.
    private(set) var answerStatus: Status = .unknown
    /// The change waiting for review; drives the sheet.
    var pendingChange: AgentHookChange?
    private(set) var isBusy = false
    private(set) var message: String?

    @ObservationIgnored private let store: AgentActivityStore
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let bundledHelper: URL?

    init(
        store: AgentActivityStore = .shared,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledHelper: URL? = AgentHookSetupModel.defaultBundledHelper
    ) {
        self.store = store
        self.home = home
        self.environment = environment
        self.bundledHelper = bundledHelper
    }

    /// `Contents/Helpers/rafu-agent-events` in the running app bundle.
    static var defaultBundledHelper: URL? {
        Bundle.main.bundleURL
            .appending(path: "Contents/Helpers", directoryHint: .isDirectory)
            .appending(path: AgentTrackingPaths.helperName)
    }

    func destination(for provider: AgentHookProvider) -> URL {
        AgentHookConfiguration.destination(
            provider: provider, home: home, environment: environment)
    }

    func status(for provider: AgentHookProvider) -> Status {
        let base = statuses[provider] ?? .unknown
        guard base == .connected else { return base }
        let live = store.sessions.contains { $0.provider == provider && $0.state != .ended }
        return live ? .receiving : .connected
    }

    /// The Settings switch "Answer Claude Code permission requests from Up
    /// next". Turning it on installs nothing: the answer entry needs its own
    /// reviewed Connect.
    var claudeAnswersEnabled: Bool {
        get { store.claudeAnswersEnabled }
        set { store.setClaudeAnswersEnabled(newValue) }
    }

    /// Whether the answer entry can be connected now: it needs Claude Code's
    /// activity hooks, which drain the spool.
    var canConnectAnswers: Bool {
        let claude = status(for: .claude)
        return claude == .connected || claude == .receiving
    }

    /// Reads each provider file off the main actor.
    func refresh() async {
        let paths = store.paths
        let targets = Self.providers.map { ($0, destination(for: $0)) }
        let results = await AgentHookSetupIO.connectionStates(targets, paths: paths)
        for (provider, connected) in results {
            statuses[provider] = connected ? .connected : .notConnected
            if store.connectedProviders.contains(provider) != connected {
                store.setConnected(provider, connected)
            }
        }
        let answers = await AgentHookSetupIO.answerConnectionState(
            destination(for: .claude), paths: paths)
        answerStatus = answers ? .connected : .notConnected
        if store.claudeAnswersConnected != answers { store.setClaudeAnswersConnected(answers) }
        // After an app update the installed helper is older than the bundled
        // one. Replace it here too, without the launch gate on
        // `connectedProviders`, which can be stale.
        let refresh = await AgentHookSetupIO.refreshHelper(
            targets, paths: paths, bundledHelper: bundledHelper)
        if case .failure = refresh { message = Self.helperRefreshFailure }
    }

    /// The fixed Settings sentence when the helper refresh fails. It names no
    /// path and no file content.
    static let helperRefreshFailure =
        "Rafu could not update its hook helper. Disconnect and connect again."

    private static let log = Logger(subsystem: "dev.vatsalsaglani.rafu", category: "agent-hooks")

    /// At launch: replaces a stale installed helper with the bundled one. Does
    /// nothing, and reads no file, when no provider was ever connected. Never
    /// installs or changes hooks. The work runs off the main actor.
    static func refreshHelperAtLaunch(
        store: AgentActivityStore = .shared,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledHelper: URL? = AgentHookSetupModel.defaultBundledHelper
    ) {
        guard !store.connectedProviders.isEmpty else { return }
        let paths = store.paths
        let targets = providers.map {
            (
                $0,
                AgentHookConfiguration.destination(
                    provider: $0, home: home, environment: environment)
            )
        }
        Task(priority: .utility) {
            let result = await AgentHookSetupIO.refreshHelper(
                targets, paths: paths, bundledHelper: bundledHelper)
            switch result {
            case .success(.updated): log.notice("Hook helper refreshed: updated")
            case .success: break
            case .failure(let error):
                // The error kind only: no path, no file content.
                log.error(
                    "Hook helper refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Builds the reviewed change for Claude Code's answer entry.
    func prepareAnswers(removing: Bool) {
        prepare(.claude, removing: removing, scope: .answers)
    }

    /// Builds the reviewed change. Writes nothing.
    func prepare(
        _ provider: AgentHookProvider, removing: Bool, scope: AgentHookScope = .activity
    ) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        let destination = destination(for: provider)
        let paths = store.paths
        Task {
            defer { isBusy = false }
            let result = await AgentHookSetupIO.prepare(
                provider: provider, destination: destination, paths: paths, removing: removing,
                scope: scope)
            switch result {
            case .success(let change): pendingChange = change
            case .failure(let error): message = Self.explanation(error, provider: provider)
            }
        }
    }

    /// Writes the reviewed change.
    func apply() {
        guard let change = pendingChange, !isBusy else { return }
        isBusy = true
        let paths = store.paths
        let helper = bundledHelper
        Task {
            defer { isBusy = false }
            let result = await AgentHookSetupIO.apply(change, paths: paths, bundledHelper: helper)
            pendingChange = nil
            switch result {
            case .success:
                record(change)
            case .failure(let error):
                message = Self.explanation(error, provider: change.provider)
            }
        }
    }

    func cancelReview() {
        pendingChange = nil
    }

    /// Updates the row states after a written change. Internal for tests.
    func record(_ change: AgentHookChange) {
        let name = change.provider.displayName
        switch change.scope {
        case .answers:
            answerStatus = change.removing ? .notConnected : .connected
            store.setClaudeAnswersConnected(!change.removing)
            message =
                change.removing
                ? "Rafu no longer answers \(name) permission requests."
                : "Connected. Start a new \(name) session to answer its requests from Up next."
        case .activity:
            statuses[change.provider] = change.removing ? .notConnected : .connected
            store.setConnected(change.provider, !change.removing)
            // The activity Disconnect also removes the answer entry.
            if change.removing, change.provider == .claude {
                answerStatus = .notConnected
                store.setClaudeAnswersConnected(false)
            }
            message =
                change.removing
                ? "\(name) no longer reports activity to Rafu."
                : "Connected. Start a new \(name) session to see activity."
        }
    }

    /// Words for a failure. Never includes file content.
    static func explanation(_ error: AgentHookConfigurationError, provider: AgentHookProvider)
        -> String
    {
        switch error {
        case .symlinkedConfiguration:
            "The \(provider.displayName) configuration is a symbolic link. Rafu does not edit linked files; nothing was changed."
        case .unparseableConfiguration:
            "The \(provider.displayName) configuration is not valid JSON. Fix it first; nothing was changed."
        case .unexpectedStructure:
            "The \(provider.displayName) hooks have a shape Rafu does not recognise; nothing was changed."
        case .configurationTooLarge:
            "The \(provider.displayName) configuration is larger than 1 MB; nothing was changed."
        case .changedSinceReview:
            "The file changed after the review. Review the change again; nothing was written."
        case .helperMissing:
            "This build has no hook helper. Build the app with ./script/build_and_run.sh; nothing was changed."
        case .fileSystemFailure:
            "Rafu could not read or write the \(provider.displayName) configuration. Check its permissions and try again."
        }
    }
}

/// The setup model's blocking work, always off the main actor.
nonisolated enum AgentHookSetupIO {
    @concurrent
    static func connectionStates(
        _ targets: [(AgentHookProvider, URL)], paths: AgentTrackingPaths
    ) async -> [(AgentHookProvider, Bool)] {
        targets.map { provider, destination in
            (
                provider,
                AgentHookInstaller.isConnected(
                    provider: provider, destination: destination, paths: paths)
            )
        }
    }

    @concurrent
    static func answerConnectionState(_ destination: URL, paths: AgentTrackingPaths) async
        -> Bool
    {
        AgentHookInstaller.isAnswerConnected(destination: destination, paths: paths)
    }

    @concurrent
    static func refreshHelper(
        _ targets: [(AgentHookProvider, URL)], paths: AgentTrackingPaths, bundledHelper: URL?
    ) async -> Result<AgentHookHelperRefresh, AgentHookConfigurationError> {
        do {
            return .success(
                try AgentHookInstaller.refreshHelper(
                    targets: targets.map { (provider: $0.0, destination: $0.1) },
                    paths: paths, bundledHelper: bundledHelper))
        } catch let error as AgentHookConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.fileSystemFailure)
        }
    }

    @concurrent
    static func prepare(
        provider: AgentHookProvider, destination: URL, paths: AgentTrackingPaths,
        removing: Bool, scope: AgentHookScope
    ) async -> Result<AgentHookChange, AgentHookConfigurationError> {
        do {
            return .success(
                try AgentHookInstaller.prepare(
                    provider: provider, destination: destination, paths: paths,
                    removing: removing, scope: scope))
        } catch let error as AgentHookConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.fileSystemFailure)
        }
    }

    @concurrent
    static func apply(
        _ change: AgentHookChange, paths: AgentTrackingPaths, bundledHelper: URL?
    ) async -> Result<Void, AgentHookConfigurationError> {
        do {
            try AgentHookInstaller.apply(change, paths: paths, bundledHelper: bundledHelper)
            return .success(())
        } catch let error as AgentHookConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.fileSystemFailure)
        }
    }
}
