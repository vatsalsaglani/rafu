import Foundation
import JSONRenderCore

/// The `GeneratedViewHost` Rafu installs at launch: it validates specs against
/// `RafuCatalog.rafu` and makes every create, update and Reset View one board
/// undo step. The MCP tools, voice and the card menus all come through here.
final class GeneratedViewActions: GeneratedViewHost {
    static let shared = GeneratedViewActions()

    /// Installs the host. `RafuAppDelegate.applicationDidFinishLaunching` calls it.
    static func install() {
        GeneratedViewHostRegistry.shared.host = shared
    }

    /// The validator text an agent sees is bounded; it holds codes, element
    /// keys and types, never prop values.
    static let messageLimit = 1_000

    /// A decoded, validated spec and its canonical text.
    struct Checked {
        let spec: Spec
        let text: String
        let summary: GeneratedViewSummary
    }

    // MARK: Validation

    func validate(specJSON: String) -> Result<GeneratedViewSummary, GeneratedViewError> {
        check(specJSON).map(\.summary)
    }

    func check(_ specJSON: String) -> Result<Checked, GeneratedViewError> {
        let size = specJSON.utf8.count
        guard size <= CanvasLimits.generatedViewSpecBytes else {
            return .failure(.tooLarge(bytes: size))
        }
        let spec: Spec
        do {
            spec = try Spec.decode(Data(specJSON.utf8), limits: .default).spec
        } catch {
            return .failure(.invalidSpec(Self.bounded(error.message)))
        }
        return check(spec)
    }

    func check(_ spec: Spec) -> Result<Checked, GeneratedViewError> {
        let report = RafuCatalog.rafu.validate(
            spec, options: ValidateSpecOptions(checkOrphans: false))
        guard report.valid else { return .failure(.invalidSpec(Self.bounded(report.formatted()))) }
        guard let text = GeneratedViewStatePersistence.canonicalText(spec) else {
            return .failure(.invalidSpec("The spec could not be encoded."))
        }
        guard text.utf8.count <= CanvasLimits.generatedViewSpecBytes else {
            return .failure(.tooLarge(bytes: text.utf8.count))
        }
        return .success(Checked(spec: spec, text: text, summary: Self.summary(spec, report)))
    }

