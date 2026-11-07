import Foundation
import JSONRenderCharts
import JSONRenderClient
import JSONRenderCore
import JSONRenderStandardCatalog
import JSONRenderSwiftUI
import SwiftUI
import os

/// The Rafu catalog: the standard components, the chart components, and
/// Rafu's own components. Built once, on first use, on any actor.
nonisolated enum RafuCatalog {
    /// One registration step; build it with `component(RafuFileLink.self)`.
    typealias Entry = @Sendable (inout Catalog) throws(CatalogError) -> Void

    /// "<package version>+rafu.<n>". Bump `n` whenever a Rafu component's
    /// definition changes: saved view state applies only when it matches.
    static let version = "0.22.0-alpha.1+rafu.1"

    /// Board components (jr-4a): FileLink, CardLink, TerminalStatus,
    /// AgentStatus, DiffSummary, IconLibraryIcon, KeyValue, Timeline, Stat.
    static var boardEntries: [Entry] {
        [
            component(RafuFileLink.self),
            component(RafuCardLink.self),
            component(RafuTerminalStatus.self),
            component(RafuAgentStatus.self),
            component(RafuDiffSummary.self),
            component(RafuIconLibraryIcon.self),
            component(RafuKeyValue.self),
            component(RafuTimeline.self),
            component(RafuStat.self),
        ]
    }

    /// One registration step for a component view. Use it for each line of
    /// `boardEntries` and `documentEntries`: a bare closure literal infers an
    /// untyped `throws` and does not convert to `Entry`.
    /// The component type must be `nonisolated` (its conformance is used off
    /// the main actor); its `body` is still main-actor, like every `View`.
    static func component<C: View & JRComponentType & SendableMetatype>(_ type: C.Type) -> Entry {
        { (catalog: inout Catalog) throws(CatalogError) in try catalog.register(C.self) }
    }

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
        registerHostActions(&catalog)
        return catalog
    }

    /// The only Rafu actions a view may bind. Each one is a user press that
    /// the card's `RafuViewActionHost` carries out on the main actor: open a
    /// workspace file, focus a card, or open an http(s)/mailto link after the
    /// user confirms. None starts a process, types into a terminal, writes a
    /// file, or reaches the network by itself.
    static let hostActionNames = ["open_file", "focus_node", "open_url"]

    private static func registerHostActions(_ catalog: inout Catalog) {
        catalog.action(
            "open_file",
            params: .object([
                .init(name: "path", schema: .string, description: "Workspace-relative path."),
                .init(name: "line", schema: PropSchema.number.optional(), description: "Line."),
            ]),
            description: "Open a workspace file in Rafu."
        ) { params, host in
            guard let host = host as? RafuViewActionHost,
                case .string(let path)?? = params["path"]
            else { throw ActionFailure("open_file needs a path") }
            let line = params["line"]??.numberValue.map { Int($0) }
            guard await host.openFile(path, line: line) else {
                throw ActionFailure("The file could not be opened.")
            }
            return nil
        }
        catalog.action(
            "focus_node",
            params: .object([
                .init(name: "node", schema: .string, description: "A card id or exact title.")
            ]),
            description: "Focus a card on this Ensemble."
        ) { params, host in
            guard let host = host as? RafuViewActionHost,
                case .string(let node)?? = params["node"]
            else { throw ActionFailure("focus_node needs a node") }
            guard await host.focusNode(node) else {
                throw ActionFailure("No card matches.")
            }
            return nil
        }
        catalog.action(
            "open_url",
            params: .object([
                .init(name: "url", schema: .string, description: "An https, http or mailto link.")
            ]),
            description: "Open a link in the browser after the user confirms."
        ) { params, host in
            guard case .string(let text)?? = params["url"], let url = URL(string: text) else {
                throw ActionFailure("open_url needs a url")
            }
            guard await host.openURL(url) else { throw ActionFailure("The link was not opened.") }
            return nil
        }
    }
}

extension Catalog {
    /// Shorthand for `RafuCatalog.rafu`, so call sites can write `catalog: .rafu`.
    nonisolated static var rafu: Catalog { RafuCatalog.rafu }
}
