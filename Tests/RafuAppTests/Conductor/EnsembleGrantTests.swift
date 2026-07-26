import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble capability grant")
struct EnsembleGrantTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A capability is 32 random bytes, live only until coordinator revocation")
    func lifecycle() throws {
        let store = makeStore()
        let token = store.mint(
            coordinatorID: "co-lifecycle",
            grant: grant()
        )

        #expect(Data(base64URL: token)?.count == 32)
        #expect(store.validate(token)?.coordinatorID == "co-lifecycle")
        #expect(store.validate(nil) == nil)

        store.recordChildRun(token: token, runID: "run-a")
        #expect(store.validate(token)?.startedRunIDs == ["run-a"])

        store.revoke(coordinatorID: "co-lifecycle")
        #expect(store.validate(token) == nil)
    }

    @Test("Missing and disallowed authority are typed 77 failures")
    func authorityFailures() throws {
        let store = makeStore()
        let token = store.mint(
            coordinatorID: "co-auth",
            grant: grant(providers: [.codex])
        )

        let missing = try #require(
            store.enforce(
                token: nil,
                providers: [.codex],
                inFlightRunIDs: [],
                manifests: []
            ).failure
        )
        let disallowed = try #require(
            store.enforce(
                token: token,
                providers: [.claudeCode],
                inFlightRunIDs: [],
                manifests: []
            ).failure
        )

        #expect(missing == .noToken)
        #expect(missing.exitCode == 77)
        #expect(disallowed == .providerNotAllowed(.claudeCode))
        #expect(disallowed.exitCode == 77)
    }

    @Test("Concurrent and total ceilings park the next run with typed 75")
    func countCeilings() throws {
        let concurrentStore = makeStore()
        let concurrentToken = concurrentStore.mint(
            coordinatorID: "co-concurrent",
            grant: grant(concurrent: 1, total: 3)
        )
        concurrentStore.recordChildRun(token: concurrentToken, runID: "run-active")
        let concurrent = try #require(
            concurrentStore.enforce(
                token: concurrentToken,
                providers: [.codex],
                inFlightRunIDs: ["run-active"],
                manifests: []
            ).failure
        )
        #expect(concurrent == .concurrentLimit(limit: 1))
        #expect(concurrent.exitCode == 75)

        let totalStore = makeStore()
        let totalToken = totalStore.mint(
            coordinatorID: "co-total",
            grant: grant(concurrent: 3, total: 1)
        )
        totalStore.recordChildRun(token: totalToken, runID: "run-finished")
        let total = try #require(
            totalStore.enforce(
                token: totalToken,
                providers: [.codex],
                inFlightRunIDs: [],
                manifests: []
            ).failure
        )
        #expect(total == .totalLimit(limit: 1))
        #expect(total.exitCode == 75)
    }

    @Test("Deadline and metered usage ceilings are typed 75")
    func deadlineAndUsage() throws {
        let deadlineStore = makeStore()
        let deadline = now.addingTimeInterval(-1)
        let deadlineToken = deadlineStore.mint(
            coordinatorID: "co-deadline",
            grant: grant(deadline: deadline)
        )
        let expired = try #require(
            deadlineStore.enforce(
                token: deadlineToken,
                providers: [.codex],
                inFlightRunIDs: [],
                manifests: []
            ).failure
        )
        #expect(expired == .deadline(deadline))
        #expect(expired.exitCode == 75)

        let usageStore = makeStore()
        let usageToken = usageStore.mint(
            coordinatorID: "co-usage",
            grant: grant(usage: 4)
        )
        usageStore.recordChildRun(token: usageToken, runID: "run-metered")
        let exhausted = try #require(
            usageStore.enforce(
                token: usageToken,
                providers: [.codex],
                inFlightRunIDs: [],
                manifests: [
                    manifest(id: "run-metered", percentPoints: 4)
                ]
            ).failure
        )
        #expect(exhausted == .usageCeiling(consumed: 4, ceiling: 4))
        #expect(exhausted.exitCode == 75)
    }

    @Test("An unresolved meter honestly does not trip a usage ceiling")
    func unmeteredUsage() throws {
        let store = makeStore()
        let token = store.mint(
            coordinatorID: "co-unmetered",
            grant: grant(usage: 0)
        )
        store.recordChildRun(token: token, runID: "run-unmetered")

        let enforcement = try #require(
            store.enforce(
                token: token,
                providers: [.codex],
                inFlightRunIDs: [],
                manifests: [manifest(id: "run-unmetered", percentPoints: nil)]
            ).success
        )
        #expect(enforcement.usageConsumedPercentPoints == nil)
    }

    @Test("No typed reason ever echoes the capability")
    func capabilityNeverEchoed() {
        let capability = "never-echo-this-capability"
        let reasons = [
            ConductorEnsembleGrantViolation.noToken,
            .providerNotAllowed(.codex),
            .concurrentLimit(limit: 1),
            .totalLimit(limit: 2),
            .deadline(now),
            .usageCeiling(consumed: 3, ceiling: 2),
        ].map(\.reason)

        #expect(reasons.allSatisfy { !$0.contains(capability) })
    }

    private func makeStore() -> ConductorEnsembleTokenStore {
        ConductorEnsembleTokenStore(
            randomBytes: { count in
                Array((0..<count).map { UInt8($0 % 251) })
            },
            clock: { now }
        )
    }

    private func grant(
        concurrent: Int = 3,
        total: Int = 12,
        providers: [ConductorCLIID] = [.codex],
        usage: Double? = nil,
        deadline: Date? = nil
    ) -> ConductorEnsembleGrant {
        ConductorEnsembleGrant(
            maxConcurrentChildRuns: concurrent,
            maxTotalChildRuns: total,
            allowedProviders: providers,
            usageCeilingPercentPoints: usage,
            deadline: deadline
        )
    }

    private func manifest(
        id: String,
        percentPoints: Double?
    ) -> ConductorRunManifest {
        let usage = percentPoints.map {
            ConductorRunUsageRecord(
                attempt: 1,
                providers: [
                    .init(
                        providerID: .codex,
                        windows: [
                            .init(label: "5h", percentPoints: $0, tokens: nil)
                        ]
                    )
                ]
            )
        }
        return ConductorRunManifest(
            id: id,
            workflowName: "Workflow",
            baseCommit: "abc",
            worktreeBranch: "rafu/run-\(id)",
            createdAt: now,
            updatedAt: now,
            steps: [
                .init(
                    agentName: "worker",
                    binding: .init(
                        provider: .codex,
                        model: "fake",
                        autonomy: .worktreeWrite,
                        adapterVersion: "1"
                    ),
                    inputArtifacts: [],
                    handoffArtifact: "report.md",
                    gateAfter: false,
                    status: .completed,
                    startedAt: now,
                    finishedAt: now,
                    usage: usage
                )
            ],
            startedBy: "co-usage"
        )
    }
}

extension Data {
    fileprivate init?(base64URL: String) {
        var value =
            base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value.append(String(repeating: "=", count: (4 - value.count % 4) % 4))
        self.init(base64Encoded: value)
    }
}

extension Result {
    fileprivate var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    fileprivate var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
