import RafuCore
import SwiftUI

/// The Share sidebar: Copy Markdown, Export Markdown…, the echo option and
/// the agent access status line. There is no access switch here.
struct MeetingShareSidebar: View {
    let feature: MeetingsFeature
    let meeting: MeetingID

    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var includeEcho = false
    @State private var result: String?
    @State private var isWorking = false
    @State private var access = UserDefaultsMeetingPreferences().agentAccess()

    private var options: MeetingExportOptions {
        MeetingExportOptions(includeEchoTurns: includeEcho)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            Toggle("Include echo lines", isOn: $includeEcho)
                .toggleStyle(.checkbox)
            HStack(spacing: RafuMetrics.space2) {
                Button("Copy Markdown") {
                    run {
                        await MeetingExportActions.copyMarkdown(
                            of: meeting, using: feature, options: options)
                            ? "Copied" : "Rafu could not copy the meeting."
                    }
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Export Markdown…") {
                    run {
                        await MeetingExportActions.saveMarkdown(
                            of: meeting, using: feature, options: options) ? "Exported" : nil
                    }
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
            .disabled(isWorking)
            if let result {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                Label(
                    MeetingDetailPresentation.accessLine(access),
                    systemImage: access == .on ? "lock.open" : "lock"
                )
                .font(.callout)
                .foregroundStyle(theme.palette.textPrimary)
                Button("Open Settings…") {
                    SettingsPaneRouter.shared.request(.meetings)
                    openSettings()
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Change agent access in Settings ▸ Meetings")
            }
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            access = UserDefaultsMeetingPreferences().agentAccess()
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        isWorking = true
        result = nil
        Task {
            result = await action()
            isWorking = false
        }
    }
}
