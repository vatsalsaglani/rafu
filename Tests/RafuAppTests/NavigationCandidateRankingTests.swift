import Foundation
import Testing

@testable import RafuApp

@Suite("Navigation candidate ranking")
struct NavigationCandidateRankingTests {
    @Test("Same-file candidates rank before every other candidate")
    func sameFileRanksFirst() {
        #expect(
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "feature/Current.swift",
                lhsOffset: 100,
                rhsRelativePath: "feature/Sibling.swift",
                rhsOffset: 0,
                requestRelativePath: "feature/Current.swift"
            ))
        #expect(
            !NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "feature/Sibling.swift",
                lhsOffset: 0,
                rhsRelativePath: "feature/Current.swift",
                rhsOffset: 100,
                requestRelativePath: "feature/Current.swift"
            ))
    }

    @Test("Same-directory candidates rank before candidates elsewhere, after same-file")
    func sameDirectoryRanksSecond() {
        // Both same-directory, neither same-file: no ordering claim from
        // this rule alone (falls through to path/offset), but a
        // same-directory candidate must always beat one elsewhere.
        #expect(
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "feature/Sibling.swift",
                lhsOffset: 0,
                rhsRelativePath: "other/Far.swift",
                rhsOffset: 0,
                requestRelativePath: "feature/Current.swift"
            ))
        #expect(
            !NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "other/Far.swift",
                lhsOffset: 0,
                rhsRelativePath: "feature/Sibling.swift",
                rhsOffset: 0,
                requestRelativePath: "feature/Current.swift"
            ))
    }

    @Test("Neither same-file nor same-directory falls back to lexicographic path")
    func fallsBackToPathOrdering() {
        #expect(
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "aaa/Alpha.swift",
                lhsOffset: 999,
                rhsRelativePath: "other/Far.swift",
                rhsOffset: 0,
                requestRelativePath: "feature/Current.swift"
            ))
        #expect(
            !NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "other/Far.swift",
                lhsOffset: 0,
                rhsRelativePath: "aaa/Alpha.swift",
                rhsOffset: 999,
                requestRelativePath: "feature/Current.swift"
            ))
    }

    @Test("Same path falls back to byte offset")
    func fallsBackToOffsetWithinSameFile() {
        #expect(
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "other/Far.swift",
                lhsOffset: 5,
                rhsRelativePath: "other/Far.swift",
                rhsOffset: 20,
                requestRelativePath: "feature/Current.swift"
            ))
        #expect(
            !NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: "other/Far.swift",
                lhsOffset: 20,
                rhsRelativePath: "other/Far.swift",
                rhsOffset: 5,
                requestRelativePath: "feature/Current.swift"
            ))
    }

    @Test("A full mixed set sorts same-file, then same-directory, then lexicographic path/offset")
    func sortsAMixedCandidateSet() {
        struct Candidate: Equatable {
            let relativePath: String
            let offset: Int
        }
        let candidates = [
            Candidate(relativePath: "other/Far.swift", offset: 0),
            Candidate(relativePath: "aaa/Alpha.swift", offset: 0),
            Candidate(relativePath: "feature/Current.swift", offset: 40),
            Candidate(relativePath: "feature/Sibling.swift", offset: 0),
            Candidate(relativePath: "feature/Current.swift", offset: 0),
        ]
        let sorted = candidates.sorted { lhs, rhs in
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: lhs.relativePath,
                lhsOffset: lhs.offset,
                rhsRelativePath: rhs.relativePath,
                rhsOffset: rhs.offset,
                requestRelativePath: "feature/Current.swift"
            )
        }
        #expect(
            sorted == [
                Candidate(relativePath: "feature/Current.swift", offset: 0),
                Candidate(relativePath: "feature/Current.swift", offset: 40),
                Candidate(relativePath: "feature/Sibling.swift", offset: 0),
                Candidate(relativePath: "aaa/Alpha.swift", offset: 0),
                Candidate(relativePath: "other/Far.swift", offset: 0),
            ])
    }

    @Test("relativePath strips the root prefix and normalizes leading/trailing slashes")
    func relativePathStripsRoot() {
        let root = URL(fileURLWithPath: "/tmp/rafu-ranking-tests/workspace")
        let file = root.appending(path: "feature/Current.swift")
        #expect(
            NavigationCandidateRanking.relativePath(for: file, rootURL: root)
                == "feature/Current.swift")
    }

    @Test("relativePath falls back to the last path component outside the root")
    func relativePathFallsBackOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/rafu-ranking-tests/workspace")
        let outside = URL(fileURLWithPath: "/tmp/elsewhere/Other.swift")
        #expect(
            NavigationCandidateRanking.relativePath(for: outside, rootURL: root) == "Other.swift")
    }
}
