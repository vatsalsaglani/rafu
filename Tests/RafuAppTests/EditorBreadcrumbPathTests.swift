import Testing

@testable import RafuApp

@Test("Breadcrumb segments run workspace, folders, then file")
func breadcrumbSegmentsBasic() {
    let segments = EditorBreadcrumbPath.segments(
        workspaceName: "Rafu",
        rootPath: "/tmp/rafu",
        filePath: "/tmp/rafu/Sources/App/Main.swift"
    )

    #expect(segments.map(\.title) == ["Rafu", "Sources", "App", "Main.swift"])
    #expect(segments.first?.kind == .workspace)
    #expect(segments.first?.path == "/tmp/rafu")
    #expect(segments[1].kind == .folder)
    #expect(segments[1].path == "/tmp/rafu/Sources")
    #expect(segments.last?.kind == .file)
    #expect(segments.last?.path == "/tmp/rafu/Sources/App/Main.swift")
}

@Test("Breadcrumb for a root-level file is workspace plus file")
func breadcrumbSegmentsRootFile() {
    let segments = EditorBreadcrumbPath.segments(
        workspaceName: "Rafu",
        rootPath: "/tmp/rafu/",
        filePath: "/tmp/rafu/README.md"
    )

    #expect(segments.map(\.title) == ["Rafu", "README.md"])
    #expect(segments.first?.kind == .workspace)
    #expect(segments.last?.kind == .file)
}

@Test("Deep breadcrumb paths collapse middle folders to an ellipsis")
func breadcrumbSegmentsCollapse() {
    let segments = EditorBreadcrumbPath.segments(
        workspaceName: "Rafu",
        rootPath: "/tmp/rafu",
        filePath: "/tmp/rafu/a/b/c/d/e/f/File.swift"
    )

    #expect(segments.map(\.title) == ["Rafu", "a", "…", "d", "e", "f", "File.swift"])
    let collapsed = segments[2]
    #expect(collapsed.kind == .collapsed)
    #expect(collapsed.path == nil)
    #expect(segments[3].path == "/tmp/rafu/a/b/c/d")
}

@Test("Files outside the workspace fall back to a single file segment")
func breadcrumbSegmentsOutsideWorkspace() {
    let segments = EditorBreadcrumbPath.segments(
        workspaceName: "Rafu",
        rootPath: "/tmp/rafu",
        filePath: "/private/other/notes.txt"
    )

    #expect(segments.map(\.title) == ["notes.txt"])
    #expect(segments.first?.kind == .file)
}
