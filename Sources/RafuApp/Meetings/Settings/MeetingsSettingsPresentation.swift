import Foundation
import RafuCore

// The words of Settings ▸ Meetings and the download sheet, as pure
// functions, so a test checks them without a view.

/// The one button of a model row.
nonisolated enum MeetingModelRowButton: Hashable, Sendable {
    case download
    case cancel
    case remove

    var title: String {
        switch self {
        case .download: "Download"
        case .cancel: "Cancel"
        case .remove: "Remove"
        }
    }
}

nonisolated struct MeetingModelRowState: Hashable, Sendable {
    var text: String
    /// Nil when the row has no button.
    var button: MeetingModelRowButton?
    /// 0...1 while a download runs, for the `ProgressView`.
    var progress: Double?
    var isFailure: Bool
}

nonisolated struct MeetingMicrophoneLine: Hashable, Sendable {
    var text: String
    /// "A headset microphone gives poor text. Use the Mac microphone." or nil.
    var warning: String?
}

nonisolated enum MeetingsSettingsPresentation {
    static let headsetWarning = "A headset microphone gives poor text. Use the Mac microphone."
    static let whisperKitNote =
        "WhisperKit makes the text after Stop. Live text comes from Nemotron English or Apple speech."
    static let noSpeakerEngineLine =
        "Speakers are not told apart until a speaker model is installed."
    static let retentionNote = "Rafu needs the audio to make the text again with another engine."
    static let agentsNote =
        "Agents in Ensemble terminals can then search and read your meetings through Rafu's tools. An agent sends what it reads to its own provider."
    static let autoSummaryTitle = "Write a title and summary after each meeting"
    static let autoSummaryNote =
        "Rafu sends the transcript and the speaker names to the provider of the chosen agent. The audio is never sent."
    static let diagnosticsNote =
        "Device names, app identifiers, error codes and timings. No transcript, no audio."

    // MARK: Model rows

    static func modelRowState(
        installState: MeetingModelInstallState, entry: MeetingModelCatalogEntry
    ) -> MeetingModelRowState {
        switch installState {
        case .notInstalled:
            return .init(
                text: "Needs a \(entry.totalSizeText) download", button: .download, progress: nil,
                isFailure: false)
        case .downloading(let fraction):
            let clamped = min(max(fraction, 0), 1)
            let percent = Int((clamped * 100).rounded())
            return .init(
                text: "Downloading \(percent)%", button: .cancel, progress: clamped,
                isFailure: false)
        case .verifying:
            return .init(
                text: "Checking the files", button: .cancel, progress: nil, isFailure: false)
        case .installed:
            return .init(text: "Ready", button: .remove, progress: nil, isFailure: false)
        case .failed(let failure):
            return .init(
                text: failure.message, button: .download, progress: nil, isFailure: true)
        }
    }

    /// The question of the Remove confirmation.
    static func removeConfirmation(for model: MeetingModelID) -> String {
        let name = MeetingModelCatalog.entry(for: model).displayName
        switch model {
        case .nemotronEnglish1120, .whisperLargeV3:
            return "Remove the \(name) model? Rafu then uses Apple speech."
        case .nemotron3Fast32, .speakerKit:
            return
                "Remove the \(name) model? Rafu then uses the other speaker model, or does not tell speakers apart."
        }
    }

    // MARK: Engines

    static func textEngineName(_ id: MeetingTextEngineID) -> String {
        switch id {
        case .nemotronEnglish: MeetingModelCatalog.entry(for: .nemotronEnglish1120).displayName
        case .appleSpeech: "Apple speech"
        case .whisperKit: MeetingModelCatalog.entry(for: .whisperLargeV3).displayName
        }
    }

    static func speakerEngineName(_ id: MeetingSpeakerEngineID) -> String {
        switch id {
        case .nemotron3: "Nemotron 3"
        case .speakerKit: "SpeakerKit"
        }
    }

    /// The model a text engine needs, or nil (Apple speech).
    static func model(for engine: MeetingTextEngineID) -> MeetingModelID? {
        switch engine {
        case .nemotronEnglish: .nemotronEnglish1120
        case .appleSpeech: nil
        case .whisperKit: .whisperLargeV3
        }
    }

    static func model(for engine: MeetingSpeakerEngineID) -> MeetingModelID {
        switch engine {
        case .nemotron3: .nemotron3Fast32
        case .speakerKit: .speakerKit
        }
    }

    /// Why an engine that is not ready is not used, as the end of a
    /// sentence. An engine that is not registered at all is "not in this
    /// build yet".
    private static func untilClause(
        name: String, availability: MeetingEngineAvailability?
    ) -> String {
        switch availability {
        case nil: ". \(name) is not in this build yet."
        case .needsModel: ", until \(name) is installed."
        case .unavailable(let reason): ". \(name) is not available: \(reason)."
        case .ready: "."
        }
    }

    /// The lines under the "Text engine" picker. The first line names the
    /// engine in use. WhisperKit adds its note.
    static func textEngineLines(
        preference: MeetingTextEngineID,
        availability: [MeetingTextEngineID: MeetingEngineAvailability]
    ) -> [String] {
        let final = resolvedFinalTextEngine(preference: preference, availability: availability)
        var lines: [String] = []
        switch preference {
        case .whisperKit:
            let name = textEngineName(.whisperKit)
            if final == .whisperKit {
                let live = resolvedLiveTextEngine(
                    preference: preference, availability: availability)
                lines.append(
                    "In use now: \(name) for the text after Stop. Live text: \(textEngineName(live))."
                )
            } else {
                lines.append(
                    "In use now: Apple speech"
                        + untilClause(name: name, availability: availability[.whisperKit]))
            }
            lines.append(whisperKitNote)
        case .appleSpeech:
            lines.append("In use now: Apple speech.")
        case .nemotronEnglish:
            let name = textEngineName(.nemotronEnglish)
            if final == .nemotronEnglish {
                lines.append("In use now: \(name).")
            } else {
                lines.append(
                    "In use now: Apple speech"
                        + untilClause(
                            name: name, availability: availability[.nemotronEnglish]))
            }
        }
        return lines
    }

    /// The line under the "Speaker engine" picker.
    static func speakerEngineLine(
        preference: MeetingSpeakerEngineID,
        availability: [MeetingSpeakerEngineID: MeetingEngineAvailability]
    ) -> String {
        let name = speakerEngineName(preference)
        guard
            let resolved = resolvedSpeakerEngine(
                preference: preference, availability: availability)
        else { return noSpeakerEngineLine }
        if resolved == preference { return "In use now: \(name)." }
        return "In use now: \(speakerEngineName(resolved))"
            + untilClause(name: name, availability: availability[preference])
    }

    /// The short status beside a picker: "Needs a download", "Not in this
    /// build yet", the reason, or nil when the engine is ready.
    static func engineStatus(_ availability: MeetingEngineAvailability?) -> String? {
        switch availability {
        case nil: "Not in this build yet"
        case .ready: nil
        case .needsModel: "Needs a download"
        case .unavailable(let reason): reason
        }
    }

    // MARK: Microphone

    static func microphoneTitle(_ device: MeetingInputDevice) -> String {
        device.name.isEmpty ? "Unnamed input" : device.name
    }

    /// True when a stored `device:<uid>` is not in the list.
    static func isMissingDevice(
        choice: MeetingMicrophoneChoice, devices: [MeetingInputDevice]
    ) -> Bool {
        guard case .device(let uid) = choice else { return false }
        return !devices.contains { $0.uid == uid }
    }

    static func microphoneLine(
        choice: MeetingMicrophoneChoice, devices: [MeetingInputDevice],
        defaultInput: MeetingInputDevice?
    ) -> MeetingMicrophoneLine {
        let resolution = MeetingMicrophonePolicy.resolve(
            choice: choice, defaultInput: defaultInput, inputs: devices)
        let resolved = resolution.device.map(microphoneTitle) ?? "no microphone found"
        let text: String
        switch choice {
        case .automatic: text = "Automatic uses: \(resolved)"
        case .systemDefault: text = "System default uses: \(resolved)"
        case .device:
            text =
                isMissingDevice(choice: choice, devices: devices)
                ? "The chosen microphone is not connected. Automatic uses: \(resolved)"
                : "Uses: \(resolved)"
        }
        return .init(text: text, warning: resolution.usesHeadsetMicrophone ? headsetWarning : nil)
    }

    // MARK: Pickers

    static func title(for retention: MeetingAudioRetention) -> String {
        switch retention {
        case .untilDeleted: "Until I delete"
        case .days30: "30 days"
        case .days7: "7 days"
        }
    }
}
