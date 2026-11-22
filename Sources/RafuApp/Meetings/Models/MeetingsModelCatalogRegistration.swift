import RafuCore

// Owned by the Apple speech engine and model catalog package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    /// Registers the model installer as the model locator. Making it reads
    /// the models folder only (no folder is made, nothing is downloaded).
    /// It takes the diagnostics recorder registered before it (the
    /// diagnostics package registers first).
    func registerModelCatalogParts() {
        register(
            .modelLocator(
                MeetingModelInstaller(
                    modelsRoot: MeetingModelInstaller.defaultModelsRoot(),
                    diagnostics: diagnostics)))
    }

    /// The model installer, for the first-use sheet and Settings ▸ Meetings
    /// (the Download, Cancel and Remove buttons call it).
    var modelInstaller: MeetingModelInstaller? {
        modelLocator as? MeetingModelInstaller
    }
}
