import JSONRenderCharts
import JSONRenderCore
import JSONRenderStandardCatalog
import JSONRenderSwiftUI
import os

/// The Rafu catalog: the standard components, the chart components, and
/// Rafu's own components. Built once, on first use, on any actor.
nonisolated enum RafuCatalog {
    /// One registration step, for example `{ try $0.register(RafuFileLink.self) }`.
    typealias Entry = @Sendable (inout Catalog) throws(CatalogError) -> Void

    /// "<package version>+rafu.<n>". Bump `n` whenever a Rafu component's
    /// definition changes: saved view state applies only when it matches.
    static let version = "0.22.0-alpha.1+rafu.1"

    /// Board components (jr-4a): FileLink, CardLink, TerminalStatus,
    /// AgentStatus, DiffSummary, IconLibraryIcon, KeyValue, Timeline, Stat.
    static var boardEntries: [Entry] { [] }

    /// Document components (jr-4d): Markdown, Mermaid, Code, Callout,
    /// Checklist, Questions, FileTree, Figure. Append-only; one line per
    /// component file.
    static var documentEntries: [Entry] { [] }

    static let rafu: Catalog = build()

    private static let logger = Logger(subsystem: "dev.vatsalsaglani.rafu", category: "RafuCatalog")

    /// A failure is a programming error that a test catches. It must never stop
    /// the app at launch: a release build falls back to the standard catalog.
    static func build() -> Catalog {
        do {
            return try buildThrowing()
        } catch {
            logger.error("The Rafu view catalog could not be built; using the standard catalog.")
            assertionFailure("RafuCatalog.build failed: \(error)")
            return (try? Catalog.standard) ?? Catalog()
        }
    }

    static func buildThrowing() throws(CatalogError) -> Catalog {
        var catalog = try Catalog.standard.merging(Catalog.charts)
        for entry in boardEntries + documentEntries { try entry(&catalog) }
        return catalog
    }
}

extension Catalog {
    /// Shorthand for `RafuCatalog.rafu`, so call sites can write `catalog: .rafu`.
    nonisolated static var rafu: Catalog { RafuCatalog.rafu }
}
