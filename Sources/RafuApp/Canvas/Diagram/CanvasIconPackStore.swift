import Foundation
import RafuCore

/// The built-in Common pack: SF Symbols listed in `Resources/DiagramPacks/common.json`.
nonisolated enum CanvasCommonIconPack {
    static let packID = "common"

    static func decode(_ data: Data) throws -> CanvasIconPack {
        guard data.count <= 512 * 1_024 else { throw CanvasDiagramError.invalidValue }
        let pack = try JSONDecoder().decode(CanvasIconPack.self, from: data)
        try pack.validate()
        guard pack.id == packID, pack.vendor == .common else {
            throw CanvasDiagramError.invalidValue
        }
        return pack
    }

    /// The bundled manifest, or an empty pack when the resource is missing.
    @MainActor
    static func load() -> CanvasIconPack {
        guard
            let url = Bundle.module.url(
                forResource: "common", withExtension: "json", subdirectory: "DiagramPacks"),
            let data = try? Data(contentsOf: url),
            let pack = try? decode(data)
        else {
            return CanvasIconPack(id: packID, name: "Common", vendor: .common, entries: [])
        }
        return pack
    }
}

/// Installed packs on disk: `<Application Support>/DiagramPacks/<pack id>/`
/// with `index.json` and an `icons` folder. All work here is off the main
/// actor; processes run as an executable plus an argument array.
nonisolated enum CanvasIconPackStore {
    static let indexFileName = "index.json"
    static let iconsFolderName = "icons"

    static func defaultDirectory(identity: RafuAppIdentity = .current) -> URL {
        identity.applicationSupportRoot()
            .appending(path: "DiagramPacks", directoryHint: .isDirectory)
    }

    static func iconURL(
        packID: String, entry: CanvasIconPackEntry, directory: URL
    ) -> URL? {
        guard CanvasDiagramText.isIdentifier(packID), let file = entry.file,
            CanvasIconPackEntry.isPlainFileName(file)
        else { return nil }
        return directory.appending(path: packID, directoryHint: .isDirectory)
            .appending(path: iconsFolderName, directoryHint: .isDirectory)
            .appending(path: file, directoryHint: .notDirectory)
    }

    // MARK: Loading

    @concurrent
    static func loadInstalled(directory: URL) async -> [CanvasIconPack] {
        let fileManager = FileManager.default
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var packs: [CanvasIconPack] = []
        for child in children {
            let index = child.appending(path: indexFileName)
            guard let size = try? index.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= 8 * 1_024 * 1_024,
                let data = try? Data(contentsOf: index),
                let pack = try? JSONDecoder().decode(CanvasIconPack.self, from: data),
                (try? pack.validate()) != nil,
                pack.id == child.lastPathComponent, pack.vendor != .common
            else { continue }
            packs.append(pack)
        }
        let order = CanvasIconPackVendor.allCases
        return packs.sorted {
            let l = order.firstIndex(of: $0.vendor) ?? 0
            let r = order.firstIndex(of: $1.vendor) ?? 0
            return l != r ? l < r : $0.name < $1.name
        }
    }

    @concurrent
    static func remove(packID: String, directory: URL) async throws {
        guard CanvasDiagramText.isIdentifier(packID), packID != CanvasCommonIconPack.packID else {
            throw CanvasDiagramError.invalidValue
        }
        let folder = directory.appending(path: packID, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Import

    /// Imports a vendor ZIP or a folder: validates the archive listing,
    /// extracts with `/usr/bin/ditto` into a private temporary folder, keeps
    /// only regular SVG and PNG files that pass the content policy, and moves
    /// the finished pack into place in one step.
    @concurrent
    static func importPack(from source: URL, directory: URL) async throws -> CanvasIconPack {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(
            path: "rafu-icon-pack-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
        ])
        let root: URL
        if values.isDirectory == true {
            root = source
        } else if values.isRegularFile == true, source.pathExtension.lowercased() == "zip" {
            guard Int64(values.fileSize ?? Int.max) <= CanvasDiagramLimits.archiveBytes else {
                throw CanvasDiagramError.archiveTooLarge
            }
            try await validateArchive(source)
            let extracted = work.appending(path: "extracted", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            let status = try await ArchiveUnpacker.runArgv(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", source.path, extracted.path])
            guard status == 0 else { throw CanvasDiagramError.extractionFailed(status) }
            root = extracted
        } else {
            throw CanvasDiagramError.unsupportedSource
        }
        try Task.checkCancellation()

        let files = try scan(root: root)
        let paths = files.map(\.path)
        let vendor = CanvasIconPackLayout.detectVendor(paths: paths)
        let candidates = CanvasIconPackLayout.candidates(paths: paths, vendor: vendor)
        guard !candidates.isEmpty else { throw CanvasDiagramError.noIcons }

        let sourceName = String(source.deletingPathExtension().lastPathComponent.prefix(80))
        let packID =
            vendor == .custom
            ? String("custom-\(CanvasDiagramText.slug(sourceName))".prefix(80)) : vendor.packID
        let staging = work.appending(path: packID, directoryHint: .isDirectory)
        let icons = staging.appending(path: iconsFolderName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: icons, withIntermediateDirectories: true)

        var total: Int64 = 0
        var accepted: [CanvasIconPackEntry] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let file = candidate.entry.file else { continue }
            let url = root.appending(path: candidate.sourcePath, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url),
                data.count <= CanvasDiagramLimits.iconFileBytes
            else { continue }
            let acceptable =
                candidate.fileExtension == "png"
                ? CanvasIconPackSafety.isPNG(data) : CanvasIconPackSafety.isAcceptableSVG(data)
            guard acceptable else { continue }
            total += Int64(data.count)
            guard total <= CanvasDiagramLimits.packBytes else {
                throw CanvasDiagramError.archiveTooLarge
            }
            try data.write(to: icons.appending(path: file), options: .atomic)
            accepted.append(candidate.entry)
        }
        guard !accepted.isEmpty else { throw CanvasDiagramError.noIcons }

        let pack = CanvasIconPack(
            id: packID, name: vendor == .custom ? sourceName : vendor.title, vendor: vendor,
            entries: accepted, sourceName: String(source.lastPathComponent.prefix(120)),
            importedAt: Date())
        try pack.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pack).write(to: staging.appending(path: indexFileName), options: .atomic)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: packID, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return pack
    }

    /// Rejects archives whose listing has unsafe names, too many entries or
    /// too many uncompressed bytes, before anything is extracted.
    static func validateArchive(_ archive: URL) async throws {
        let listing = try await runCapturing(
            URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-1", archive.path],
            maximumBytes: 16 * 1_024 * 1_024)
        guard listing.status == 0, let text = String(data: listing.output, encoding: .utf8) else {
            throw CanvasDiagramError.unsupportedSource
        }
        let names = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard names.count <= CanvasDiagramLimits.archiveEntries else {
            throw CanvasDiagramError.archiveTooLarge
        }
        guard names.allSatisfy({ CanvasIconPackSafety.isSafeArchiveEntry(String($0)) }) else {
            throw CanvasDiagramError.unsafeArchive
        }
        let summary = try await runCapturing(
            URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-t", archive.path],
            maximumBytes: 64 * 1_024)
        guard summary.status == 0,
            let totals = CanvasIconPackSafety.zipTotals(
                String(data: summary.output, encoding: .utf8) ?? "")
        else { throw CanvasDiagramError.unsupportedSource }
        guard totals.entries <= CanvasDiagramLimits.archiveEntries,
            totals.uncompressedBytes <= CanvasDiagramLimits.archiveUncompressedBytes
        else { throw CanvasDiagramError.archiveTooLarge }
    }

    /// Regular, non-symlink icon files below `root`, as relative paths.
    static func scan(root: URL) throws -> [(path: String, size: Int)] {
        let rootComponents = root.standardizedFileURL.pathComponents
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw CanvasDiagramError.noIcons }
        var result: [(path: String, size: Int)] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            guard seen <= CanvasDiagramLimits.scannedFiles else {
                throw CanvasDiagramError.archiveTooLarge
            }
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ]),
                values.isSymbolicLink != true, values.isRegularFile == true,
                let size = values.fileSize, size <= CanvasDiagramLimits.iconFileBytes
            else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                Array(components.prefix(rootComponents.count)) == rootComponents
            else { continue }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard CanvasIconPackLayout.isIconPath(relative) else { continue }
            result.append((relative, size))
        }
        return result
    }

    /// Runs one executable with an argument array and returns its standard
    /// output, stopping the process when the output passes `maximumBytes`.
    static func runCapturing(
        _ executable: URL, _ arguments: [String], maximumBytes: Int
    ) async throws -> (status: Int32, output: Data) {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var output = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > maximumBytes {
                process.terminate()
                process.waitUntilExit()
                throw CanvasDiagramError.archiveTooLarge
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
