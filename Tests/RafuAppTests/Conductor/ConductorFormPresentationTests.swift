import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble form presentation helpers")
struct ConductorFormPresentationTests {
    @Test("Base reference options start with HEAD, then unique local branches")
    func baseReferenceOptions() {
        let options = ConductorBaseReferenceOptions.options(
            branchNames: ["main", " feature/a ", "main", "", "HEAD", "feature/b"])

        #expect(options == ["HEAD", "main", "feature/a", "feature/b"])
        #expect(ConductorBaseReferenceOptions.options(branchNames: []) == ["HEAD"])
    }

    @Test("Base reference options stay bounded in repositories with many branches")
    func baseReferenceOptionsAreBounded() {
        let names = (0..<500).map { "branch-\($0)" }
        let options = ConductorBaseReferenceOptions.options(branchNames: names)

        #expect(options.count == ConductorBaseReferenceOptions.maximumBranchCount + 1)
        #expect(options.first == "HEAD")
        #expect(options.last == "branch-\(ConductorBaseReferenceOptions.maximumBranchCount - 1)")
    }

    @Test("Workflow rows show repository paths relative, home paths with a tilde")
    func workflowDisplayPaths() {
        let root = URL(fileURLWithPath: "/work/repo", isDirectory: true)
        let repoFile = URL(fileURLWithPath: "/work/repo/.rafu/workflows/review.md")
        let userFile = URL(fileURLWithPath: "/Users/ada/.rafu/workflows/review.md")
        let otherFile = URL(fileURLWithPath: "/opt/shared/review.md")

        #expect(
            ConductorWorkflowPathPresentation.displayPath(
                for: repoFile, workspaceRoot: root, homeDirectory: "/Users/ada")
                == ".rafu/workflows/review.md")
        #expect(
            ConductorWorkflowPathPresentation.displayPath(
                for: userFile, workspaceRoot: root, homeDirectory: "/Users/ada")
                == "~/.rafu/workflows/review.md")
        #expect(
            ConductorWorkflowPathPresentation.displayPath(
                for: otherFile, workspaceRoot: root, homeDirectory: "/Users/ada")
                == "/opt/shared/review.md")
        #expect(
            ConductorWorkflowPathPresentation.displayPath(
                for: userFile, workspaceRoot: nil, homeDirectory: "")
                == "/Users/ada/.rafu/workflows/review.md")
    }
}
