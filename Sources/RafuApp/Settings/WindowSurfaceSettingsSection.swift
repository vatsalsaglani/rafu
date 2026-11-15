import SwiftUI

/// Settings ▸ Appearance ▸ Window: Window background (Solid or Frosted) and
/// Frost strength. The rules live in `WindowSurfacePreference` (pure,
/// tested); every workspace window reads the same two defaults.
struct WindowSurfaceSettingsSection: View {
    @AppStorage(WindowSurfacePreference.styleKey) private var style =
        WindowSurfacePreference.Style.solid.rawValue
    @AppStorage(WindowSurfacePreference.frostLevelKey) private var frostLevel =
        WindowSurfacePreference.FrostLevel.balanced.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Section {
            LabeledContent("Window background") {
                Picker("Window background", selection: $style) {
                    ForEach(WindowSurfacePreference.Style.allCases, id: \.self) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(
                    minWidth: SettingsPresentationLayout.minimumPopupWidth, alignment: .trailing)
            }
            .help("Frosted shows the desktop, blurred, through the window frame")
            LabeledContent("Frost") {
                Picker("Frost", selection: $frostLevel) {
                    ForEach(WindowSurfacePreference.FrostLevel.allCases, id: \.self) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(
                    minWidth: SettingsPresentationLayout.minimumPopupWidth, alignment: .trailing)
            }
            .disabled(!isFrostedSelected || forcedSolidReason != nil)
            .help("How much of the desktop shows through the frame")
        } header: {
            Text("Window")
        } footer: {
            if let forcedSolidReason {
                Text(forcedSolidReason.explanation)
            } else {
                Text(
                    "Frosted applies to the window frame. The editor, terminal, and popups stay opaque."
                )
            }
        }
    }

    private var isFrostedSelected: Bool {
        WindowSurfacePreference.Style(rawValue: style) == .frosted
    }

    private var forcedSolidReason: WindowSurfacePreference.ForcedSolidReason? {
        WindowSurfacePreference.forcedSolidReason(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased)
    }
}
