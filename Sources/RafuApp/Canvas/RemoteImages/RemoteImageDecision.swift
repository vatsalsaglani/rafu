import Foundation

/// What allowed an image. A cached image carries its grant, so removing the
/// grant drops the image at once.
nonisolated enum RemoteImageGrant: Hashable, Sendable {
    /// The user allowed images in this Ensemble from its consent card.
    case ensemble(CanvasID)
    /// A trust-list pattern (its text).
    case pattern(String)
    /// The global setting is Always allow.
    case global
}

/// The decision for one image host. Pure: the provider supplies the mode,
/// the trust list and this Ensemble's consent.
nonisolated enum RemoteImageDecision: Equatable, Sendable {
    case allow(RemoteImageGrant)
    case deny(reason: String)
    /// The user has not allowed this host yet; the card offers "Allow…".
    case ask

    static let offReason = "Images from the web are off in Settings."

    /// - Parameters:
    ///   - host: lowercase punycode, as `RemoteImageFetchPolicy.classify` returns it.
    ///   - patterns: the trust list.
    ///   - ensemble: this Ensemble and whether the user allowed images in it.
    static func evaluate(
        host: String,
        mode: CanvasRemoteImageMode,
        patterns: [HostPattern],
        ensemble: CanvasID,
        ensembleConsented: Bool
    ) -> RemoteImageDecision {
        switch mode {
        case .off:
            return .deny(reason: offReason)
        case .ask:
            if let match = patterns.first(where: { $0.matches(host: host) }) {
                return .allow(.pattern(match.text))
            }
            return ensembleConsented ? .allow(.ensemble(ensemble)) : .ask
        case .always:
            if let match = patterns.first(where: { $0.matches(host: host) }) {
                return .allow(.pattern(match.text))
            }
            return .allow(.global)
        }
    }
}
