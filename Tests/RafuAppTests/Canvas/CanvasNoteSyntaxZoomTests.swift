import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas note syntax, zoom, and links")
struct CanvasNoteSyntaxZoomTests {
    private func pieces(_ source: String, _ result: CanvasNoteSyntax.Result)
        -> [(CanvasNoteSyntax.Style, String)]
    {
        result.runs.map { ($0.style, NSString(string: source).substring(with: $0.range)) }
    }

    @Test("Headings are sized and their hashes muted")
    func headings() {
        let source = "## Title here"
        let found = pieces(source, CanvasNoteSyntax.runs(in: source, restrictedTo: nil))
        #expect(found.contains { $0.0 == .heading(2) && $0.1 == "## Title here" })
        #expect(found.contains { $0.0 == .marker && $0.1 == "##" })
    }

    @Test("Strong, emphasis, and code spans mute their markers")
    func inline() {
        let source = "a **b** *c* `d`"
        let found = pieces(source, CanvasNoteSyntax.runs(in: source, restrictedTo: nil))
        #expect(found.contains { $0.0 == .strong && $0.1 == "b" })
        #expect(found.contains { $0.0 == .emphasis && $0.1 == "c" })
        #expect(found.contains { $0.0 == .code && $0.1 == "d" })
        #expect(found.filter { $0.0 == .marker }.map(\.1) == ["**", "**", "*", "*", "`", "`"])
    }

    @Test("A star inside a code span does not close emphasis")
    func starInCode() {
        let source = "*a `*` b*"
        let found = pieces(source, CanvasNoteSyntax.runs(in: source, restrictedTo: nil))
        #expect(found.contains { $0.0 == .emphasis && $0.1 == "a `*` b" })
    }

    @Test("Lone markers and bullets stay plain")
    func plain() {
        let source = "* item\n2 * 3 * 4"
        let result = CanvasNoteSyntax.runs(in: source, restrictedTo: nil)
        #expect(result.runs.isEmpty)
    }

    @Test("Links are one run")
    func links() {
        let source = "see [docs](a/b.md) now"
        let found = pieces(source, CanvasNoteSyntax.runs(in: source, restrictedTo: nil))
        #expect(found.contains { $0.0 == .link && $0.1 == "[docs](a/b.md)" })
    }

    @Test("Inline markers inside a heading are muted but keep the heading size")
    func headingInline() {
        let source = "# a **b**"
        let found = pieces(source, CanvasNoteSyntax.runs(in: source, restrictedTo: nil))
        #expect(!found.contains { $0.0 == .strong })
        #expect(found.filter { $0.0 == .marker }.map(\.1) == ["#", "**", "**"])
    }

    @Test("Fenced code is styled as code, not as Markdown")
    func fences() {
        let source = "```\n# not heading **x**\n```\n# real"
        let result = CanvasNoteSyntax.runs(in: source, restrictedTo: nil)
        let found = pieces(source, result)
        #expect(found.contains { $0.0 == .fencedCode && $0.1 == "# not heading **x**" })
        #expect(!found.contains { $0.0 == .strong })
        #expect(found.contains { $0.0 == .heading(1) && $0.1 == "# real" })
    }

    @Test("Restricting to a range scans only the touched lines")
    func restricted() {
        let source = "# one\n**two**\n# three"
        let result = CanvasNoteSyntax.runs(
            in: source, restrictedTo: NSRange(location: 8, length: 0))
        #expect(result.covered == NSRange(location: 6, length: 8))
        #expect(pieces(source, result).contains { $0.0 == .strong && $0.1 == "two" })
        #expect(!result.runs.contains { if case .heading = $0.style { true } else { false } })
    }

    @Test("Fence signature changes when a fence is added")
    func signature() {
        #expect(CanvasNoteSyntax.fenceSignature(of: "a\nb") == [])
        #expect(CanvasNoteSyntax.fenceSignature(of: "a\n```\nb\n```") == [1, 3])
        #expect(CanvasNoteSyntax.fenceSignature(of: "a\n```\nb") == [1])
    }

    @Test("Zoom faces switch at 75, 50, and 25 percent")
    func faces() {
        #expect(CanvasNoteZoom.face(forScale: 1) == .full)
        #expect(CanvasNoteZoom.face(forScale: 0.75) == .full)
        #expect(CanvasNoteZoom.face(forScale: 0.74) == .collapsedCode)
        #expect(CanvasNoteZoom.face(forScale: 0.5) == .collapsedCode)
        #expect(CanvasNoteZoom.face(forScale: 0.49) == .summary)
        #expect(CanvasNoteZoom.face(forScale: 0.25) == .summary)
        #expect(CanvasNoteZoom.face(forScale: 0.24) == .titleOnly)
        #expect(CanvasNoteZoom.canEdit(atScale: 0.5))
        #expect(!CanvasNoteZoom.canEdit(atScale: 0.49))
    }

    @Test("Summary titles stay at least 11 screen points")
    func titleSize() {
        #expect(CanvasNoteZoom.fontSize(screenPoints: 11, scale: 0.25, floor: 14) == 44)
        #expect(CanvasNoteZoom.fontSize(screenPoints: 11, scale: 1, floor: 14) == 14)
    }

    @Test("Zooming to a card centres it at a usable scale")
    func viewportForCard() {
        let rect = CanvasRect(x: 100, y: 200, width: 400, height: 300)
        let viewport = CanvasNoteZoom.viewport(
            centering: rect, in: CGSize(width: 1_000, height: 800))
        #expect(viewport.scale == 1)
        #expect(viewport.x == 1_000 / 2 - 300)
        #expect(viewport.y == 800 / 2 - 350)
        let huge = CanvasRect(x: 0, y: 0, width: 2_000, height: 2_000)
        let clamped = CanvasNoteZoom.viewport(centering: huge, in: CGSize(width: 800, height: 600))
        #expect(clamped.scale == 0.5)
    }

    @Test("Links go to the workspace, the system, or nowhere")
    func linkTargets() {
        let root = URL(fileURLWithPath: "/work/space", isDirectory: true)
        let base = CanvasNoteLink.baseURL(for: root)
        #expect(base?.absoluteString.hasSuffix("/") == true)
        let relative = URL(string: "docs/a%20b.md#top", relativeTo: base)!
        #expect(CanvasNoteLink.classify(relative, root: root) == .workspaceFile("docs/a b.md"))
        let parent = URL(string: "../secret.txt", relativeTo: base)!
        #expect(CanvasNoteLink.classify(parent, root: root) == .ignored)
        let outside = URL(string: "file:///etc/passwd")!
        #expect(CanvasNoteLink.classify(outside, root: root) == .ignored)
        let web = URL(string: "https://example.com/x")!
        #expect(CanvasNoteLink.classify(web, root: root) == .external(web))
        #expect(
            CanvasNoteLink.classify(URL(string: "javascript:alert(1)")!, root: root) == .ignored)
        #expect(CanvasNoteLink.classify(URL(string: "file:///work/space")!, root: root) == .ignored)
    }
}
