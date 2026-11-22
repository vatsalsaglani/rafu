import Observation
import RafuCore
import SwiftUI
import Synchronization

// The Meetings composition root. Each later package adds its parts from a
// registration file in its own folder (`register…Parts()` below) and never
// edits this file. With nothing registered, each surface shows
// `MeetingsPlaceholderView`.

/// A view hook that needs only the feature (the Meetings window, Settings ▸
/// Meetings, the companion section).
typealias MeetingsViewHook = @MainActor (MeetingsFeature) -> AnyView
/// A view hook inside one workspace window (navigator panel, Welcome card,
/// record button).
typealias MeetingsSessionViewHook = @MainActor (MeetingsFeature, WorkspaceSession) -> AnyView
/// The body of a meeting tab in a workspace window.
typealias MeetingsTabBodyHook = @MainActor (MeetingsFeature, WorkspaceSession, MeetingID) -> AnyView
/// An action that the menu runs (for example, Export Meeting Diagnostics…).
typealias MeetingsAction = @MainActor (MeetingsFeature) -> Void

/// One part that a package registers.
enum MeetingsFeaturePart {
    case store(any MeetingStoring)
    case recorder(any MeetingRecorderControlling)
    case textEngine(any MeetingTextEngine)
    case speakerEngine(any MeetingSpeakerEngine)
    case modelLocator(any MeetingModelLocating)
    case diagnosticsRecorder(any MeetingDiagnosticsRecording)
    /// Runs "Export Meeting Diagnostics…" (its own save panel).
    case diagnosticsExporter(MeetingsAction)
    case agentRunner(any MeetingAgentRunning)
    case windowView(MeetingsViewHook)
    case navigatorView(MeetingsSessionViewHook)
    case meetingTabBody(MeetingsTabBodyHook)
    case welcomeCard(MeetingsSessionViewHook)
    case settingsView(MeetingsViewHook)
    case recordButton(MeetingsSessionViewHook)
    case companionSection(MeetingsViewHook)

    /// The kind of part, without its value.
    enum Kind: CaseIterable, Hashable {
        case store, recorder, textEngine, speakerEngine, modelLocator
        case diagnosticsRecorder, diagnosticsExporter, agentRunner
        case windowView, navigatorView, meetingTabBody, welcomeCard, settingsView
        case recordButton, companionSection
    }

    var kind: Kind {
        switch self {
        case .store: .store
        case .recorder: .recorder
        case .textEngine: .textEngine
        case .speakerEngine: .speakerEngine
        case .modelLocator: .modelLocator
        case .diagnosticsRecorder: .diagnosticsRecorder
        case .diagnosticsExporter: .diagnosticsExporter
        case .agentRunner: .agentRunner
        case .windowView: .windowView
        case .navigatorView: .navigatorView
        case .meetingTabBody: .meetingTabBody
        case .welcomeCard: .welcomeCard
        case .settingsView: .settingsView
        case .recordButton: .recordButton
        case .companionSection: .companionSection
        }
    }
}

/// The one Meetings feature object for the app. Made lazily by
/// `MeetingsFeatureFactory.resolve()` at the first use of a Meetings entry
/// point, never at launch.
@MainActor
@Observable
final class MeetingsFeature {
    // Services. Nil until a package registers one.
    private(set) var store: (any MeetingStoring)?
    private(set) var recorder: (any MeetingRecorderControlling)?
    private(set) var modelLocator: (any MeetingModelLocating)?
    private(set) var agentRunner: (any MeetingAgentRunning)?
    /// Never nil: the no-op recorder until the diagnostics package registers.
    private(set) var diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics()
    private(set) var hasDiagnosticsRecorder = false
    private(set) var diagnosticsExporter: MeetingsAction?

    // Engine registry, one engine for each id.
    private(set) var textEngines: [MeetingTextEngineID: any MeetingTextEngine] = [:]
    private(set) var speakerEngines: [MeetingSpeakerEngineID: any MeetingSpeakerEngine] = [:]

    // View hooks.
    private(set) var windowView: MeetingsViewHook?
    private(set) var navigatorView: MeetingsSessionViewHook?
    private(set) var meetingTabBody: MeetingsTabBodyHook?
    private(set) var welcomeCard: MeetingsSessionViewHook?
    private(set) var settingsView: MeetingsViewHook?
    private(set) var recordButton: MeetingsSessionViewHook?
    private(set) var companionSection: MeetingsViewHook?

