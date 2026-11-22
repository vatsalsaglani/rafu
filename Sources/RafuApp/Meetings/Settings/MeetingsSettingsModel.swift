import CoreAudio
import Foundation
import Observation
import RafuCore

// The state behind Settings ▸ Meetings and the model download sheet. It never
// starts a download, opens a device or asks for a permission by itself: a
// download starts only from `download(_:)`, which the Download button calls.

/// The part of the model installer that the settings need. The installer
/// actor conforms; a test uses a fake.
nonisolated protocol MeetingModelInstalling: Sendable {
    func state(for model: MeetingModelID) -> MeetingModelInstallState?
    func stateUpdates(for model: MeetingModelID) -> AsyncStream<MeetingModelInstallState>
    func install(_ model: MeetingModelID) async -> MeetingModelInstallState
    func cancelInstall(_ model: MeetingModelID) async
    func remove(_ model: MeetingModelID) async throws
}

extension MeetingModelInstaller: MeetingModelInstalling {}

/// The input devices now and the default input.
nonisolated struct MeetingInputDeviceSnapshot: Sendable, Equatable {
    var inputs: [MeetingInputDevice] = []
    var defaultInput: MeetingInputDevice?
}

/// Lists the input devices. Listing opens no device and asks for no
/// permission.
nonisolated protocol MeetingInputDeviceListing: Sendable {
    func snapshot() -> MeetingInputDeviceSnapshot
}

nonisolated struct CoreAudioInputDeviceListing: MeetingInputDeviceListing {
    func snapshot() -> MeetingInputDeviceSnapshot {
        let audio = MeetingCoreAudio(diagnostics: NoopMeetingDiagnostics(), meeting: nil)
        let inputs = audio.inputDevices()
        let defaultInput = audio.defaultDevice(input: true).flatMap { audio.inputDevice($0) }
        return MeetingInputDeviceSnapshot(inputs: inputs, defaultInput: defaultInput)
    }
}

@MainActor
@Observable
final class MeetingsSettingsModel {
    // Stored choices. Each write goes to the same key that
    // `UserDefaultsMeetingPreferences` reads.
    var textEngine: MeetingTextEngineID {
        didSet { defaults.set(textEngine.rawValue, forKey: MeetingPreferenceKeys.textEngine) }
    }
    var speakerEngine: MeetingSpeakerEngineID {
        didSet {
            defaults.set(speakerEngine.rawValue, forKey: MeetingPreferenceKeys.speakerEngine)
        }
    }
    var microphone: MeetingMicrophoneChoice {
        didSet { defaults.set(microphone.storageValue, forKey: MeetingPreferenceKeys.microphone) }
    }
    var audioRetention: MeetingAudioRetention {
        didSet {
            defaults.set(audioRetention.rawValue, forKey: MeetingPreferenceKeys.audioRetention)
        }
    }
    var agentAccessOn: Bool {
        didSet {
            defaults.set(
                (agentAccessOn ? MeetingAgentAccess.on : .off).rawValue,
                forKey: MeetingPreferenceKeys.agentAccess)
        }
    }

    // Read state.
    private(set) var installStates: [MeetingModelID: MeetingModelInstallState] = [:]
    private(set) var textAvailability: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
    private(set) var speakerAvailability: [MeetingSpeakerEngineID: MeetingEngineAvailability] = [:]
    private(set) var devices = MeetingInputDeviceSnapshot()
    /// True until the first availability read finished.
    private(set) var isReadingAvailability = true
    /// The model that the Remove confirmation asks about.
    var pendingRemoval: MeetingModelID?
    /// The failure sentence of the last Remove, or nil.
    private(set) var removalFailure: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installer: (any MeetingModelInstalling)?
    @ObservationIgnored private let textEngines: [MeetingTextEngineID: any MeetingTextEngine]
    @ObservationIgnored private let speakerEngines:
        [MeetingSpeakerEngineID: any MeetingSpeakerEngine]
    @ObservationIgnored private let deviceLister: any MeetingInputDeviceListing

