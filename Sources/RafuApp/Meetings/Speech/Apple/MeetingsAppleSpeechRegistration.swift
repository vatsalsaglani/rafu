import RafuCore

// Owned by the Apple speech engine and model catalog package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    /// Registers `AppleSpeechEngine` on macOS 26 and later. Making it starts
    /// nothing: no analyzer, no system download. It takes the diagnostics
    /// recorder registered before it (the diagnostics package registers first).
    func registerAppleSpeechParts() {
        guard #available(macOS 26, *) else { return }
        register(.textEngine(AppleSpeechEngine(diagnostics: diagnostics)))
    }
}
