import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble search")
struct CanvasBoardSearchTests {
    private func card(_ title: String, _ content: CanvasCardContent) -> CanvasCard {
        CanvasCard(title: title, content: content)
    }

    private func terminal(_ title: String) -> CanvasCard {
        card(title, .terminal(groupID: TerminalGroupID()))
    }

    private func titles(_ items: [CanvasSearchItem]) -> [String] { items.map(\.title) }

    /// Injects a provider per terminal card title.
    private func index(
        _ cards: [CanvasCard], connections: [CanvasConnection] = [],
        providers: [String: String] = [:]
    ) -> CanvasBoardSearchIndex {
        CanvasBoardSearchIndex(cards: cards, connections: connections) { card in
            CanvasSearchTerminalInfo(providerName: providers[card.title])
        }
    }

    @Test("An exact title beats a substring, and a substring beats a subsequence")
    func ranking() {
        let cards = [
            card("a build log", .note(snapshot: "")),
            card("b-u-i-l-d", .note(snapshot: "")),
            card("build", .note(snapshot: "")),
        ]
        let found = index(cards).matches("build")
        #expect(titles(found) == ["build", "a build log", "b-u-i-l-d"])
    }

    @Test("A kind filter with no query lists only that kind, in board order")
    func categoryFilterKeepsBoardOrder() {
        let cards = [
            card("Zed", .note(snapshot: "")),
            terminal("Shell"),
            card("Alpha", .note(snapshot: "")),
            card("readme", .file(path: "README.md")),
        ]
        let found = index(cards).matches("", filter: .init(categories: [.note]))
        #expect(titles(found) == ["Zed", "Alpha"])
        #expect(index(cards).categories == [.terminal, .note, .file])
    }

    @Test("An agent name finds a terminal whose title lacks it")
    func providerNameMatches() {
        let cards = [terminal("Terminal"), terminal("Builder"), card("Notes", .note(snapshot: ""))]
        let found = index(cards, providers: ["Builder": "Claude Code"]).matches("claude")
        #expect(titles(found) == ["Builder"])
        #expect(found.first?.category == .agent)
        #expect(found.first?.subtitle == "Terminal · Claude Code")
    }

    @Test("A provider chip narrows to that provider; chips come only from live providers")
    func providerFilter() {
        let cards = [
            terminal("One"), terminal("Two"), terminal("Three"), terminal("Plain"),
        ]
        let built = index(
            cards, providers: ["One": "Claude Code", "Two": "Codex", "Three": "Claude Code"])
        #expect(built.providers == ["Claude Code", "Codex"])
        let claude = built.matches("", filter: .init(providers: ["Claude Code"]))
        #expect(titles(claude) == ["One", "Three"])
        let both = built.matches("", filter: .init(providers: ["Claude Code", "Codex"]))
        #expect(titles(both) == ["One", "Two", "Three"])
        // No agent on the board, no provider chip and no agent kind.
        let plain = index([terminal("Plain")])
        #expect(plain.providers.isEmpty)
        #expect(plain.categories == [.terminal])
    }

    @Test("Kinds and providers are one or-group; Linked is an and")
    func filterCombination() {
        let note = card("Plan", .note(snapshot: ""))
        let claude = terminal("One")
        let plain = terminal("Plain")
        let link = CanvasConnection(from: claude.id, to: note.id)
        let built = index([note, claude, plain], connections: [link], providers: ["One": "Codex"])
        let kindOrProvider = built.matches(
            "", filter: .init(categories: [.note], providers: ["Codex"]))
        #expect(titles(kindOrProvider) == ["Plan", "One"])
        let linked = built.matches("", filter: .init(categories: [.terminal], linkedOnly: true))
        #expect(linked.isEmpty)
        let linkedAgent = built.matches("", filter: .init(providers: ["Codex"], linkedOnly: true))
        #expect(titles(linkedAgent) == ["One"])
    }

