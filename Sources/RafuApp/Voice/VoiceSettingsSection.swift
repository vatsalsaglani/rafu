import AppKit
import RafuCore
import SwiftUI

/// Settings ▸ Voice. Every value here is a plain preference; the OpenAI key
/// stays in Settings ▸ AI and the Keychain.
struct VoiceSettingsSection: View {
    @AppStorage(VoicePreferences.backendKey) private var backend = VoiceBackendModel.default
        .rawValue
    @AppStorage(VoicePreferences.voiceKey) private var voice = VoiceVoice.default.rawValue
    @AppStorage(VoicePreferences.shareTerminalTailKey) private var sharesTerminalTail = true
    @AppStorage(VoicePreferences.personalizationKey) private var personalization = false
    @AppStorage(VoicePreferences.monthlyCapKey) private var monthlyCap = Int(
        VoiceCostMeter.defaultCapDollars)
    @AppStorage(VoicePreferences.debugTranscriptKey) private var keepsDebugTranscript = false
    @State private var microphone = VoiceMicrophonePermission.access
    @State private var isResetPresented = false
    @State private var chordConflict = false

    private let costs = VoiceSession.shared.costStore
    private let profileStore = VoiceStyleProfileStore()

    static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    var body: some View {
        Section {
            LabeledContent(
                "Push to talk",
                value: VoiceHotkey.shared.isGlobal
                    ? "⌃⌥Space, in any app" : "⌃⌥Space while Rafu is in front")
            if chordConflict {
                Label(
                    "macOS uses ⌃⌥Space to switch input sources on this Mac. Use ⌃⌥⇧Space (Start Listening), or turn off that shortcut in Keyboard Shortcuts ▸ Input Sources.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                "Click the voice blob or choose Start Listening to keep the microphone open. Rafu checks in after 45 seconds of silence, pauses at 60, and closes the session after 90."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Talking to Rafu")
        } footer: {
            Text(
                "Voice uses OpenAI GPT-Live with the OpenAI key in Settings ▸ AI. Audio goes to OpenAI only while you hold ⌃⌥Space or keep Rafu listening."
            )
        }

        Section("Model and Voice") {
            menuPicker("Backend model", selection: $backend) {
                ForEach(VoiceBackendModel.allCases) { model in
                    Text(model.title).tag(model.rawValue)
                }
            }
            .help("The model that reads the Ensemble and calls Rafu's tools.")
            menuPicker("Voice", selection: $voice) {
                ForEach(VoiceVoice.allCases) { voice in
                    Text(voice.title).tag(voice.rawValue)
                }
            }
            .help("Applies to the next voice session.")
        }

        Section {
            Toggle("Share terminal output in Allow mode", isOn: $sharesTerminalTail)
        } footer: {
            Text(
                "In an Ensemble set to Allow, Rafu may read up to 40 visible lines of each terminal, with secrets removed. Ask and Off never share terminal output."
            )
        }

        Section {
            Toggle("Personalization", isOn: $personalization)
            HStack(spacing: 8) {
                Button("View") { showProfile() }
                Button("Reset…") { isResetPresented = true }
            }
        } header: {
            Text("Personalization")
        } footer: {
            Text(
                "A small local profile of your preferences, never audio or transcripts. Rafu stores it on this Mac only. Learning arrives in a later version."
            )
        }
        .sheet(isPresented: $isResetPresented) {
            RafuConfirmPopup(
                title: "Reset the voice profile?",
                message: "Rafu deletes the local voice profile. This cannot be undone.",
                actions: [
                    .init("Reset Profile", isDestructive: true) {
                        try? profileStore.reset()
                        isResetPresented = false
                    }
                ]
            ) {
                isResetPresented = false
            }
        }

        Section {
            Stepper(
                "Monthly cap: $\(monthlyCap)", value: $monthlyCap, in: VoicePreferences.capRange)
            LabeledContent("This month", value: costLine)
        } header: {
            Text("Cost")
        } footer: {
            Text(
                "GPT-Live costs about $0.05 per minute of open session. The cap stops new sessions, never a running one."
            )
        }

        Section {
            Toggle("Keep a debug transcript", isOn: $keepsDebugTranscript)
            Button("Show in Finder") { showTranscriptFolder() }
        } header: {
            Text("Debugging")
        } footer: {
            Text(
                "Rafu writes what you say, what Rafu says, and every tool call with its arguments and results to \(VoiceDebugTranscript.displayPath()) on this Mac. It can hold text from your notes and terminals. Never the key or audio. Applies from the next voice session. Rafu keeps the newest \(VoiceDebugTranscript.keptFiles) files."
            )
        }

        Section("Microphone") {
            LabeledContent("Access", value: microphoneText)
            // macOS lists an app under Privacy ▸ Microphone only after the app asks, so
            // "Open System Settings" cannot help before the first request.
            if microphone == .notAsked {
                Button("Allow Microphone…") {
                    Task {
                        _ = await VoiceMicrophonePermission.request()
                        microphone = VoiceMicrophonePermission.access
                    }
                }
            } else {
                Button("Open System Settings") { NSWorkspace.shared.open(Self.privacyURL) }
            }
        }
        .onAppear {
            microphone = VoiceMicrophonePermission.access
            chordConflict = VoiceHotkeyConflict.isActive()
        }
    }

    private func menuPicker<Content: View>(
        _ title: String, selection: Binding<String>, @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(minWidth: SettingsPresentationLayout.minimumPopupWidth, alignment: .trailing)
        }
    }

    private var costLine: String {
        let minutes = Int((costs.monthlySeconds / 60).rounded())
        return String(format: "$%.2f (%d min)", costs.monthlyCost, minutes)
    }

    private var microphoneText: String {
        switch microphone {
        case .allowed: "Allowed"
        case .notAsked: "Rafu asks the first time you talk"
        case .denied: "Off. Turn it on in System Settings."
        }
    }

    /// Opens the transcript folder, or the nearest folder above it that
    /// exists (before the first transcript).
    private func showTranscriptFolder() {
        let folder = VoiceDebugTranscript.defaultDirectory()
        let app = folder.deletingLastPathComponent()
        let candidates = [folder, app, app.deletingLastPathComponent()]
        let target =
            candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[2]
        NSWorkspace.shared.open(target)
    }

    private func showProfile() {
        let message: String
        if let profile = profileStore.load(), let data = try? profile.encoded() {
            message = String(decoding: data, as: UTF8.self)
        } else {
            message = "No profile yet."
        }
        RafuPopupPresenter.presentMessage(kind: .info, title: "Voice Profile", message: message)
    }
}
