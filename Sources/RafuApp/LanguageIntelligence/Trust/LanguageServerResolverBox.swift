import Foundation
import Synchronization

/// A `Sendable` box holding the current, swappable `LanguageServerResolving`
/// implementation. `LanguageServerManager` is constructed exactly once, in
/// `LanguageIntelligenceCoordinator.init()`, with a `DynamicLanguageServerResolver`
/// reading through this box — so rebuilding a per-workspace
/// `InstalledServerResolver` (fresh trust/user-entry/toolchain state on
/// every `workspaceDidOpen(root:)`) only ever mutates this box's contents,
/// never the manager itself, preserving its identity (and any live
/// servers/crash state) across a workspace switch.
nonisolated final class LanguageServerResolverBox: Sendable {
    private let lock = Mutex<(any LanguageServerResolving)?>(nil)

    init(_ initial: (any LanguageServerResolving)? = nil) {
        lock.withLock { $0 = initial }
    }

    func current() -> (any LanguageServerResolving)? {
        lock.withLock { $0 }
    }

    func set(_ resolver: (any LanguageServerResolving)?) {
        lock.withLock { $0 = resolver }
    }
}

/// The `LanguageServerResolving` conformer `LanguageServerManager` is
/// actually constructed with: every `resolve(languageID:)` call reads
/// through `box` at call time, so swapping `box`'s contents (a new
/// `InstalledServerResolver` per workspace, or `nil` on close) changes what
/// the manager resolves without the manager ever being rebuilt. An empty
/// box (nothing set yet, or `workspaceDidClose()` cleared it) declines
/// every languageID, exactly like `NoLanguageServersResolver`.
nonisolated struct DynamicLanguageServerResolver: LanguageServerResolving {
    let box: LanguageServerResolverBox

    func resolve(languageID: String) -> ResolvedLanguageServer? {
        box.current()?.resolve(languageID: languageID)
    }
}
