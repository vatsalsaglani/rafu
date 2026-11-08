import AppKit
import SwiftUI

/// Show Spec…: the view's spec as read-only monospaced text, with Copy.
/// Escape and Close dismiss it. A spec over 64 KiB uses a read-only text
/// view, which stays fast; a smaller one is plain selectable text.
struct GeneratedViewSpecPopup: View {
    let title: String
    let specJSON: String
    let dismiss: () -> Void
    @Environment(\.rafuTheme) private var theme
    @State private var copied = false

    static let plainTextLimit = 64 * 1_024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(
                symbol: "curlybraces", title: "View Spec",
                subtitle: "\(title) · \(specJSON.utf8.count.formatted()) bytes")
            Group {
                if specJSON.utf8.count > Self.plainTextLimit {
                    TextEditor(text: .constant(specJSON))
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(specJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.palette.textPrimary)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 460)
            .background(theme.palette.fieldBackground)
            .accessibilityLabel("View spec")
            RafuPopupFooter(hints: [("esc", "Close")]) {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(specJSON, forType: .string)
                    copied = true
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                Button("Close", action: dismiss)
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560, alignment: .top)
        .rafuPopupSurface(.sheet)
        .onExitCommand(perform: dismiss)
    }
}
