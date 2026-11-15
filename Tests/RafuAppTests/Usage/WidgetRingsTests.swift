import Foundation
import RafuWidgetShared
import Testing

@testable import RafuApp

// Widget W1: snapshot v2, presentation states, timeline dates, and the
// widget link. Synthetic data only: nothing here reads `~`, the network, or
// a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let ringsNow = Date(timeIntervalSince1970: 1_784_800_800)
private let ringsCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let ringsLocale = Locale(identifier: "en_US")

private let indigoInks = WidgetUsageSnapshot.InkSet(
    accent: "#7C83FD", info: "#82A7F0", success: "#7CC08A", warning: "#E8894A",
    critical: "#E06C75")

/// A weekly window `elapsedHours` into its 7 days, `used` percent used.
private func weekly(used: Double, elapsedHours: Double, label: String = "7d")
    -> WidgetUsageSnapshot.Window
{
    WidgetUsageSnapshot.Window(
        label: label, usedPercent: used,
        resetsAt: ringsNow.addingTimeInterval((168 - elapsedHours) * 3_600),
        windowMinutes: 10_080)
}

private func snapshot(
    providers: [WidgetUsageSnapshot.Provider], writtenAt: Date = ringsNow,
    mode: String = "used", palette: String = "color"
) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        writtenAt: writtenAt, displayMode: mode, palette: palette, isSample: false,
        providers: providers,
        inks: WidgetUsageSnapshot.ThemeInks(light: indigoInks, dark: indigoInks))
}

private func claude(
    _ windows: [WidgetUsageSnapshot.Window], observedAt: Date = ringsNow, isStale: Bool = false
) -> WidgetUsageSnapshot.Provider {
    WidgetUsageSnapshot.Provider(
        id: "claude", displayName: "Claude", observedAt: observedAt, isStale: isStale,
        windows: windows, source: "providerAPI")
}

private func present(_ snapshot: WidgetUsageSnapshot?, at now: Date = ringsNow, max: Int = 2)
    -> WidgetRingsPresentation
{
    WidgetRingsPresentation.make(
        snapshot: snapshot, now: now, maxProviders: max, calendar: ringsCalendar,
        locale: ringsLocale)
}

private func onlyCard(_ presentation: WidgetRingsPresentation) throws -> WidgetProviderCard {
    guard case .providers(let cards) = presentation.content else {
        Issue.record("expected providers, got \(presentation.content)")
        throw CancellationError()
    }
    return try #require(cards.first)
}

