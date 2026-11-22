import Foundation
import RafuCore

// Owned by the meeting library and Markdown export package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerLibraryParts() {
        registerLibraryParts(
            rootDirectory: MeetingStore.defaultRootDirectory(),
            snapshotRoot: MeetingAgentRunFolders.defaultSnapshotRoot)
    }

    /// Registers the library at an explicit root (tests pass a temporary
    /// one). Making a store touches no file; the folders are made at the
    /// first write. The diagnostics recorder registers first, so the store
    /// reports its writes to it.
    /// `snapshotRoot` nil keeps the store's own default.
    func registerLibraryParts(rootDirectory: URL, snapshotRoot: URL? = nil) {
        register(
            .store(
                MeetingStore(
                    rootDirectory: rootDirectory, snapshotRoot: snapshotRoot,
                    diagnostics: diagnostics)))
    }
}
