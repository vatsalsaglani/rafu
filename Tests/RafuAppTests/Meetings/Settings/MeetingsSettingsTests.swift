import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

/// An installer that counts calls and never touches the network or a disk.
nonisolated final class FakeSettingsInstaller: MeetingModelInstalling {
    private let installCalls = Mutex<[MeetingModelID]>([])
    private let startStates: [MeetingModelID: MeetingModelInstallState]

    init(states: [MeetingModelID: MeetingModelInstallState] = [:]) {
        startStates = states
    }

    var installCount: Int { installCalls.withLock { $0.count } }
    var installedModels: [MeetingModelID] { installCalls.withLock { $0 } }

    func state(for model: MeetingModelID) -> MeetingModelInstallState? {
        startStates[model] ?? .notInstalled(bytes: MeetingModelCatalog.entry(for: model).totalBytes)
    }

    func stateUpdates(for model: MeetingModelID) -> AsyncStream<MeetingModelInstallState> {
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingModelInstallState.self)
        if let state = state(for: model) { continuation.yield(state) }
        continuation.finish()
        return stream
    }

    func install(_ model: MeetingModelID) async -> MeetingModelInstallState {
        installCalls.withLock { $0.append(model) }
        return .installed(revision: "test")
    }

    func cancelInstall(_ model: MeetingModelID) async {}
    func remove(_ model: MeetingModelID) async throws {}
}

nonisolated struct FakeDeviceLister: MeetingInputDeviceListing {
    var value = MeetingInputDeviceSnapshot()
    func snapshot() -> MeetingInputDeviceSnapshot { value }
}

nonisolated struct FakeSettingsTextEngine: MeetingTextEngine {
    let id: MeetingTextEngineID
    let ready: MeetingEngineAvailability
    var supportsLiveText: Bool { id != .whisperKit }
    func availability() async -> MeetingEngineAvailability { ready }
    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        throw CancellationError()
    }
    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        throw CancellationError()
    }
}

private func suite() -> String { "rafu.tests.meetings.settings.\(UUID().uuidString)" }

private func removeSuite(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}

private let builtIn = MeetingInputDevice(
    objectID: 1, uid: "built-in", name: "MacBook Pro Microphone",
    transportType: MeetingTransportType.builtIn)
private let headset = MeetingInputDevice(
    objectID: 2, uid: "headset", name: "Test Headset",
    transportType: MeetingTransportType.bluetooth)

@Suite("Settings ▸ Meetings")
@MainActor
struct MeetingsSettingsTests {
    // 1. Row state for each install state.
    @Test func modelRowStateForEachInstallState() {
        let entry = MeetingModelCatalog.entry(for: .nemotronEnglish1120)
        let notInstalled = MeetingsSettingsPresentation.modelRowState(
            installState: .notInstalled(bytes: entry.totalBytes), entry: entry)
        #expect(notInstalled.text.contains(entry.totalSizeText))
        #expect(notInstalled.text.contains("626.2 MB"))
        #expect(notInstalled.button == .download)

        let downloading = MeetingsSettingsPresentation.modelRowState(
            installState: .downloading(fraction: 0.42), entry: entry)
        #expect(downloading.text == "Downloading 42%")
        #expect(downloading.button == .cancel)
        #expect(downloading.progress == 0.42)

        let verifying = MeetingsSettingsPresentation.modelRowState(
            installState: .verifying, entry: entry)
        #expect(verifying.text == "Checking the files")
        #expect(verifying.button == .cancel)

        let installed = MeetingsSettingsPresentation.modelRowState(
            installState: .installed(revision: "r"), entry: entry)
        #expect(installed.text == "Ready")
        #expect(installed.button == .remove)

        let failed = MeetingsSettingsPresentation.modelRowState(
            installState: .failed(.diskWrite), entry: entry)
        #expect(failed.text == MeetingModelInstallFailure.diskWrite.message)
        #expect(failed.button == .download)
        #expect(failed.isFailure)
    }