@Suite struct WidgetSnapshotV2Tests {
    @Test func roundTripsSettingsInksSourceAndTokenSummary() throws {
        var original = snapshot(
            providers: [
                claude([weekly(used: 41, elapsedHours: 144)]),
                WidgetUsageSnapshot.Provider(
                    id: "codex", displayName: "Codex", observedAt: ringsNow, isStale: true,
                    windows: [], source: "localEstimate", tokenSummary: "7d 1.4M tok"),
            ], mode: "remaining", palette: "monochrome")
        original.inks = WidgetUsageSnapshot.ThemeInks(
            light: indigoInks,
            dark: WidgetUsageSnapshot.InkSet(
                accent: "#AABBCC", info: "#112233", success: "#445566", warning: "#778899",
                critical: "#FF000080"))
        let data = try WidgetSnapshotStore.encode(original)
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(data))
        #expect(decoded == original)
        #expect(decoded.version == WidgetUsageSnapshot.currentVersion)
        #expect(decoded.resolvedDisplayMode == .remaining)
        #expect(decoded.resolvedPalette == .monochrome)
        #expect(decoded.inks?.dark.critical == "#FF000080")
        #expect(decoded.providers[1].tokenSummary == "7d 1.4M tok")
        #expect(decoded.providers[1].source == "localEstimate")
    }

    @Test func decodesAVersionOneFileWithoutTheNewFields() throws {
        let v1 = """
            {"displayMode":"used","isSample":false,"palette":"color","providers":[\
            {"displayName":"Claude","id":"claude","isStale":false,\
            "observedAt":"2026-07-23T10:00:00Z","windows":[{"label":"7d",\
            "resetsAt":"2026-07-24T18:00:00Z","usedPercent":41,"windowMinutes":10080}]}],\
            "version":1,"writtenAt":"2026-07-23T10:00:00Z"}
            """
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(Data(v1.utf8)))
        #expect(decoded.version == 1)
        #expect(decoded.inks == nil)
        #expect(decoded.providers[0].source == nil)
        #expect(decoded.providers[0].tokenSummary == nil)
        #expect(decoded.providers[0].windows[0].usedPercent == 41)
        // A v1 file still renders: system inks, same rings.
        let card = try onlyCard(present(decoded))
        #expect(card.cluster?.centerText == "41%")
    }

    @Test func rejectsAnUnknownFutureVersion() throws {
        var future = snapshot(providers: [claude([weekly(used: 41, elapsedHours: 144)])])
        future.version = 99
        #expect(WidgetSnapshotStore.decodeSupported(try WidgetSnapshotStore.encode(future)) == nil)
        #expect(WidgetSnapshotStore.decodeSupported(Data("not json".utf8)) == nil)
    }

    @Test func unknownSettingsFallBackToUsedAndColor() {
        let odd = snapshot(providers: [], mode: "sideways", palette: "plaid")
        #expect(odd.resolvedDisplayMode == .used)
        #expect(odd.resolvedPalette == .color)
    }

    @Test func publisherCarriesInksSourceAndLocalEstimateTotals() {
        let inks = WidgetUsageSnapshot.ThemeInks(light: indigoInks, dark: indigoInks)
        let exact = UsageSnapshot(
            providerID: .claude,
            windows: [UsageWindow(label: "7d", percent: 41, tokens: nil, resetsAt: nil)],
            costLine: nil, identity: nil, source: .providerAPI)
        let estimate = UsageSnapshot(
            providerID: .codex,
            windows: [UsageWindow(label: "7d", percent: nil, tokens: 1_400_000, resetsAt: nil)],
            costLine: nil, identity: nil, source: .localEstimate)
        let widget = WidgetSnapshotPublisher.makeSnapshot(
            snapshots: [exact, estimate], observedAt: [:], stale: [], mode: .used,
            palette: .color, now: ringsNow, inks: inks)
        #expect(widget.inks == inks)
        #expect(widget.providers.map(\.id) == ["claude", "codex"])
        #expect(widget.providers[0].source == "providerAPI")
        #expect(widget.providers[0].tokenSummary == nil)
        #expect(widget.providers[1].windows.isEmpty)
        #expect(widget.providers[1].tokenSummary == "7d 1.4M tok")
    }

    @Test func fingerprintFollowsInksAndReloadKeepsTheWidgetFresh() {
        let base = snapshot(providers: [claude([weekly(used: 41, elapsedHours: 144)])])
        var recoloured = base
        recoloured.inks?.dark.accent = "#000000"
        #expect(
            WidgetSnapshotPublisher.fingerprint(base)
                != WidgetSnapshotPublisher.fingerprint(recoloured))

        let print = WidgetSnapshotPublisher.fingerprint(base)
        // First publish and any change reload.
        #expect(
            WidgetSnapshotPublisher.shouldReload(
                fingerprint: print, lastFingerprint: nil, lastReloadAt: nil, now: ringsNow))
        #expect(
            WidgetSnapshotPublisher.shouldReload(
                fingerprint: print, lastFingerprint: "other", lastReloadAt: ringsNow,
                now: ringsNow))
        // Unchanged values: no reload until the keep-alive interval.
        #expect(
            !WidgetSnapshotPublisher.shouldReload(
                fingerprint: print, lastFingerprint: print, lastReloadAt: ringsNow,
                now: ringsNow.addingTimeInterval(14 * 60)))
        #expect(
            WidgetSnapshotPublisher.shouldReload(
                fingerprint: print, lastFingerprint: print, lastReloadAt: ringsNow,
                now: ringsNow.addingTimeInterval(15 * 60)))
        #expect(
            WidgetSnapshotPublisher.keepAliveInterval < WidgetRingsPresentation.staleAge)
    }

    @MainActor @Test func themeInkSetUsesTheThemeTokensAndFallbacks() {
        let inks = RafuThemeCatalog.indigo.widgetInkSet
        #expect(inks.accent == RafuThemeCatalog.indigo.ui.accent)
        #expect(inks.info == (RafuThemeCatalog.indigo.ui.info ?? RafuTheme.defaultInfoHex))
        #expect(inks.critical == (RafuThemeCatalog.indigo.ui.error ?? RafuTheme.defaultErrorHex))
        #expect(WidgetRGBA(hex: inks.accent) != nil)
    }

    @Test func hexParsingAcceptsOnlyThemeForms() throws {
        let opaque = try #require(WidgetRGBA(hex: "#FF8000"))
        #expect(opaque.red == 1)
        #expect(abs(opaque.green - 128.0 / 255) < 0.0001)
        #expect(opaque.blue == 0)
        #expect(opaque.alpha == 1)
        let translucent = try #require(WidgetRGBA(hex: "00000080"))
        #expect(abs(translucent.alpha - 128.0 / 255) < 0.0001)
        for bad in ["", "#", "#FFF", "#GGGGGG", "#FF80001", "red", "#ＦＦ8000", "#+F8000"] {
            #expect(WidgetRGBA(hex: bad) == nil, "\(bad)")
        }
    }
}

