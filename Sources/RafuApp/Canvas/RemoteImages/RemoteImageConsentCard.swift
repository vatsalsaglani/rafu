import SwiftUI

/// The consent card for images from the web (ADR 0033 popup language). It
/// names the host that will see the request and offers: allow images in this
/// Ensemble, always allow this host, always allow the parent domain (when the
/// host has one), or cancel. Return runs "Allow for This Ensemble"; Escape
/// cancels. Return never adds to the trust list.
struct RemoteImageConsentCard: View {
    let request: RemoteImageConsentRequest
    let answer: (RemoteImageConsentOutcome) -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(symbol: "photo", title: "Allow images from the web?")
            VStack(alignment: .leading, spacing: 10) {
                RafuPopupRow(
                    symbol: "globe", title: request.host, caption: "Image host",
                    isSelected: false
                )
                .accessibilityLabel("Image host, \(RemoteImageSpeech.spoken(request.host))")
                Text(Self.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            VStack(alignment: .leading, spacing: 6) {
                Button("Always allow images from \(request.host)") {
                    answer(.trust(request.hostPattern))
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .accessibilityLabel(
                    "Always allow images from \(RemoteImageSpeech.spoken(request.host))")
                if let parent = request.parentPattern {
                    Button("Always allow images from \(parent.text)") {
                        answer(.trust(parent))
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .accessibilityLabel(
                        "Always allow images from \(parent.spoken)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            RafuPopupFooter(hints: [("esc", "Cancel")]) {
                Button("Cancel") { answer(.cancel) }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes without allowing images")
                Button("Allow for This Ensemble") { answer(.allowEnsemble) }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Allows images from the web in this Ensemble")
            }
        }
        .frame(width: 440, alignment: .top)
        .rafuPopupSurface(.sheet)
        .onExitCommand { answer(.cancel) }
    }

    static let explanation =
        "The image host will see a request from this Mac. Rafu sends no cookies and no account details. Settings ▸ Ensemble ▸ Images from the web lists the hosts you trust."
}

/// Shows the consent card as a sheet on the workspace window, one at a time
/// for the whole app: a second request waits for the first answer.
@MainActor
extension RemoteImageConsentCard {
    private static var isShowing = false
    private static var waiting: [() -> Void] = []

    /// Matches `RemoteImageProvider.ConsentPresenter`. With no window to host
    /// the sheet, it answers cancel at once (nothing is allowed).
    static func present(
        _ request: RemoteImageConsentRequest,
        answer: @escaping @MainActor (RemoteImageConsentOutcome) -> Void
    ) {
        let show: () -> Void = {
            guard RafuPopupPresenter.parentWindow() != nil else {
                answer(.cancel)
                next()
                return
            }
            isShowing = true
            var answered = false
            RafuPopupPresenter.presentSheet(size: NSSize(width: 440, height: 300)) { dismiss in
                RemoteImageConsentCard(request: request) { outcome in
                    // A button and Escape can both report; the first one counts.
                    guard !answered else { return }
                    answered = true
                    dismiss()
                    answer(outcome)
                    next()
                }
            }
        }
        if isShowing { waiting.append(show) } else { show() }
    }

    private static func next() {
        isShowing = false
        if !waiting.isEmpty { waiting.removeFirst()() }
    }
}
