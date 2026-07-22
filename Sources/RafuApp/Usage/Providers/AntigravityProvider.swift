// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum AntigravityProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .antigravity,
        displayName: "Antigravity",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads Antigravity's own signed-in OAuth token from its local state.vscdb; sends only that token to cloudcode-pa.googleapis.com/v1internal:loadCodeAssist and cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels (and v1internal:retrieveUserQuota only when needed) to fetch model quota percentages. No prompt or message content is read.",
        defaultEnabled: false,
        makeStrategies: { _ in [AntigravityLocalOAuthStrategy()] }
    )
}

nonisolated enum AntigravityUsageError: Error, Sendable, Equatable {
    case missingCredential
    case invalidCredentials
    case invalidResponse
}

/// Reads Antigravity's own signed-in OAuth token from its read-only
/// `state.vscdb` (the same VS Code-style local database Rafu already reads
/// for Cursor/Windsurf), then sends only that token to Google's Cloud Code
/// quota endpoints. It never refreshes credentials, onboards an account,
/// probes a process, runs an OAuth flow, or writes the source database.
nonisolated struct AntigravityLocalOAuthStrategy: UsageFetchStrategy {
    let id = "antigravity.local-oauth"

    private let databasePath: String
    private let fileExists: @Sendable (String) -> Bool

    init(
        databasePath: String = Self.defaultDatabasePath,
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.databasePath = databasePath
        self.fileExists = fileExists
    }

    /// Antigravity persists its signed-in OAuth token under this
    /// `ItemTable` key in its own `state.vscdb`.
    private static let oauthTokenKey = "antigravityUnifiedStateSync.oauthToken"

    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
            )
            .path
    }

    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let fetchAvailableModelsURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    private static let retrieveUserQuotaURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let maximumLocalFileBytes = 64 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        loadCredential() != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = loadCredential() else {
            throw AntigravityUsageError.missingCredential
        }

        let loadData = try await Self.send(
            url: Self.loadCodeAssistURL,
            accessToken: credential.accessToken,
            body: [
                "metadata": [
                    "ideType": "ANTIGRAVITY",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ]
            ],
            forbiddenMeansInvalidCredentials: true,
            context: context)
        let projectID = credential.projectID ?? Self.projectID(fromLoadCodeAssist: loadData)

        var quotas: [ModelQuota]
        var shouldVerifyQuotas = false
        do {
            let modelData = try await Self.send(
                url: Self.fetchAvailableModelsURL,
                accessToken: credential.accessToken,
                body: Self.projectBody(projectID),
                forbiddenMeansInvalidCredentials: false,
                context: context)
            quotas = try Self.parseAvailableModels(modelData)
            shouldVerifyQuotas =
                quotas.isEmpty
                || quotas.allSatisfy { $0.remainingFraction >= 0.999 }
        } catch UsageHTTPError.httpStatus(403) {
            quotas = try await Self.retrieveQuota(
                accessToken: credential.accessToken,
                projectID: projectID,
                context: context)
        }

        if shouldVerifyQuotas {
            // CodexBar verifies suspicious all-full model responses against the
            // quota-bucket endpoint. An unverified all-full response is not a
            // truthful usage signal, so Rafu does not display it.
            quotas = try await Self.retrieveQuota(
                accessToken: credential.accessToken,
                projectID: projectID,
                context: context)
        }

        let windows = Self.groupedWindows(quotas)
        guard !windows.isEmpty else { throw AntigravityUsageError.invalidResponse }
        return UsageSnapshot(
            providerID: .antigravity,
            windows: windows,
            costLine: nil,
            identity: credential.identity)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private struct LoadedCredential: Sendable {
        let accessToken: String
        let projectID: String?
        let identity: String?
    }

    private struct ModelQuota: Sendable {
        let modelID: String
        let remainingFraction: Double
        let resetsAt: Date?
    }

    private struct AvailableModelsResponse: Decodable, Sendable {
        let models: [String: AvailableModel]?
    }

    private struct AvailableModel: Decodable, Sendable {
        let quotaInfo: QuotaInfo?
    }

    private struct QuotaInfo: Decodable, Sendable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    private struct QuotaResponse: Decodable, Sendable {
        let buckets: [QuotaBucket]?
    }

    private struct QuotaBucket: Decodable, Sendable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }

    /// Reads Antigravity's opaque OAuth token from its own read-only
    /// `state.vscdb` via the bound-parameter SQLite shim (the token never
    /// enters SQL). The stored token carries no expiry, project, or email,
    /// so the project id is derived from the `loadCodeAssist` response and
    /// identity is left unset (Settings-only enrichment).
    private func loadCredential() -> LoadedCredential? {
        guard fileExists(databasePath),
            let rows = try? UsageSQLite.query(
                databasePath: databasePath,
                sql: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;",
                parameters: [Self.oauthTokenKey],
                columns: ["value"]),
            let accessToken = Self.cleanedCredential(rows.first?["value"])
        else { return nil }

        return LoadedCredential(accessToken: accessToken, projectID: nil, identity: nil)
    }

    private static func cleanedCredential(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= Self.maximumLocalFileBytes,
            !value.contains("\r"),
            !value.contains("\n")
        else { return nil }
        return value
    }

    private static func cleanedIdentifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= 512,
            !value.contains("\r"),
            !value.contains("\n")
        else { return nil }
        return value
    }

    private static func projectBody(_ projectID: String?) -> [String: Any] {
        if let projectID { return ["project": projectID] }
        return [:]
    }

    private static func send(
        url: URL,
        accessToken: String,
        body: [String: Any],
        forbiddenMeansInvalidCredentials: Bool,
        context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await context.http.send(request, provider: .antigravity)
        } catch UsageHTTPError.httpStatus(401) {
            throw AntigravityUsageError.invalidCredentials
        } catch UsageHTTPError.httpStatus(403) where forbiddenMeansInvalidCredentials {
            throw AntigravityUsageError.invalidCredentials
        } catch UsageHTTPError.httpStatus(let status) where (300..<400).contains(status) {
            throw AntigravityUsageError.invalidCredentials
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw AntigravityUsageError.invalidResponse
        }
        guard !Self.looksSignedOut(data: data, response: response) else {
            throw AntigravityUsageError.invalidCredentials
        }
        return data
    }

    private static func retrieveQuota(
        accessToken: String,
        projectID: String?,
        context: UsageFetchContext
    ) async throws -> [ModelQuota] {
        let data: Data
        do {
            data = try await Self.send(
                url: Self.retrieveUserQuotaURL,
                accessToken: accessToken,
                body: Self.projectBody(projectID),
                forbiddenMeansInvalidCredentials: false,
                context: context)
        } catch UsageHTTPError.httpStatus(403) {
            throw AntigravityUsageError.invalidResponse
        }
        return try Self.parseQuotaBuckets(data)
    }

    private static func projectID(fromLoadCodeAssist data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let project = object["cloudaicompanionProject"] as? String {
            return Self.cleanedIdentifier(project)
        }
        guard let project = object["cloudaicompanionProject"] as? [String: Any] else {
            return nil
        }
        return Self.cleanedIdentifier(project["id"] as? String)
            ?? Self.cleanedIdentifier(project["projectId"] as? String)
    }

    private static func parseAvailableModels(_ data: Data) throws -> [ModelQuota] {
        guard let response = try? JSONDecoder().decode(AvailableModelsResponse.self, from: data)
        else { throw AntigravityUsageError.invalidResponse }
        return (response.models ?? [:]).compactMap { modelID, model in
            Self.modelQuota(
                modelID: modelID,
                remainingFraction: model.quotaInfo?.remainingFraction,
                resetTime: model.quotaInfo?.resetTime)
        }
    }

    private static func parseQuotaBuckets(_ data: Data) throws -> [ModelQuota] {
        guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data),
            let buckets = response.buckets
        else { throw AntigravityUsageError.invalidResponse }

        var minimumByModel: [String: ModelQuota] = [:]
        for bucket in buckets {
            guard
                let quota = Self.modelQuota(
                    modelID: bucket.modelId,
                    remainingFraction: bucket.remainingFraction,
                    resetTime: bucket.resetTime)
            else { continue }
            if let existing = minimumByModel[quota.modelID],
                existing.remainingFraction <= quota.remainingFraction
            {
                continue
            }
            minimumByModel[quota.modelID] = quota
        }
        return Array(minimumByModel.values)
    }

    private static func modelQuota(
        modelID rawModelID: String?,
        remainingFraction: Double?,
        resetTime: String?
    ) -> ModelQuota? {
        guard let modelID = Self.cleanedIdentifier(rawModelID),
            let remainingFraction,
            remainingFraction.isFinite,
            (0...1).contains(remainingFraction)
        else { return nil }
        return ModelQuota(
            modelID: modelID,
            remainingFraction: remainingFraction,
            resetsAt: resetTime.flatMap(UsageDateParsing.parseISO8601Fractional))
    }

    private static func groupedWindows(_ quotas: [ModelQuota]) -> [UsageWindow] {
        let usable = quotas.filter { quota in
            let model = quota.modelID.lowercased()
            return !model.contains("lite")
                && !model.contains("image")
                && !model.contains("autocomplete")
                && !model.hasPrefix("tab_")
        }
        return [
            ("Gemini Models", usable.filter { $0.modelID.lowercased().contains("gemini") }),
            (
                "Claude and GPT",
                usable.filter {
                    let model = $0.modelID.lowercased()
                    return model.contains("claude") || model.contains("gpt")
                        || model.contains("openai")
                }
            ),
        ].compactMap { label, candidates in
            guard let representative = Self.mostConsumed(candidates) else { return nil }
            return UsageWindow(
                label: label,
                percent: (1 - representative.remainingFraction) * 100,
                tokens: nil,
                resetsAt: representative.resetsAt)
        }
    }

    private static func mostConsumed(_ quotas: [ModelQuota]) -> ModelQuota? {
        quotas.min { lhs, rhs in
            if lhs.remainingFraction != rhs.remainingFraction {
                return lhs.remainingFraction < rhs.remainingFraction
            }
            switch (lhs.resetsAt, rhs.resetsAt) {
            case (.some(let left), .some(let right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
        }
    }

    private static func looksSignedOut(data: Data, response: HTTPURLResponse) -> Bool {
        let host = response.url?.host?.lowercased() ?? ""
        let path = response.url?.path.lowercased() ?? ""
        if host == "accounts.google.com" || path.contains("signin") || path.contains("login") {
            return true
        }
        if response.mimeType?.lowercased() == "text/html" { return true }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }
}