@Suite struct WidgetRingsPresentationTests {
    @Test func noSnapshotIsNotConnected() {
        let presentation = present(nil)
        #expect(presentation.content == .notConnected(.noData))
        #expect(presentation.accessibilityLabel.contains("not connected"))
        #expect(present(snapshot(providers: [])).content == .notConnected(.noData))
    }

    @Test func aSnapshotOlderThanSixHoursMeansRafuIsNotRunning() {
        let old = snapshot(
            providers: [claude([weekly(used: 41, elapsedHours: 144)])],
            writtenAt: ringsNow.addingTimeInterval(-6 * 3_600 - 1))
        #expect(present(old).content == .notConnected(.rafuNotRunning))
    }

    @Test func freshDataUsesTheAppsClusterAndPace() throws {
        // 41 % after 6 of 7 days projects ~48 % at reset: ~52 % spare.
        let fresh = snapshot(
            providers: [claude([weekly(used: 41, elapsedHours: 144)])])
        let card = try onlyCard(present(fresh))
        let window = UsageWindow(
            label: "7d", percent: 41, tokens: nil,
            resetsAt: ringsNow.addingTimeInterval(24 * 3_600), windowMinutes: 10_080)
        let appCluster = UsageRingClusterBuilder.make(
            snapshot: UsageSnapshot(
                providerID: .claude, windows: [window], costLine: nil, identity: nil),
            observedAt: ringsNow, mode: .used, displayName: "Claude", now: ringsNow,
            calendar: ringsCalendar, locale: ringsLocale)
        #expect(card.cluster == appCluster)
        guard case .pace(let pace) = card.status else {
            Issue.record("expected a pace status, got \(card.status)")
            return
        }
        #expect(pace.state == .enough)
        #expect(card.status.shortText(now: ringsNow) == "✓ On pace")
        #expect(card.status.longText(now: ringsNow) == "On pace · ~52% spare at reset")
        #expect(card.resetsAt == ringsNow.addingTimeInterval(24 * 3_600))
        #expect(!card.isDimmed)
        #expect(
            card.accessibilityLabel
                == "Claude, Weekly 41%, resets Friday, on pace, about 52 percent spare at reset")
    }

    @Test func remainingModeFlipsTheRingButNotTheLevel() throws {
        let fresh = snapshot(
            providers: [claude([weekly(used: 97, elapsedHours: 160)])], mode: "remaining")
        let card = try onlyCard(present(fresh))
        #expect(card.cluster?.centerText == "3%")
        #expect(card.cluster?.arcs.first?.level == .critical)
        #expect(card.accessibilityLabel.hasPrefix("Claude remaining, Weekly 3%"))
    }

    @Test func runningOutNamesTheTimeLeft() throws {
        // 60 % after 2 of 7 days: 30 %/day, out in ~32 h.
        let card = try onlyCard(
            present(snapshot(providers: [claude([weekly(used: 60, elapsedHours: 48)])])))
        guard case .pace(let pace) = card.status else {
            Issue.record("expected a pace status")
            return
        }
        #expect(pace.state == .runningOut)
        #expect(card.status.level == .warning)
        #expect(card.status.shortText(now: ringsNow) == "▲ Out in ~1d")
        #expect(card.status.longText(now: ringsNow).hasPrefix("May run out in "))
        #expect(card.accessibilityLabel.hasSuffix("may run out in 1 day"))
    }

    @Test func atLimitWinsOverAFreshLeadingWindow() throws {
        let card = try onlyCard(
            present(
                snapshot(providers: [
                    claude([
                        weekly(used: 10, elapsedHours: 100),
                        weekly(used: 100, elapsedHours: 100, label: "Fable 7d"),
                    ])
                ])))
        #expect(card.status.level == .critical)
        #expect(card.status.shortText(now: ringsNow) == "■ At limit")
        #expect(card.status.longText(now: ringsNow) == "Limit reached · wait for reset")
    }

    @Test func staleAfterTwentyMinutesDimsAndDropsThePace() throws {
        let fresh = snapshot(providers: [claude([weekly(used: 41, elapsedHours: 144)])])
        let later = ringsNow.addingTimeInterval(20 * 60 + 1)
        let card = try onlyCard(present(fresh, at: later))
        #expect(card.status == .stale(age: 20 * 60 + 1))
        #expect(card.isDimmed)
        #expect(card.status.shortText(now: later) == "⚠ 20m old")
        #expect(card.accessibilityLabel.hasSuffix("data 20 minutes old, open Rafu to refresh"))

        // At exactly 20 minutes the data is still current.
        let edge = try onlyCard(present(fresh, at: ringsNow.addingTimeInterval(20 * 60)))
        #expect(!edge.isDimmed)
    }

    @Test func aFailedRefreshIsStaleAtOnce() throws {
        let failed = snapshot(
            providers: [claude([weekly(used: 41, elapsedHours: 144)], isStale: true)])
        #expect(try onlyCard(present(failed)).status == .stale(age: 0))
    }

    @Test func aPassedResetAsksForARefresh() throws {
        // The weekly window resets one hour from now.
        let fresh = snapshot(providers: [claude([weekly(used: 41, elapsedHours: 167)])])
        let afterReset = ringsNow.addingTimeInterval(3_600)
        let card = try onlyCard(present(fresh, at: afterReset))
        #expect(card.status == .resetPassed)
        #expect(card.resetsAt == nil)
        #expect(card.isDimmed)
    }

    @Test func localEstimateShowsTotalsWithoutARing() throws {
        let estimate = snapshot(providers: [
            WidgetUsageSnapshot.Provider(
                id: "claude", displayName: "Claude", observedAt: ringsNow, isStale: false,
                windows: [], source: "localEstimate", tokenSummary: "7d 1.4M tok")
        ])
        let card = try onlyCard(present(estimate))
        #expect(card.cluster == nil)
        #expect(card.status == .localEstimate)
        #expect(card.tokenSummary == "7d 1.4M tok")
        #expect(card.status.shortText(now: ringsNow) == "Estimated")
    }

    @Test func smallShowsOneProviderAndMediumTwo() {
        let codex = WidgetUsageSnapshot.Provider(
            id: "codex", displayName: "Codex", observedAt: ringsNow, isStale: false,
            windows: [weekly(used: 34, elapsedHours: 80)], source: "providerAPI")
        let both = snapshot(providers: [claude([weekly(used: 41, elapsedHours: 144)]), codex])
        guard case .providers(let small) = present(both, max: 1).content,
            case .providers(let medium) = present(both, max: 2).content
        else {
            Issue.record("expected providers")
            return
        }
        #expect(small.map(\.id) == ["claude"])
        #expect(medium.map(\.id) == ["claude", "codex"])
        let label = present(both, max: 2).accessibilityLabel
        #expect(label.contains("Claude, Weekly 41%"))
        #expect(label.contains(". Codex, Weekly 34%"))
    }
}

