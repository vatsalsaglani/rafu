import Foundation
import Testing

@testable import RafuApp

@Suite("Remote image decision")
struct RemoteImageDecisionTests {
    private let board = CanvasID()
    private let trusted = [
        HostPattern(kind: .wildcard, base: "example.com"),
        HostPattern(kind: .exact, base: "cdn.other.net"),
    ]

    private func decide(
        _ host: String, mode: CanvasRemoteImageMode, listed: Bool, consented: Bool
    ) -> RemoteImageDecision {
        RemoteImageDecision.evaluate(
            host: host, mode: mode, patterns: trusted, ensemble: board,
            ensembleConsented: consented)
    }

    @Test("Off denies everything, even a listed host with consent")
    func off() {
        for host in ["images.example.com", "unlisted.org"] {
            for consented in [true, false] {
                #expect(
                    decide(host, mode: .off, listed: true, consented: consented)
                        == .deny(reason: RemoteImageDecision.offReason))
            }
        }
    }

    @Test("Ask: a listed host loads; otherwise consent decides")
    func ask() {
        #expect(
            decide("images.example.com", mode: .ask, listed: true, consented: false)
                == .allow(.pattern("*.example.com")))
        #expect(
            decide("cdn.other.net", mode: .ask, listed: true, consented: false)
                == .allow(.pattern("cdn.other.net")))
        #expect(decide("unlisted.org", mode: .ask, listed: false, consented: false) == .ask)
        #expect(
            decide("unlisted.org", mode: .ask, listed: false, consented: true)
                == .allow(.ensemble(board)))
    }

    @Test("A pattern beats Ensemble consent")
    func patternWins() {
        #expect(
            decide("images.example.com", mode: .ask, listed: true, consented: true)
                == .allow(.pattern("*.example.com")))
    }

    @Test("Always allows everything; a listed host still reports its pattern")
    func always() {
        #expect(
            decide("unlisted.org", mode: .always, listed: false, consented: false)
                == .allow(.global))
        #expect(
            decide("images.example.com", mode: .always, listed: true, consented: false)
                == .allow(.pattern("*.example.com")))
    }

    @Test("The bare base of a wildcard is not on the list")
    func wildcardBase() {
        #expect(decide("example.com", mode: .ask, listed: false, consented: false) == .ask)
    }
}
