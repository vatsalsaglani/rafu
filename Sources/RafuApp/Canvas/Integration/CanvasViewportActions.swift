import Foundation

extension CanvasBoardState {
    func alignSelection(leading: Bool) throws {
        let selected = cards.filter { selection.contains($0.id) }
        guard selected.count > 1 else { return }
        guard
            let coordinate =
                (leading ? selected.map { $0.rect.x }.min() : selected.map { $0.rect.y }.min())
        else { return }
        try edit { value in
            for index in value.cards.indices where selection.contains(value.cards[index].id) {
                if leading {
                    value.cards[index].rect.x = coordinate
                } else {
                    value.cards[index].rect.y = coordinate
                }
            }
        }
    }

    func zoom(_ factor: Double) {
        let original = viewport
        let scale = min(2, max(0.25, original.scale * factor))
        let ratio = scale / original.scale
        setViewport(
            .init(
                scale: scale,
                x: visibleSize.width / 2 - (visibleSize.width / 2 - original.x) * ratio,
                y: visibleSize.height / 2 - (visibleSize.height / 2 - original.y) * ratio))
    }
    func fitAll() {
        guard let first = cards.first else {
            setViewport(.init())
            return
        }
        var bounds = CGRect(
            x: first.rect.x, y: first.rect.y, width: first.rect.width, height: first.rect.height)
        for card in cards.dropFirst() {
            bounds = bounds.union(
                CGRect(
                    x: card.rect.x, y: card.rect.y, width: card.rect.width, height: card.rect.height
                ))
        }
        let scale = min(
            1,
            max(
                0.25,
                min(
                    (visibleSize.width - 80) / bounds.width,
                    (visibleSize.height - 100) / bounds.height)))
        setViewport(
            .init(
                scale: scale,
                x: (visibleSize.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (visibleSize.height - bounds.height * scale) / 2 - bounds.minY * scale))
    }
}
