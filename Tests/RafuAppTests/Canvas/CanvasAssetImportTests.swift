import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// External images are copied into the workspace with consent; a card never
/// references a path outside the root (ADR 0025, Amendment 4).
@Suite("Ensemble external image import")
struct CanvasAssetImportTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// A temporary folder with `workspace/` and `outside/` inside it.
    private static func makeFolders() throws -> (folder: URL, root: URL, outside: URL) {
        let folder = URL.temporaryDirectory.appending(path: "asset-import-\(UUID().uuidString)")
        let root = folder.appending(path: "workspace")
        let outside = folder.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (folder, root, outside)
    }

    @Test("The plan references inside files, copies outside images, and refuses the rest")
    func planClassifies() throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inside = root.appending(path: "notes.md")
        let insideFolder = root.appending(path: "Sources", directoryHint: .isDirectory)
        let image = outside.appending(path: "Shot.PNG")
        let text = outside.appending(path: "todo.txt")
        let outsideFolder = outside.appending(path: "Pictures", directoryHint: .isDirectory)
        try Data("n".utf8).write(to: inside)
        try FileManager.default.createDirectory(at: insideFolder, withIntermediateDirectories: true)
        try Self.png.write(to: image)
        try Data("t".utf8).write(to: text)
        try FileManager.default.createDirectory(
            at: outsideFolder, withIntermediateDirectories: true)

        let plan = try CanvasAssetImportPlan.resolve(
            urls: [inside, insideFolder, image, text, outsideFolder], root: root)
        #expect(plan.insidePaths == ["notes.md"])
        #expect(plan.externalImages.map(\.lastPathComponent) == ["Shot.PNG"])
        #expect(plan.refused.map(\.lastPathComponent) == ["todo.txt", "Pictures"])
        #expect(plan.items.count == 2)
    }

    @Test("A symlink inside the workspace that points outside counts as outside")
    func symlinkOutsideIsExternal() throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = outside.appending(path: "real.png")
        try Self.png.write(to: image)
        let link = root.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let text = outside.appending(path: "real.txt")
        try Data("t".utf8).write(to: text)
        let textLink = root.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: textLink, withDestinationURL: text)

        let plan = try CanvasAssetImportPlan.resolve(urls: [link, textLink], root: root)
        #expect(plan.insidePaths.isEmpty)
        #expect(plan.externalImages.map(\.lastPathComponent) == ["real.png"])
        #expect(plan.refused == [textLink])
    }

    @Test("Only raster image extensions qualify for a copy")
    func extensionFilter() {
        for name in ["a.png", "b.JPG", "c.jpeg", "d.heic", "e.webp", "f.gif", "g.tiff"] {
            #expect(CanvasDroppedFileKind.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
        for name in ["a.svg", "b.pdf", "c.txt", "png", ".png", "d.png.zip"] {
            #expect(!CanvasDroppedFileKind.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    @Test("A collision gets -2, then -3, and never replaces a file")
    func collisionNaming() {
        var taken: Set<String> = ["shot.png", "shot-2.png"]
        #expect(CanvasAssetImporter.uniqueName(for: "new.png") { taken.contains($0) } == "new.png")
        #expect(
            CanvasAssetImporter.uniqueName(for: "shot.png") { taken.contains($0) } == "shot-3.png")
        taken = ["README"]
        #expect(CanvasAssetImporter.uniqueName(for: "README") { taken.contains($0) } == "README-2")
    }

    @Test("The folder is the asset folder plus a safe board slug")
    func folderAndSlug() {
        #expect(CanvasAssetImporter.slug("Sprint Plan / Q3!") == "sprint-plan-q3")
        #expect(CanvasAssetImporter.slug("   ") == "ensemble")
        #expect(CanvasAssetImporter.slug("Ünïcode") == "n-code")
        #expect(CanvasAssetImporter.slug(String(repeating: "a", count: 200)).count == 60)
        #expect(
            CanvasAssetImporter.folder(parent: nil, boardTitle: "Plan")
                == ".rafu/ensemble-assets/plan")
        #expect(
            CanvasAssetImporter.folder(parent: "assets/boards/", boardTitle: "Plan")
                == "assets/boards/plan")
        #expect(
            CanvasAssetImporter.folder(parent: "../escape", boardTitle: "Plan")
                == ".rafu/ensemble-assets/plan")
    }

    @Test("Copies land atomically in the folder, in order, and existing files are kept")
    func copyWritesAtomically() async throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = outside.appending(path: "shot.png")
        let second = outside.appending(path: "other.png")
        try Self.png.write(to: first)
        try (Self.png + Data([1])).write(to: second)
        let target = root.appending(path: ".rafu/ensemble-assets/plan")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = Data("keep".utf8)
        try existing.write(to: target.appending(path: "shot.png"))

        let paths = try await CanvasAssetImporter.copy(
            [first, second], into: ".rafu/ensemble-assets/plan", root: root)
        #expect(
            paths == [
                ".rafu/ensemble-assets/plan/shot-2.png", ".rafu/ensemble-assets/plan/other.png",
            ])
        #expect(try Data(contentsOf: target.appending(path: "shot.png")) == existing)
        #expect(try Data(contentsOf: target.appending(path: "shot-2.png")) == Self.png)
        #expect(try Data(contentsOf: target.appending(path: "other.png")) == Self.png + Data([1]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.path)
            .filter { $0.hasPrefix(".rafu-import-") }
        #expect(leftovers.isEmpty)
        // The sources are untouched.
        #expect(try Data(contentsOf: first) == Self.png)
    }

    @Test("Copies the board refuses are removed again; invalid paths are skipped")
    func removeCopiesDeletesOnlyCopiedFiles() async throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = outside.appending(path: "shot.png")
        try Self.png.write(to: source)
        let paths = try await CanvasAssetImporter.copy(
            [source], into: ".rafu/ensemble-assets/plan", root: root)
        let kept = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: kept)

        await CanvasAssetImporter.removeCopies(paths + ["../outside/shot.png"], root: root)

        #expect(!FileManager.default.fileExists(atPath: root.appending(path: paths[0]).path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("An image over 16 MB is refused before it is read, and nothing is left behind")
    func sizeCapRefusesBatch() async throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = outside.appending(path: "small.png")
        try Self.png.write(to: small)
        let big = outside.appending(path: "big.png")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(CanvasAssetImporter.maxFileBytes + 1))
        try handle.close()

        await #expect(throws: CanvasAssetImporter.ImportError.tooLarge("big.png")) {
            try await CanvasAssetImporter.copy([small, big], into: "assets", root: root)
        }
        let written = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "assets").path)
        #expect(written.isEmpty)
    }

    @Test("A folder that leaves the workspace through a symlink is refused")
    func folderSymlinkRefused() async throws {
        let (folder, root, outside) = try Self.makeFolders()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = outside.appending(path: "shot.png")
        try Self.png.write(to: image)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "escape"), withDestinationURL: outside)
        await #expect(throws: CanvasAssetImporter.ImportError.folderOutsideWorkspace) {
            try await CanvasAssetImporter.copy([image], into: "escape/assets", root: root)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "assets").path))
    }

    @Test("Always copy is remembered per workspace root")
    func preferencesArePerWorkspace() {
        let suite = TestDefaultsSuite.name("dev.rafu.asset-import-tests")
        defer { TestDefaultsSuite.remove(suite) }
        let preferences = CanvasAssetImportPreferences(suiteName: suite)
        #expect(!preferences.entry(forRootPath: "/a").alwaysCopy)
        preferences.setAlwaysCopy(true, forRootPath: "/a")
        #expect(preferences.entry(forRootPath: "/a").alwaysCopy)
        #expect(!preferences.entry(forRootPath: "/b").alwaysCopy)
        #expect(preferences.entry(forRootPath: "/a").ensembleAssetFolder == nil)
    }

    @Test("The refusal names one file, or counts several")
    func refusalMessage() {
        #expect(
            CanvasAssetImportPlan.refusalMessage(for: [URL(fileURLWithPath: "/x/todo.txt")])
                == "\u{201C}todo.txt\u{201D} is outside this workspace. Only images from outside can be copied in."
        )
        #expect(
            CanvasAssetImportPlan.refusalMessage(for: [
                URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"),
            ]).hasPrefix("2 items are outside this workspace."))
    }
}
