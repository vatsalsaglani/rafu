import SwiftUI

/// The face of a generated view card until jr-4a adds the renderer.
struct CanvasGeneratedViewPlaceholder: View {
    var body: some View {
        Text("View")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Generated view")
    }
}
