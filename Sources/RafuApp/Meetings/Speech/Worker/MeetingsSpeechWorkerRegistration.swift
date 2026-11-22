import AppKit
import Dispatch
import RafuCore

// Owned by the speech worker package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerSpeechWorkerParts() {
        let process = MeetingWorkerProcess(
            helperURL: MeetingWorkerProcess.bundledHelperURL(), diagnostics: diagnostics)
        let context = MeetingWorkerEngineContext(
            process: process, locator: MeetingFeatureModelLocator(feature: self),
            diagnostics: diagnostics, platform: availability)
        register(.textEngine(NemotronTextEngine(context: context)))
        register(.textEngine(WhisperKitTextEngine(context: context)))
        register(.speakerEngine(Nemotron3SpeakerEngine(context: context)))
        register(.speakerEngine(SpeakerKitSpeakerEngine(context: context)))
        MeetingWorkerSystemSignals.install(process: process)
    }
}

/// Reads the model locator from the feature at each call, so the order of
/// registration does not matter and no locator is held before the catalog
/// registers one.
nonisolated final class MeetingFeatureModelLocator: MeetingModelLocating {
    private let current: @MainActor @Sendable () -> (any MeetingModelLocating)?

    @MainActor
    init(feature: MeetingsFeature) {
        current = { [weak feature] in feature?.modelLocator }
    }

    func installedFolder(for model: MeetingModelID) async -> URL? {
        guard let locator = await current() else { return nil }
        return await locator.installedFolder(for: model)
    }
}

/// Ends each helper at app quit, and stops the after-Stop job on critical
/// memory pressure (the audio stays; the caller gets a typed error).
@MainActor
final class MeetingWorkerSystemSignals {
    private static var installed: MeetingWorkerSystemSignals?

    private let process: MeetingWorkerProcess
    private let memorySource: any DispatchSourceMemoryPressure
    private var quitObserver: (any NSObjectProtocol)?

    static func install(process: MeetingWorkerProcess) {
        installed = MeetingWorkerSystemSignals(process: process)
    }

    private init(process: MeetingWorkerProcess) {
        self.process = process
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global())
        source.setEventHandler {
            Task { await process.stopFileJobForMemoryPressure() }
        }
        source.resume()
        memorySource = source
        let registry = process.registry
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            registry.terminateAll()
        }
    }
}
