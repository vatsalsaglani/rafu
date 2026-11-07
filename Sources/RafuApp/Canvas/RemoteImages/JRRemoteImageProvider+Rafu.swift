import CoreGraphics
import Foundation
import JSONRenderSwiftUI
import Observation

/// The live adapter between Rafu's image policy and the package hook. One
/// per generated view card: it adds the card to each request, so the
/// 20-images-per-view limit counts per card. It holds the engine weakly: the
/// engine owns its adapters. `revision` reads the engine's
/// observed state, so a view that reads it in `body` redraws when a load
/// ends, a grant changes, or a setting changes.
@MainActor
@Observable
final class RafuCardRemoteImages: JRRemoteImageProvider {
    @ObservationIgnored private weak var engine: RemoteImageProvider?
    @ObservationIgnored private let cardID: CanvasCardID

    init(engine: RemoteImageProvider, cardID: CanvasCardID) {
        self.engine = engine
        self.cardID = cardID
    }

    var revision: Int { engine?.revision ?? 0 }

    func state(for url: URL, pixelSize: CGSize, elementID: String) -> JRRemoteImageState {
        guard let engine else { return .notAllowed(reason: nil) }
        let state: JRRemoteImageState
        switch engine.state(for: url, pixelSize: pixelSize, cardID: cardID) {
        case .notAllowed(let reason): state = .notAllowed(reason: reason)
        case .needsConsent(let host): state = .needsConsent(host: host)
        case .loading: state = .loading
        case .image(let image): state = .image(image)
        case .failed(let message): state = .failed(message)
        }
        return state
    }

    func requestConsent(for url: URL, elementID: String) {
        engine?.requestConsent(for: url)
    }
}
