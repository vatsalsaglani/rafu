import Foundation
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Meetings wiring points")
struct MeetingsWiringTests {
    // MARK: Navigator mode and restoration

    @Test("Old restoration data with no meetings value still decodes")
    func oldRestorationDataDecodes() throws {
        let payload = RestorableWorkspace(
            bookmark: Data([1, 2, 3]), rootPath: "/tmp", openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .history,
            editorLayout: EditorLayoutRestoration(layout: EditorLayoutState()))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RestorableWorkspace.self, from: data)
        #expect(decoded.navigatorMode == .history)
    }

    @Test("\"meetings\" decodes to .meetings, in a mode and in a full payload")
    func meetingsDecodes() throws {
        let mode = try JSONDecoder().decode(
            WorkspaceNavigatorMode.self, from: Data(#""meetings""#.utf8))
        #expect(mode == .meetings)
        let payload = RestorableWorkspace(
            bookmark: Data([1]), rootPath: "/tmp", openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .meetings, editorLayout: nil)
        let decoded = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONEncoder().encode(payload))
        #expect(decoded.navigatorMode == .meetings)
    }

    @MainActor
    @Test("Meetings is usable with no folder open on macOS 26, and is ⌘7")
    func meetingsNeedsNoFolder() {
        let session = WorkspaceSession()
        #expect(session.descriptor == nil)
        #expect(WorkspaceNavigatorMode.meetings.shortcutLabel == "⌘7")
        #expect(WorkspaceNavigatorMode.meetings.title == "Meetings")
        if MeetingsAvailability.current.isAvailable {
            #expect(session.isNavigatorModeAvailable(.meetings))
            #expect(session.navigatorModeUnavailableReason(.meetings) == nil)
            session.switchNavigator(to: .meetings)
            #expect(session.navigatorMode == .meetings)
        } else {
            #expect(!session.isNavigatorModeAvailable(.meetings))
            #expect(
                session.navigatorModeUnavailableReason(.meetings) == "Meetings needs macOS 26")
        }
        #expect(!session.isNavigatorModeAvailable(.history))
        #expect(session.navigatorModeUnavailableReason(.history) == "open a folder first")
        #expect(
            NavigatorRailPresentation.tooltip(
                title: "Meetings", isEnabled: false, isActive: false, shortcut: "⌘7",
                disabledReason: "Meetings needs macOS 26")
                == "Meetings — Meetings needs macOS 26")
    }

    // MARK: Meeting tab

    @MainActor
    @Test("A meeting tab opens with no folder, is selected, and closes")
    func meetingTabLifecycle() {
        let session = WorkspaceSession()
        let meeting = MeetingID()
        session.openMeetingTab(meeting)
        #expect(session.auxiliaryTabs == [.meeting(meeting)])
        #expect(session.selectedAuxiliaryTab == .meeting(meeting))
        #expect(WorkspaceAuxiliaryTab.meeting(meeting).title == "Meeting")
        session.openMeetingTab(meeting)
        #expect(session.auxiliaryTabs.count == 1)
        session.closeAuxiliaryTab(.meeting(meeting))
        #expect(session.auxiliaryTabs.isEmpty)
        #expect(session.selectedAuxiliaryTab == nil)
        #expect(session.visibleMeetingTab == nil)
    }

    // MARK: Settings and notch

    @Test("Settings ▸ Meetings comes after Ensemble")
    func settingsPane() {
        #expect(SettingsPane.allCases.last == .meetings)
        #expect(SettingsPane.meetings.title == "Meetings")
    }

    @Test("The notch hides Meetings while no recorder is registered")
    func notchHidesMeetings() {
        #expect(!MeetingsCompanionGate.shared.isRecorderRegistered)
        #expect(!NotchSection.allCases.contains(.meetings))
        #expect(NotchSection(rawValue: "meetings") == .meetings)
        #expect(NotchSection.selection(remembered: .meetings, visible: [.ensembles]) == .ensembles)
        #expect(NotchSection.meetings.title == "Meetings")
    }

    // MARK: Feature factory

    @MainActor
    @Test("The feature is made only when an entry point resolves it, one time")
    func featureIsLazy() {
        let factory = MeetingsFeatureFactory()
        #expect(factory.makeCount == 0)
        #expect(factory.feature == nil)
        let first = factory.resolve()
        #expect(factory.makeCount == 1)
        #expect(factory.resolve() === first)
        #expect(factory.makeCount == 1)
    }

    @MainActor
    @Test("The shared factory has made no feature in a process that used no entry point")
    func sharedFactoryNotMadeAtLaunch() {
        // No test in this target resolves the shared factory, so a nonzero
        // count means a launch path (or a passive surface) made the feature.
        #expect(MeetingsFeatureFactory.shared.makeCount == 0)
    }

    @MainActor
    @Test("Registration fills each part and an empty feature shows placeholders")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.registeredKinds.isEmpty)
        #expect(feature.windowView == nil)
        #expect(!feature.canExportDiagnostics)
        #expect(!feature.hasDiagnosticsRecorder)
        var exported = 0
        feature.register(.diagnosticsExporter { _ in exported += 1 })
        feature.register(.diagnosticsRecorder(NoopMeetingDiagnostics()))
        feature.register(.windowView { _ in AnyView(EmptyView()) })
        #expect(feature.canExportDiagnostics)
        feature.exportDiagnostics()
        #expect(exported == 1)
        #expect(
            feature.registeredKinds == [.diagnosticsExporter, .diagnosticsRecorder, .windowView])
        // A test feature never opens the notch section.
        feature.register(.recorder(FakeRecorder()))
        #expect(!MeetingsCompanionGate.shared.isRecorderRegistered)

        let old = MeetingsFeature(availability: .needsMacOS26)
        old.register(.diagnosticsExporter { _ in exported += 1 })
        #expect(!old.canExportDiagnostics)
        old.exportDiagnostics()
        #expect(exported == 1)
        #expect(MeetingsPlaceholderView.message(for: .needsMacOS26) == "Meetings needs macOS 26")
        #expect(MeetingsPlaceholderView.message(for: .available) == "Meetings is being built")
    }

    // MARK: Source policy

    @Test("Open Meetings is ⇧⌘M and no other command uses that key")
    func openMeetingsShortcutIsUnique() throws {
        let files = try Self.appSources()
        let patterns = [
            #".keyboardShortcut("m", modifiers: [.command, .shift])"#,
            #".keyboardShortcut("m", modifiers: [.shift, .command])"#,
            #".keyboardShortcut("M", modifiers: [.command, .shift])"#,
            #".keyboardShortcut("M", modifiers: [.shift, .command])"#,
        ]
        var hits: [String] = []
        for (path, source) in files {
            for pattern in patterns where source.contains(pattern) {
                hits.append(path)
            }
        }
        #expect(hits == ["Sources/RafuApp/App/RafuAppCommands.swift"])
        let commands = try #require(files.first { $0.0 == hits.first }?.1)
        #expect(commands.contains(#"CommandMenu("Meetings")"#))
        #expect(commands.contains(#"Button("Open Meetings")"#))
        #expect(commands.contains("openWindow(id: MeetingsWindowRoot.windowID)"))
        #expect(commands.components(separatedBy: "meetingsExportDiagnosticsButton").count == 4)
    }

    @Test("Meetings registers no system-wide hot key")
    func noGlobalHotKey() throws {
        for (path, source) in try Self.appSources() where path.contains("/Meetings/") {
            #expect(!source.contains("RegisterEventHotKey"), "\(path)")
            #expect(!source.contains("addGlobalMonitorForEvents"), "\(path)")
        }
    }

    @Test("Launch paths never make the Meetings feature")
    func launchPathsDoNotResolve() throws {
        let files = try Self.appSources()
        for path in [
            "Sources/RafuApp/App/RafuApp.swift", "Sources/RafuApp/App/ExternalOpenRequests.swift",
            "Sources/RafuApp/Views/EditorCanvasView.swift",
            "Sources/RafuApp/Views/WorkspaceTitlebarRow.swift",
            "Sources/RafuApp/Notch/NotchDisplayPreferences.swift",
        ] {
            let source = try #require(files.first { $0.0 == path }?.1, "\(path)")
            #expect(!source.contains(".resolve()"), "\(path)")
        }
        let hosts = try #require(
            files.first { $0.0.hasSuffix("Meetings/Placeholders/MeetingsHookHosts.swift") }?.1)
        for passive in [
            "MeetingsWelcomeCardSlot", "MeetingsRecordButtonSlot", "MeetingsCompanionSectionHost",
        ] {
            let start = try #require(hosts.range(of: "struct \(passive)"))
            let rest = hosts[start.upperBound...]
            let body = rest.range(of: "\nstruct ").map { rest[..<$0.lowerBound] } ?? rest
            #expect(!body.contains("resolve()"), "\(passive)")
        }
    }

    // MARK: Session contract

    @MainActor
    @Test("Record is possible only with a driver and a free recorder")
    func canStartRecording() {
        let model = MeetingsSessionModel()
        #expect(!model.canStartRecording)
        model.isDriverInstalled = true
        #expect(model.canStartRecording)
        model.recorderState = .problem(.noBuffers)
        #expect(model.canStartRecording)
        model.recorderState = .recording(MeetingID())
        #expect(!model.canStartRecording)
        #expect(model.isRecordingOrPaused)
        model.recorderState = .starting
        #expect(!model.canStartRecording)
    }

    @MainActor
    @Test("An action calls its handler")
    func actionsCallHandlers() {
        let model = MeetingsSessionModel()
        var stops = 0
        var started: [String?] = []
        var deleted: [MeetingID] = []
        model.handlers.stop = { stops += 1 }
        model.handlers.start = { started.append($0) }
        model.handlers.deleteMeeting = { deleted.append($0) }
        model.stop()
        model.stop()
        model.startRecording(title: "Weekly")
        let meeting = MeetingID()
        model.deleteMeeting(meeting)
        #expect(stops == 2)
        #expect(started == ["Weekly"])
        #expect(deleted == [meeting])
        let before = model.libraryRevision
        model.noteLibraryChanged()
        #expect(model.libraryRevision == before + 1)
    }

    @MainActor
    @Test("Registering the detail and download hooks fills them")
    func detailAndDownloadHooks() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.meetingDetailView == nil)
        #expect(feature.modelDownloadSheet == nil)
        feature.register(.meetingDetailView { _, _ in AnyView(EmptyView()) })
        feature.register(.modelDownloadSheet { _ in AnyView(EmptyView()) })
        #expect(feature.meetingDetailView != nil)
        #expect(feature.modelDownloadSheet != nil)
        #expect(feature.registeredKinds == [.meetingDetailView, .modelDownloadSheet])
    }

    @Test("A processing step has a plain label")
    func processingStepLabel() {
        #expect(
            MeetingsProcessingStep.text(track: .me, fraction: 0.4).label
                == "Writing the text (Me) 40%")
        #expect(
            MeetingsProcessingStep.text(track: .them, fraction: 3).label
                == "Writing the text (Them) 100%")
        #expect(MeetingsProcessingStep.failed(reasonCode: "interrupted").isFailed)
        #expect(!MeetingsProcessingStep.waiting.isFailed)
    }

    // MARK: Helpers

    private struct FakeRecorder: MeetingRecorderControlling {
        var states: AsyncStream<MeetingRecorderState> { AsyncStream { $0.finish() } }
        func start(title: String) async throws -> MeetingID { MeetingID() }
        func pause() async {}
        func resume() async {}
        func stop() async {}
    }

    private static func appSources(file: StaticString = #filePath) throws -> [(String, String)] {
        var root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while root.path != "/",
            !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path)
        {
            root = root.deletingLastPathComponent()
        }
        let base = root.appending(path: "Sources/RafuApp")
        guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return [] }
        var result: [(String, String)] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
            result.append(("Sources/RafuApp/\(relative)", source))
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
