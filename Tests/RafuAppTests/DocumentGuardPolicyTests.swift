import Foundation
import Testing

@testable import RafuApp

@Test("A normal small file evaluates to .normal")
func guardPolicyNormalSmallFile() {
    let decision = DocumentGuardPolicy.evaluate(byteCount: 128, maxLineLength: 40)
    #expect(decision == .normal)
}

@Test("Byte count exactly at the threshold stays normal; one byte over guards")
func guardPolicyByteThresholdBoundary() {
    let atThreshold = DocumentGuardPolicy.evaluate(
        byteCount: DocumentGuardPolicy.maximumUnguardedBytes, maxLineLength: 10)
    #expect(atThreshold == .normal)

    let overThreshold = DocumentGuardPolicy.evaluate(
        byteCount: DocumentGuardPolicy.maximumUnguardedBytes + 1, maxLineLength: 10)
    #expect(
        overThreshold
            == .guarded(reason: .tooLarge(bytes: DocumentGuardPolicy.maximumUnguardedBytes + 1)))
}

@Test("A single-line minified file under the byte cap guards on line length")
func guardPolicyLongLineOnlyGuardsWhenSmallEnough() {
    let text = String(repeating: "a", count: DocumentGuardPolicy.maximumUnguardedLineLength + 1)
    let decision = DocumentGuardPolicy.evaluate(
        byteCount: text.utf8.count, maxLineLength: DocumentGuardPolicy.maxLineLength(in: text))
    #expect(decision == .guarded(reason: .longLine(length: text.count)))
}

@Test("A 2-4 MB byte-only case guards as too large")
func guardPolicyMidRangeByteCase() {
    let bytes = DocumentGuardPolicy.maximumUnguardedBytes + (1 * 1_024 * 1_024)
    let decision = DocumentGuardPolicy.evaluate(byteCount: bytes, maxLineLength: 40)
    #expect(decision == .guarded(reason: .tooLarge(bytes: bytes)))
}

@Test("Byte reason takes precedence when both thresholds trigger")
func guardPolicyBytePrecedenceOverLongLine() {
    let bytes = DocumentGuardPolicy.maximumUnguardedBytes + 10
    let longLine = DocumentGuardPolicy.maximumUnguardedLineLength + 10
    let decision = DocumentGuardPolicy.evaluate(byteCount: bytes, maxLineLength: longLine)
    #expect(decision == .guarded(reason: .tooLarge(bytes: bytes)))
}

@Test("An empty string evaluates to .normal")
func guardPolicyEmptyString() {
    #expect(DocumentGuardPolicy.maxLineLength(in: "") == 0)
    let decision = DocumentGuardPolicy.evaluate(byteCount: 0, maxLineLength: 0)
    #expect(decision == .normal)
}

@Test("maxLineLength counts UTF-16 code units, not characters, for multi-byte/emoji lines")
func guardPolicyMaxLineLengthCountsUTF16Units() {
    // Each emoji is a single `Character` (extended grapheme cluster) but two
    // UTF-16 code units, so the UTF-16 count differs from `text.count`.
    let emojiLine = String(repeating: "🙂", count: 5)
    let text = "short\n\(emojiLine)\nshort"
    #expect(emojiLine.count == 5)
    #expect(emojiLine.utf16.count == 10)
    #expect(DocumentGuardPolicy.maxLineLength(in: text) == 10)
}

@Test("CRLF line endings behave like LF: \\r counts within its line, not as a boundary")
func guardPolicyCRLFTreatsCarriageReturnAsOrdinaryCharacter() {
    let text = "abc\r\ndefgh\r\nij"
    // Longest line is "defgh\r" (6 UTF-16 units) since only "\n" is a
    // boundary and the trailing "\r" stays attached to its line.
    #expect(DocumentGuardPolicy.maxLineLength(in: text) == 6)
}

@Test("A lone-\\r file with no \\n is conservatively measured as one long line")
func guardPolicyLoneCarriageReturnConservativelyGuards() {
    // No "\n" anywhere, so the whole string is one "line" per this policy's
    // documented conservative-guard limitation.
    let text = String(repeating: "a\r", count: 6_000)
    let decision = DocumentGuardPolicy.evaluate(
        byteCount: text.utf8.count, maxLineLength: DocumentGuardPolicy.maxLineLength(in: text))
    #expect(decision == .guarded(reason: .longLine(length: text.utf16.count)))
}

@Test("decide(for:) matches evaluate(byteCount:maxLineLength:) for the same text")
func guardPolicyDecideMatchesEvaluate() async {
    let text = String(repeating: "x", count: DocumentGuardPolicy.maximumUnguardedLineLength + 5)
    let decision = await DocumentGuardPolicy.decide(for: text)
    let expected = DocumentGuardPolicy.evaluate(
        byteCount: text.utf8.count, maxLineLength: DocumentGuardPolicy.maxLineLength(in: text))
    #expect(decision == expected)
}
