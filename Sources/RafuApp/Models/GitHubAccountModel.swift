import AppKit
import Foundation
import Observation

/// Process-wide GitHub account state backing `GitHubAccountStatusView`'s
/// status-bar chip. One shared instance (mirrors `MemoryPressureMonitor.shared`)
/// because signing in to `gh` is a per-machine, not per-window, fact — every
/// open workspace window reads the same account.
///
/// Never runs `gh auth login` or any other interactive flow. `refresh()` is
/// the only network/process-touching entry point and is always explicit
/// (window launch, the status-bar Refresh menu item, or after a successful
/// publish) — never a background poll.
@MainActor
@Observable
final class GitHubAccountModel {
    static let shared = GitHubAccountModel()

    nonisolated enum AccountState: Equatable, Sendable {
        case unknown
        case cliMissing
        case signedOut
        case signedIn(GitHubAccount)
    }

    private(set) var state: AccountState = .unknown
    /// Best-effort, in-memory-only avatar (never written to disk). `nil`
    /// until a signed-in refresh's avatar fetch completes; the chip always
    /// renders a text/glyph fallback while this is `nil`.
    private(set) var avatarImage: NSImage?

    @ObservationIgnored
    private let makeService: @Sendable () -> GitHubCLIService
    @ObservationIgnored
    private let urlSession: URLSession
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var avatarLoadTask: Task<Void, Never>?

    init(
        makeService: @escaping @Sendable () -> GitHubCLIService = { GitHubCLIService() },
        urlSession: URLSession = .shared
    ) {
        self.makeService = makeService
        self.urlSession = urlSession
    }

    /// Refreshes `state` (and, when signed in, `avatarImage`). Concurrent
    /// calls dedupe onto the same in-flight refresh rather than spawning a
    /// second `gh` process — every caller `await`s the same result.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        // Fresh detection on every refresh (rather than caching a resolved
        // executable URL at launch) so installing `gh` mid-session and
        // pressing Refresh works without relaunching Rafu.
        guard GitHubCLILocator.locate() != nil else {
            state = .cliMissing
            avatarLoadTask?.cancel()
            avatarImage = nil
            return
        }
        do {
            let account = try await makeService().account()
            state = .signedIn(account)
            loadAvatar(for: account)
        } catch is CancellationError {
            return
        } catch GitHubCLIError.notAuthenticated {
            state = .signedOut
            avatarLoadTask?.cancel()
            avatarImage = nil
        } catch {
            // Any other failure (couldNotLaunch, malformedResponse, a
            // transient commandFailed) is not a durable "signed out" fact,
            // but the chip has only signed-in/signed-out/missing states to
            // show — fail safe toward "sign in" rather than claiming a
            // stale signed-in account.
            state = .signedOut
            avatarLoadTask?.cancel()
            avatarImage = nil
        }
    }

    /// Fire-and-forget avatar fetch: off-main via `URLSession`, silent
    /// failure, memory-only. Never blocks `refresh()` — the text-first
    /// login chip is already correct the moment `state` updates.
    private func loadAvatar(for account: GitHubAccount) {
        avatarLoadTask?.cancel()
        avatarImage = nil
        guard let avatarURL = account.avatarURL else { return }
        avatarLoadTask = Task { [weak self, urlSession] in
            guard let (data, _) = try? await urlSession.data(from: avatarURL) else { return }
            guard !Task.isCancelled, let image = NSImage(data: data) else { return }
            self?.avatarImage = image
        }
    }
}
