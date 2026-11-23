import Foundation
import Observation
import RafuCore
import SwiftUI
import Synchronization
import Testing

@testable import RafuApp

@Suite("Meetings workspace surfaces")
struct MeetingsWorkspaceSurfacesTests {
    @MainActor
    @Test("Registration fills the four workspace hooks and nothing else")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.navigatorView == nil)
        #expect(feature.meetingTabBody == nil)
        #expect(feature.welcomeCard == nil)
        #expect(feature.recordButton == nil)
        feature.registerWorkspaceParts()
        #expect(feature.navigatorView != nil)
        #expect(feature.meetingTabBody != nil)
        #expect(feature.welcomeCard != nil)
        #expect(feature.recordButton != nil)
        #expect(
            feature.registeredKinds == [
                .navigatorView, .meetingTabBody, .welcomeCard, .recordButton,
            ])
    }

    @MainActor
    @Test("The session actions call their handlers one time each")
    func actionsCallHandlers() {
        let model = MeetingsSessionModel()
        var calls: [String] = []
        let meeting = MeetingID()
        model.handlers.start = { _ in calls.append("start") }
        model.handlers.pause = { calls.append("pause") }
        model.handlers.resume = { calls.append("resume") }
        model.handlers.stop = { calls.append("stop") }
        model.handlers.retryProcessing = { _ in calls.append("retry") }
        model.handlers.deleteMeeting = { id in
            #expect(id == meeting)
            calls.append("delete")
        }
        model.startRecording()
        model.pause()
        model.resume()
        model.stop()
        model.retryProcessing(meeting)
        model.deleteMeeting(meeting)
        #expect(calls == ["start", "pause", "resume", "stop", "retry", "delete"])
    }

    @MainActor
    @Test("A row click opens the meeting tab, selected, with no folder")
    func rowClickOpensTab() {
        let workspace = WorkspaceSession()
        let meeting = MeetingID()
        workspace.openMeetingTab(meeting)
        #expect(workspace.auxiliaryTabs == [.meeting(meeting)])
        #expect(workspace.selectedAuxiliaryTab == .meeting(meeting))
        // A second click selects the same tab and adds no second one.
        workspace.openMeetingTab(meeting)
        #expect(workspace.auxiliaryTabs == [.meeting(meeting)])
    }

    @MainActor
    @Test("The title cache holds each listed title and writes only on a change")
    func titleCache() {
        let model = MeetingsSessionModel()
        let first = MeetingID()
        let second = MeetingID()
        model.noteMeetingTitles([(first, "Weekly"), (second, "Standup")])
        #expect(model.meetingTitles == [first: "Weekly", second: "Standup"])
        model.noteMeetingTitle(first, "Weekly sync")
        #expect(model.meetingTitles[first] == "Weekly sync")

        // The same list again: no write, so no tab label redraws.
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.meetingTitles
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.noteMeetingTitles([(first, "Weekly sync"), (second, "Standup")])
        #expect(!changed.withLock { $0 })
        // A deleted meeting leaves the cache with the next full list.
        model.noteMeetingTitles([(second, "Standup")])
        #expect(changed.withLock { $0 })
        #expect(model.meetingTitles == [second: "Standup"])
    }

    @MainActor
    @Test("A meeting tab label falls back to Meeting; other tabs keep their title")
    func tabLabel() {
        #expect(WorkspaceAuxiliaryTab.settings.displayTitle == "Settings")
        let unknown = MeetingID()
        if MeetingsFeatureFactory.shared.feature?.session.meetingTitles[unknown] == nil {
            #expect(WorkspaceAuxiliaryTab.meeting(unknown).displayTitle == "Meeting")
        }
    }

    @MainActor
    @Test("The list model reads rows from a store and keeps no turn text")
    func listModelReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "rafu-meetings-w2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootDirectory: root, diagnostics: NoopMeetingDiagnostics())
        let first = try await store.create(
            title: "Weekly", startDate: Date(timeIntervalSince1970: 100))
        let second = try await store.create(
            title: "Standup", startDate: Date(timeIntervalSince1970: 200))
        let list = MeetingsWorkspaceListModel()
        #expect(!list.isLoaded)
        await list.reload(from: store)
        #expect(list.isLoaded)
        #expect(list.rows.map(\.id) == [second.id, first.id])
        await list.reload(from: nil)
        #expect(list.rows.isEmpty)
    }

    @Test("No file of the two folders calls resolve()")
    func noResolveInSurfaces() throws {
        let files = try Self.sources(in: ["Workspace", "Welcome"])
        #expect(files.count >= 6, "the scan found \(files.count) files")
        for (path, source) in files {
            #expect(!source.contains(".resolve()"), "\(path) must not make the feature")
        }
    }

    @Test("No file of the two folders mentions Canvas or Conductor in a string")
    func noOldNamesInStrings() throws {
        for (path, source) in try Self.sources(in: ["Workspace", "Welcome"]) {
            for line in source.split(separator: "\n") where line.contains("\"") {
                #expect(!line.contains("Canvas"), "\(path): \(line)")
                #expect(!line.contains("Conductor"), "\(path): \(line)")
            }
        }
    }

    private static func sources(in folders: [String], file: StaticString = #filePath) throws
        -> [(String, String)]
    {
        var root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while root.path != "/",
            !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path)
        {
            root = root.deletingLastPathComponent()
        }
        var result: [(String, String)] = []
        for folder in folders {
            let base = root.appending(path: "Sources/RafuApp/Meetings/\(folder)")
            guard let enumerator = FileManager.default.enumerator(atPath: base.path) else {
                continue
            }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                let source = try String(
                    contentsOf: base.appending(path: relative), encoding: .utf8)
                result.append(("\(folder)/\(relative)", source))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