    static func summary(_ spec: Spec, _ report: ValidationReport) -> GeneratedViewSummary {
        let types = Set(spec.elements.values.map(\.type)).sorted().prefix(8)
        return GeneratedViewSummary(
            elementCount: spec.elements.count, types: Array(types),
            warnings: report.warnings.count)
    }

    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > messageLimit else { return text }
        return String(text.prefix(messageLimit - 1)) + "…"
    }

    // MARK: Create

    func create(
        specJSON: String, title: String, rect: CanvasRect,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) throws -> CanvasCardID {
        try checkRoom(on: board)
        let checked = try check(specJSON).get()
        if let refusal = GeneratedViewBudget.refusal(specJSON: checked.text, cards: board.cards) {
            throw refusal
        }
        let card = CanvasCard(
            title: Self.title(title), rect: rect,
            content: .generatedView(Self.view(checked.text, provenance: provenance)))
        try board.edit { $0.cards.append(card) }
        board.select([card.id])
        return card.id
    }

    func checkRoom(on board: CanvasBoardState) throws {
        let cards = board.cards
        guard cards.count < CanvasLimits.cards,
            cards.count(where: Self.isView) < CanvasLimits.generatedViewCards
        else { throw GeneratedViewError.capacity }
    }

    static func isView(_ card: CanvasCard) -> Bool {
        if case .generatedView = card.content { true } else { false }
    }

    static func view(_ text: String, provenance: CanvasGeneratedViewProvenance)
        -> CanvasGeneratedView
    {
        var provenance = provenance
        provenance.promptSummary = provenance.promptSummary.map { String($0.prefix(200)) }
        provenance.journal = Array(
            provenance.journal.suffix(CanvasLimits.generatedViewJournalEntries))
        return CanvasGeneratedView(
            specJSON: text, catalogVersion: RafuCatalog.version, provenance: provenance,
            state: nil)
    }

    static func title(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "View" : String(trimmed.prefix(120))
    }

    // MARK: Update

    func update(
        _ card: CanvasCardID, change: GeneratedViewChange,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) async throws -> GeneratedViewSummary {
        let current = try Self.view(card, on: board)
        let checked: Checked
        switch change {
        case .reset:
            Self.reset(card, on: board)
            return try summary(of: current.specJSON)
        case .spec(let text):
            checked = try check(text).get()
        case .patches(let text):
            let patches = try Self.patches(text)
            let spec = try check(current.specJSON).get().spec
            let (patched, errors, report) = await SpecStore.applying(
                patches, to: spec, catalog: RafuCatalog.rafu, limits: .default)
            if let error = errors.first { throw GeneratedViewError.invalidSpec(Self.text(error)) }
            guard report.valid else {
                throw GeneratedViewError.invalidSpec(Self.bounded(report.formatted()))
            }
            checked = try check(patched).get()
        }
        // The board can change while the patches apply.
        let latest = try Self.view(card, on: board)
        guard checked.text != latest.specJSON else { return checked.summary }
        if let refusal = GeneratedViewBudget.refusal(
            specJSON: checked.text, cards: board.cards, replacing: card)
        {
            throw refusal
        }
        try board.edit { document in
            guard let index = document.cards.firstIndex(where: { $0.id == card }),
                case .generatedView(var view) = document.cards[index].content
            else { return }
            view.specJSON = checked.text
            view.catalogVersion = RafuCatalog.version
            view.state = nil
            view.provenance.updatedAt = provenance.updatedAt ?? Date()
            document.cards[index].content = .generatedView(view)
        }
        return checked.summary
    }

    private func summary(of specJSON: String) throws -> GeneratedViewSummary {
        switch check(specJSON) {
        case .success(let checked): return checked.summary
        case .failure:
            // A saved view that no longer validates still resets.
            let spec = try? Spec.decode(Data(specJSON.utf8)).spec
            return GeneratedViewSummary(
                elementCount: spec?.elements.count ?? 0,
                types: Array(Set(spec?.elements.values.map(\.type) ?? []).sorted().prefix(8)),
                warnings: 0)
        }
    }

    static func view(_ id: CanvasCardID, on board: CanvasBoardState) throws -> CanvasGeneratedView {
        guard let card = board.cards.first(where: { $0.id == id }) else {
            throw GeneratedViewError.notAView
        }
        guard case .generatedView(let view) = card.content else {
            throw GeneratedViewError.notAView
        }
        return view
    }

    /// JSON Lines to patches. A bad line names its number and the decoder's
    /// fixed reason, never the line.
    static func patches(_ text: String) throws -> [SpecPatch] {
        var patches: [SpecPatch] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            switch SpecStreamDecoder.parseLine(trimmed) {
            case .success(let patch): patches.append(patch)
            case .failure(let error):
                throw GeneratedViewError.invalidSpec("line \(index + 1): \(error.rawValue)")
            }
        }
        guard !patches.isEmpty else { throw GeneratedViewError.invalidSpec("no patches") }
        return patches
    }

    private static func text(_ error: StreamError) -> String {
        switch error {
        case .badLine(let index, let reason): "line \(index + 1): \(reason)"
        case .patchFailed(let index, let op, let path, let reason):
            "patch \(index + 1) (\(op.rawValue) \(String(path.prefix(120)))): \(reason)"
        case .unrecoverable: "the patches could not be applied"
        case .budget(let kind): "the patched spec is over the \(kind.rawValue) limit"
        }
    }

    // MARK: Reset View

    /// Reset View for the menus and ⌥⌘R: the focused card, else the one
    /// selected card, when it is a view.
    static func resetTarget(on board: CanvasBoardState) -> CanvasCardID? {
        let id = board.focusedCardID ?? (board.selection.count == 1 ? board.selection.first : nil)
        guard let id, let card = board.cards.first(where: { $0.id == id }), isView(card) else {
            return nil
        }
        return id
    }

    /// Restores the view's initial state in one board undo step. The state
    /// shown now is first written into the board without an undo step, so
    /// Undo brings it back. Returns `false` when there was nothing to reset.
    @discardableResult
    static func reset(_ id: CanvasCardID, on board: CanvasBoardState) -> Bool {
        GeneratedViewModels.shared.existing(id, on: board)?.flushIntoDocument()
        guard let view = try? view(id, on: board), view.state != nil else {
            // Nothing saved yet: only the live store holds changes.
            GeneratedViewModels.shared.existing(id, on: board)?.resetLiveState()
            return false
        }
        do {
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == id }),
                    case .generatedView(var view) = document.cards[index].content
                else { return }
                view.state = nil
                document.cards[index].content = .generatedView(view)
            }
        } catch {
            board.showNotice(error.localizedDescription)
            return false
        }
        return true
    }

    // MARK: Streaming

    func beginStreaming(
        title: String, rect: CanvasRect, provenance: CanvasGeneratedViewProvenance,
        on board: CanvasBoardState
    ) throws -> any GeneratedViewStreamHandle {
        try checkRoom(on: board)
        let skeleton = GeneratedViewStreamSession.skeletonSpec
        if let refusal = GeneratedViewBudget.refusal(specJSON: skeleton, cards: board.cards) {
            throw refusal
        }
        let card = CanvasCard(
            title: Self.title(title), rect: rect,
            content: .generatedView(Self.view(skeleton, provenance: provenance)))
        try board.edit { $0.cards.append(card) }
        board.select([card.id])
        return GeneratedViewStreamSession(
            card: card, board: board, provenance: provenance, host: self)
    }
}
