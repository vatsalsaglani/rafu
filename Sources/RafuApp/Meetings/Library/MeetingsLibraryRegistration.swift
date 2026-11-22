import Foundation
import RafuCore

// Owned by the meeting library and Markdown export package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerLibraryParts() {
        registerLibraryParts(rootDirectory: MeetingStore.defaultRootDirectory())
    }

    /// Registers the library at an explicit root (tests pass a temporary
    /// one). Making a store touches no file; the folders are made at the
    /// first write. The diagnostics recorder registers first, so the store
    /// reports its writes to it.
    func registerLibraryParts(rootDirectory: URL) {
        register(.store(MeetingStore(rootDirectory: rootDirectory, diagnostics: diagnostics)))
    }
}
