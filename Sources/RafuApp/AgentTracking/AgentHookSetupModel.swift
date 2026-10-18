import Foundation
import Observation
import RafuCore

/// Settings ▸ Agents ▸ Activity tracking. Connect and Disconnect are always
/// two steps: `prepare` reads the provider file and builds a reviewed
/// change; only `apply`, after the person confirms the sheet, writes. All
/// file work runs off the main actor. Nothing here runs at launch.
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
    }

    /// Builds the reviewed change. Writes nothing.
    func prepare(_ provider: AgentHookProvider, removing: Bool) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        let destination = destination(for: provider)
        let paths = store.paths
        Task {
            defer { isBusy = false }
            let result = await AgentHookSetupIO.prepare(
                provider: provider, destination: destination, paths: paths, removing: removing)
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
                statuses[change.provider] = change.removing ? .notConnected : .connected
                store.setConnected(change.provider, !change.removing)
                message =
                    change.removing
                    ? "\(change.provider.displayName) no longer reports activity to Rafu."
                    : "Connected. Start a new \(change.provider.displayName) session to see activity."
            case .failure(let error):
                message = Self.explanation(error, provider: change.provider)
            }
        }
    }

    func cancelReview() {
        pendingChange = nil
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
    static func prepare(
        provider: AgentHookProvider, destination: URL, paths: AgentTrackingPaths,
        removing: Bool
    ) async -> Result<AgentHookChange, AgentHookConfigurationError> {
        do {
            return .success(
                try AgentHookInstaller.prepare(
                    provider: provider, destination: destination, paths: paths,
                    removing: removing))
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
