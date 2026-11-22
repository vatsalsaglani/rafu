import Foundation
import RafuCore
import Synchronization

/// Downloads, checks, installs and removes the meeting models, and finds an
/// installed model folder for the helper.
///
/// A download starts only from `install(_:)`, which a user action calls (the
/// first-use sheet or Settings ▸ Meetings). Nothing in this type starts one by
/// itself: no timer, no launch hook, no retry.
///
/// Layout below `modelsRoot` (`<application support>/Meetings/Models/`):
/// - `.staging/<model id>-<uuid>/`: a download in progress, never used.
/// - `<model id>/<revision>/`: an installed model, mode 0700, with
///   `LICENSE.txt`, `NOTICE` and the `.rafu-verified` marker.
actor MeetingModelInstaller: MeetingModelLocating {
    nonisolated let modelsRoot: URL
    private let transport: any MeetingModelTransport
    private let diagnostics: any MeetingDiagnosticsRecording
    private let entries: [MeetingModelID: MeetingModelCatalogEntry]
    private nonisolated let states: MeetingModelStateBroadcaster
    private var activeInstalls: [MeetingModelID: Task<MeetingModelInstallState, Never>] = [:]

    init(
        modelsRoot: URL,
        transport: any MeetingModelTransport = URLSessionMeetingModelTransport(),
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        entries: [MeetingModelCatalogEntry] = MeetingModelCatalog.entries
    ) {
        self.modelsRoot = modelsRoot
        self.transport = transport
        self.diagnostics = diagnostics
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.entries = byID
        var initial: [MeetingModelID: MeetingModelInstallState] = [:]
        for entry in byID.values {
            initial[entry.id] = Self.restingState(modelsRoot: modelsRoot, entry: entry)
        }
        self.states = MeetingModelStateBroadcaster(initial: initial)
    }

    /// `<application support>/Meetings/Models/`.
    nonisolated static func defaultModelsRoot(identity: RafuAppIdentity = .current) -> URL {
        identity.applicationSupportRoot()
            .appending(path: "Meetings", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    // MARK: State

    /// The state now. Never nil for a catalog model.
    nonisolated func state(for model: MeetingModelID) -> MeetingModelInstallState? {
        states.current(model)
    }

    /// A stream of the state of one model. It starts with the state now.
    nonisolated func stateUpdates(for model: MeetingModelID) -> AsyncStream<
        MeetingModelInstallState
    > {
        states.stream(for: model)
    }

    // MARK: MeetingModelLocating

    /// The installed folder, only when its marker holds the pinned revision.
    func installedFolder(for model: MeetingModelID) async -> URL? {
        guard let entry = entries[model] else { return nil }
        let folder = MeetingModelInstallFiles.installFolder(modelsRoot: modelsRoot, entry: entry)
        return MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry)
            ? folder : nil
    }

    // MARK: User actions

    /// Downloads, checks and installs `model`. Call it only from a user
    /// action. A second call while an install runs waits for the same install;
    /// a call when the model is installed does nothing. Cancelling the calling
    /// task cancels the install.
    @discardableResult
    func install(_ model: MeetingModelID) async -> MeetingModelInstallState {
        guard let entry = entries[model] else { return .failed(.missingFile) }
        if let running = activeInstalls[model] {
            return await running.value
        }
        let folder = MeetingModelInstallFiles.installFolder(modelsRoot: modelsRoot, entry: entry)
        if MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry) {
            let installed = MeetingModelInstallState.installed(revision: entry.revision)
            states.publish(model, installed)
            return installed
        }
        let job = InstallJob(
            entry: entry, modelsRoot: modelsRoot, transport: transport,
            diagnostics: diagnostics, states: states)
        let task = Task { await job.run() }
        activeInstalls[model] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        activeInstalls[model] = nil
        return result
    }

    /// Cancels a running install of `model`. Its staging folder is removed.
    func cancelInstall(_ model: MeetingModelID) {
        activeInstalls[model]?.cancel()
    }

    /// Cancels a running install and removes each installed revision of `model`.
    func remove(_ model: MeetingModelID) async throws {
        guard let entry = entries[model] else { return }
        if let running = activeInstalls[model] {
            running.cancel()
            _ = await running.value
        }
        let modelFolder = modelsRoot.appending(path: model.rawValue, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: modelFolder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: modelFolder)
        }
        states.publish(model, .notInstalled(bytes: entry.totalBytes))
    }

    // MARK: Helpers

    nonisolated static func restingState(
        modelsRoot: URL, entry: MeetingModelCatalogEntry
    ) -> MeetingModelInstallState {
        let folder = MeetingModelInstallFiles.installFolder(modelsRoot: modelsRoot, entry: entry)
        return MeetingModelInstallFiles.isVerifiedInstall(folder: folder, entry: entry)
            ? .installed(revision: entry.revision) : .notInstalled(bytes: entry.totalBytes)
    }
}