    /// `suiteName` nil uses `UserDefaults.standard`.
    init(
        installer: (any MeetingModelInstalling)?,
        textEngines: [MeetingTextEngineID: any MeetingTextEngine] = [:],
        speakerEngines: [MeetingSpeakerEngineID: any MeetingSpeakerEngine] = [:],
        deviceLister: any MeetingInputDeviceListing = CoreAudioInputDeviceListing(),
        suiteName: String? = nil
    ) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let stored = UserDefaultsMeetingPreferences(suiteName: suiteName)
        self.defaults = defaults
        self.installer = installer
        self.textEngines = textEngines
        self.speakerEngines = speakerEngines
        self.deviceLister = deviceLister
        textEngine = stored.speechPreferences().textEngine
        speakerEngine = stored.speechPreferences().speakerEngine
        microphone = stored.microphoneChoice()
        audioRetention = stored.audioRetention()
        agentAccessOn = stored.agentAccess() == .on
        for model in MeetingModelID.allCases {
            if let state = installer?.state(for: model) { installStates[model] = state }
        }
    }

    // MARK: Observing (a view calls this from `.task`)

    /// Reads the devices and the engine availability, and follows the install
    /// state of each model until the calling task is cancelled. It starts no
    /// download.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            if let installer {
                for model in MeetingModelID.allCases {
                    let updates = installer.stateUpdates(for: model)
                    group.addTask { await self.follow(model, updates: updates) }
                }
            }
            group.addTask { await self.refreshDevices() }
            group.addTask { await self.refreshAvailability() }
        }
    }

    private func follow(
        _ model: MeetingModelID, updates: AsyncStream<MeetingModelInstallState>
    ) async {
        for await state in updates {
            installStates[model] = state
            if case .downloading = state { continue }
            await refreshAvailability()
        }
    }

    func refreshAvailability() async {
        var text: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in textEngines { text[id] = await engine.availability() }
        var speaker: [MeetingSpeakerEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in speakerEngines { speaker[id] = await engine.availability() }
        textAvailability = text
        speakerAvailability = speaker
        isReadingAvailability = false
    }

    func refreshDevices() async {
        let lister = deviceLister
        devices = await Task.detached { lister.snapshot() }.value
    }

    // MARK: Models

    func installState(for model: MeetingModelID) -> MeetingModelInstallState {
        installStates[model]
            ?? .notInstalled(bytes: MeetingModelCatalog.entry(for: model).totalBytes)
    }

    /// Starts the download of `model`. Only the Download button calls this.
    /// The download is not tied to the view: it goes on after the pane or the
    /// sheet closes. The returned task ends with the install.
    @discardableResult
    func download(_ model: MeetingModelID) -> Task<Void, Never>? {
        guard let installer else { return nil }
        removalFailure = nil
        return Task { _ = await installer.install(model) }
    }

    @discardableResult
    func cancelDownload(_ model: MeetingModelID) -> Task<Void, Never>? {
        guard let installer else { return nil }
        return Task { await installer.cancelInstall(model) }
    }

    /// Removes `model` after the user confirmed.
    @discardableResult
    func confirmRemoval(of model: MeetingModelID) -> Task<Void, Never>? {
        pendingRemoval = nil
        guard let installer else { return nil }
        return Task {
            do {
                try await installer.remove(model)
                removalFailure = nil
            } catch {
                removalFailure = "Rafu could not remove the model files."
            }
            await refreshAvailability()
        }
    }

    // MARK: Presentation

    var textLines: [String] {
        MeetingsSettingsPresentation.textEngineLines(
            preference: textEngine, availability: textAvailability)
    }

    var speakerLine: String {
        MeetingsSettingsPresentation.speakerEngineLine(
            preference: speakerEngine, availability: speakerAvailability)
    }

    var textStatus: String? {
        if isReadingAvailability { return nil }
        return MeetingsSettingsPresentation.engineStatus(textAvailability[textEngine])
    }

    var speakerStatus: String? {
        if isReadingAvailability { return nil }
        return MeetingsSettingsPresentation.engineStatus(speakerAvailability[speakerEngine])
    }

    var microphoneLine: MeetingMicrophoneLine {
        MeetingsSettingsPresentation.microphoneLine(
            choice: microphone, devices: devices.inputs, defaultInput: devices.defaultInput)
    }

    var isMicrophoneMissing: Bool {
        MeetingsSettingsPresentation.isMissingDevice(
            choice: microphone, devices: devices.inputs)
    }
}
