import RafuCore
import SwiftUI

struct WorkspaceStatusBar: View {
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @Environment(\.rafuTheme) private var theme
    @State private var memorySample: ProcessMemorySample?
    let descriptor: WorkspaceDescriptor?
    @Binding var isResourcesPresented: Bool
    let languageIntelligence: LanguageIntelligenceCoordinator

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(descriptor == nil ? theme.palette.textMuted : theme.palette.success)
                    .frame(width: 6, height: 6)
                Label(statusText, systemImage: statusSymbol)
                    .lineLimit(1)
            }

            Spacer()

            if showsProcessMemory, let memorySample {
                Label(memorySample.formatted, systemImage: "memorychip")
                    .foregroundStyle(theme.palette.textMuted)
                    .help("Rafu process resident memory. This is shared by all windows.")
            }

            Button {
                isResourcesPresented.toggle()
            } label: {
                Image(systemName: "memorychip")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.textMuted)
            .accessibilityLabel("Show Resources")
            .help("Show Resources")
            .popover(isPresented: $isResourcesPresented) {
                ResourcesView(coordinator: languageIntelligence)
            }

            Text(descriptor == nil ? "Ready" : "Local editor")
                .foregroundStyle(theme.palette.textMuted)
        }
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: RafuMetrics.statusBarHeight)
        .background(theme.palette.statusBarBackground)
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .task(id: showsProcessMemory) {
            guard showsProcessMemory else {
                memorySample = nil
                return
            }
            let sampler = ProcessMemorySampler()
            while !Task.isCancelled {
                memorySample = sampler.sample()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private var statusText: String {
        guard let descriptor else {
            return "No workspace"
        }

        switch descriptor.location {
        case .local:
            return "Local"
        case .ssh(let reference):
            return reference.hostAlias
        }
    }

    private var statusSymbol: String {
        guard let descriptor else {
            return "circle.dashed"
        }

        switch descriptor.location {
        case .local:
            return "internaldrive"
        case .ssh:
            return "network"
        }
    }
}