/// One install run. All of its work is off the installer actor, so a long
/// download or a hash of 600 MB never blocks `installedFolder(for:)`.
private nonisolated struct InstallJob: Sendable {
    let entry: MeetingModelCatalogEntry
    let modelsRoot: URL
    let transport: any MeetingModelTransport
    let diagnostics: any MeetingDiagnosticsRecording
    let states: MeetingModelStateBroadcaster

    private enum Failure: Error {
        case install(MeetingModelInstallFailure, MeetingChecksumResult, MeetingInstallResult)
    }

    @concurrent
    func run() async -> MeetingModelInstallState {
        let model = entry.id
        let started = ContinuousClock.now
        let progress = MeetingModelByteProgress(
            model: model, totalBytes: entry.totalBytes, states: states)
        diagnostics.record(
            .modelDownloadStarted(model: model, expectedBytes: entry.totalBytes), meeting: nil)
        states.publish(model, .downloading(fraction: 0))

        let stagingRoot = modelsRoot.appending(
            path: MeetingModelInstallFiles.stagingFolderName, directoryHint: .isDirectory)
        let staging = stagingRoot.appending(
            path: "\(model.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)

        func finish(
            _ state: MeetingModelInstallState, checksum: MeetingChecksumResult,
            install: MeetingInstallResult
        ) -> MeetingModelInstallState {
            let wall = started.duration(to: .now)
            let seconds =
                Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
            diagnostics.record(
                .modelDownloadFinished(
                    model: model, bytes: progress.bytes, wallSeconds: seconds,
                    checksum: checksum, install: install),
                meeting: nil)
            states.publish(model, state)
            return state
        }

        do {
            try prepareStaging(staging, stagingRoot: stagingRoot)
            try Task.checkCancellation()
            try await download(into: staging, progress: progress)
            try Task.checkCancellation()
            states.publish(model, .verifying)
            do {
                try MeetingModelVerifier.verify(
                    folder: staging, entry: entry, allowRafuFiles: false)
            } catch {
                throw Failure.install(
                    Self.failure(for: error), error.checksumResult, .removedAfterBadFile)
            }
            try writeRafuFiles(into: staging)
            try Task.checkCancellation()
            try moveIntoPlace(staging)
            Self.removeIfEmpty(stagingRoot)
            return finish(
                .installed(revision: entry.revision), checksum: .matched, install: .installed)
        } catch Failure.install(let code, let checksum, let result) {
            Self.remove(staging)
            Self.removeIfEmpty(stagingRoot)
            return finish(.failed(code), checksum: checksum, install: result)
        } catch is CancellationError {
            Self.remove(staging)
            Self.removeIfEmpty(stagingRoot)
            return finish(
                .notInstalled(bytes: entry.totalBytes), checksum: .missingFile,
                install: .cancelled)
        } catch {
            Self.remove(staging)
            Self.removeIfEmpty(stagingRoot)
            return finish(.failed(.diskWrite), checksum: .missingFile, install: .failed)
        }
    }

    /// Checks the catalog paths, clears old staging folders of this model,
    /// and makes the new staging folder (mode 0700).
    private func prepareStaging(_ staging: URL, stagingRoot: URL) throws {
        do {
            try MeetingModelVerifier.checkCatalogPaths(entry)
        } catch {
            throw Failure.install(.unexpectedContent, .mismatched, .failed)
        }
        do {
            try Self.makeFolder(modelsRoot)
            try Self.makeFolder(stagingRoot)
            let prefix = "\(entry.id.rawValue)-"
            let leftovers =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: stagingRoot.path(percentEncoded: false))) ?? []
            for name in leftovers where name.hasPrefix(prefix) {
                Self.remove(stagingRoot.appending(path: name, directoryHint: .isDirectory))
            }
            try Self.makeFolder(staging)
        } catch {
            throw Failure.install(.diskWrite, .missingFile, .failed)
        }
    }

    /// Downloads each catalog file into its local path below `staging`.
    private func download(into staging: URL, progress: MeetingModelByteProgress) async throws {
        for file in entry.files {
            try Task.checkCancellation()
            guard let url = file.downloadURL else {
                throw Failure.install(.downloadFailed, .missingFile, .failed)
            }
            let destination = staging.appending(path: file.localPath, directoryHint: .notDirectory)
            do {
                try Self.makeFolder(destination.deletingLastPathComponent())
            } catch {
                throw Failure.install(.diskWrite, .missingFile, .failed)
            }
            do {
                try await transport.download(
                    from: url, to: destination, maximumBytes: file.bytes,
                    onBytes: { progress.add($0) })
            } catch let error as MeetingModelTransportError {
                switch error {
                case .tooLarge:
                    throw Failure.install(.tooLarge, .wrongSize, .removedAfterBadFile)
                case .diskWrite:
                    throw Failure.install(.diskWrite, .missingFile, .failed)
                case .httpStatus, .transferFailed:
                    throw Failure.install(.downloadFailed, .missingFile, .failed)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw Failure.install(.downloadFailed, .missingFile, .failed)
            }
        }
    }

    /// Writes `LICENSE.txt`, `NOTICE`, and last the marker (each mode 0600).
    private func writeRafuFiles(into staging: URL) throws {
        let files: [(String, String)] = [
            (
                MeetingModelInstallFiles.licenseFileName,
                MeetingModelInstallFiles.licenseText(for: entry)
            ),
            (
                MeetingModelInstallFiles.noticeFileName,
                MeetingModelInstallFiles.noticeText(for: entry)
            ),
            (
                MeetingModelInstallFiles.verifiedMarkerFileName,
                MeetingModelInstallFiles.markerText(for: entry)
            ),
        ]
        for (name, text) in files {
            let url = staging.appending(path: name, directoryHint: .notDirectory)
            guard
                FileManager.default.createFile(
                    atPath: url.path(percentEncoded: false), contents: Data(text.utf8),
                    attributes: [.posixPermissions: 0o600])
            else { throw Failure.install(.diskWrite, .matched, .failed) }
        }
    }

    /// Renames the checked staging folder to `<model id>/<revision>/` (one
    /// `rename` on the same volume) and sets mode 0700.
    private func moveIntoPlace(_ staging: URL) throws {
        let destination = MeetingModelInstallFiles.installFolder(
            modelsRoot: modelsRoot, entry: entry)
        do {
            try Self.makeFolder(destination.deletingLastPathComponent())
            let path = destination.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            {
                // An old folder with no valid marker (an install found a valid
                // one before it started this job).
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw Failure.install(.diskWrite, .matched, .failed)
        }
    }

    private static func failure(
        for error: MeetingModelVerificationError
    ) -> MeetingModelInstallFailure {
        switch error {
        case .checksumMismatch: .checksumMismatch
        case .wrongSize: .wrongSize
        case .missingFile: .missingFile
        case .unsafePath, .symbolicLink, .notRegularFile, .unexpectedFile, .duplicatePath:
            .unexpectedContent
        case .unreadable: .diskWrite
        }
    }

    private static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func removeIfEmpty(_ url: URL) {
        let path = url.path(percentEncoded: false)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: path), names.isEmpty {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Adds downloaded bytes and publishes `.downloading(fraction:)` when the
/// fraction moves by at least 0.5 %, so a 600 MB download sends about 200
/// updates, not one for each network packet.
nonisolated final class MeetingModelByteProgress: Sendable {
    private struct State {
        var bytes: Int64 = 0
        var lastPublished: Double = 0
    }

    private let model: MeetingModelID
    private let totalBytes: Int64
    private let states: MeetingModelStateBroadcaster
    private let state = Mutex(State())

    init(model: MeetingModelID, totalBytes: Int64, states: MeetingModelStateBroadcaster) {
        self.model = model
        self.totalBytes = totalBytes
        self.states = states
    }

    var bytes: Int64 { state.withLock { $0.bytes } }

    func add(_ count: Int64) {
        let fraction = state.withLock { state -> Double? in
            state.bytes += count
            let value = totalBytes > 0 ? min(1, Double(state.bytes) / Double(totalBytes)) : 1
            guard value - state.lastPublished >= 0.005 || (value >= 1 && state.lastPublished < 1)
            else { return nil }
            state.lastPublished = value
            return value
        }
        if let fraction { states.publish(model, .downloading(fraction: fraction)) }
    }
}

/// The state of each model and the streams that follow it. Yields happen
/// inside the lock, so each stream sees the states in the order they were set.
nonisolated final class MeetingModelStateBroadcaster: Sendable {
    private struct Subscriber {
        let model: MeetingModelID
        let continuation: AsyncStream<MeetingModelInstallState>.Continuation
    }

    private struct State {
        var current: [MeetingModelID: MeetingModelInstallState]
        var subscribers: [UUID: Subscriber] = [:]
    }

    private let state: Mutex<State>

    init(initial: [MeetingModelID: MeetingModelInstallState]) {
        state = Mutex(State(current: initial))
    }

    func current(_ model: MeetingModelID) -> MeetingModelInstallState? {
        state.withLock { $0.current[model] }
    }

    func publish(_ model: MeetingModelID, _ value: MeetingModelInstallState) {
        state.withLock { state in
            state.current[model] = value
            for subscriber in state.subscribers.values where subscriber.model == model {
                subscriber.continuation.yield(value)
            }
        }
    }

    func stream(for model: MeetingModelID) -> AsyncStream<MeetingModelInstallState> {
        let (stream, continuation) = AsyncStream<MeetingModelInstallState>.makeStream(
            bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        state.withLock { state in
            state.subscribers[id] = Subscriber(model: model, continuation: continuation)
            if let value = state.current[model] { continuation.yield(value) }
        }
        return stream
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    private func removeSubscriber(_ id: UUID) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
