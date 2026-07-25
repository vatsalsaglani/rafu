import Foundation
import RafuCore

nonisolated struct ConductorEnsembleGrant: Sendable {
    var maxConcurrentChildRuns: Int = 3
    var maxTotalChildRuns: Int = 12
    var allowedProviders: [ConductorCLIID]
    var usageCeilingPercentPoints: Double? = nil
    var deadline: Date? = nil
}

nonisolated enum ConductorEnsembleGrantViolation: Error, Equatable, Sendable {
    case noToken
    case providerNotAllowed(ConductorCLIID)
    case concurrentLimit(limit: Int)
    case totalLimit(limit: Int)
    case deadline(Date)
    case usageCeiling(consumed: Double, ceiling: Double)

    var exitCode: Int32 {
        switch self {
        case .noToken, .providerNotAllowed:
            77
        case .concurrentLimit, .totalLimit, .deadline, .usageCeiling:
            75
        }
    }

    var reason: String {
        switch self {
        case .noToken:
            "A live Ensemble coordinator capability is required."
        case .providerNotAllowed(let provider):
            "\(provider.displayName) is not allowed by this coordinator grant."
        case .concurrentLimit(let limit):
            "The coordinator grant already has \(limit) active child runs."
        case .totalLimit(let limit):
            "The coordinator grant has used its \(limit)-run total allowance."
        case .deadline:
            "The coordinator grant deadline has passed."
        case .usageCeiling(let consumed, let ceiling):
            "The coordinator grant usage ceiling is exhausted (\(consumed) of \(ceiling) percentage points)."
        }
    }
}

@MainActor
final class ConductorEnsembleTokenStore {
    typealias RandomBytes = @MainActor (Int) -> [UInt8]
    typealias Clock = @MainActor () -> Date

    nonisolated struct Entry: Equatable, Sendable {
        let coordinatorID: String
        let grant: ConductorEnsembleGrant
        var startedRunIDs: [String]
        let mintedAt: Date

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.coordinatorID == rhs.coordinatorID
                && lhs.grant.maxConcurrentChildRuns == rhs.grant.maxConcurrentChildRuns
                && lhs.grant.maxTotalChildRuns == rhs.grant.maxTotalChildRuns
                && lhs.grant.allowedProviders.map(\.rawValue)
                    == rhs.grant.allowedProviders.map(\.rawValue)
                && lhs.grant.usageCeilingPercentPoints
                    == rhs.grant.usageCeilingPercentPoints
                && lhs.grant.deadline == rhs.grant.deadline
                && lhs.startedRunIDs == rhs.startedRunIDs
                && lhs.mintedAt == rhs.mintedAt
        }
    }

    nonisolated struct Enforcement: Sendable {
        let entry: Entry
        let activeChildRuns: Int
        let usageConsumedPercentPoints: Double?
    }

    static let shared = ConductorEnsembleTokenStore()

    private var entriesByToken: [String: Entry] = [:]
    private var reservedRunIDsByToken: [String: Set<String>] = [:]
    private let randomBytes: RandomBytes
    private let clock: Clock

    init(
        randomBytes: @escaping RandomBytes = { count in
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            }
        },
        clock: @escaping Clock = Date.init
    ) {
        self.randomBytes = randomBytes
        self.clock = clock
    }

    func mint(coordinatorID: String, grant: ConductorEnsembleGrant) -> String {
        revoke(coordinatorID: coordinatorID)
        var token: String
        repeat {
            let bytes = randomBytes(32)
            precondition(bytes.count == 32, "Ensemble token RNG must return exactly 32 bytes")
            token = Self.base64URL(bytes)
        } while entriesByToken[token] != nil

        entriesByToken[token] = Entry(
            coordinatorID: coordinatorID,
            grant: grant,
            startedRunIDs: [],
            mintedAt: clock()
        )
        return token
    }

    func validate(_ token: String?) -> Entry? {
        guard let token, !token.isEmpty else { return nil }
        return entriesByToken[token]
    }

    func recordChildRun(token: String, runID: String) {
        guard var entry = entriesByToken[token] else { return }
        reservedRunIDsByToken[token]?.remove(runID)
        if !entry.startedRunIDs.contains(runID) {
            entry.startedRunIDs.append(runID)
            entriesByToken[token] = entry
        }
    }

    func revoke(coordinatorID: String) {
        let removedTokens = entriesByToken.compactMap { token, entry in
            entry.coordinatorID == coordinatorID ? token : nil
        }
        entriesByToken = entriesByToken.filter { _, entry in
            entry.coordinatorID != coordinatorID
        }
        for token in removedTokens {
            reservedRunIDsByToken.removeValue(forKey: token)
        }
    }

    func reserveChildRun(token: String, runID: String) -> Bool {
        guard entriesByToken[token] != nil else { return false }
        reservedRunIDsByToken[token, default: []].insert(runID)
        return true
    }

    func cancelChildRunReservation(token: String, runID: String) {
        reservedRunIDsByToken[token]?.remove(runID)
    }

    func enforce(
        token: String?,
        providers: [ConductorCLIID],
        inFlightRunIDs: Set<String>,
        manifests: [ConductorRunManifest]
    ) -> Result<Enforcement, ConductorEnsembleGrantViolation> {
        guard let token, let entry = validate(token) else {
            return .failure(.noToken)
        }

        for provider in providers
        where !entry.grant.allowedProviders.contains(where: { $0 == provider }) {
            return .failure(.providerNotAllowed(provider))
        }

        if let deadline = entry.grant.deadline, clock() >= deadline {
            return .failure(.deadline(deadline))
        }

        let reserved = reservedRunIDsByToken[token]?.count ?? 0
        let active = entry.startedRunIDs.filter(inFlightRunIDs.contains).count + reserved
        if active >= max(0, entry.grant.maxConcurrentChildRuns) {
            return .failure(
                .concurrentLimit(limit: max(0, entry.grant.maxConcurrentChildRuns)))
        }
        if entry.startedRunIDs.count + reserved >= max(0, entry.grant.maxTotalChildRuns) {
            return .failure(.totalLimit(limit: max(0, entry.grant.maxTotalChildRuns)))
        }

        let consumed = Self.usageConsumed(entry: entry, manifests: manifests)
        if let ceiling = entry.grant.usageCeilingPercentPoints,
            ceiling.isFinite,
            let consumed,
            consumed >= ceiling
        {
            return .failure(.usageCeiling(consumed: consumed, ceiling: ceiling))
        }

        return .success(
            Enforcement(
                entry: entry,
                activeChildRuns: active,
                usageConsumedPercentPoints: consumed
            ))
    }

    func status(
        token: String?,
        inFlightRunIDs: Set<String>,
        manifests: [ConductorRunManifest]
    ) -> Result<Enforcement, ConductorEnsembleGrantViolation> {
        guard let token, let entry = validate(token) else {
            return .failure(.noToken)
        }
        return .success(
            Enforcement(
                entry: entry,
                activeChildRuns: entry.startedRunIDs.filter(inFlightRunIDs.contains).count
                    + (reservedRunIDsByToken[token]?.count ?? 0),
                usageConsumedPercentPoints: Self.usageConsumed(
                    entry: entry,
                    manifests: manifests
                )
            ))
    }

    private static func usageConsumed(
        entry: Entry,
        manifests: [ConductorRunManifest]
    ) -> Double? {
        let started = Set(entry.startedRunIDs)
        let values =
            manifests
            .filter { started.contains($0.id) }
            .flatMap(\.steps)
            .compactMap(\.usage)
            .flatMap(\.providers)
            .flatMap(\.windows)
            .compactMap(\.percentPoints)
            .filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
