import Foundation
import Testing

@testable import RafuApp

/// terminal-notch-hud.md N-A: the pure core — `NotchHUDGeometry`,
/// `NotchHUDPolicy`, and the `TerminalAttentionSurface` preference store
/// with its legacy-boolean migration. Everything here is headless: no
/// `NSScreen`, no window, no `UserNotifications`.
///
/// The probed metrics below are this machine's real ones, copied from the
/// phase brief: a 1710×1107 built-in screen with a 33pt top safe-area
/// inset and auxiliary top areas (0,1074,763,33) / (948,1074,762,33),
/// which derive a notch rect of (763,1074,185,33).

private let realNotchMetrics = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
    visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
    safeAreaTopInset: 33,
    auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 763, height: 33),
    auxiliaryTopRight: CGRect(x: 948, y: 1074, width: 762, height: 33)
)

// MARK: - notchRect

@Test("notchRect derives the real notch band from this machine's probed metrics")
func notchRectFromRealMetrics() {
    #expect(
        NotchHUDGeometry.notchRect(for: realNotchMetrics)
            == CGRect(x: 763, y: 1074, width: 185, height: 33))
}

@Test("notchRect is nil for a zero inset, nil auxiliary areas, or a non-positive derived width")
func notchRectNilCases() {
    let zeroInset = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
        safeAreaTopInset: 0,
        auxiliaryTopLeft: CGRect(x: 0, y: 1056, width: 900, height: 24),
        auxiliaryTopRight: CGRect(x: 1020, y: 1056, width: 900, height: 24)
    )
    #expect(NotchHUDGeometry.notchRect(for: zeroInset) == nil)

    // A synthetic ultrawide: no notch, both auxiliary areas nil.
    let ultrawide = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1416),
        safeAreaTopInset: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )
    #expect(NotchHUDGeometry.notchRect(for: ultrawide) == nil)

    // Inset present but only ONE auxiliary area — not a notch we can bound.
    let oneSided = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
        safeAreaTopInset: 33,
        auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 763, height: 33),
        auxiliaryTopRight: nil
    )
    #expect(NotchHUDGeometry.notchRect(for: oneSided) == nil)

    // Overlapping auxiliary areas would derive a negative width.
    let overlapping = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
        safeAreaTopInset: 33,
        auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 900, height: 33),
        auxiliaryTopRight: CGRect(x: 800, y: 1074, width: 762, height: 33)
    )
    #expect(NotchHUDGeometry.notchRect(for: overlapping) == nil)
}

// MARK: - hudFrame

@Test("hudFrame is flush with the SCREEN top so the band merges with the housing")
func hudFrameBelowNotch() {
    let frame = NotchHUDGeometry.hudFrame(
        for: realNotchMetrics,
        contentSize: CGSize(width: 384, height: 52),
        state: .compact
    )
    // SEAMLESS contract: the window's top edge sits at the screen top
    // (1107), its height is content (52) PLUS the 33pt band the view fills
    // housing-black, and it centers on the notch (midX 855.5 → x 663.5).
    #expect(frame == CGRect(x: 663.5, y: 1022, width: 384, height: 85))
    #expect(frame.maxY == realNotchMetrics.frame.maxY)
    #expect(NotchHUDGeometry.bandInset(for: realNotchMetrics) == 33)
    #expect(realNotchMetrics.frame.contains(frame))

    // A content size NARROWER than the notch still matches the notch width.
    let narrow = NotchHUDGeometry.hudFrame(
        for: realNotchMetrics,
        contentSize: CGSize(width: 120, height: 52),
        state: .compact
    )
    #expect(narrow.width == 185)
    #expect(narrow.midX == 855.5)
}

@Test("hudFrame clamps inside the screen frame for oversized content")
func hudFrameClampsWithinFrame() {
    let metrics = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 576),
        safeAreaTopInset: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )
    let frame = NotchHUDGeometry.hudFrame(
        for: metrics,
        contentSize: CGSize(width: 1200, height: 900),
        state: .expanded
    )
    #expect(metrics.frame.contains(frame))
}

@Test("hudFrame without a notch anchors top-center just below the menu bar")
func hudFrameNonNotchFallback() {
    // External 1080p display right of the built-in: 24pt menu bar, no
    // safe-area inset, no auxiliary areas.
    let metrics = NotchScreenMetrics(
        frame: CGRect(x: 1710, y: -263, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1710, y: -263, width: 1920, height: 1056),
        safeAreaTopInset: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )
    let frame = NotchHUDGeometry.hudFrame(
        for: metrics,
        contentSize: CGSize(width: 384, height: 52),
        state: .compact
    )
    #expect(frame.midX == metrics.frame.midX)
    #expect(frame.maxY == metrics.visibleFrame.maxY)
    #expect(metrics.frame.contains(frame))
}

@Test("hudFrame expanded grows downward only — same top edge and width as compact")
func hudFrameExpandedGrowsDownwardOnly() {
    let compact = NotchHUDGeometry.hudFrame(
        for: realNotchMetrics,
        contentSize: CGSize(width: 384, height: 52),
        state: .compact
    )
    let expanded = NotchHUDGeometry.hudFrame(
        for: realNotchMetrics,
        contentSize: CGSize(width: 384, height: 210),
        state: .expanded
    )
    #expect(expanded.maxY == compact.maxY)
    #expect(expanded.minX == compact.minX)
    #expect(expanded.width == compact.width)
    #expect(expanded.minY < compact.minY)
}

// MARK: - NotchHUDPolicy.merge (queue of one)

