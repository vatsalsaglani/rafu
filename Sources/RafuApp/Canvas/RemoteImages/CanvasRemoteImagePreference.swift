import Foundation
import RafuCore

/// Settings ▸ Ensemble ▸ Images from the web (wave 3).
nonisolated enum CanvasRemoteImageMode: String, CaseIterable, Sendable {
    case off, ask, always
}

/// The keys and file location for images from the web. The mode lives in
/// user defaults; the trust list lives in a file, never in defaults.
nonisolated enum CanvasRemoteImagePreference {
    /// Default `CanvasRemoteImageMode.ask`.
    static let modeKey = "ensemble.remoteImages.mode"
    static let defaultMode = CanvasRemoteImageMode.ask
    static let trustFileName = "image-trust.json"

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
