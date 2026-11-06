import SwiftUI

/// The set-down ring of a drop (UX Round A, S1): one hairline ring around
/// each card that just landed (`CanvasBoardState.landing`, at most
/// `CanvasLanding.maximumRings`), which grows a few points and fades out.
/// Reduce Motion draws no ring; the card's own fade remains. The layer
/// clears `landing` shortly after, so it reads cards and the viewport only
/// while a ring shows.
struct CanvasSetDownRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let board: CanvasBoardState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let landing = board.landing, !reduceMotion {
                let viewport = board.viewport
                let ids = Set(landing.ids.prefix(CanvasLanding.maximumRings))
                ZStack(alignment: .topLeading) {
                    ForEach(board.cards.filter { ids.contains($0.id) }) { card in
                        CanvasSetDownRingShape(
                            frame: CGRect(
                                x: card.rect.x * viewport.scale + viewport.x,
                                y: card.rect.y * viewport.scale + viewport.y,
                                width: card.rect.width * viewport.scale,
                                height: card.rect.height * viewport.scale))
                    }
                }
                // A new landing restarts every ring, also for the same ids.
                .id(landing.token)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: board.landing?.token) {
            guard let token = board.landing?.token else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            if board.landing?.token == token { board.landing = nil }
        }
    }
}

/// One ring. Its own state starts collapsed and animates once on appear.
private struct CanvasSetDownRingShape: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let frame: CGRect
    @State private var grown = false

    var body: some View {
        let increased = contrast == .increased
        let spread = grown ? RafuMotion.landingRingSpread : 0
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
                increased ? theme.palette.borderStrong : theme.palette.accent,
                lineWidth: increased ? 1.5 : 1
            )
            .frame(width: frame.width + 2 * spread, height: frame.height + 2 * spread)
            .opacity(grown ? 0 : 1)
            .offset(x: frame.minX - spread, y: frame.minY - spread)
            .onAppear {
                withAnimation(RafuMotion.landingRing) { grown = true }
            }
    }
}
