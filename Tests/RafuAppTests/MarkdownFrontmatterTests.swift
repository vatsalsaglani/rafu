import Foundation
import Testing

@testable import RafuApp

@Test("Metadata is detected only when the fence is on line one")
func metadataDetectionIsStrict() {
    let scanner = MarkdownFrontmatterScanner()
    let source = "---\nname: advisor\n---\n# Body"

    guard let scan = scanner.scan(source), case .parsed(let metadata) = scan.result else {
        Issue.record("Expected line-one metadata to scan")
        return
    }
    #expect(metadata.title == "advisor")
    #expect(scan.remainder == "# Body")

    expectNoScan(scanner, "\n---\nname: advisor\n---\n# Body")
    expectNoScan(scanner, "# Title\n\n---\n# Body")
    expectNoScan(scanner, "---\nname: advisor\n# no closing fence")
}

@Test("Metadata scanning accepts BOM, CRLF, and the alternate closing fence")
func metadataScannerToleratesLineEndingsAndAlternateCloser() {
    let body = "\r\n# Body\r\n"
    let source = "\u{FEFF}---\r\nName: 'Advisor'\r\n...\r\n" + body

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected BOM and CRLF metadata to scan")
        return
    }
    #expect(metadata.title == "Advisor")
    #expect(scan.remainder == body)
}

@Test("Scalars strip one quote pair, skip comments, and preserve key casing")
func metadataScalarsPreserveDisplayKeys() {
    let source = """
        ---
        Name: 'Advisor'
        Model: "claude-opus-5"
        # This line is not a field.
        permissionMode: plan
        ---
        Body.
        """

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected scalar metadata to parse")
        return
    }
    #expect(metadata.title == "Advisor")
    #expect(metadata.fields.map(\.key) == ["Model", "permissionMode"])
    #expect(metadata.fieldCount == 3)
    guard case .scalar(let model) = metadata.fields[0].value else {
        Issue.record("Expected a scalar model value")
        return
    }
    #expect(model == "claude-opus-5")
}

@Test("Block and flow lists trim and unquote their items")
func metadataListsParseAsTokens() {
    let source = """
        ---
        tools:
          - Read
          - 'Grep'
        tags: [one, "two", three]
        ---
        """

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected list metadata to parse")
        return
    }
    guard metadata.fields.count == 2 else {
        Issue.record("Expected two list fields")
        return
    }
    guard case .list(let tools) = metadata.fields[0].value,
        case .list(let tags) = metadata.fields[1].value
    else {
        Issue.record("Expected both list values")
        return
    }
    #expect(tools == ["Read", "Grep"])
    #expect(tags == ["one", "two", "three"])
}

@Test("Folded and literal block scalars use their declared joining rules")
func metadataBlockScalarsJoinCorrectly() {
    let source = """
        ---
        description: >
          first line
          second line
        notes: |-
          line one
          line two
        ---
        """

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected block scalars to parse")
        return
    }
    #expect(metadata.description == "first line second line")
    guard case .block(let notes) = metadata.fields[0].value else {
        Issue.record("Expected literal block value")
        return
    }
    #expect(notes == "line one\nline two")
}

@Test("Title and description keys lift out of the ledger")
func metadataLiftingRemovesHeaderKeys() {
    let source = """
        ---
        Name: Advisor
        SUMMARY: A short description.
        title: A later title is not shown as a row.
        color: purple
        ---
        """

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected lifted metadata to parse")
        return
    }
    #expect(metadata.title == "Advisor")
    #expect(metadata.description == "A short description.")
    #expect(metadata.fields.map(\.key) == ["color"])
    #expect(metadata.fieldCount == 4)
}

@Test("The advisor metadata fixture parses into the designed header and ledger")
func advisorMetadataFixtureParses() {
    let source = """
        ---
        name: advisor
        description: >
          Read-only senior engineering advisor. Use proactively before implementing non-
          trivial features, fixes, refactors, migrations, or architectural changes.
        tools: [Read, Grep, Glob, Bash]
        disallowedTools: [Write, Edit, NotebookEdit]
        model: claude-opus-5
        permissionMode: plan
        effort: medium
        maxTurns: 60
        color: purple
        ---
        You are the Advisor in an Advisor–Implementor workflow.
        """

    guard let scan = MarkdownFrontmatterScanner().scan(source),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected the advisor fixture to parse")
        return
    }
    #expect(metadata.title == "advisor")
    #expect(metadata.fieldCount == 9)
    #expect(
        metadata.fields.map(\.key) == [
            "tools", "disallowedTools", "model", "permissionMode", "effort", "maxTurns", "color",
        ])
}

