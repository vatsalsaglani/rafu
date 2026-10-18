import AppKit
import Foundation
import Observation
import RafuCore

/// The state of one review sheet. It reads the session once (off the main
/// actor), decodes only the images the chosen range can show, and renders
/// the Markdown on demand. Nothing is written until the user clicks.
///
/// Privacy: no transcript text, prompt, path, or image data is logged.
@MainActor
@Observable
final class AgentHandoffModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum RangeChoice: Hashable {
        case all
        case last
    }

    enum WriteState: Equatable {
        case editing
        case writing
        case written(folderName: String)
    }

    struct ImageRow: Identifiable {
        enum Status {
            case loading
            case ready(AgentHandoffDecodedImage)
            case skipped(AgentHandoffImageSkipReason)
        }

        let ref: AgentHandoffImageRef
        let number: Int
        let status: Status
        var id: Int { ref.id }
    }

    let request: AgentHandoffRequest
    let projectRoot: URL?

    private(set) var phase: Phase = .loading
    private(set) var writeState: WriteState = .editing
    var errorMessage: String?

    var target: AgentHistoryProvider {
        didSet { if oldValue != target { rerender() } }
    }
    var rangeChoice: RangeChoice = .last {
        didSet { if oldValue != rangeChoice { planChanged() } }
    }
    var lastTurnCount = AgentHandoffOptions.defaultTurnCount {
        didSet {
            let clamped = min(max(lastTurnCount, 1), 500)
            if clamped != lastTurnCount { lastTurnCount = clamped }
            if oldValue != lastTurnCount { planChanged() }
        }
    }
    var includesToolCalls = true {
        didSet { if oldValue != includesToolCalls { planChanged() } }
    }
    var includesToolOutputs = false {
        didSet { if oldValue != includesToolOutputs { planChanged() } }
    }
    private(set) var excludedImageIDs: Set<Int> = []
    var addsGitignore = false
    private(set) var gitignoreState: AgentHandoffWriter.GitignoreState = .notGitRepository

    private(set) var document: AgentHandoffDocument?
    private(set) var imageRows: [ImageRow] = []
    private(set) var overLimitImageCount = 0
    private(set) var attachments: [AgentHandoffAttachment] = []
    private(set) var totalTurnCount = 0
    private(set) var thumbnails: [Int: NSImage] = [:]

    @ObservationIgnored private var conversation: AgentHandoffConversation?
    @ObservationIgnored private var plan: AgentHandoffPlan?
    @ObservationIgnored private var imageResults: [Int: AgentHandoffImageResult] = [:]
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var decodeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var attachmentTask: Task<Void, Never>?
    @ObservationIgnored private(set) var writeTask: Task<Void, Never>?

    init(request: AgentHandoffRequest, projectRoot: URL?) {
        self.request = request
        self.projectRoot = projectRoot
        self.target = request.target
    }

    var summary: AgentHistorySessionSummary { request.summary }
    var source: AgentHistoryProvider { request.summary.provider }
    var projectName: String { projectRoot?.lastPathComponent ?? "" }

    var options: AgentHandoffOptions {
        AgentHandoffOptions(
            range: rangeChoice == .all ? .all : .last(lastTurnCount),
            includesToolCalls: includesToolCalls, includesToolOutputs: includesToolOutputs,
            excludedImageIDs: excludedImageIDs)
    }

    /// `true` when the session ran in a folder other than the project that
    /// receives the files.
    var sessionRanElsewhere: Bool {
        guard let path = summary.projectPath, let root = projectRoot else { return false }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        return !AgentHistoryPath.isPath(path, inside: resolvedRoot)
            && !AgentHistoryPath.isPath(path, inside: root.standardizedFileURL.path)
    }

    var canWrite: Bool {
        phase == .ready && projectRoot != nil && document != nil && writeState == .editing
    }

    /// Bytes of text plus the image files, for the size line.
    var estimatedTotalBytes: Int {
        guard let document else { return 0 }
        var total = document.byteCount
        for file in document.imageFiles {
            if case .image(let image)? = imageResults[file.imageID] { total += image.data.count }
        }
        return total
    }

    // MARK: Loading

    func load() {
        guard loadTask == nil else { return }
        let session = summary
        let root = projectRoot
        loadTask = Task { [weak self] in
            do {
                let loaded = try await AgentHandoffLoader.load(session)
                let git = await Self.gitignoreState(root: root)
                guard let self, !Task.isCancelled else { return }
                self.conversation = loaded
                self.totalTurnCount = loaded.turns.count
                self.gitignoreState = git
                self.addsGitignore = git == .needsEntry
                self.phase = .ready
                self.planChanged()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.phase = .failed("Rafu could not read this session.")
            }
        }
    }

    /// Stops all work. Called when the sheet goes away.
    func cancel() {
        loadTask?.cancel()
        decodeTask?.cancel()
        attachmentTask?.cancel()
        writeTask?.cancel()
    }

    @concurrent
    private static func gitignoreState(root: URL?) async -> AgentHandoffWriter.GitignoreState {
        guard let root else { return .notGitRepository }
        return AgentHandoffWriter.gitignoreState(projectRoot: root)
    }

    // MARK: Options

    func setImage(_ id: Int, included: Bool) {
        if included {
            excludedImageIDs.remove(id)
        } else {
            excludedImageIDs.insert(id)
        }
        rerender()
    }

    func isImageIncluded(_ id: Int) -> Bool { !excludedImageIDs.contains(id) }

    /// The range, tool, or session changed: pick the turns again, then
    /// decode the images those turns can show.
    private func planChanged() {
        guard let conversation else { return }
        plan = AgentHandoffPlan.make(conversation: conversation, options: options)
        overLimitImageCount = plan?.overLimitImageIDs.count ?? 0
        classifyAttachments()
        decodeMissingImages()
        rerender()
    }

    private func decodeMissingImages() {
        guard let plan else { return }
        let missing = plan.imageRefs.filter { imageResults[$0.id] == nil }
        guard !missing.isEmpty else { return }
        decodeTask?.cancel()
        let session = summary
        decodeTask = Task { [weak self] in
            let results = await AgentHandoffLoader.decodeImages(missing, session: session)
            guard let self, !Task.isCancelled else { return }
            for (id, result) in results {
                self.imageResults[id] = result
                if case .image(let image) = result {
                    self.thumbnails[id] = NSImage(data: image.data)
                }
            }
            self.rerender()
        }
    }

    private func classifyAttachments() {
        attachmentTask?.cancel()
        guard let plan, let root = projectRoot else { return }
        let raw = Array(AgentHandoffAttachments.paths(in: plan.turns).prefix(400))
        let workingDirectory = summary.projectPath
        attachmentTask = Task { [weak self] in
            let classified = await Self.classify(
                raw, root: root, workingDirectory: workingDirectory)
            guard let self, !Task.isCancelled else { return }
            self.attachments = classified
            self.rerender()
        }
    }

    @concurrent
    private static func classify(
        _ paths: [String], root: URL, workingDirectory: String?
    ) async -> [AgentHandoffAttachment] {
        AgentHandoffAttachments.classify(
            paths, projectRoot: root, workingDirectory: workingDirectory)
    }

    private func rerender() {
        guard let plan else { return }
        let options = options
        document = AgentHandoffRenderer.render(
            plan: plan, metadata: AgentHandoffMetadata(session: summary, target: target),
            options: options, images: imageResults, attachments: attachments)
        var rows: [ImageRow] = []
        for (offset, ref) in plan.imageRefs.enumerated() {
            let status: ImageRow.Status
            switch imageResults[ref.id] {
            case .image(let image)?: status = .ready(image)
            case .skipped(let reason)?: status = .skipped(reason)
            case nil: status = ref.knownSkip.map { .skipped($0) } ?? .loading
            }
            rows.append(ImageRow(ref: ref, number: offset + 1, status: status))
        }
        imageRows = rows
    }

    // MARK: Writing

    /// Writes the files. With `startAfter` the target agent starts in a new
    /// terminal afterwards. Returns `true` when the files were written.
    func write(startAfter: Bool, session: WorkspaceSession) {
        guard canWrite, let root = projectRoot, let document else { return }
        errorMessage = nil
        writeState = .writing
        let files: [AgentHandoffImageData] = document.imageFiles.compactMap { file in
            guard case .image(let image)? = imageResults[file.imageID] else { return nil }
            return AgentHandoffImageData(name: file.name, data: image.data)
        }
        let markdown = document.markdown
        let baseName = AgentHandoffWriter.folderName(date: Date(), title: summary.title)
        let wantsGitignore = addsGitignore && gitignoreState == .needsEntry
        let launch = (target: target, source: source, title: summary.title)
        let sessionFolder = summary.projectPath
        let origin = request.origin
        writeTask = Task { [weak self] in
            do {
                let result = try await Self.perform(
                    markdown: markdown, files: files, root: root, baseName: baseName,
                    updatesGitignore: wantsGitignore)
                guard let self else { return }
                if startAfter {
                    session.startAgentHandoff(
                        AgentHandoffLaunchRequest(
                            target: launch.target, source: launch.source, title: launch.title,
                            result: result, sessionFolder: sessionFolder, origin: origin))
                }
                self.writeState = .written(folderName: result.folderName)
                self.writtenResult = result
                if startAfter { self.shouldDismiss = true }
            } catch {
                guard let self else { return }
                self.writeState = .editing
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    /// Set once the files exist, for the "Written" view.
    private(set) var writtenResult: AgentHandoffWriteResult?
    /// Set after a successful Write & Start; the sheet closes itself.
    private(set) var shouldDismiss = false

    @concurrent
    private static func perform(
        markdown: String, files: [AgentHandoffImageData], root: URL, baseName: String,
        updatesGitignore: Bool
    ) async throws -> AgentHandoffWriteResult {
        let result = try AgentHandoffWriter.write(
            markdown: markdown, images: files, projectRoot: root, baseName: baseName)
        if updatesGitignore {
            // A .gitignore failure never undoes the handoff; it only means
            // the line was not added.
            _ = try? AgentHandoffWriter.appendGitignoreEntry(projectRoot: root)
        }
        return result
    }

    private static func message(for error: any Error) -> String {
        switch error as? AgentHandoffWriteError {
        case .projectUnavailable?: "The project folder is not available."
        case .outsideProject?:
            "Rafu stopped: the handoff folder would be outside the project. Nothing was written."
        case .noFreeFolder?: "Rafu could not find a free handoff folder name."
        case .invalidFileName?: "Rafu made an invalid file name. Nothing was written."
        case .writeFailed?, nil: "Rafu could not write the handoff. Check the folder permissions."
        }
    }
}
