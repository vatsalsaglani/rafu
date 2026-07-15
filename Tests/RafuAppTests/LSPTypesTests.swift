import Foundation
import Testing

@testable import RafuApp

@Test("BoolOrOptions decodes a bare bool and an options object")
func boolOrOptionsDecodesBothShapes() throws {
    let decoder = JSONDecoder()
    let flag = try decoder.decode(BoolOrOptions<EmptyOptions>.self, from: Data("true".utf8))
    #expect(flag.isEnabled)
    let off = try decoder.decode(BoolOrOptions<EmptyOptions>.self, from: Data("false".utf8))
    #expect(!off.isEnabled)
    let options = try decoder.decode(BoolOrOptions<EmptyOptions>.self, from: Data("{}".utf8))
    #expect(options.isEnabled)
}

@Test("ServerCapabilities decodes definitionProvider from true and {} and ignores unknown keys")
func serverCapabilitiesDecodesDefinitionProviderAndIgnoresUnknownKeys() throws {
    let boolBody = Data(
        #"{"definitionProvider":true,"somethingRafuDoesNotKnowAbout":{"nested":[1,2,3]}}"#.utf8)
    let boolCapabilities = try JSONDecoder().decode(ServerCapabilities.self, from: boolBody)
    #expect(boolCapabilities.definitionProvider?.isEnabled == true)

    let optionsBody = Data(#"{"definitionProvider":{}}"#.utf8)
    let optionsCapabilities = try JSONDecoder().decode(ServerCapabilities.self, from: optionsBody)
    #expect(optionsCapabilities.definitionProvider?.isEnabled == true)

    let absentBody = Data("{}".utf8)
    let absentCapabilities = try JSONDecoder().decode(ServerCapabilities.self, from: absentBody)
    #expect(absentCapabilities.definitionProvider == nil)
}

@Test("textDocumentSync decodes a bare kind and an options object")
func textDocumentSyncDecodesBareKindAndOptions() throws {
    let bareKind = try JSONDecoder().decode(
        ServerCapabilities.self, from: Data(#"{"textDocumentSync":2}"#.utf8))
    #expect(bareKind.textDocumentSync?.effectiveKind == .incremental)
    #expect(bareKind.textDocumentSync?.openClose == true)

    let options = try JSONDecoder().decode(
        ServerCapabilities.self,
        from: Data(#"{"textDocumentSync":{"openClose":false,"change":1}}"#.utf8))
    #expect(options.textDocumentSync?.effectiveKind == .full)
    #expect(options.textDocumentSync?.openClose == false)

    let optionsMissingFields = try JSONDecoder().decode(
        ServerCapabilities.self, from: Data(#"{"textDocumentSync":{}}"#.utf8))
    #expect(optionsMissingFields.textDocumentSync?.effectiveKind == TextDocumentSyncKind.none)
    #expect(optionsMissingFields.textDocumentSync?.openClose == true)
}

@Test("LocationsResult decodes a single Location, an array, links, and null")
func locationsResultDecodesEveryShape() throws {
    let decoder = JSONDecoder()

    let single = try decoder.decode(
        LocationsResult.self,
        from: Data(
            #"{"uri":"file:///a.swift","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}"#
                .utf8)
    )
    #expect(
        single.locations == [
            Location(
                uri: "file:///a.swift",
                range: LSPRange(
                    start: Position(line: 1, character: 2), end: Position(line: 1, character: 5)))
        ])

    let array = try decoder.decode(
        LocationsResult.self,
        from: Data(
            #"[{"uri":"file:///a.swift","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]"#
                .utf8)
    )
    #expect(array.locations.count == 1)
    #expect(array.locations[0].uri == "file:///a.swift")

    let links = try decoder.decode(
        LocationsResult.self,
        from: Data(
            #"[{"targetUri":"file:///b.swift","targetRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":4}},"targetSelectionRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}}}]"#
                .utf8)
    )
    #expect(
        links.locations == [
            Location(
                uri: "file:///b.swift",
                range: LSPRange(
                    start: Position(line: 2, character: 0), end: Position(line: 2, character: 4)))
        ])

    let none = try decoder.decode(LocationsResult.self, from: Data("null".utf8))
    #expect(none.locations == [])
}

@Test("HoverResult decodes a hover object and null")
func hoverResultDecodesObjectAndNull() throws {
    let decoder = JSONDecoder()
    let hover = try decoder.decode(
        HoverResult.self,
        from: Data(#"{"contents":{"kind":"markdown","value":"docs"}}"#.utf8))
    guard case .hover(let value) = hover else {
        Issue.record("Expected .hover")
        return
    }
    guard case .markup(let markup) = value.contents else {
        Issue.record("Expected .markup contents")
        return
    }
    #expect(markup.value == "docs")

    let none = try decoder.decode(HoverResult.self, from: Data("null".utf8))
    guard case .none = none else {
        Issue.record("Expected .none")
        return
    }
}

@Test("Hover.contents tolerates a bare MarkedString and an array of MarkedString")
func hoverContentsTakesEveryMarkedStringShape() throws {
    let decoder = JSONDecoder()
    let bareString = try decoder.decode(HoverContents.self, from: Data(#""plain text""#.utf8))
    #expect(bareString == .markedString(.plain("plain text")))

    let languageValue = try decoder.decode(
        HoverContents.self, from: Data(#"{"language":"swift","value":"let x = 1"}"#.utf8))
    #expect(
        languageValue == .markedString(.languageValue(language: "swift", value: "let x = 1")))

    let array = try decoder.decode(
        HoverContents.self, from: Data(#"["a",{"language":"swift","value":"b"}]"#.utf8))
    #expect(array == .markedStrings([.plain("a"), .languageValue(language: "swift", value: "b")]))
}

@Test("DocumentSymbolResult decodes hierarchical symbols, flat symbols, and null")
func documentSymbolResultDecodesEveryShape() throws {
    let decoder = JSONDecoder()

    let hierarchical = try decoder.decode(
        DocumentSymbolResult.self,
        from: Data(
            #"[{"name":"foo","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}}]"#
                .utf8)
    )
    guard case .documentSymbols(let symbols) = hierarchical else {
        Issue.record("Expected .documentSymbols")
        return
    }
    #expect(symbols.first?.name == "foo")

    let flat = try decoder.decode(
        DocumentSymbolResult.self,
        from: Data(
            #"[{"name":"foo","kind":12,"location":{"uri":"file:///a.swift","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}}}]"#
                .utf8)
    )
    guard case .symbolInformation(let symbols) = flat else {
        Issue.record("Expected .symbolInformation")
        return
    }
    #expect(symbols.first?.name == "foo")

    let none = try decoder.decode(DocumentSymbolResult.self, from: Data("null".utf8))
    guard case .none = none else {
        Issue.record("Expected .none")
        return
    }
}

@Test("PositionEncoding defaults to utf16 when absent or unrecognized")
func positionEncodingDefaultsToUTF16() {
    #expect(PositionEncoding(rawLSPValue: nil) == .utf16)
    #expect(PositionEncoding(rawLSPValue: "utf-8") == .utf8)
    #expect(PositionEncoding(rawLSPValue: "utf-16") == .utf16)
    #expect(PositionEncoding(rawLSPValue: "utf-32") == .utf16)
}

@Test("$/progress begin, report, and end decode via the kind discriminator")
func progressValueDecodesEveryKind() throws {
    let decoder = JSONDecoder()

    let begin = try decoder.decode(
        ProgressParams<WorkDoneProgressValue>.self,
        from: Data(#"{"token":1,"value":{"kind":"begin","title":"Indexing"}}"#.utf8))
    #expect(begin.token == .number(1))
    guard case .begin(let beginValue) = begin.value else {
        Issue.record("Expected .begin")
        return
    }
    #expect(beginValue.title == "Indexing")

    let report = try decoder.decode(
        ProgressParams<WorkDoneProgressValue>.self,
        from: Data(#"{"token":"t","value":{"kind":"report","percentage":50}}"#.utf8))
    #expect(report.token == .string("t"))
    guard case .report(let reportValue) = report.value else {
        Issue.record("Expected .report")
        return
    }
    #expect(reportValue.percentage == 50)

    let end = try decoder.decode(
        ProgressParams<WorkDoneProgressValue>.self,
        from: Data(#"{"token":1,"value":{"kind":"end"}}"#.utf8))
    guard case .end = end.value else {
        Issue.record("Expected .end")
        return
    }
}