    @Test("Linked cards are the link endpoints; a peer title and a link label both match")
    func linkSearch() {
        let api = card("API", .web(destination: try! CanvasWebDestination("http://localhost:3000")))
        let docs = card("Design doc", .note(snapshot: ""))
        let loose = card("Loose", .note(snapshot: ""))
        let link = CanvasConnection(from: api.id, to: docs.id, label: "reads schema")
        let built = index([api, docs, loose], connections: [link])
        let linked = built.matches("", filter: .init(linkedOnly: true))
        #expect(titles(linked) == ["API", "Design doc"])
        #expect(linked.allSatisfy { $0.linkCount == 1 })
        #expect(built.hasLinks)
        // "Design" is the peer of API; "schema" is the link's own label.
        #expect(titles(built.matches("design doc")).first == "Design doc")
        #expect(
            titles(built.matches("design", filter: .init(linkedOnly: true))) == [
                "Design doc", "API",
            ])
        #expect(titles(built.matches("schema")) == ["API", "Design doc"])
        #expect(!titles(built.matches("schema")).contains("Loose"))
        #expect(!index([loose]).hasLinks)
    }

    @Test("A note body never matches; its title does")
    func noteBodyIsNotIndexed() {
        let note = card("Release plan", .note(snapshot: "remember the zebra migration"))
        let built = index([note])
        #expect(built.matches("zebra").isEmpty)
        #expect(titles(built.matches("release")) == ["Release plan"])
    }

    @Test("A text card matches a bounded label prefix; the rest of a long label is not indexed")
    func labelPrefix() {
        let long = String(repeating: "a", count: CanvasBoardSearchIndex.labelPrefixLimit) + " tail"
        let text = card("Text", .text(CanvasText(text: long)))
        let shape = card(
            "Box", .shape(CanvasShape(kind: .rectangle, label: "Deploy\ngate")))
        let built = index([text, shape])
        #expect(built.items[0].detail.count == CanvasBoardSearchIndex.labelPrefixLimit)
        #expect(built.matches("tail").isEmpty)
        #expect(titles(built.matches("deploy gate")) == ["Box"])
        #expect(built.items[1].detail == "Deploy gate")
        #expect(built.items[0].category == .drawing)
    }

    @Test("The limit is respected and equal scores keep a stable order")
    func limitAndStableTies() {
        let cards = (0..<30).map { card("Item", .note(snapshot: "\($0)")) }
        let built = index(cards)
        #expect(built.matches("item", limit: 7).count == 7)
        #expect(built.matches("", limit: 5).count == 5)
        #expect(built.matches("item").count == 30)
        let first = built.matches("item").map(\.id)
        for _ in 0..<5 { #expect(built.matches("item").map(\.id) == first) }
        // Reversing the board does not change tied order: the id decides.
        let reversed = index(cards.reversed()).matches("item").map(\.id)
        #expect(reversed == first)
    }

    @Test("Files, frames and diagrams get a useful detail line")
    func detailLines() {
        let frame = CanvasFrame(title: "Group", memberIDs: [CanvasCardID(), CanvasCardID()])
        let built = index([
            card("readme", .file(path: "docs/README.md")),
            card("Layout", .frame(frame)),
            card("Flow", .mermaid(source: "graph TD\nA-->B")),
        ])
        #expect(built.items[0].subtitle == "File · docs/README.md")
        #expect(built.items[1].detail == "2 cards")
        #expect(built.items[2].detail == "graph TD")
        #expect(titles(built.matches("", filter: .init(categories: [.diagram]))) == ["Flow"])
    }

    @Test("A header name from the live pane is the title")
    func shownTitle() {
        let named = terminal("Terminal")
        let built = CanvasBoardSearchIndex(cards: [named], connections: []) { _ in
            CanvasSearchTerminalInfo(providerName: nil, shownTitle: "Server logs")
        }
        #expect(titles(built.matches("server")) == ["Server logs"])
        #expect(titles(built.matches("terminal")) == ["Server logs"])
    }
}
