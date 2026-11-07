import Foundation
import RafuCore

/// Settings ▸ Ensemble ▸ Images from the web (wave 3).
nonisolated enum CanvasRemoteImageMode: String, CaseIterable, Sendable {
    case off, ask, always

    var title: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask"
        case .always: "Always allow"
        }
    }
}

/// The keys and file location for images from the web. The mode lives in
/// user defaults; the trust list lives in a file, never in defaults.
nonisolated enum CanvasRemoteImagePreference {
    /// Default `CanvasRemoteImageMode.ask`.
    static let modeKey = "ensemble.remoteImages.mode"
    static let defaultMode = CanvasRemoteImageMode.ask
    static let trustFileName = "image-trust.json"

    /// The saved mode, or the default when nothing (or nothing valid) is saved.
    static func mode(_ defaults: UserDefaults = .standard) -> CanvasRemoteImageMode {
        defaults.string(forKey: modeKey).flatMap(CanvasRemoteImageMode.init(rawValue:))
            ?? defaultMode
    }

    static func setMode(_ mode: CanvasRemoteImageMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// `<Application Support>/<identity>/image-trust.json`, so Rafu Lightning and
    /// the release app keep separate lists, like the Ensemble store.
    static func trustFileURL(
        identity: RafuAppIdentity = .current,
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) -> URL {
        identity.applicationSupportRoot(baseDirectory: baseDirectory)
            .appending(path: trustFileName, directoryHint: .notDirectory)
    }
}