@Suite struct WidgetTimelinePlanTests {
    @Test func withoutDataTheTimelineIsHourly() {
        let dates = WidgetTimelinePlan.entryDates(snapshot: nil, now: ringsNow)
        #expect(dates == (0...6).map { ringsNow.addingTimeInterval(Double($0) * 3_600) })
    }

    @Test func addsResetStaleAndAbandonPointsWithinSixHours() {
        let soonReset = WidgetUsageSnapshot.Window(
            label: "5h", usedPercent: 12, resetsAt: ringsNow.addingTimeInterval(90 * 60),
            windowMinutes: 300)
        let farReset = weekly(used: 41, elapsedHours: 144)  // in 24 h: outside
        let written = ringsNow.addingTimeInterval(-5 * 60)
        let data = snapshot(
            providers: [claude([farReset, soonReset], observedAt: written)], writtenAt: written)
        let dates = WidgetTimelinePlan.entryDates(snapshot: data, now: ringsNow)

        #expect(dates.first == ringsNow)
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
        // The 20-minute stale point (writtenAt + 20 min = now + 15 min).
        #expect(dates.contains(ringsNow.addingTimeInterval(15 * 60)))
        // The 5h window's reset.
        #expect(dates.contains(ringsNow.addingTimeInterval(90 * 60)))
        // The 6-hour abandon point (writtenAt + 6 h = now + 5 h 55 m).
        #expect(dates.contains(ringsNow.addingTimeInterval(6 * 3_600 - 5 * 60)))
        // Hourly up to six hours, nothing later.
        for hour in 1...6 {
            #expect(dates.contains(ringsNow.addingTimeInterval(Double(hour) * 3_600)))
        }
        #expect(!dates.contains(ringsNow.addingTimeInterval(24 * 3_600)))
        #expect(dates.allSatisfy { $0 <= ringsNow.addingTimeInterval(WidgetTimelinePlan.horizon) })
        #expect(dates.count == 1 + 6 + 3)
    }

