import RafuCore
import SwiftUI

/// Settings ▸ Agents ▸ Activity tracking: per provider, Connect or
/// Disconnect Rafu's activity hooks. Both open a review of the exact file
/// and entries before anything is written.
struct AgentTrackingSettingsSection: View {
    @State private var model = AgentHookSetupModel()

    var body: some View {
        Section {
            ForEach(AgentHookSetupModel.providers) { provider in
                AgentTrackingProviderRow(provider: provider, model: model)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Activity tracking")
        } footer: {
            Text(
                "Hooks tell Rafu when an agent works, waits for approval, asks a question, or finishes, also for sessions you run outside Rafu. Rafu keeps session ids, folder paths, tool names, and up to 600 characters of each final reply, on this Mac only. Prompts, tool inputs, and transcripts are discarded. Rafu changes a configuration file only after you review the change, and keeps a backup."
            )
        }
        .sheet(item: $model.pendingChange) { change in
            AgentHookReviewSheet(
                change: change,
                isBusy: model.isBusy,
                onCancel: { model.cancelReview() },
                onConfirm: { model.apply() })
        }
        .task { await model.refresh() }
        ClaudeAnswersSettingsSection(model: model)
    }
}

/// Settings ▸ Agents ▸ Answers from Up next: the opt-in switch and the
/// separate, reviewed Connect of Claude Code's answer hook entry.
private struct ClaudeAnswersSettingsSection: View {
    @Bindable var model: AgentHookSetupModel

    var body: some View {
        Section {
            Toggle(
                "Answer Claude Code permission requests from Up next",
                isOn: $model.claudeAnswersEnabled)
            if model.claudeAnswersEnabled || model.answerStatus == .connected {
                LabeledContent("Answer hook") {
                    HStack(spacing: RafuMetrics.space3) {
                        Label(word, systemImage: symbol)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if model.answerStatus == .connected {
                            Button("Disconnect…") { model.prepareAnswers(removing: true) }
                                .help("Review and remove Rafu's answer hook from Claude Code")
                        } else {
                            Button("Connect…") { model.prepareAnswers(removing: false) }
                                .help("Review and add Rafu's answer hook to Claude Code")
                                .disabled(!model.canConnectAnswers)
                        }
                    }
                    .disabled(model.isBusy)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Claude Code answer hook, \(word)")
                if !model.canConnectAnswers, model.answerStatus != .connected {
                    Text("Connect Claude Code activity tracking first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Answers from Up next")
        } footer: {
            Text(
                "When this is on and the answer hook is connected, Rafu can allow or deny a tool for Claude Code from Up next. Claude Code still shows its own dialog in the terminal, and an answer there works as before. The hook waits for your answer only while Rafu runs and this switch is on."
            )
        }
    }

    private var word: String {
        switch model.answerStatus {
        case .unknown: "Checking"
        case .notConnected: "Not connected"
        case .connected, .receiving: "Connected"
        }
    }

    private var symbol: String {
        switch model.answerStatus {
        case .unknown: "ellipsis.circle"
        case .notConnected: "circle.dashed"
        case .connected, .receiving: "checkmark.circle"
        }
    }
}

/// One provider: icon, name, state as a glyph plus a word, and one button.
private struct AgentTrackingProviderRow: View {
    let provider: AgentHookProvider
    let model: AgentHookSetupModel

    var body: some View {
        let status = model.status(for: provider)
        LabeledContent {
            HStack(spacing: RafuMetrics.space3) {
                Label(Self.word(status), systemImage: Self.symbol(status))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if status == .connected || status == .receiving {
                    Button("Disconnect…") { model.prepare(provider, removing: true) }
                        .help("Review and remove Rafu's hooks from \(provider.displayName)")
                } else {
                    Button("Connect…") { model.prepare(provider, removing: false) }
                        .help("Review and add Rafu's activity hooks to \(provider.displayName)")
                }
            }
            .disabled(model.isBusy)
        } label: {
            HStack(spacing: RafuMetrics.space2) {
                AgentIconView(cli: provider.cli, size: 16)
                    .accessibilityHidden(true)
                Text(provider.displayName)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) activity tracking, \(Self.word(status))")
    }

    static func word(_ status: AgentHookSetupModel.Status) -> String {
        switch status {
        case .unknown: "Checking"
        case .notConnected: "Not connected"
        case .connected: "Connected"
        case .receiving: "Receiving activity"
        }
    }

    static func symbol(_ status: AgentHookSetupModel.Status) -> String {
        switch status {
        case .unknown: "ellipsis.circle"
        case .notConnected: "circle.dashed"
        case .connected: "checkmark.circle"
        case .receiving: "dot.radiowaves.left.and.right"
        }
    }
}

/// The review: the exact file, the exact entries, and what is collected.
struct AgentHookReviewSheet: View {
    let change: AgentHookChange
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RafuSheetHeader(
                icon: "point.3.connected.trianglepath.dotted",
                title: (change.removing ? "Disconnect " : "Connect ")
                    + change.provider.displayName
                    + (change.scope == .answers ? " answers" : ""),
                subtitle: summary)
            LabeledContent("File") {
                Text(change.destination.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(change.removing ? "Rafu removes only these entries:" : "Rafu adds these entries:")
                .font(.callout.weight(.semibold))
            ScrollView {
                Text(change.isNoOp ? "No entries to change." : change.preview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 240)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(change.removing ? "Disconnect" : "Connect") { onConfirm() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(minWidth: 520)
    }

    private var summary: String {
        if change.isNoOp {
            return change.removing
                ? "Rafu's hooks are not in this file." : "Rafu's hooks are already in this file."
        }
        return "\(change.changedEvents.count) hook events change. Other hooks stay as they are."
    }

    private var detail: String {
        var parts: [String] = []
        if change.before != nil, !change.isNoOp {
            parts.append(
                "Rafu first saves a copy of the file next to it, named \(change.destination.lastPathComponent).rafu-backup-<date>."
            )
        }
        if !change.removing, change.scope == .answers {
            parts.append(
                "For each permission request, the hook runs Rafu's helper. While Rafu runs and the switch is on, the helper shows the request in Up next and waits up to five minutes. If you answer there, Rafu tells Claude Code to allow or deny the tool. Claude Code still shows its own dialog in the terminal, and an answer there works as before. When Rafu is not running, the helper exits at once without output."
            )
        } else if change.removing, change.scope == .activity, change.provider == .claude,
            change.preview.contains(AgentHookConfiguration.answerFlag)
        {
            parts.append("This also removes the answer hook, which needs activity tracking.")
        }
        if !change.removing, change.scope == .activity {
            parts.append(
                "The hook runs Rafu's helper from Rafu's Application Support folder. It reads the event, writes one small private file for Rafu, and always exits within one second without output, so it never changes what the agent does."
            )
            if change.provider == .codex {
                parts.append("Codex may ask you to trust the new hooks the next time it starts.")
            }
        }
        return parts.joined(separator: " ")
    }
}
