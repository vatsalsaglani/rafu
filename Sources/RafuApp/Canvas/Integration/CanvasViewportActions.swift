import AppKit
import Foundation
import SwiftUI

extension CanvasBoardState {
    // MARK: Arrange

    func alignSelection(leading: Bool) throws {
        try align(leading ? .left : .top)
    }

    func align(_ alignment: CanvasAlignment) throws {
        try edit { value in
            let indices = value.cards.indices.filter { selection.contains(value.cards[$0].id) }
            guard indices.count > 1 else { return }
            let result = CanvasLayoutMath.align(indices.map { value.cards[$0].rect }, alignment)
            for (offset, index) in indices.enumerated() { value.cards[index].rect = result[offset] }
        }
    }

    func distribute(_ distribution: CanvasDistribution) throws {
        try edit { value in
            let indices = value.cards.indices.filter { selection.contains(value.cards[$0].id) }
            guard indices.count > 2 else { return }
            let result = CanvasLayoutMath.distribute(
                indices.map { value.cards[$0].rect }, distribution)
            for (offset, index) in indices.enumerated() { value.cards[index].rect = result[offset] }
        }
    }

    func bringSelectionToFront() throws { try reorder(selection, toFront: true) }
    func sendSelectionToBack() throws { try reorder(selection, toFront: false) }

    /// Resizes the single selected card by a delta in board units, keeping its
    /// minimum size and, for images, its shape.
    func resizeSelection(dw: Double, dh: Double) throws {
        guard selection.count == 1, let card = cards.first(where: { selection.contains($0.id) })
        else { return }
        let edges: CanvasResizeEdges =
            dw != 0 && dh != 0 ? [.right, .bottom] : (dw != 0 ? .right : .bottom)
        let outcome = CanvasLayoutMath.resize(
            card.rect, edges: edges, dx: dw, dy: dh, minimum: card.content.minimumSize,
            aspect: card.content.keepsAspect ? card.rect.width / card.rect.height : nil,
            allowsResistance: false)
        try edit { value in
            guard let index = value.cards.firstIndex(where: { $0.id == card.id }) else { return }
            value.cards[index].rect = outcome.rect
        }
    }

    // MARK: Zoom

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Button, menu and shortcut zoom animates; pinch and scroll set the
    /// viewport directly so they stay 1:1 with the pointer.
    func setViewport(animated viewport: CanvasViewport, animation: Animation) {
        let resolved = RafuMotion.resolve(animation, reduceMotion: reduceMotion)
        withAnimation(resolved) { setViewport(viewport) }
    }

    func zoom(_ factor: Double) {
        zoom(toScale: viewport.scale * factor)
    }

    func zoom(toScale scale: Double) {
        setViewport(
            animated: CanvasZoomMetrics.viewport(scaling: viewport, to: scale, in: visibleSize),
            animation: RafuMotion.zoomStep)
    }

    func actualSize() { zoom(toScale: 1) }

    func fitAll() {
        guard let first = cards.first else {
            setViewport(animated: .init(), animation: RafuMotion.zoomToFit)
            return
        }
        let bounds = cards.dropFirst().reduce(first.rect.cgRect) { $0.union($1.rect.cgRect) }
        setViewport(
            animated: CanvasZoomMetrics.viewport(fitting: bounds, in: visibleSize),
            animation: RafuMotion.zoomToFit)
    }

    func zoomToSelection() {
        let chosen = cards.filter { selection.contains($0.id) }
        guard let first = chosen.first else { return }
        let bounds = chosen.dropFirst().reduce(first.rect.cgRect) { $0.union($1.rect.cgRect) }
        setViewport(
            animated: CanvasZoomMetrics.viewport(fitting: bounds, in: visibleSize, maximumScale: 2),
            animation: RafuMotion.zoomToFit)
    }

    func zoomToCard(_ id: CanvasCardID) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        setViewport(
            animated: CanvasZoomMetrics.viewport(
                fitting: card.rect.cgRect, in: visibleSize, maximumScale: 2),
            animation: RafuMotion.zoomToFit)
    }

    /// Pans (without zoom change) so `id` is fully inside the visible board.
    /// Used by Tab navigation; keyboard navigation does not animate.
    func revealCard(_ id: CanvasCardID) {
        guard let card = cards.first(where: { $0.id == id }), visibleSize.width > 0 else { return }
        let scale = viewport.scale
        let margin = 40.0
        var next = viewport
        let left = card.rect.x * scale + viewport.x
        let right = (card.rect.x + card.rect.width) * scale + viewport.x
        let top = card.rect.y * scale + viewport.y
        let bottom = (card.rect.y + card.rect.height) * scale + viewport.y
        if left < margin {
            next.x += margin - left
        } else if right > Double(visibleSize.width) - margin {
            next.x -= right - (Double(visibleSize.width) - margin)
        }
        if top < margin + 36 {
            next.y += margin + 36 - top
        } else if bottom > Double(visibleSize.height) - margin {
            next.y -= bottom - (Double(visibleSize.height) - margin)
        }
        setViewport(next)
    }
}
