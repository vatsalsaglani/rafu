import Foundation
import Testing

@testable import RafuApp

/// Settings ▸ Appearance ▸ Window background: the pure resolver, the
/// persisted strings, and the one-time move from the frosted-base spike.
@Suite("Window surface preference")
struct WindowSurfacePreferenceTests {
    private static func resolve(
        _ style: String?, _ level: String? = nil, isDark: Bool = true,
        reduceTransparency: Bool = false, increaseContrast: Bool = false
    ) -> WindowSurfacePreference.Resolved {
        WindowSurfacePreference.resolve(
            style: style, level: level, isDark: isDark,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    }

    @Test("Solid is the default, and an unknown style is Solid")
    func defaultsToSolid() {
        #expect(Self.resolve(nil) == .solid)
        #expect(Self.resolve("") == .solid)
        #expect(Self.resolve("solid") == .solid)
        #expect(Self.resolve("glass") == .solid)
        #expect(Self.resolve("Frosted") == .solid)
        #expect(!WindowSurfacePreference.Resolved.solid.isFrosted)
        #expect(WindowSurfacePreference.Resolved.solid.tintOpacity == 1)
    }

    @Test("Frosted maps each strength to its tint, per theme appearance")
    func frostedTints() {
        // Dark: Balanced 0.50 is the value the user chose in Indigo.
        #expect(Self.resolve("frosted", "subtle", isDark: true).tintOpacity == 0.62)
        #expect(Self.resolve("frosted", "balanced", isDark: true).tintOpacity == 0.50)
        #expect(Self.resolve("frosted", "strong", isDark: true).tintOpacity == 0.38)
        #expect(Self.resolve("frosted", "subtle", isDark: false).tintOpacity == 0.86)
        #expect(Self.resolve("frosted", "balanced", isDark: false).tintOpacity == 0.74)
        #expect(Self.resolve("frosted", "strong", isDark: false).tintOpacity == 0.60)
        #expect(Self.resolve("frosted", "balanced").isFrosted)
    }

    @Test("A missing or unknown strength is Balanced")
    func unknownLevelIsBalanced() {
        #expect(Self.resolve("frosted", nil, isDark: true) == Self.resolve("frosted", "balanced"))
        #expect(
            Self.resolve("frosted", "max", isDark: false)
                == Self.resolve("frosted", "balanced", isDark: false))
        #expect(Self.resolve("frosted", nil, isDark: true).tintOpacity == 0.50)
    }

