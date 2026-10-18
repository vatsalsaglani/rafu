import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.rafuensemble`: a saved board as versioned JSON. Declared as an
    /// exported type in the app's Info.plist (`script/build_and_run.sh`);
    /// keep both identifiers in lockstep.
    nonisolated static let rafuEnsemble = UTType(
        exportedAs: CanvasEnsembleFile.typeIdentifier, conformingTo: .json)
}

extension WorkspaceSession {
    /// Whether `url` names an Ensemble file (by extension).
    nonisolated static func isEnsembleFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == CanvasEnsembleFile.pathExtension
    }

    /// Opens a workspace `.rafuensemble` file as a board tab bound to that
    /// file. Saving writes back to the file with an expected-version check.
    func openEnsembleFile(at url: URL) {
        guard let rootURL else { return }
        Task(name: "Open Ensemble file") { [weak self] in
            guard let self else { return }
            do {
                let path = try await CanvasPreviewLoader.relativePath(for: url, root: rootURL)
                guard self.rootURL == rootURL, await canvas.configure(root: rootURL),
                    self.rootURL == rootURL
                else { return }
                guard let opened = await canvas.openFile(atRelativePath: path) else {
                    presentEnsembleFileError(
                        canvas.libraryNotice ?? CanvasError.unavailable.localizedDescription)
                    return
                }
                restoreCanvasTerminalReferences(opened.board)
                presentCanvasBoard(opened.board)
                scheduleCanvasWorkspaceSave()
                if !opened.missingEmbeddedImages.isEmpty {
                    await offerEmbeddedImageRestore(opened.missingEmbeddedImages)
                }
            } catch {
                presentEnsembleFileError(error.localizedDescription)
            }
        }
    }

    /// "Save Ensemble As…": writes the board to a new file in the workspace and
    /// opens that file as its own tab. The current board is kept as it is.
    func requestSaveCanvasAs(_ id: CanvasID) {
        guard let rootURL, let board = canvas.boards[id] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rafuEnsemble]
        panel.directoryURL = rootURL
        panel.nameFieldStringValue = Self.ensembleFileName(for: board.title)
        panel.prompt = "Save"
        panel.message = "Choose a place inside this workspace."
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url, self.rootURL == rootURL else {
                return
            }
            Task(name: "Save Ensemble as file") {
                guard let saved = await self.canvas.saveAsFile(id, to: url) else { return }
                self.restoreCanvasTerminalReferences(saved)
                self.presentCanvasBoard(saved)
                self.scheduleCanvasWorkspaceSave()
            }
        }
    }

    /// "Export Ensemble…": writes a portable copy anywhere, with small
    /// workspace images embedded. Nothing opens and nothing is bound.
    func requestExportCanvas(_ id: CanvasID) {
        guard rootURL != nil, let board = canvas.boards[id] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rafuEnsemble]
        panel.nameFieldStringValue = Self.ensembleFileName(for: board.title)
        panel.prompt = "Export"
        panel.message = "Small images are embedded so the file opens elsewhere."
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task(name: "Export Ensemble file") { _ = await self.canvas.exportFile(id, to: url) }
        }
    }

    nonisolated static func ensembleFileName(for title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Ensemble" : String(cleaned.prefix(80))) + "."
            + CanvasEnsembleFile.pathExtension
    }

    /// Asks before writing any embedded image into the workspace. Only paths
    /// that do not exist are written.
    private func offerEmbeddedImageRestore(_ images: [String: Data]) async {
        let alert = NSAlert()
        alert.messageText =
            images.count == 1
            ? "This file contains 1 image that is not in the workspace."
            : "This file contains \(images.count) images that are not in the workspace."
        alert.informativeText =
            "Rafu can write them to the paths saved in the file. Existing files are not replaced."
        alert.addButton(withTitle: "Restore Images")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try await canvas.restoreEmbeddedImages(images)
        } catch {
            presentEnsembleFileError(error.localizedDescription)
        }
    }

    private func presentEnsembleFileError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The Ensemble file could not be opened."
        alert.informativeText = message
        alert.runModal()
    }
}

/// File menu items for the Ensemble file format, placed after "Open Ensemble…".
struct CanvasEnsembleFileCommandItems: View {
    let session: WorkspaceSession?
    let board: CanvasBoardState?

    var body: some View {
        Button("Save Ensemble As…") {
            if let board { session?.requestSaveCanvasAs(board.id) }
        }
        .disabled(board == nil || session?.rootURL == nil)
        Button("Export Ensemble…") {
            if let board { session?.requestExportCanvas(board.id) }
        }
        .disabled(board == nil || session?.rootURL == nil)
    }
}

/// Opens `.rafuensemble` files that arrive from Finder or `open`. A file
/// inside an open workspace opens in that window. Otherwise its folder opens
/// as a workspace (the same rule the CLI uses for files), and the file opens
/// when that window's workspace is ready.
@MainActor
final class CanvasEnsembleOpenRouter {
    static let shared = CanvasEnsembleOpenRouter()
    private var pending: [URL] = []
    private var isObserving = false

    /// Returns the URLs that are not Ensemble files, for the folder path.
    func route(_ urls: [URL]) -> [URL] {
        var others: [URL] = []
        var folders: [URL] = []
        for url in urls {
            guard url.isFileURL, WorkspaceSession.isEnsembleFile(url) else {
                others.append(url)
                continue
            }
            if !deliver(url) {
                guard pending.count < 8 else { continue }
                pending.append(url)
                folders.append(url.deletingLastPathComponent())
            }
        }
        if !folders.isEmpty { ExternalOpenRequests.shared.enqueue(folders) }
        observe()
        return others
    }

    private func deliver(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots() {
            let root = snapshot.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard target.hasPrefix(root + "/") else { continue }
            snapshot.session.openEnsembleFile(at: url)
            WorkspaceWindowRegistry.shared.focus(session: snapshot.session)
            return true
        }
        return false
    }

    /// Re-checks pending files whenever a window registers or a workspace
    /// root changes. Event-driven (Observation), never a timer.
    private func observe() {
        guard !pending.isEmpty, !isObserving else { return }
        isObserving = true
        withObservationTracking {
            for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots() {
                _ = snapshot.session.rootURL
            }
        } onChange: {
            Task { @MainActor in
                let router = CanvasEnsembleOpenRouter.shared
                router.isObserving = false
                router.pending = router.pending.filter { !router.deliver($0) }
                router.observe()
            }
        }
    }
}