@Test(
    "merge: newest event wins; superseded sessions count toward the +N chip; a same-session re-bell refreshes without counting"
)
func mergeQueueOfOneSemantics() {
    let first = NotchHUDEvent(sessionID: UUID(), title: "zsh 1", snippet: "a", color: nil)
    let second = NotchHUDEvent(sessionID: UUID(), title: "zsh 2", snippet: "b", color: .info)

    // Fresh show: nothing superseded.
    let fresh = NotchHUDPolicy.merge(current: nil, incoming: first, pendingCount: 0)
    #expect(fresh.shown == first)
    #expect(fresh.pendingCount == 0)

    // A different session bells while the HUD is up: newest wins, count 1.
    let superseded = NotchHUDPolicy.merge(
        current: fresh.shown, incoming: second, pendingCount: fresh.pendingCount)
    #expect(superseded.shown == second)
    #expect(superseded.pendingCount == 1)

    // A third session: the count grows.
    let third = NotchHUDEvent(sessionID: UUID(), title: "zsh 3", snippet: "c", color: nil)
    let again = NotchHUDPolicy.merge(
        current: superseded.shown, incoming: third, pendingCount: superseded.pendingCount)
    #expect(again.shown == third)
    #expect(again.pendingCount == 2)

    // The SHOWN session re-bells (new snippet): replace, count unchanged.
    let refreshed = NotchHUDEvent(
        sessionID: third.sessionID, title: third.title, snippet: "c2", color: nil)
    let reBell = NotchHUDPolicy.merge(
        current: again.shown, incoming: refreshed, pendingCount: again.pendingCount)
    #expect(reBell.shown == refreshed)
    #expect(reBell.pendingCount == 2)
}

// MARK: - NotchHUDPolicy.shouldDismiss

@Test(
    "shouldDismiss truth table: reply/Escape/cleared-attention dismiss immediately; the 12s timer dismisses only when not hovered"
)
func shouldDismissTruthTable() {
    // Immediate reasons win over everything else.
    #expect(
        NotchHUDPolicy.shouldDismiss(
            didReply: true, escapePressed: false, secondsSinceInteraction: 0,
            stillNeedsAttention: true, isHovered: true))
    #expect(
        NotchHUDPolicy.shouldDismiss(
            didReply: false, escapePressed: true, secondsSinceInteraction: 0,
            stillNeedsAttention: true, isHovered: true))
    #expect(
        NotchHUDPolicy.shouldDismiss(
            didReply: false, escapePressed: false, secondsSinceInteraction: 0,
            stillNeedsAttention: false, isHovered: true))

    // Timer: boundary at 12s, and hovering pauses it indefinitely.
    #expect(
        !NotchHUDPolicy.shouldDismiss(
            didReply: false, escapePressed: false, secondsSinceInteraction: 11.9,
            stillNeedsAttention: true, isHovered: false))
    #expect(
        NotchHUDPolicy.shouldDismiss(
            didReply: false, escapePressed: false, secondsSinceInteraction: 12.0,
            stillNeedsAttention: true, isHovered: false))
    #expect(
        !NotchHUDPolicy.shouldDismiss(
            didReply: false, escapePressed: false, secondsSinceInteraction: 3600,
            stillNeedsAttention: true, isHovered: true))
}

// MARK: - NotchHUDPolicy.surfaces (arbitration)

@Test(
    "surfaces: .hud never depends on authorization; .notification always does; .both follows authorization; .none suppresses all"
)
func surfacesArbitrationTable() {
    for authorized in [true, false] {
        #expect(NotchHUDPolicy.surfaces(for: .hud, authorized: authorized) == (false, true))
        #expect(
            NotchHUDPolicy.surfaces(for: .notification, authorized: authorized)
                == (authorized, false))
        #expect(
            NotchHUDPolicy.surfaces(for: .both, authorized: authorized) == (authorized, true))
        #expect(NotchHUDPolicy.surfaces(for: .none, authorized: authorized) == (false, false))
    }
}

// MARK: - TerminalAttentionSurfaceStore (migration + round-trip)

@Test("Store: a completely fresh suite migrates to .both and writes the new key")
func storeMigratesAbsentToBoth() throws {
    let suiteName = "NotchHUDCoreTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)

    #expect(store.surface() == .both)
    // The migration wrote the new key so the legacy key is never read again.
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    #expect(defaults.string(forKey: TerminalAttentionSurfaceStore.defaultsKey) == "both")
}

@Test(
    "Store: legacy true migrates to .both; legacy false migrates to .none; the legacy key is removed either way"
)
func storeMigratesLegacyBoolean() throws {
    for (legacy, expected) in [(true, TerminalAttentionSurface.both), (false, .none)] {
        let suiteName = "NotchHUDCoreTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(legacy, forKey: TerminalAttentionSurfaceStore.legacyEnabledKey)

        let store = TerminalAttentionSurfaceStore(suiteName: suiteName)
        #expect(store.surface() == expected)
        #expect(defaults.object(forKey: TerminalAttentionSurfaceStore.legacyEnabledKey) == nil)
        #expect(
            defaults.string(forKey: TerminalAttentionSurfaceStore.defaultsKey)
                == expected.rawValue)
    }
}

@Test("Store: an existing new-key value wins over a stale legacy boolean")
func storeNewKeyWinsOverLegacy() throws {
    let suiteName = "NotchHUDCoreTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(
        TerminalAttentionSurface.hud.rawValue, forKey: TerminalAttentionSurfaceStore.defaultsKey)
    defaults.set(false, forKey: TerminalAttentionSurfaceStore.legacyEnabledKey)

    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)
    #expect(store.surface() == .hud)
}

@Test("Store: all four raw values round-trip")
func storeRoundTripsAllSurfaces() {
    let suiteName = "NotchHUDCoreTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)

    for surface in TerminalAttentionSurface.allCases {
        store.setSurface(surface)
        #expect(store.surface() == surface)
    }
    #expect(TerminalAttentionSurface.allCases.count == 4)
}
