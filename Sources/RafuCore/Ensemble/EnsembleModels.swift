import Foundation

public enum EnsembleRunState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case running
    case awaitingGate
    case awaitingPlanGate
    case awaitingMergeGate
    case completed
    case failed
    case aborted
    case interrupted
    case merged
}

public struct EnsembleStepSummary: Codable, Hashable, Sendable {
    public let index: Int
    public let agentName: String
    public let provider: String
    public let model: String
    public let state: String
    public let attempt: Int
    public let evidencePath: String?
    public let artifacts: [String]

    public init(
        index: Int,
        agentName: String,
        provider: String,
        model: String,
        state: String,
        attempt: Int,
        evidencePath: String? = nil,
        artifacts: [String]
    ) {
        self.index = index
        self.agentName = agentName
        self.provider = provider
        self.model = model
        self.state = state
        self.attempt = attempt
        self.evidencePath = evidencePath
        self.artifacts = artifacts
    }
}

public struct EnsembleGateSummary: Codable, Hashable, Sendable {
    public let kind: String
    public let stepIndex: Int
    public let prompt: String?

    public init(kind: String, stepIndex: Int, prompt: String? = nil) {
        self.kind = kind
        self.stepIndex = stepIndex
        self.prompt = prompt
    }
}

public struct EnsembleRunSummary: Codable, Hashable, Sendable {
    public let runID: String
    public let workflowName: String
    public let label: String?
    public let state: EnsembleRunState
    public let startedBy: String?
    public let gate: EnsembleGateSummary?
    public let steps: [EnsembleStepSummary]
    public let usageLines: [String]

    public init(
        runID: String,
        workflowName: String,
        label: String? = nil,
        state: EnsembleRunState,
        startedBy: String? = nil,
        gate: EnsembleGateSummary? = nil,
        steps: [EnsembleStepSummary],
        usageLines: [String]
    ) {
        self.runID = runID
        self.workflowName = workflowName
        self.label = label
        self.state = state
        self.startedBy = startedBy
        self.gate = gate
        self.steps = steps
        self.usageLines = usageLines
    }
}

public struct EnsembleStatusResult: Codable, Hashable, Sendable {
    public let runs: [EnsembleRunSummary]
    public let cursor: UInt64
    public let verbVersion: Int
    public let tree: Bool
    /// Incremental events requested with `--since`. Empty for a full snapshot.
    public let events: [EnsembleEvent]

    public init(
        runs: [EnsembleRunSummary],
        cursor: UInt64,
        verbVersion: Int,
        tree: Bool,
        events: [EnsembleEvent] = []
    ) {
        self.runs = runs
        self.cursor = cursor
        self.verbVersion = verbVersion
        self.tree = tree
        self.events = events
    }
}

public struct EnsembleArtifactResult: Codable, Hashable, Sendable {
    public let runID: String
    public let stepIndex: Int
    public let artifacts: [String]

    public init(runID: String, stepIndex: Int, artifacts: [String]) {
        self.runID = runID
        self.stepIndex = stepIndex
        self.artifacts = artifacts
    }
}

public struct EnsembleRoleOverride: Codable, Hashable, Sendable {
    public let name: String
    public let provider: String
    public let model: String?

    public init(name: String, provider: String, model: String? = nil) {
        self.name = name
        self.provider = provider
        self.model = model
    }
}

public struct EnsembleRunStartResult: Codable, Hashable, Sendable {
    public let runID: String
    public let workflow: String
    public let worktree: String
    public let branch: String
    public let state: EnsembleRunState
    public let startedBy: String

    public init(
        runID: String,
        workflow: String,
        worktree: String,
        branch: String,
        state: EnsembleRunState,
        startedBy: String
    ) {
        self.runID = runID
        self.workflow = workflow
        self.worktree = worktree
        self.branch = branch
        self.state = state
        self.startedBy = startedBy
    }
}

public struct EnsembleMutationResult: Codable, Hashable, Sendable {
    public let verb: String
    public let runID: String
    public let state: EnsembleRunState?

    public init(verb: String, runID: String, state: EnsembleRunState? = nil) {
        self.verb = verb
        self.runID = runID
        self.state = state
    }
}

public struct EnsembleGrantResult: Codable, Hashable, Sendable {
    public let maxConcurrentChildRuns: Int
    public let activeChildRuns: Int
    public let maxTotalChildRuns: Int
    public let startedChildRuns: Int
    public let allowedProviders: [String]
    public let deadline: Date?
    public let usageConsumedPercentPoints: Double?
    public let usageCeilingPercentPoints: Double?

    public init(
        maxConcurrentChildRuns: Int,
        activeChildRuns: Int,
        maxTotalChildRuns: Int,
        startedChildRuns: Int,
        allowedProviders: [String],
        deadline: Date? = nil,
        usageConsumedPercentPoints: Double? = nil,
        usageCeilingPercentPoints: Double? = nil
    ) {
        self.maxConcurrentChildRuns = maxConcurrentChildRuns
        self.activeChildRuns = activeChildRuns
        self.maxTotalChildRuns = maxTotalChildRuns
        self.startedChildRuns = startedChildRuns
        self.allowedProviders = allowedProviders
        self.deadline = deadline
        self.usageConsumedPercentPoints = usageConsumedPercentPoints
        self.usageCeilingPercentPoints = usageCeilingPercentPoints
    }
}

