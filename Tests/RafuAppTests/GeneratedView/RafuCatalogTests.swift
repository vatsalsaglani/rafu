import Foundation
import JSONRenderCore
import JSONRenderSwiftUI
import Testing

@testable import RafuApp

@Suite("Rafu view catalog")
struct RafuCatalogTests {
    static let boardNames = [
        "FileLink", "CardLink", "TerminalStatus", "AgentStatus", "DiffSummary",
        "IconLibraryIcon", "KeyValue", "Timeline", "Stat",
    ]

    @Test("The catalog builds with unique names and the nine board components")
    func builds() throws {
        let catalog = try RafuCatalog.buildThrowing()
        let names = catalog.componentNames
        #expect(Set(names).count == names.count)
        for name in Self.boardNames {
            #expect(catalog.component(named: name) != nil, "missing \(name)")
            #expect(catalog.viewFactory(for: name) != nil, "no renderer for \(name)")
        }
        let standard = try Catalog.standard.merging(Catalog.charts)
        #expect(names.count >= standard.componentNames.count + Self.boardNames.count)
    }

    @Test("Only the three Rafu host actions are added")
    func hostActions() throws {
        let catalog = try RafuCatalog.buildThrowing()
        let standard = try Catalog.standard.merging(Catalog.charts)
        let added = Set(catalog.actionOrder).subtracting(standard.actionOrder)
        #expect(added == Set(RafuCatalog.hostActionNames))
    }

    /// The pin: a Rafu component definition change must bump
    /// `RafuCatalog.version`, because saved state applies only when the
    /// catalog version matches. Update both together.
    @Test("The board component definitions match the version pin")
    func versionPin() throws {
        let catalog = try RafuCatalog.buildThrowing()
        let lines = Self.boardNames.compactMap { name in
            catalog.component(named: name).map { "\($0.name): \($0.props.formatted())" }
        }
        #expect(RafuCatalog.version == "0.22.0-alpha.1+rafu.1")
        #expect(
            lines == [
                "FileLink: { path: string, line?: number, label?: string }",
                "CardLink: { node: string, label?: string }",
                "TerminalStatus: { node: string, title?: string }",
                "AgentStatus: { node: string, agent?: string }",
                "DiffSummary: { files: Array<unknown> }",
                "IconLibraryIcon: { pack: string, icon: string, size?: \"sm\" | \"md\" | \"lg\" }",
                "KeyValue: { items: Array<unknown> }",
                "Timeline: { events: Array<unknown> }",
                "Stat: { label: string, value: unknown, delta?: string, unit?: string, intent?: \"neutral\" | \"info\" | \"good\" | \"warning\" | \"critical\" }",
            ])
    }

    @Test("The generated prompt stays within 64 KiB")
    func promptSize() throws {
        let catalog = try RafuCatalog.buildThrowing()
        #expect(catalog.prompt().utf8.count <= 64 * 1_024)
    }

    @Test("Every Rafu component's example props validate")
    func examplesValidate() throws {
        let catalog = try RafuCatalog.buildThrowing()
        for name in Self.boardNames {
            let definition = try #require(catalog.component(named: name))
            let props = definition.example ?? (definition.props.exampleValue().objectValue ?? [:])
            let spec = Spec(
                root: "r", elements: ["r": UIElement(type: name, props: props)])
            let report = catalog.validate(spec)
            #expect(report.valid, "\(name): \(report.formatted())")
        }
    }
}
