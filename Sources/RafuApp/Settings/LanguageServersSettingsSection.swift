import SwiftUI

/// Placeholder host for lane 2's Settings > Language Servers UI. Wired into
/// `RafuSettingsView` as part of the increment-0 contract commit; its
/// contents belong to lane 2 from this commit forward.
struct LanguageServersSettingsSection: View {
    var body: some View {
        Section("Language Servers") {
            Text(
                "Language server support is in development. Curated servers and custom entries will appear here."
            )
            .foregroundStyle(.secondary)
        }
    }
}