    @Test func pastPointsAreDropped() {
        let written = ringsNow.addingTimeInterval(-30 * 60)
        let data = snapshot(
            providers: [claude([weekly(used: 41, elapsedHours: 144)], observedAt: written)],
            writtenAt: written)
        let dates = WidgetTimelinePlan.entryDates(snapshot: data, now: ringsNow)
        // Stale point already passed; abandon point at now + 5 h 30 m remains.
        #expect(!dates.contains(written.addingTimeInterval(20 * 60)))
        #expect(dates.contains(ringsNow.addingTimeInterval(5.5 * 3_600)))
        #expect(dates.count == 1 + 6 + 1)
    }
}

@Suite struct RafuDeepLinkTests {
    @Test func eachVariantHasItsOwnScheme() {
        #expect(RafuDeepLink.scheme(forBundleIdentifier: "dev.vatsalsaglani.rafu") == "rafu")
        #expect(
            RafuDeepLink.scheme(forBundleIdentifier: "dev.vatsalsaglani.rafu.widgets") == "rafu")
        #expect(
            RafuDeepLink.scheme(forBundleIdentifier: "dev.vatsalsaglani.rafu.lightning")
                == "rafu-lightning")
        #expect(
            RafuDeepLink.scheme(forBundleIdentifier: "dev.vatsalsaglani.rafu.lightning.widgets")
                == "rafu-lightning")
        #expect(
            RafuDeepLink.scheme(forBundleIdentifier: "dev.vatsalsaglani.rafu.lightningX") == "rafu")
        #expect(RafuDeepLink.scheme(forBundleIdentifier: nil) == "rafu")
        #expect(RafuDeepLink.usageURL(scheme: "rafu").absoluteString == "rafu://usage")
        #expect(
            RafuDeepLink.usageURL(scheme: "rafu-lightning").absoluteString
                == "rafu-lightning://usage")
    }

    @Test func acceptsOnlyTheExactUsageLink() throws {
        func accepts(_ text: String, _ scheme: String = "rafu") throws -> Bool {
            RafuDeepLink.isUsageLink(try #require(URL(string: text)), scheme: scheme)
        }
        #expect(try accepts("rafu://usage"))
        #expect(try accepts("rafu://usage/"))
        #expect(try accepts("RAFU://usage"))
        #expect(try accepts("rafu-lightning://usage", "rafu-lightning"))

        let rejected = [
            "rafu-lightning://usage",  // the other variant's scheme
            "rafu://usage?provider=claude",
            "rafu://usage?",
            "rafu://usage#top",
            "rafu://usage/claude",
            "rafu://usage/../settings",
            "rafu://settings/usage",
            "rafu://USAGE",
            "rafu://us%61ge",
            "rafu://user@usage",
            "rafu://user:secret@usage",
            "rafu://usage:8080",
            "rafu:usage",
            "rafu:///usage",
            "rafu://",
            "file:///usage",
            "https://usage",
            "https://example.com/rafu://usage",
            "rafu://usage/" + String(repeating: "a", count: 80),
        ]
        for text in rejected {
            #expect(try !accepts(text), "\(text)")
        }
        #expect(try !accepts("rafu://usage", "rafu-lightning"))
    }

    @Test func schemeOwnershipIsCaseInsensitiveAndExact() throws {
        #expect(RafuDeepLink.usesScheme(try #require(URL(string: "RaFu://x")), scheme: "rafu"))
        #expect(
            !RafuDeepLink.usesScheme(
                try #require(URL(string: "rafu-lightning://x")), scheme: "rafu"))
        #expect(
            !RafuDeepLink.usesScheme(URL(filePath: "/Users/example/rafu"), scheme: "rafu"))
    }

    @Test func linkTargetPrefersTheMenuBarThenThePanelThenSettings() {
        #expect(
            UsageDeepLinkTarget.resolve(
                hasMenuBarItem: true, hasPanel: true, panelOffersUsage: true)
                == .menuBarCard)
        #expect(
            UsageDeepLinkTarget.resolve(
                hasMenuBarItem: false, hasPanel: true, panelOffersUsage: true)
                == .companionPanel)
        #expect(
            UsageDeepLinkTarget.resolve(
                hasMenuBarItem: false, hasPanel: true, panelOffersUsage: false) == .settings)
        #expect(
            UsageDeepLinkTarget.resolve(
                hasMenuBarItem: false, hasPanel: false, panelOffersUsage: true) == .settings)
    }

    @Test func theStagedInfoPlistRegistersTheSameSchemes() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appending(path: "Package.swift").path)
        {
            let parent = directory.deletingLastPathComponent()
            try #require(parent.path != directory.path)
            directory = parent
        }
        let script = try String(
            contentsOf: directory.appending(path: "script/build_and_run.sh"), encoding: .utf8)
        #expect(script.contains("URL_SCHEME=\"\(RafuDeepLink.lightningScheme)\""))
        #expect(script.contains("URL_SCHEME=\"\(RafuDeepLink.releaseScheme)\""))
        #expect(script.contains("<key>CFBundleURLSchemes</key>"))
    }
}