    /// The kinds registered so far, for tests and diagnostics.
    private(set) var registeredKinds: Set<MeetingsFeaturePart.Kind> = []

    let availability: MeetingsAvailability
    /// Only the app's shared feature updates the companion gate, so a test
    /// feature cannot change the notch sections of another test.
    @ObservationIgnored private let updatesCompanionGate: Bool

    init(availability: MeetingsAvailability = .current, updatesCompanionGate: Bool = false) {
        self.availability = availability
        self.updatesCompanionGate = updatesCompanionGate
    }

    /// Adds one part. A second part of the same kind replaces the first
    /// (an engine replaces the engine with the same id).
    func register(_ part: MeetingsFeaturePart) {
        registeredKinds.insert(part.kind)
        switch part {
        case .store(let value): store = value
        case .recorder(let value):
            recorder = value
            if updatesCompanionGate { MeetingsCompanionGate.shared.setRecorderRegistered(true) }
        case .textEngine(let engine): textEngines[engine.id] = engine
        case .speakerEngine(let engine): speakerEngines[engine.id] = engine
        case .modelLocator(let value): modelLocator = value
        case .diagnosticsRecorder(let value):
            diagnostics = value
            hasDiagnosticsRecorder = true
        case .diagnosticsExporter(let action): diagnosticsExporter = action
        case .agentRunner(let value): agentRunner = value
        case .windowView(let hook): windowView = hook
        case .navigatorView(let hook): navigatorView = hook
        case .meetingTabBody(let hook): meetingTabBody = hook
        case .welcomeCard(let hook): welcomeCard = hook
        case .settingsView(let hook): settingsView = hook
        case .recordButton(let hook): recordButton = hook
        case .companionSection(let hook): companionSection = hook
        }
    }

    /// True when Meetings can run on this Mac and an exporter is registered.
    var canExportDiagnostics: Bool {
        availability.isAvailable && diagnosticsExporter != nil
    }

    func exportDiagnostics() {
        guard availability.isAvailable, let diagnosticsExporter else { return }
        diagnosticsExporter(self)
    }

    /// Calls each package's registration function. Each one lives in that
    /// package's own folder and starts empty.
    func registerBuiltInParts() {
        registerDiagnosticsParts()
        registerLibraryParts()
        registerRecorderParts()
        registerAppleSpeechParts()
        registerModelCatalogParts()
        registerSpeechWorkerParts()
        registerSettingsParts()
        registerWindowParts()
        registerCompanionParts()
        registerAgentParts()
    }
}

/// Makes the `MeetingsFeature` lazily. Views that must not make it (the
/// Welcome card, the title bar, the notch) read `feature`; entry points
/// that the user uses (the Meetings window, ⌘⇧M, the navigator mode,
/// Settings ▸ Meetings, a meeting tab, Export) call `resolve()`.
@MainActor
@Observable
final class MeetingsFeatureFactory {
    static let shared = MeetingsFeatureFactory(isShared: true)

    /// The feature, when it is made.
    private(set) var feature: MeetingsFeature?
    /// How many times `resolve()` made a feature (0 or 1).
    @ObservationIgnored private(set) var makeCount = 0

    @ObservationIgnored private let isShared: Bool
    @ObservationIgnored let availability: MeetingsAvailability

    init(isShared: Bool = false, availability: MeetingsAvailability = .current) {
        self.isShared = isShared
        self.availability = availability
    }

    /// The feature, made on the first call.
    @discardableResult
    func resolve() -> MeetingsFeature {
        if let feature { return feature }
        let made = MeetingsFeature(availability: availability, updatesCompanionGate: isShared)
        makeCount += 1
        feature = made
        if isShared { made.registerBuiltInParts() }
        return made
    }
}

/// Whether the notch shows its Meetings section: only after a recorder is
/// registered. Readable from each thread (`NotchSection` is nonisolated).
nonisolated final class MeetingsCompanionGate: Sendable {
    static let shared = MeetingsCompanionGate()

    private let recorderRegistered = Mutex(false)

    var isRecorderRegistered: Bool { recorderRegistered.withLock { $0 } }

    func setRecorderRegistered(_ value: Bool) {
        recorderRegistered.withLock { $0 = value }
    }
}