@Test("Unsupported nested maps fall back to the exact raw block")
func metadataNestedMapUsesRawFallback() {
    let raw = "matrix:\n  include:\n    - os: macos-15\n    - os: macos-14"
    let source = "---\n" + raw + "\n---\nBody"

    guard let scan = MarkdownFrontmatterScanner().scan(source) else {
        Issue.record("Expected a fenced block to be consumed")
        return
    }
    guard case .unparsed(let fallback) = scan.result else {
        Issue.record("Expected nested maps to use raw fallback")
        return
    }
    #expect(fallback == raw)
}

@Test("Tabs used for indentation use the all-or-nothing raw fallback")
func metadataTabsUseRawFallback() {
    let raw = "tags:\n\t- release"
    let source = "---\n" + raw + "\n---\nBody"

    guard let scan = MarkdownFrontmatterScanner().scan(source) else {
        Issue.record("Expected a fenced block to be consumed")
        return
    }
    guard case .unparsed(let fallback) = scan.result else {
        Issue.record("Expected tab indentation to use raw fallback")
        return
    }
    #expect(fallback == raw)
}

@Test("An empty metadata block is consumed but produces no fields")
func emptyMetadataIsParsedWithoutFields() {
    guard let scan = MarkdownFrontmatterScanner().scan("---\n---\nBody"),
        case .parsed(let metadata) = scan.result
    else {
        Issue.record("Expected an empty block to parse")
        return
    }
    #expect(metadata.fieldCount == 0)
    #expect(metadata.raw.isEmpty)
    #expect(scan.remainder == "Body")
}

@Test("The body after the closing fence is returned byte-identically")
func metadataRemainderIsByteIdentical() {
    let body = "# Body\r\n\r\nA line with — Unicode.\r\n"
    let source = "---\r\nname: advisor\r\n---\r\n" + body

    guard let scan = MarkdownFrontmatterScanner().scan(source) else {
        Issue.record("Expected metadata to scan")
        return
    }
    #expect(scan.remainder == body)
}

@Test("Preview segments place metadata before Markdown and Mermaid")
func metadataSegmentIntegration() {
    let source = """
        ---
        name: advisor
        ---
        # Before

        ```mermaid
        flowchart LR
          A --> B
        ```

        After.
        """

    let segments = MarkdownPreviewSegmentParser().parse(source)
    #expect(segments.count == 4)
    guard case .frontmatter = segments[0].content else {
        Issue.record("Expected the metadata segment first")
        return
    }
    guard case .markdown(let leading) = segments[1].content else {
        Issue.record("Expected Markdown after metadata")
        return
    }
    #expect(leading.contains("# Before"))
    guard case .mermaid = segments[2].content else {
        Issue.record("Expected Mermaid after leading Markdown")
        return
    }
    guard case .markdown(let trailing) = segments[3].content else {
        Issue.record("Expected trailing Markdown")
        return
    }
    #expect(trailing.contains("After."))
}

@Test("Preview segmentation without metadata remains unchanged")
func previewSegmentationWithoutMetadataIsUnchanged() {
    let source = """
        Before.

        ```mermaid
        flowchart LR
          A --> B
        ```

        After.
        """

    let segments = MarkdownPreviewSegmentParser().parse(source)
    #expect(segments.count == 3)
    guard case .markdown(let leading) = segments[0].content,
        case .mermaid = segments[1].content,
        case .markdown(let trailing) = segments[2].content
    else {
        Issue.record("Expected the existing Markdown/Mermaid segment order")
        return
    }
    #expect(leading.contains("Before."))
    #expect(trailing.contains("After."))
}

private func expectNoScan(_ scanner: MarkdownFrontmatterScanner, _ source: String) {
    if case .some = scanner.scan(source) {
        Issue.record("Expected no leading metadata scan")
    }
}
