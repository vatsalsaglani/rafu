import Foundation
import JSONRenderCore

@testable import RafuApp

/// Specs and builders the generated-view tests share.
enum GeneratedViewFixtures {
    static let textSpec = #"{"elements":{"r":{"props":{"text":"Hello"},"type":"Text"}},"root":"r"}"#
    static let otherSpec = #"{"elements":{"r":{"props":{"text":"Bye"},"type":"Text"}},"root":"r"}"#

    /// A form: a Switch bound to /on and a password Input bound to /pw.
    static let formSpec = #"""
        {"root":"c","elements":{
          "c":{"type":"Stack","props":{},"children":["s","p"]},
          "s":{"type":"Switch","props":{"label":"On","name":"on","checked":{"$bindState":"/on"}}},
          "p":{"type":"Input","props":{"label":"Password","name":"pw","type":"password","value":{"$bindState":"/pw"}}}
        },"state":{"on":false,"pw":""}}
        """#

    static func spec(_ text: String) throws -> Spec {
        try Spec.decode(Data(text.utf8)).spec
    }

    static func provenance(_ creator: String = "Claude") -> CanvasGeneratedViewProvenance {
        CanvasGeneratedViewProvenance(
            creator: creator, provider: "claude",
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            admission: "allow", journal: [])
    }

    static let rect = CanvasRect(x: 0, y: 0, width: 420, height: 300)

    @MainActor
    static func view(on board: CanvasBoardState, _ id: CanvasCardID) -> CanvasGeneratedView? {
        guard case .generatedView(let view)? = board.cards.first(where: { $0.id == id })?.content
        else { return nil }
        return view
    }

    /// Puts a saved state on a card without an undo step, like a save does.
    @MainActor
    static func setState(
        _ state: CanvasGeneratedViewState?, on id: CanvasCardID, board: CanvasBoardState
    ) {
        board.refreshResources { document in
            guard let index = document.cards.firstIndex(where: { $0.id == id }),
                case .generatedView(var view) = document.cards[index].content
            else { return }
            view.state = state
            document.cards[index].content = .generatedView(view)
        }
    }
}
