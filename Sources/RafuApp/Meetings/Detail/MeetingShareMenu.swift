import RafuCore
import SwiftUI

/// The Share menu of the meeting header: Copy as Markdown, Export as
/// Markdown…, the repeated-lines option, the agent access line (inactive)
/// and Meetings Settings…. It reports "Copied" or "Exported 12:31" to the
/// header for four seconds.
struct MeetingShareMenu: View {
    let feature: MeetingsFeature
    let meeting: MeetingID
    let onResult: (String) -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var includeRepeated = false
    @State private var isWorking = false
    @State private var access = UserDefaultsMeetingPreferences().agentAccess()

    private var options: MeetingExportOptions {
        MeetingExportOptions(includeEchoTurns: includeRepeated)
    }

    var body: some View {
        Menu {
            Button("Copy as Markdown", systemImage: "doc.on.doc") {
                run {
                    await MeetingExportActions.copyMarkdown(
                        of: meeting, using: feature, options: options)
                        ? "Copied" : "Rafu could not copy the meeting."
                }
            }
            Button("Export as Markdown…", systemImage: "square.and.arrow.down") {
                run {
                    await MeetingExportActions.saveMarkdown(
                        of: meeting, using: feature, options: options)
                        ? MeetingDetailPresentation.exportedText(at: Date()) : nil
                }
            }
            Toggle("Include repeated lines", isOn: $includeRepeated)
            Divider()
            Button(MeetingDetailPresentation.accessLine(access)) {}
                .disabled(true)
            Button("Meetings Settings…") {
                SettingsPaneRouter.shared.request(.meetings)
                openSettings()
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isWorking)
        .help("Share this meeting")
        .accessibilityLabel("Share")
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            access = UserDefaultsMeetingPreferences().agentAccess()
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        isWorking = true
        Task {
            if let result = await action() { onResult(result) }
            isWorking = false
        }
    }
}
