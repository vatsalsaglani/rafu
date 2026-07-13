import Testing

@testable import RafuApp

@Test("Markdown parser recognizes prose and Mermaid flowcharts")
func parsesMarkdownAndMermaid() {
    let blocks = MarkdownParser().parse(
        """
        # Rafu

        A **native** editor.

        ```mermaid
        flowchart LR
          Plan[Plan] -->|opens| Edit[Edit]
          Edit --> Commit[Commit]
        ```
        """
    )

    #expect(blocks.count == 3)
    guard case .mermaid(let diagram) = blocks.last?.content else {
        Issue.record("Expected a Mermaid block")
        return
    }
    #expect(diagram.kind == .flow)
    #expect(diagram.edges.count == 2)
    #expect(diagram.edges.first?.label == "opens")
    #expect(diagram.nodes["Plan"] == "Plan")
    #expect(diagram.nodes["Commit"] == "Commit")
}

@Test("Markdown blocks retain distinct stable identities for repeated content")
func repeatedBlocksHaveUniqueIdentity() {
    let blocks = MarkdownParser().parse("Same\n\nSame")

    #expect(blocks.count == 2)
    #expect(blocks[0].id != blocks[1].id)
}

@Test("Rich preview keeps GFM Markdown around native Mermaid blocks")
func richPreviewSegmentation() {
    let segments = MarkdownPreviewSegmentParser().parse(
        """
        | Name | Value |
        | --- | --- |
        | Rafu | live |

        ```mermaid
        flowchart LR
          A --> B
        ```

        After the diagram.
        """
    )

    #expect(segments.count == 3)
    guard case .markdown(let table) = segments[0].content else {
        Issue.record("Expected leading Markdown table")
        return
    }
    #expect(table.contains("| Name | Value |"))
    guard case .mermaid(let diagram) = segments[1].content else {
        Issue.record("Expected native Mermaid segment")
        return
    }
    #expect(diagram.edges.count == 1)
}

@Test("Markdown parser recognizes Mermaid sequence diagrams")
func parsesSequenceDiagram() {
    let blocks = MarkdownParser().parse(
        """
        ```mermaid
        sequenceDiagram
          participant User
          participant Rafu
          User->>Rafu: Save file
        ```
        """
    )
    guard case .mermaid(let diagram) = blocks.first?.content else {
        Issue.record("Expected a Mermaid block")
        return
    }
    #expect(diagram.kind == .sequence)
    #expect(diagram.participants == ["User", "Rafu"])
    #expect(diagram.messages.first?.label == "Save file")
}
