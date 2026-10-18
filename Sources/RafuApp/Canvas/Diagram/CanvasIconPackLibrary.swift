import AppKit
import Foundation
import Observation

/// The installed icon packs for every window: the built-in Common pack plus
/// the vendor packs the user imported. Observation exposes only pack metadata;
/// images load lazily into a bounded cache.
@Observable
@MainActor
final class CanvasIconPackLibrary {
    static let shared = CanvasIconPackLibrary()

    private(set) var packs: [CanvasIconPack]
    private(set) var isImporting = false
    private(set) var hasLoaded = false
    var notice: String?
    @ObservationIgnored private(set) var searchIndex: CanvasIconSearchIndex
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let images = NSCache<NSString, NSImage>()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(directory: URL = CanvasIconPackStore.defaultDirectory()) {
        self.directory = directory
        let common = CanvasCommonIconPack.load()
        packs = [common]
        searchIndex = CanvasIconSearchIndex(packs: [common])
        images.countLimit = 400
    }

    var importedPacks: [CanvasIconPack] { packs.filter { $0.vendor != .common } }

    /// Loads the installed indexes once. Cheap to call from every view.
    func loadIfNeeded() async {
        if hasLoaded { return }
        if let loadTask { return await loadTask.value }
        let directory = directory
        let task = Task { [weak self] in
            let installed = await CanvasIconPackStore.loadInstalled(directory: directory)
            guard let self else { return }
            self.install(installed)
            self.hasLoaded = true
        }
        loadTask = task
        await task.value
    }

    func search(_ query: String, limit: Int = 60) -> [CanvasServiceIconMatch] {
        searchIndex.search(query, limit: limit)
    }

    func pack(id: String) -> CanvasIconPack? { packs.first { $0.id == id } }

    func entry(for icon: CanvasServiceIcon) -> CanvasIconPackEntry? {
        pack(id: icon.packID)?.entry(id: icon.iconID)
    }

    /// The imported vendor image, or nil for an SF Symbol entry or a missing file.
    func image(for icon: CanvasServiceIcon) -> NSImage? {
        guard let entry = entry(for: icon), entry.file != nil,
            let url = CanvasIconPackStore.iconURL(
                packID: icon.packID, entry: entry, directory: directory)
        else { return nil }
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// An SF Symbol name that exists, for a built-in entry or as the fallback.
    func symbol(for icon: CanvasServiceIcon) -> String {
        if let symbol = entry(for: icon)?.symbol,
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        {
            return symbol
        }
        return "square.dashed"
    }

    func importPack(from source: URL) async {
        guard !isImporting else { return }
        await loadIfNeeded()
        isImporting = true
        notice = nil
        defer { isImporting = false }
        do {
            let pack = try await CanvasIconPackStore.importPack(
                from: source, directory: directory)
            var next = importedPacks.filter { $0.id != pack.id }
            guard next.count < CanvasDiagramLimits.importedPacks else {
                try? await CanvasIconPackStore.remove(packID: pack.id, directory: directory)
                throw CanvasDiagramError.packLimit
            }
            next.append(pack)
            install(next)
            images.removeAllObjects()
            notice = "Imported \(pack.entries.count) icons into \(pack.name)."
        } catch {
            notice = error.localizedDescription
        }
    }

    func remove(packID: String) async {
        do {
            try await CanvasIconPackStore.remove(packID: packID, directory: directory)
            install(importedPacks.filter { $0.id != packID })
            images.removeAllObjects()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func install(_ imported: [CanvasIconPack]) {
        let common = packs.first { $0.vendor == .common } ?? CanvasCommonIconPack.load()
        packs = [common] + imported
        searchIndex = CanvasIconSearchIndex(packs: packs)
    }
}
