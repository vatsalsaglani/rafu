import Foundation
import Testing

@testable import RafuApp

private func makeCandidate(name: String = "target") -> SymbolCandidate {
    SymbolCandidate(
        relativePath: "A.swift",
        range: NSRange(location: 0, length: name.count),
        name: name,
        kindLabel: "function",
        previewLine: "func \(name)() {}"
    )
}

@Test("A nil answer (every tier declined) presents an empty peek")
func navigationPresentationNilAnswerIsEmpty() {
    let outcome = NavigationPresentation.outcome(for: nil, kind: .definition)
    #expect(outcome == .peek(.empty(.definition)))
}

@Test("An indexing-state answer presents the indexing peek regardless of candidates")
func navigationPresentationIndexingAnswerIsIndexing() {
    let answer = NavigationAnswer(tier: .syntactic, candidates: [], state: .indexing)
    let outcome = NavigationPresentation.outcome(for: answer, kind: .definition)
    #expect(outcome == .peek(.indexing))
}

@Test("A ready answer with zero candidates presents an empty peek")
func navigationPresentationReadyZeroCandidatesIsEmpty() {
    let answer = NavigationAnswer(tier: .syntactic, candidates: [], state: .ready)
    let outcome = NavigationPresentation.outcome(for: answer, kind: .references)
    #expect(outcome == .peek(.empty(.references)))
}

@Test("An unavailable answer with zero candidates presents an empty peek")
func navigationPresentationUnavailableZeroCandidatesIsEmpty() {
    let answer = NavigationAnswer(tier: .text, candidates: [], state: .unavailable)
    let outcome = NavigationPresentation.outcome(for: answer, kind: .declaration)
    #expect(outcome == .peek(.empty(.declaration)))
}

@Test("A ready answer with exactly one candidate jumps directly")
func navigationPresentationReadyOneCandidateJumps() {
    let candidate = makeCandidate()
    let answer = NavigationAnswer(tier: .syntactic, candidates: [candidate], state: .ready)
    let outcome = NavigationPresentation.outcome(for: answer, kind: .definition)
    #expect(outcome == .jump(candidate))
}

@Test("A ready answer with multiple candidates presents a results peek")
func navigationPresentationReadyMultipleCandidatesPeeks() {
    let candidates = [makeCandidate(name: "a"), makeCandidate(name: "b")]
    let answer = NavigationAnswer(tier: .text, candidates: candidates, state: .ready)
    let outcome = NavigationPresentation.outcome(for: answer, kind: .references)
    #expect(outcome == .peek(.results(answer)))
}