    @Test("Stronger frost always shows more of the desktop, inside sane bounds")
    func tintsAreMonotonicAndBounded() {
        for isDark in [true, false] {
            let tints = WindowSurfacePreference.FrostLevel.allCases.map {
                WindowSurfacePreference.tintOpacity(for: $0, isDark: isDark)
            }
            #expect(tints == tints.sorted(by: >))
            for tint in tints {
                #expect(tint >= 0.35 && tint < 1)
            }
        }
        // A light tint is more opaque than the dark one at the same strength:
        // a dark tint over a bright desktop already reads darker.
        for level in WindowSurfacePreference.FrostLevel.allCases {
            #expect(
                WindowSurfacePreference.tintOpacity(for: level, isDark: false)
                    > WindowSurfacePreference.tintOpacity(for: level, isDark: true))
        }
    }

    @Test(
        "Reduce Transparency or Increase Contrast forces Solid for every setting",
        arguments: [true, false])
    func accessibilityForcesSolid(isDark: Bool) {
        let styles: [String?] = [nil, "solid", "frosted"]
        let levels: [String?] = [nil] + WindowSurfacePreference.FrostLevel.allCases.map(\.rawValue)
        for style in styles {
            for level in levels {
                #expect(
                    Self.resolve(style, level, isDark: isDark, reduceTransparency: true) == .solid)
                #expect(
                    Self.resolve(style, level, isDark: isDark, increaseContrast: true) == .solid)
                #expect(
                    Self.resolve(
                        style, level, isDark: isDark, reduceTransparency: true,
                        increaseContrast: true) == .solid)
            }
        }
    }

    @Test("The Settings footnote names the setting that forces Solid")
    func forcedSolidReason() {
        typealias Preference = WindowSurfacePreference
        #expect(
            Preference.forcedSolidReason(reduceTransparency: false, increaseContrast: false) == nil)
        #expect(
            Preference.forcedSolidReason(reduceTransparency: true, increaseContrast: false)
                == .reduceTransparency)
        #expect(
            Preference.forcedSolidReason(reduceTransparency: false, increaseContrast: true)
                == .increaseContrast)
        // Reduce Transparency wins: macOS usually turns it on with Increase
        // Contrast.
        #expect(
            Preference.forcedSolidReason(reduceTransparency: true, increaseContrast: true)
                == .reduceTransparency)
        #expect(
            Preference.ForcedSolidReason.reduceTransparency.explanation.contains(
                "Reduce Transparency"))
        #expect(
            Preference.ForcedSolidReason.increaseContrast.explanation.contains("Increase Contrast"))
    }

    @Test("The persisted keys and raw values are stable")
    func persistedStrings() throws {
        #expect(WindowSurfacePreference.styleKey == "windowSurfaceStyle")
        #expect(WindowSurfacePreference.frostLevelKey == "windowSurfaceFrost")
        #expect(WindowSurfacePreference.frostContentKey == "windowSurfaceFrostContent")
        #expect(WindowSurfacePreference.Style.allCases.map(\.rawValue) == ["solid", "frosted"])
        #expect(
            WindowSurfacePreference.FrostLevel.allCases.map(\.rawValue)
                == ["subtle", "balanced", "strong"])
        #expect(WindowSurfacePreference.Style.allCases.map(\.title) == ["Solid", "Frosted"])
        #expect(
            WindowSurfacePreference.FrostLevel.allCases.map(\.title)
                == ["Subtle", "Balanced", "Strong"])

        let suite = TestDefaultsSuite.name("window-surface")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(
            WindowSurfacePreference.Style.frosted.rawValue, forKey: WindowSurfacePreference.styleKey
        )
        defaults.set(
            WindowSurfacePreference.FrostLevel.strong.rawValue,
            forKey: WindowSurfacePreference.frostLevelKey)
        let reread = try #require(UserDefaults(suiteName: suite))
        let resolved = WindowSurfacePreference.resolve(
            style: reread.string(forKey: WindowSurfacePreference.styleKey),
            level: reread.string(forKey: WindowSurfacePreference.frostLevelKey),
            isDark: false, reduceTransparency: false, increaseContrast: false)
        #expect(resolved.isFrosted)
        #expect(resolved.tintOpacity == 0.60)
    }

    // MARK: Spike migration

    @Test("A spike build that showed frost keeps it as Frosted, Balanced")
    func migratesVisualEffectSpike() throws {
        let suite = TestDefaultsSuite.name("window-surface-migration")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("visualEffect", forKey: "RafuFrostSpike")
        defaults.set("hudWindow", forKey: "RafuFrostSpikeMaterial")
        defaults.set(0.5, forKey: "RafuFrostSpikeTint")
        defaults.set(true, forKey: "RafuFrostSpikeTerminalProbe")

        #expect(WindowSurfacePreference.migrateFrostSpike(defaults: defaults))

        #expect(defaults.string(forKey: WindowSurfacePreference.styleKey) == "frosted")
        #expect(defaults.string(forKey: WindowSurfacePreference.frostLevelKey) == "balanced")
        for key in WindowSurfacePreference.spikeKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) was not removed")
        }
        // Runs once: a second launch finds nothing to do.
        #expect(!WindowSurfacePreference.migrateFrostSpike(defaults: defaults))
        #expect(defaults.string(forKey: WindowSurfacePreference.styleKey) == "frosted")
    }

    @Test("Other spike mechanisms are removed without turning frost on")
    func otherSpikeValuesOnlyClean() throws {
        let suite = TestDefaultsSuite.name("window-surface-migration")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("glass", forKey: "RafuFrostSpike")
        defaults.set("clip", forKey: "RafuFrostSpikeWedge")

        #expect(!WindowSurfacePreference.migrateFrostSpike(defaults: defaults))

        #expect(defaults.object(forKey: WindowSurfacePreference.styleKey) == nil)
        #expect(defaults.object(forKey: "RafuFrostSpike") == nil)
        #expect(defaults.object(forKey: "RafuFrostSpikeWedge") == nil)
    }

    @Test("Migration never overwrites a setting the user already chose")
    func migrationKeepsExplicitChoice() throws {
        let suite = TestDefaultsSuite.name("window-surface-migration")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("solid", forKey: WindowSurfacePreference.styleKey)
        defaults.set("visualEffect", forKey: "RafuFrostSpike")

        #expect(!WindowSurfacePreference.migrateFrostSpike(defaults: defaults))

        #expect(defaults.string(forKey: WindowSurfacePreference.styleKey) == "solid")
        #expect(defaults.object(forKey: "RafuFrostSpike") == nil)
    }

    @Test("A clean install has nothing to migrate")
    func cleanInstallIsUntouched() throws {
        let suite = TestDefaultsSuite.name("window-surface-migration")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))

        #expect(!WindowSurfacePreference.migrateFrostSpike(defaults: defaults))
        #expect(defaults.object(forKey: WindowSurfacePreference.styleKey) == nil)
        #expect(defaults.object(forKey: WindowSurfacePreference.frostLevelKey) == nil)
    }
}