public struct EnsembleEvent: Codable, Hashable, Sendable {
    public let cursor: UInt64
    public let at: Date
    public let runID: String
    public let kind: String
    public let state: EnsembleRunState?
    public let stepIndex: Int?
    public let note: String?
    public let label: String?
    public let startedBy: String?

    public init(
        cursor: UInt64,
        at: Date,
        runID: String,
        kind: String,
        state: EnsembleRunState? = nil,
        stepIndex: Int? = nil,
        note: String? = nil,
        label: String? = nil,
        startedBy: String? = nil
    ) {
        self.cursor = cursor
        self.at = at
        self.runID = runID
        self.kind = kind
        self.state = state
        self.stepIndex = stepIndex
        self.note = note
        self.label = label
        self.startedBy = startedBy
    }
}

public struct EnsembleRequestPayload: Codable, Hashable, Sendable {
    public let verb: String
    public let workingDirectory: String
    public let runIDs: [String]
    public let stepIndex: Int?
    public let states: [EnsembleRunState]
    public let any: Bool
    public let sinceCursor: UInt64?
    public let token: String?
    public let tree: Bool?
    public let workflow: String?
    public let roleOverrides: [EnsembleRoleOverride]?
    public let prompt: String?
    public let artifacts: [String]?
    public let baseReference: String?
    public let label: String?
    public let text: String?

    public init(
        verb: String,
        workingDirectory: String,
        runIDs: [String] = [],
        stepIndex: Int? = nil,
        states: [EnsembleRunState] = [],
        any: Bool = false,
        sinceCursor: UInt64? = nil,
        token: String? = nil,
        tree: Bool? = nil,
        workflow: String? = nil,
        roleOverrides: [EnsembleRoleOverride]? = nil,
        prompt: String? = nil,
        artifacts: [String]? = nil,
        baseReference: String? = nil,
        label: String? = nil,
        text: String? = nil
    ) {
        self.verb = verb
        self.workingDirectory = workingDirectory
        self.runIDs = runIDs
        self.stepIndex = stepIndex
        self.states = states
        self.any = any
        self.sinceCursor = sinceCursor
        self.token = token
        self.tree = tree
        self.workflow = workflow
        self.roleOverrides = roleOverrides
        self.prompt = prompt
        self.artifacts = artifacts
        self.baseReference = baseReference
        self.label = label
        self.text = text
    }
}

public enum EnsembleResponsePayload: Hashable, Sendable {
    case status(EnsembleStatusResult)
    case artifact(EnsembleArtifactResult)
    case runStarted(EnsembleRunStartResult)
    case mutation(EnsembleMutationResult)
    case grant(EnsembleGrantResult)
    case subscribed(cursor: UInt64)
    case failure(code: Int32, message: String)
}

extension EnsembleResponsePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case result
        case status
        case artifact
        case runStarted
        case mutation
        case grant
        case cursor
        case code
        case message
    }

    private enum Result: String, Codable {
        case status
        case artifact
        case runStarted
        case mutation
        case grant
        case subscribed
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Result.self, forKey: .result) {
        case .status:
            self = .status(try container.decode(EnsembleStatusResult.self, forKey: .status))
        case .artifact:
            self = .artifact(try container.decode(EnsembleArtifactResult.self, forKey: .artifact))
        case .runStarted:
            self = .runStarted(
                try container.decode(EnsembleRunStartResult.self, forKey: .runStarted))
        case .mutation:
            self = .mutation(
                try container.decode(EnsembleMutationResult.self, forKey: .mutation))
        case .grant:
            self = .grant(try container.decode(EnsembleGrantResult.self, forKey: .grant))
        case .subscribed:
            self = .subscribed(cursor: try container.decode(UInt64.self, forKey: .cursor))
        case .failure:
            self = .failure(
                code: try container.decode(Int32.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let value):
            try container.encode(Result.status, forKey: .result)
            try container.encode(value, forKey: .status)
        case .artifact(let value):
            try container.encode(Result.artifact, forKey: .result)
            try container.encode(value, forKey: .artifact)
        case .runStarted(let value):
            try container.encode(Result.runStarted, forKey: .result)
            try container.encode(value, forKey: .runStarted)
        case .mutation(let value):
            try container.encode(Result.mutation, forKey: .result)
            try container.encode(value, forKey: .mutation)
        case .grant(let value):
            try container.encode(Result.grant, forKey: .result)
            try container.encode(value, forKey: .grant)
        case .subscribed(let cursor):
            try container.encode(Result.subscribed, forKey: .result)
            try container.encode(cursor, forKey: .cursor)
        case .failure(let code, let message):
            try container.encode(Result.failure, forKey: .result)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}
