// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum AntigravityProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .antigravity,
        displayName: "Antigravity",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads the unexpired access token in ~/.codexbar/antigravity/oauth_creds.json; sends only that token to cloudcode-pa.googleapis.com/v1internal:loadCodeAssist and cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels (and v1internal:retrieveUserQuota only when needed) to fetch model quota percentages.",
        defaultEnabled: false,
        makeStrategies: { _ in [AntigravityLocalOAuthStrategy()] }
    )
}

nonisolated enum AntigravityUsageError: Error, Sendable, Equatable {
    case missingCredential
    case invalidCredentials
    case invalidResponse
}

/// Uses only the narrow credential-file capability available through
/// `UsageFetchContext`. It never refreshes credentials, onboards an account,
/// probes a process, or writes the source file.
nonisolated struct AntigravityLocalOAuthStrategy: UsageFetchStrategy {
    let id = "antigravity.local-oauth"

    private static let credentialsPath = ".codexbar/antigravity/oauth_creds.json"
    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let fetchAvailableModelsURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    private static let retrieveUserQuotaURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let maximumLocalFileBytes = 64 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.loadCredential(context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = Self.loadCredential(context) else {
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

    private struct Credential: Decodable, Sendable {
        let accessToken: String?
        let expiryDateMilliseconds: Double?
        let idToken: String?
        let email: String?
        let projectID: String?

        private enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case expiryDateSnake = "expiry_date"
            case expiresAtCamel = "expiresAt"
            case idTokenSnake = "id_token"
            case idTokenCamel = "idToken"
            case email
            case projectIDSnake = "project_id"
            case projectIDCamel = "projectId"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken =
                try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            idToken =
                try container.decodeIfPresent(String.self, forKey: .idTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .idTokenCamel)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            projectID =
                try container.decodeIfPresent(String.self, forKey: .projectIDSnake)
                ?? container.decodeIfPresent(String.self, forKey: .projectIDCamel)
            if let value = try? container.decode(Double.self, forKey: .expiryDateSnake) {
                expiryDateMilliseconds = value
            } else if let value = try? container.decode(Double.self, forKey: .expiresAtCamel) {
                expiryDateMilliseconds = value
            } else if let value = try? container.decode(String.self, forKey: .expiryDateSnake) {
                expiryDateMilliseconds = Double(value)
            } else if let value = try? container.decode(String.self, forKey: .expiresAtCamel) {
                expiryDateMilliseconds = Double(value)
            } else {
                expiryDateMilliseconds = nil
            }
        }
    }

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

    private static func loadCredential(_ context: UsageFetchContext) -> LoadedCredential? {
        guard let contents = context.readFile(Self.credentialsPath),
            contents.utf8.count <= Self.maximumLocalFileBytes,
            let data = contents.data(using: .utf8),
            let credential = try? JSONDecoder().decode(Credential.self, from: data),
            let accessToken = Self.cleanedCredential(credential.accessToken),
            credential.expiryDateMilliseconds.map({ milliseconds in
                milliseconds.isFinite
                    && milliseconds / 1_000 > context.now.timeIntervalSince1970
            }) != false
        else { return nil }

        return LoadedCredential(
            accessToken: accessToken,
            projectID: Self.cleanedIdentifier(credential.projectID),
            identity: Self.email(fromIDToken: credential.idToken)
                ?? Self.cleanedIdentity(credential.email))
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

    private static func cleanedIdentity(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= 512,
            !value.contains("\r"),
            !value.contains("\n")
        else { return nil }
        return value
    }

    private static func email(fromIDToken token: String?) -> String? {
        guard let token, token.utf8.count <= Self.maximumLocalFileBytes else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
            data.count <= Self.maximumLocalFileBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.cleanedIdentity(object["email"] as? String)
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
