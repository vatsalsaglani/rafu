import RafuCore
import SwiftUI

/// The Settings ▸ Meetings sections (the `settingsView` hook). The host puts
/// them in the pane's grouped `Form`, so this view returns `Section`s.
struct MeetingsSettingsSections: View {
    let feature: MeetingsFeature

    var body: some View {
        if feature.availability.isAvailable {
            MeetingsAvailableSettingsSections(feature: feature)
        } else {
            Section {
                Text(MeetingsPlaceholderView.message(for: feature.availability))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Meetings")
            }
        }
    }
}

private struct MeetingsAvailableSettingsSections: View {
    let feature: MeetingsFeature
    @State private var model: MeetingsSettingsModel

    init(feature: MeetingsFeature) {
        self.feature = feature
        _model = State(
            initialValue: MeetingsSettingsModel(
                installer: feature.modelInstaller, textEngines: feature.textEngines,
                speakerEngines: feature.speakerEngines))
    }

    private var canRemove: Bool {
        !feature.session.isRecordingOrPaused && feature.session.processing.isEmpty
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<MeetingsSettingsModel, Value>
    ) -> Binding<Value> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }

    var body: some View {
        Group {
            enginesSection
            modelsSection
            microphoneSection
            keepAudioSection
            agentsSection
            diagnosticsSection
        }
    }

    // MARK: Sections

    private var enginesSection: some View {
        Section {
            enginePicker(
                "Text engine", status: model.textStatus, selection: binding(\.textEngine),
                options: MeetingTextEngineID.allCases,
                title: MeetingsSettingsPresentation.textEngineName)
            ForEach(Array(model.textLines.enumerated()), id: \.offset) { _, line in
                noteText(line)
            }
            enginePicker(
                "Speaker engine", status: model.speakerStatus,
                selection: binding(\.speakerEngine),
                options: MeetingSpeakerEngineID.allCases,
                title: MeetingsSettingsPresentation.speakerEngineName)
            noteText(model.speakerLine)
        } header: {
            Text("Engines")
        }
        // One task for the whole pane: it ends when the pane goes away.
        .task { await model.run() }
    }

    private func enginePicker<Option: Hashable>(
        _ label: String, status: String?, selection: Binding<Option>, options: [Option],
        title: @escaping (Option) -> String
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Picker(label, selection: selection) {
                    ForEach(options, id: \.self) { Text(title($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(MeetingModelID.allCases, id: \.self) { id in
                MeetingModelRow(model: id, settings: model, canRemove: canRemove)
            }
            if let failure = model.removalFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Rafu downloads a model only when you press Download. Models stay on this Mac.")
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } })
        ) {
            if let pending = model.pendingRemoval {
                RafuConfirmPopup(
                    title: "Remove the model?",
                    message: MeetingsSettingsPresentation.removeConfirmation(for: pending),
                    actions: [
                        .init("Remove", isDestructive: true) {
                            model.confirmRemoval(of: pending)
                        }
                    ]
                ) {
                    model.pendingRemoval = nil
                }
            }
        }
    }

    private var microphoneSection: some View {
        Section {
            LabeledContent("Microphone") {
                HStack(spacing: 8) {
                    Picker("Microphone", selection: binding(\.microphone)) {
                        Text("Automatic").tag(MeetingMicrophoneChoice.automatic)
                        Text("System default").tag(MeetingMicrophoneChoice.systemDefault)
                        ForEach(model.devices.inputs, id: \.uid) { device in
                            Text(MeetingsSettingsPresentation.microphoneTitle(device))
                                .tag(MeetingMicrophoneChoice.device(uid: device.uid))
                        }
                        if model.isMicrophoneMissing {
                            Text("Unknown microphone (not connected)").tag(model.microphone)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("Read the list of microphones again")
                    .accessibilityLabel("Refresh the list of microphones")
                }
            }
            let line = model.microphoneLine
            noteText(line.text)
            if let warning = line.warning {
                Label(warning, systemImage: "headphones")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Microphone")
        }
    }

    private var keepAudioSection: some View {
        Section {
            Picker("Keep audio", selection: binding(\.audioRetention)) {
                ForEach(MeetingAudioRetention.allCases, id: \.self) {
                    Text(MeetingsSettingsPresentation.title(for: $0)).tag($0)
                }
            }
            noteText(MeetingsSettingsPresentation.retentionNote)
        } header: {
            Text("Keep audio")
        }
    }

    private var agentsSection: some View {
        Section {
            Toggle("Allow agents to read your meetings", isOn: binding(\.agentAccessOn))
            noteText(MeetingsSettingsPresentation.agentsNote)
        } header: {
            Text("Agents")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button("Export Meeting Diagnostics…") { feature.exportDiagnostics() }
                .disabled(!feature.canExportDiagnostics)
                .help("Save a file for a bug report. It holds no transcript and no audio.")
            noteText(MeetingsSettingsPresentation.diagnosticsNote)
        } header: {
            Text("Diagnostics")
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
