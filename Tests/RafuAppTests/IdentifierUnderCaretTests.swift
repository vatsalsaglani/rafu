import Foundation
import Testing

@testable import RafuApp

@Test("Mid-word caret expands to the whole identifier")
func identifierUnderCaretMidWord() {
    let text = "let targetValue = 1"
    // Caret between "target" and "Value" (inside the identifier).
    let position = (text as NSString).range(of: "target").location + 3
    let result = IdentifierUnderCaret.word(in: text, at: position)
    #expect(result?.word == "targetValue")
    #expect(result?.position == (text as NSString).range(of: "targetValue").location)
}

@Test("Caret just before the identifier's first character expands it")
func identifierUnderCaretBoundaryBefore() {
    let text = "let targetValue = 1"
    let start = (text as NSString).range(of: "targetValue").location
    let result = IdentifierUnderCaret.word(in: text, at: start)
    #expect(result?.word == "targetValue")
    #expect(result?.position == start)
}

@Test("Caret just after the identifier's last character (double-click semantics) expands it")
func identifierUnderCaretBoundaryAfter() {
    let text = "let targetValue = 1"
    let range = (text as NSString).range(of: "targetValue")
    let afterEnd = range.location + range.length
    let result = IdentifierUnderCaret.word(in: text, at: afterEnd)
    #expect(result?.word == "targetValue")
    #expect(result?.position == range.location)
}

@Test("Caret over whitespace with no adjacent identifier returns nil")
func identifierUnderCaretNoIdentifier() {
    let text = "foo = bar"
    let position = (text as NSString).range(of: " = ").location + 1
    #expect(IdentifierUnderCaret.word(in: text, at: position) == nil)
}

@Test("Caret at the very start of the text over a word character")
func identifierUnderCaretStart() {
    let text = "targetValue = 1"
    let result = IdentifierUnderCaret.word(in: text, at: 0)
    #expect(result?.word == "targetValue")
    #expect(result?.position == 0)
}

@Test("Caret at the very end of the text, just after the last identifier")
func identifierUnderCaretEnd() {
    let text = "let x = targetValue"
    let result = IdentifierUnderCaret.word(in: text, at: (text as NSString).length)
    #expect(result?.word == "targetValue")
}

@Test("Underscores are part of the identifier's word class")
func identifierUnderCaretUnderscores() {
    let text = "let _private_value = 1"
    let position = (text as NSString).range(of: "_private_value").location + 4
    let result = IdentifierUnderCaret.word(in: text, at: position)
    #expect(result?.word == "_private_value")
}

@Test("Digits are part of the identifier's word class")
func identifierUnderCaretDigits() {
    let text = "let value123 = 1"
    let position = (text as NSString).range(of: "value123").location + 5
    let result = IdentifierUnderCaret.word(in: text, at: position)
    #expect(result?.word == "value123")
}

@Test("Empty text returns nil")
func identifierUnderCaretEmptyText() {
    #expect(IdentifierUnderCaret.word(in: "", at: 0) == nil)
}

@Test("An out-of-range position is clamped into bounds instead of crashing")
func identifierUnderCaretOutOfRangeIsClamped() {
    let text = "let targetValue = 1"
    let length = (text as NSString).length
    let overResult = IdentifierUnderCaret.word(in: text, at: length + 500)
    #expect(overResult?.word == "1")

    let underResult = IdentifierUnderCaret.word(in: text, at: -50)
    #expect(underResult?.word == "let")
}
