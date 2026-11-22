import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meeting diagnostics: registration and logger")
struct MeetingDiagnosticsRegistrationTests {
    @MainActor
    @Test("The diagnostics package registers its recorder and exporter, so the menu item is active")
    func registers() {
        let feature = MeetingsFeature(availability: .available)
        #expect(!feature.canExportDiagnostics)
        feature.registerDiagnosticsParts()
        #expect(feature.registeredKinds == [.diagnosticsRecorder, .diagnosticsExporter])
        #expect(feature.hasDiagnosticsRecorder)
        #expect(feature.diagnostics is MeetingDiagnosticsRecorder)
        #expect(feature.canExportDiagnostics)
    }

    @MainActor
    @Test("On a Mac that needs macOS 26 the export stays not active")
    func notActiveOnOldMac() {
        let feature = MeetingsFeature(availability: .needsMacOS26)
        feature.registerDiagnosticsParts()
        #expect(!feature.canExportDiagnostics)
    }

    @MainActor
    @Test("The diagnostics folder is below the app's own Application Support root")
    func defaultDirectory() {
        let lightning = MeetingsDiagnosticsRuntime.defaultDirectory(identity: .lightning)
        #expect(lightning.path.hasSuffix("/Rafu Lightning/Meetings/Diagnostics"))
        let release = MeetingsDiagnosticsRuntime.defaultDirectory(identity: .release)
        #expect(release.path.hasSuffix("/Rafu/Meetings/Diagnostics"))
        #expect(
            lightning.path.hasPrefix(
                RafuAppIdentity.lightning.applicationSupportRoot().path))
    }

    @Test("The logger uses the subsystem and category of the plan")
    func loggerNames() {
        #expect(MeetingDiagnosticsLogger.subsystem == "dev.vatsalsaglani.rafu")
        #expect(MeetingDiagnosticsLogger.category == "meetings")
        // Logging an event with a device name does not crash.
        let device = MeetingAudioDeviceFacts(
            name: "Test AirPods", uid: "uid-1", transportType: 0x626C_7565,
            nominalSampleRate: 24000, channelCount: 1)
        MeetingDiagnosticsLogger().log(
            MeetingDiagnosticEvent.devices(input: device, output: nil).diagnosticDescription,
            meeting: MeetingID())
    }
}
