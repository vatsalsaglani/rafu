import Foundation
import SwiftUI

/// The visual grade the first-launch experience renders in, chosen the same
/// way `RafuThemeCatalog.resolved(choice: .system, systemScheme:)` chooses
/// between Indigo and Khadi for the workspace itself: dark matches Indigo,
/// anything else matches Khadi. The user is never asked; the room is matched
/// (docs/plans/phases/first-launch-onboarding.md, "The two cuts").
nonisolated enum OnboardingGrade: String, Sendable {
    case indigo
    case khadi

    static func resolve(for scheme: ColorScheme) -> Self {
        scheme == .dark ? .indigo : .khadi
    }
}

/// Resolves bundled onboarding stills/videos via the same two-candidate
/// bundle/cwd lookup `RafuThemeCatalog.load(named:)`
/// (`Sources/RafuApp/Support/RafuTheme.swift`) and `FileIconAssets.image(named:)`
/// (`Sources/RafuApp/Support/FileIconProvider.swift`) already use: the
/// packaged `.app`'s `Bundle.main` resource path first, falling back to the
/// repo-relative `Resources/` tree for `swift run`/`swift test`. Root
/// `Resources/` is not an SPM resource (see `Package.swift`); it is staged by
/// `script/build_and_run.sh`.
///
/// Every lookup returns `nil` rather than trapping when an asset is absent,
/// so a missing/renamed asset degrades the experience (still → themed fill,
/// score → silence) instead of crashing it. Video was cut from the
/// experience entirely (user decision, 2026-07-27): the intro is stills +
/// motion design + score, which also brings the bundled media back under
/// the screenplay's ≤25 MB budget.
nonisolated enum OnboardingAssetCatalog {
    static func stillURL(_ name: String, grade: OnboardingGrade) -> URL? {
        resolve("\(grade.rawValue)/\(name)", extension: "jpg")
    }

    private static func resolve(_ relativeName: String, extension ext: String) -> URL? {
        if let bundled = Bundle.main.url(
            forResource: relativeName,
            withExtension: ext,
            subdirectory: "Onboarding"
        ) {
            return bundled
        }
        // `Bundle.url(forResource:)` already existence-checks the bundled
        // candidate; the cwd fallback is a bare path construction, so it must
        // be existence-checked explicitly before being handed back as if it
        // resolved.
        let cwdFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Resources/Onboarding/\(relativeName).\(ext)")
        return FileManager.default.fileExists(atPath: cwdFallback.path) ? cwdFallback : nil
    }
}
