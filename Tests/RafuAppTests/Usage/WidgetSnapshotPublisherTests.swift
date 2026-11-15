import Foundation
import RafuWidgetShared
import Testing

@testable import RafuApp

// SPIKE (widget packaging). Synthetic data only: no test here reads or
// writes `~`; `WidgetSnapshotStore.directory(appName:home:)` takes the home.

private let widgetNow = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct WidgetSnapshotPublisherTests {
    @Test func mapsPercentWindowsAndDropsIdentityAndTokenOnlyProviders() {
        let claude = UsageSnapshot(
            providerID: .claude,
            windows: [
                UsageWindow(
                    label: "7d", percent: 41, tokens: nil,
                    resetsAt: widgetNow.addingTimeInterval(3_600), windowMinutes: 10_080),
                UsageWindow(label: "5h", percent: nil, tokens: 12_000, resetsAt: nil),
            ],
            costLine: nil, identity: "someone@example.com")
        let tokenOnly = UsageSnapshot(
            providerID: .codex,
            windows: [UsageWindow(label: "7d", percent: nil, tokens: 99, resetsAt: nil)],
            costLine: nil, identity: nil)

        let snapshot = WidgetSnapshotPublisher.makeSnapshot(
            snapshots: [claude, tokenOnly], observedAt: [.claude: widgetNow],
            stale: [.claude], mode: .remaining, palette: .monochrome, now: widgetNow)

        #expect(snapshot.providers.map(\.id) == ["claude"])
        #expect(snapshot.providers[0].windows.map(\.label) == ["7d"])
        #expect(snapshot.providers[0].windows[0].usedPercent == 41)
        #expect(snapshot.providers[0].isStale)
        #expect(snapshot.displayMode == "remaining")
        #expect(snapshot.palette == "monochrome")
        #expect(!snapshot.isSample)
    }

    @Test func encodedSnapshotCarriesNoIdentity() throws {
        let claude = UsageSnapshot(
            providerID: .claude,
            windows: [UsageWindow(label: "7d", percent: 41, tokens: nil, resetsAt: nil)],
            costLine: nil, identity: "someone@example.com")
        let snapshot = WidgetSnapshotPublisher.makeSnapshot(
            snapshots: [claude], observedAt: [:], stale: [], mode: .used, palette: .color,
            now: widgetNow)
        let json = String(decoding: try WidgetSnapshotStore.encode(snapshot), as: UTF8.self)
        #expect(!json.contains("someone@example.com"))
        #expect(try WidgetSnapshotStore.decode(Data(json.utf8)) == snapshot)
    }

    @Test func fingerprintChangesOnlyWhenAShownValueChanges() {
        func snapshot(_ percent: Double, at date: Date) -> WidgetUsageSnapshot {
            WidgetSnapshotPublisher.makeSnapshot(
                snapshots: [
                    UsageSnapshot(
                        providerID: .claude,
                        windows: [
                            UsageWindow(label: "7d", percent: percent, tokens: nil, resetsAt: nil)
                        ],
                        costLine: nil, identity: nil)
                ], observedAt: [:], stale: [], mode: .used, palette: .color, now: date)
        }
        let base = WidgetSnapshotPublisher.fingerprint(snapshot(41.2, at: widgetNow))
        let sameShown = WidgetSnapshotPublisher.fingerprint(
            snapshot(40.8, at: widgetNow.addingTimeInterval(180)))
        let changed = WidgetSnapshotPublisher.fingerprint(snapshot(42, at: widgetNow))
        #expect(base == sameShown)
        #expect(base != changed)
    }

    @Test func storeDirectoryIsPerVariant() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        #expect(
            WidgetSnapshotStore.fileURL(appName: "Rafu Lightning", home: home).path
                == "/Users/example/Library/Application Support/Rafu Lightning/Widgets/usage-snapshot.json"
        )
        #expect(
            WidgetSnapshotStore.directory(appName: "Rafu", home: home).path
                == "/Users/example/Library/Application Support/Rafu/Widgets")
    }

    @Test func hostAppNameIsNilOutsideAStagedBundle() {
        // Tests run inside xctest/swiftpm-testing-helper, never a Rafu bundle,
        // so the publisher never writes to the user's home during tests.
        #expect(WidgetSnapshotPublisher.hostAppName == nil)
    }
}
