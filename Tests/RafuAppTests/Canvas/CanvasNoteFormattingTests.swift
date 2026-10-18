import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas note formatting")
struct CanvasNoteFormattingTests {
    /// Applies a command and returns the new text and selection.
    private func run(
        _ command: CanvasNoteFormatCommand, _ text: String, _ selection: NSRange
    ) -> (text: String, selection: NSRange)? {
        guard let result = CanvasNoteFormatting.apply(command, to: text, selection: selection)
        else { return nil }
        let out = NSString(string: text).replacingCharacters(
            in: result.range, with: result.replacement)
        return (out, result.selection)
    }

    private func range(_ location: Int, _ length: Int = 0) -> NSRange {
        NSRange(location: location, length: length)
    }

    private func selected(_ value: (text: String, selection: NSRange)?) -> String? {
        value.map { NSString(string: $0.text).substring(with: $0.selection) }
    }

    @Test("Bold wraps, unwraps, and unwraps from outside the selection")
    func bold() {
        let wrapped = run(.bold, "say hello now", range(4, 5))
        #expect(wrapped?.text == "say **hello** now")
        #expect(selected(wrapped) == "hello")
        let inner = run(.bold, "say **hello** now", range(6, 5))
        #expect(inner?.text == "say hello now")
        #expect(selected(inner) == "hello")
        let whole = run(.bold, "say **hello** now", range(4, 9))
        #expect(whole?.text == "say hello now")
        #expect(selected(whole) == "hello")
    }

    @Test("An empty selection inserts a pair, and a second press removes it")
    func emptySelection() {
        let pair = run(.bold, "ab", range(1))
        #expect(pair?.text == "a****b")
        #expect(pair?.selection == range(3))
        let removed = run(.bold, "a****b", range(3))
        #expect(removed?.text == "ab")
        #expect(removed?.selection == range(1))
    }

    @Test("Italic and code use their own markers")
    func italicAndCode() {
        #expect(run(.italic, "word", range(0, 4))?.text == "*word*")
        #expect(run(.code, "word", range(0, 4))?.text == "`word`")
        #expect(run(.code, "`word`", range(1, 4))?.text == "word")
    }

    @Test("Italic does not mistake bold markers for its own")
    func italicOnBold() {
        let result = run(.italic, "**word**", range(2, 4))
        #expect(result?.text == "***word***")
        let back = run(.italic, "***word***", range(3, 4))
        #expect(back?.text == "**word**")
    }

    @Test("Link wraps the selection, selecting the url placeholder")
    func link() {
        let plain = run(.link, "see docs", range(4, 4))
        #expect(plain?.text == "see [docs](url)")
        #expect(selected(plain) == "url")
        let url = run(.link, "https://example.com", range(0, 19))
        #expect(url?.text == "[link](https://example.com)")
        #expect(selected(url) == "link")
        let empty = run(.link, "", range(0))
        #expect(empty?.text == "[](url)")
        #expect(empty?.selection == range(1))
    }

    @Test("Bullets toggle on a selection of lines and skip blank lines")
    func bullets() {
        let text = "one\n\ntwo"
        let on = run(.bullets, text, range(0, text.utf16.count))
        #expect(on?.text == "- one\n\n- two")
        let off = run(.bullets, on?.text ?? "", range(0, on?.text.utf16.count ?? 0))
        #expect(off?.text == text)
    }

    @Test("Numbers renumber from one")
    func numbers() {
        let result = run(.numbers, "a\nb\nc", range(0, 5))
        #expect(result?.text == "1. a\n2. b\n3. c")
        #expect(run(.numbers, "1. a\n2. b", range(0, 9))?.text == "a\nb")
    }

    @Test("Task toggles and keeps an existing checked state")
    func task() {
        #expect(run(.task, "item", range(2))?.text == "- [ ] item")
        #expect(run(.task, "- item", range(0))?.text == "- [ ] item")
        #expect(run(.task, "- [x] item", range(0))?.text == "item")
        #expect(run(.task, "- [x] a\nb", range(0, 9))?.text == "- [x] a\n- [ ] b")
    }

    @Test("Caret follows a single-line prefix change")
    func caretShift() {
        let result = run(.bullets, "item", range(2))
        #expect(result?.text == "- item")
        #expect(result?.selection == range(4))
        let removed = run(.bullets, "- item", range(4))
        #expect(removed?.selection == range(2))
    }

    @Test("Headings replace list markers and toggle off")
    func headings() {
        #expect(run(.heading1, "text", range(0))?.text == "# text")
        #expect(run(.heading2, "# text", range(0))?.text == "## text")
        #expect(run(.heading3, "### text", range(0))?.text == "text")
        #expect(run(.heading1, "- item", range(0))?.text == "# item")
        #expect(run(.body, "## text", range(0))?.text == "text")
        #expect(run(.body, "plain", range(0))?.text == "plain")
    }

    @Test("Hashtags are not headings")
    func hashtag() {
        #expect(run(.heading1, "#tag", range(0))?.text == "# #tag")
    }

    @Test("Line commands work on the final empty line and keep CRLF")
    func lineEdges() {
        #expect(run(.bullets, "a\n", range(2))?.text == "a\n- ")
        #expect(run(.bullets, "", range(0))?.text == "- ")
        #expect(run(.bullets, "a\r\nb", range(0, 4))?.text == "- a\r\n- b")
    }

    @Test("A selection that ends at a line start does not include that line")
    func selectionEndsAtLineStart() {
        let result = run(.bullets, "a\nb", range(0, 2))
        #expect(result?.text == "- a\nb")
    }

    @Test("Out-of-range selections are rejected")
    func invalidSelection() {
        #expect(CanvasNoteFormatting.apply(.bold, to: "ab", selection: range(1, 5)) == nil)
    }

    @Test("Shortcuts match the review table")
    func shortcuts() {
        func map(_ code: UInt16, shift: Bool = false, option: Bool = false)
            -> CanvasNoteFormatCommand?
        {
            CanvasNoteShortcuts.command(
                keyCode: code, command: true, shift: shift, option: option, control: false)
        }
        #expect(map(11) == .bold)
        #expect(map(34) == .italic)
        #expect(map(40) == .link)
        #expect(map(14) == .code)
        #expect(map(26, shift: true) == .bullets)
        #expect(map(25, shift: true) == .numbers)
        #expect(map(37, shift: true) == .task)
        #expect(map(18, option: true) == .heading1)
        #expect(map(19, option: true) == .heading2)
        #expect(map(20, option: true) == .heading3)
        #expect(map(29, option: true) == .body)
        #expect(map(11, shift: true) == nil)
        #expect(
            CanvasNoteShortcuts.command(
                keyCode: 11, command: false, shift: false, option: false, control: false) == nil)
    }

    @Test("Escape and Command-Return leave Edit mode")
    func exits() {
        #expect(
            CanvasNoteShortcuts.exitsEditing(
                keyCode: 53, command: false, shift: false, option: false, control: false))
        #expect(
            CanvasNoteShortcuts.exitsEditing(
                keyCode: 36, command: true, shift: false, option: false, control: false))
        #expect(
            !CanvasNoteShortcuts.exitsEditing(
                keyCode: 36, command: false, shift: false, option: false, control: false))
    }
}