    // 2. A download starts only from the button.
    @Test func downloadStartsOnlyFromTheDownloadAction() async {
        let name = suite()
        defer { removeSuite(name) }
        let installer = FakeSettingsInstaller()
        let model = MeetingsSettingsModel(
            installer: installer, deviceLister: FakeDeviceLister(), suiteName: name)
        #expect(installer.installCount == 0)
        await model.run()
        #expect(installer.installCount == 0)
        model.textEngine = .whisperKit
        model.speakerEngine = .speakerKit
        model.microphone = .systemDefault
        model.agentAccessOn = true
        model.pendingRemoval = .nemotronEnglish1120
        #expect(installer.installCount == 0)
        await model.download(.nemotronEnglish1120)?.value
        #expect(installer.installedModels == [.nemotronEnglish1120])
    }

    // 3. The "In use" lines.
    @Test func nemotronNotInstalledNamesAppleSpeech() {
        let lines = MeetingsSettingsPresentation.textEngineLines(
            preference: .nemotronEnglish,
            availability: [
                .nemotronEnglish: .needsModel([.nemotronEnglish1120]), .appleSpeech: .ready,
            ])
        #expect(
            lines == ["In use now: Apple speech, until Nemotron English is installed."])
    }

    @Test func missingEngineSaysNotInThisBuild() {
        let lines = MeetingsSettingsPresentation.textEngineLines(
            preference: .nemotronEnglish, availability: [.appleSpeech: .ready])
        #expect(lines.first?.contains("not in this build yet") == true)
        #expect(MeetingsSettingsPresentation.engineStatus(nil) == "Not in this build yet")
        #expect(
            MeetingsSettingsPresentation.engineStatus(.needsModel([.nemotronEnglish1120]))
                == "Needs a download")
    }

    @Test func whisperKitReadyKeepsLiveTextOnNemotronOrApple() {
        let withNemotron = MeetingsSettingsPresentation.textEngineLines(
            preference: .whisperKit,
            availability: [.whisperKit: .ready, .nemotronEnglish: .ready, .appleSpeech: .ready])
        #expect(withNemotron[0].contains("WhisperKit large-v3 for the text after Stop"))
        #expect(withNemotron[0].contains("Live text: Nemotron English"))
        #expect(withNemotron[1] == MeetingsSettingsPresentation.whisperKitNote)

        let appleOnly = MeetingsSettingsPresentation.textEngineLines(
            preference: .whisperKit, availability: [.whisperKit: .ready, .appleSpeech: .ready])
        #expect(appleOnly[0].contains("Live text: Apple speech"))
    }

    @Test func speakerLineWithoutAnyInstalledModel() {
        let none = MeetingsSettingsPresentation.speakerEngineLine(
            preference: .nemotron3,
            availability: [
                .nemotron3: .needsModel([.nemotron3Fast32]),
                .speakerKit: .needsModel([.speakerKit]),
            ])
        #expect(none.contains("Speakers are not told apart until a speaker model is installed"))

        let other = MeetingsSettingsPresentation.speakerEngineLine(
            preference: .nemotron3,
            availability: [
                .nemotron3: .needsModel([.nemotron3Fast32]), .speakerKit: .ready,
            ])
        #expect(other == "In use now: SpeakerKit, until Nemotron 3 is installed.")

        let own = MeetingsSettingsPresentation.speakerEngineLine(
            preference: .nemotron3, availability: [.nemotron3: .ready])
        #expect(own == "In use now: Nemotron 3.")
    }

    // 4. Microphone line.
    @Test func automaticPrefersBuiltInOverBluetoothDefault() {
        let line = MeetingsSettingsPresentation.microphoneLine(
            choice: .automatic, devices: [headset, builtIn], defaultInput: headset)
        #expect(line.text == "Automatic uses: MacBook Pro Microphone")
        #expect(line.warning == nil)
    }

    @Test func systemDefaultWithBluetoothWarns() {
        let line = MeetingsSettingsPresentation.microphoneLine(
            choice: .systemDefault, devices: [headset, builtIn], defaultInput: headset)
        #expect(line.text.contains("Test Headset"))
        #expect(line.warning == MeetingsSettingsPresentation.headsetWarning)
    }

    @Test func missingStoredDeviceSaysNotConnected() {
        let choice = MeetingMicrophoneChoice.device(uid: "gone")
        #expect(
            MeetingsSettingsPresentation.isMissingDevice(choice: choice, devices: [builtIn]))
        let line = MeetingsSettingsPresentation.microphoneLine(
            choice: choice, devices: [builtIn], defaultInput: builtIn)
        #expect(line.text.contains("not connected"))
        #expect(line.text.contains("MacBook Pro Microphone"))
    }

    // 5. Stored values match what the readers read.
    @Test func pickersWriteTheRawValuesTheReaderReads() {
        let name = suite()
        defer { removeSuite(name) }
        let model = MeetingsSettingsModel(
            installer: nil, deviceLister: FakeDeviceLister(), suiteName: name)
        let reader = UserDefaultsMeetingPreferences(suiteName: name)

        model.textEngine = .whisperKit
        model.speakerEngine = .speakerKit
        model.microphone = .device(uid: "abc")
        model.audioRetention = .days7
        model.agentAccessOn = true

        #expect(reader.speechPreferences().textEngine == .whisperKit)
        #expect(reader.speechPreferences().speakerEngine == .speakerKit)
        #expect(reader.microphoneChoice() == .device(uid: "abc"))
        #expect(reader.audioRetention() == .days7)
        #expect(reader.agentAccess() == .on)

        let defaults = UserDefaults(suiteName: name)
        #expect(defaults?.string(forKey: MeetingPreferenceKeys.textEngine) == "whisperkit")
        #expect(defaults?.string(forKey: MeetingPreferenceKeys.speakerEngine) == "speakerkit")
        #expect(defaults?.string(forKey: MeetingPreferenceKeys.microphone) == "device:abc")
        #expect(defaults?.string(forKey: MeetingPreferenceKeys.audioRetention) == "days7")
        #expect(defaults?.string(forKey: MeetingPreferenceKeys.agentAccess) == "on")

        model.agentAccessOn = false
        #expect(reader.agentAccess() == .off)

        // A second model reads what the first wrote.
        let second = MeetingsSettingsModel(
            installer: nil, deviceLister: FakeDeviceLister(), suiteName: name)
        #expect(second.textEngine == .whisperKit)
        #expect(second.microphone == .device(uid: "abc"))
    }

    // 6. Defaults with an empty suite.
    @Test func emptySuiteGivesTheDefaults() {
        let name = suite()
        defer { removeSuite(name) }
        let model = MeetingsSettingsModel(
            installer: nil, deviceLister: FakeDeviceLister(), suiteName: name)
        #expect(model.agentAccessOn == false)
        #expect(model.textEngine == .nemotronEnglish)
        #expect(model.speakerEngine == .nemotron3)
        #expect(model.microphone == .automatic)
        #expect(model.audioRetention == .untilDeleted)
    }

    // 7. Registration.
    @Test func registrationAddsTheSettingsAndSheetHooks() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.settingsView == nil)
        #expect(feature.modelDownloadSheet == nil)
        feature.registerSettingsParts()
        #expect(feature.settingsView != nil)
        #expect(feature.modelDownloadSheet != nil)
    }

    // Extra: availability is read from the registered engines, and the
    // devices from the lister.
    @Test func runReadsAvailabilityAndDevices() async {
        let name = suite()
        defer { removeSuite(name) }
        let model = MeetingsSettingsModel(
            installer: FakeSettingsInstaller(),
            textEngines: [
                .appleSpeech: FakeSettingsTextEngine(id: .appleSpeech, ready: .ready),
                .nemotronEnglish: FakeSettingsTextEngine(
                    id: .nemotronEnglish, ready: .needsModel([.nemotronEnglish1120])),
            ],
            deviceLister: FakeDeviceLister(
                value: MeetingInputDeviceSnapshot(
                    inputs: [builtIn, headset], defaultInput: headset)),
            suiteName: name)
        await model.run()
        #expect(model.devices.inputs.count == 2)
        #expect(model.textStatus == "Needs a download")
        #expect(
            model.textLines == ["In use now: Apple speech, until Nemotron English is installed."])
        #expect(model.microphoneLine.text == "Automatic uses: MacBook Pro Microphone")
    }

    @Test func removeConfirmationNamesTheModelAndTheFallback() {
        #expect(
            MeetingsSettingsPresentation.removeConfirmation(for: .nemotronEnglish1120)
                == "Remove the Nemotron English model? Rafu then uses Apple speech.")
    }
}
