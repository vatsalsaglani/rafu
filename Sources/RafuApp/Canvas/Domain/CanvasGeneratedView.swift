import Foundation

/// Who made or last changed a generated view (wave 3). Names, counts and ids
/// only; never spec text, state, or prop values.
nonisolated struct CanvasGeneratedViewProvenance: Codable, Equatable, Sendable {
    /// "Claude", "Codex", "Rafu (voice)" or "User" (`CanvasAgentNoticeText.vendor`).
    var creator: String
    /// "claude", "codex", "voice", "user".
    var provider: String
    var createdAt: Date
    var updatedAt: Date?
    /// At most 200 bytes; the spoken request or the tool title. Optional.
    var promptSummary: String?
    /// "allow", "ask" (approved) or "voice". How the creating call was admitted.
    var admission: String
    /// Stream journal lines (ids, ops, counts only), at most
    /// `CanvasLimits.generatedViewJournalEntries` lines of 160 bytes.
    var journal: [String]
}

/// The card's own state, saved with the board. Applied on load only when both
/// versions match the card's current spec and catalog.
nonisolated struct CanvasGeneratedViewState: Codable, Equatable, Sendable {
    /// SHA-256 (lowercase hex) of the canonical spec JSON without its `state` key.
    var specVersion: String
    var catalogVersion: String
    var savedAt: Date
    /// A JSON object, canonical (sorted keys), at most `CanvasLimits.generatedViewStateBytes`.
    var stateJSON: String
}

/// A generated view card: a declarative spec rendered natively (wave 3).
///
/// The Domain layer stores the spec as text so the board file never depends
/// on the json-render package's types; the app decodes and validates it.
nonisolated struct CanvasGeneratedView: Codable, Equatable, Sendable {
    /// Canonical JSON text (sorted keys, no escaped slashes) of the spec:
    /// `root`, `elements`, optional `state`. At most `CanvasLimits.generatedViewSpecBytes`.
    var specJSON: String
    var catalogVersion: String
    var provenance: CanvasGeneratedViewProvenance
    var state: CanvasGeneratedViewState?

    func validate() throws {
        guard specJSON.utf8.count <= CanvasLimits.generatedViewSpecBytes,
            let object = try? JSONSerialization.jsonObject(with: Data(specJSON.utf8))
                as? [String: Any],
            object["root"] is String, object["elements"] is [String: Any],
            CanvasStyleDecoding.validText(catalogVersion, limit: 64),
            !catalogVersion.isEmpty,
            CanvasStyleDecoding.validText(provenance.creator, limit: 60),
            CanvasStyleDecoding.validText(provenance.provider, limit: 16),
            CanvasStyleDecoding.validText(provenance.admission, limit: 16),
            provenance.promptSummary.map({ CanvasStyleDecoding.validText($0, limit: 200) })
                ?? true,
            provenance.journal.count <= CanvasLimits.generatedViewJournalEntries,
            provenance.journal.allSatisfy({ CanvasStyleDecoding.validText($0, limit: 160) })
        else { throw CanvasError.invalidDocument }
        if let state {
            guard state.stateJSON.utf8.count <= CanvasLimits.generatedViewStateBytes,
                (try? JSONSerialization.jsonObject(with: Data(state.stateJSON.utf8)))
                    is [String: Any],
                state.specVersion.utf8.count == 64,
                state.specVersion.allSatisfy(\.isHexDigit),
                CanvasStyleDecoding.validText(state.catalogVersion, limit: 64)
            else { throw CanvasError.invalidDocument }
        }
    }
}

/// Per-Ensemble consent for images from the web (wave 3). Written only from
/// the consent card, never by a tool. Absent means not granted.
nonisolated struct CanvasRemoteImageConsent: Codable, Equatable, Sendable {
    var allowed: Bool
    var grantedAt: Date
    /// Always "user".
    var grantedBy: String
}

/// Per-Ensemble permissions. Saved with the board in the private store only;
/// a `.rafuensemble` file never carries one user's consent.
nonisolated struct CanvasPermissions: Codable, Equatable, Sendable {
    var remoteImages: CanvasRemoteImageConsent?

    func validate() throws {
        if let remoteImages, remoteImages.grantedBy != "user" {
            throw CanvasError.invalidDocument
        }
    }
}
