import Foundation

// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

/// Reads the reusable OAuth credential written by Gemini CLI at
/// `~/.gemini/oauth_creds.json`, then follows Gemini CLI's Cloud Code
/// quota request chain. Rafu deliberately does not refresh or rewrite the
/// credential: an absent or expired access token simply makes this
/// strategy unavailable.
nonisolated struct GeminiCLILocalTokenStrategy: UsageFetchStrategy {
    let id = "gemini-cli.local-token"

    // `UsageFetchContext.readFile` paths are home-relative, so these
    // resolve to the observed `~/.gemini/...` files in production.
    private static let credentialsPath = ".gemini/oauth_creds.json"
    private static let settingsPath = ".gemini/settings.json"
    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let projectsURL = URL(
        string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
    private static let quotaURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let maximumLocalFileBytes = 64 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.loadCredential(context) != nil && Self.supportsConfiguredAuth(context)
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard Self.supportsConfiguredAuth(context),
            let credential = Self.loadCredential(context)
        else {
            throw UsageLocalDataError.noData
        }

        var projectID: String?
        do {
            let data = try await Self.loadCodeAssist(
                accessToken: credential.accessToken, context: context)
            projectID = Self.parseProjectID(fromLoadCodeAssist: data)
        } catch {
            // CodexBar treats this setup probe as best-effort and still
            // attempts project discovery/quota retrieval.
            projectID = nil
        }

        if projectID == nil {
            do {
                let data = try await Self.discoverProjects(
                    accessToken: credential.accessToken, context: context)
                projectID = Self.parseProjectID(fromProjects: data)
            } catch {
                // A project is optional; retrieveUserQuota accepts `{}`.
                projectID = nil
            }
        }

        let data = try await Self.retrieveQuota(
            accessToken: credential.accessToken, projectID: projectID, context: context)
        guard data.count <= Self.maximumResponseBytes,
            let snapshot = Self.parseQuotaResponse(
                data, identity: Self.email(fromIDToken: credential.idToken))
        else {
            throw UsageLocalDataError.noData
        }
        return snapshot
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private struct Credential: Decodable {
        let accessToken: String?
        let idToken: String?
        let expiryDate: Double?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case expiryDate = "expiry_date"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.accessToken = try? container.decode(String.self, forKey: .accessToken)
            self.idToken = try? container.decode(String.self, forKey: .idToken)
            if let value = try? container.decode(Double.self, forKey: .expiryDate) {
                self.expiryDate = value
            } else if let value = try? container.decode(String.self, forKey: .expiryDate) {
                self.expiryDate = Double(value)
            } else {
                self.expiryDate = nil
            }
        }
    }

    private struct Settings: Decodable {
        let security: Security?

        struct Security: Decodable {
            let auth: Auth?
        }

        struct Auth: Decodable {
            let selectedType: String?
        }
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
    }

    private struct ModelQuota {
        let remainingFraction: Double
        let resetTime: String?
    }

    private static func loadCredential(_ context: UsageFetchContext) -> (
        accessToken: String, idToken: String?
    )? {
        guard let contents = context.readFile(Self.credentialsPath),
            contents.utf8.count <= Self.maximumLocalFileBytes,
            let data = contents.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Credential.self, from: data),
            let accessToken = cleanedToken(decoded.accessToken),
            decoded.expiryDate.map({
                $0.isFinite && $0 / 1_000 > context.now.timeIntervalSince1970
            }) != false
        else { return nil }
        return (accessToken, decoded.idToken)
    }

    private static func supportsConfiguredAuth(_ context: UsageFetchContext) -> Bool {
        guard let contents = context.readFile(Self.settingsPath) else { return true }
        guard contents.utf8.count <= Self.maximumLocalFileBytes,
            let data = contents.data(using: .utf8),
            let settings = try? JSONDecoder().decode(Settings.self, from: data),
            let selectedType = settings.security?.auth?.selectedType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            // Missing/unrecognized settings mean "try the OAuth creds",
            // matching CodexBar's `.unknown` auth behavior.
            return true
        }
        return selectedType != "api-key" && selectedType != "gemini-api-key"
            && selectedType != "vertex-ai"
    }

    private static func cleanedToken(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, value.utf8.count <= Self.maximumLocalFileBytes,
            !value.contains("\r"), !value.contains("\n")
        else { return nil }
        return value
    }

    private static func loadCodeAssist(
        accessToken: String, context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: Self.loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
        let (data, _) = try await context.http.send(request, provider: .geminiCLI)
        guard data.count <= Self.maximumResponseBytes else { throw UsageLocalDataError.noData }
        return data
    }

    private static func discoverProjects(
        accessToken: String, context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: Self.projectsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await context.http.send(request, provider: .geminiCLI)
        guard data.count <= Self.maximumResponseBytes else { throw UsageLocalDataError.noData }
        return data
    }

    private static func retrieveQuota(
        accessToken: String, projectID: String?, context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let projectID {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["project": projectID], options: [.sortedKeys])
        } else {
            request.httpBody = Data("{}".utf8)
        }
        let (data, _) = try await context.http.send(request, provider: .geminiCLI)
        return data
    }

    private static func parseProjectID(fromLoadCodeAssist data: Data) -> String? {
        guard data.count <= Self.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let rawProject = object["cloudaicompanionProject"]
        if let project = rawProject as? String {
            return cleanedProjectID(project)
        }
        if let project = rawProject as? [String: Any] {
            return cleanedProjectID(project["id"] as? String)
                ?? cleanedProjectID(project["projectId"] as? String)
        }
        return nil
    }

    private static func parseProjectID(fromProjects data: Data) -> String? {
        guard data.count <= Self.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = object["projects"] as? [[String: Any]]
        else { return nil }
        for project in projects {
            guard let projectID = cleanedProjectID(project["projectId"] as? String) else {
                continue
            }
            if projectID.hasPrefix("gen-lang-client") {
                return projectID
            }
            if let labels = project["labels"] as? [String: Any],
                labels["generative-language"] != nil
            {
                return projectID
            }
        }
        return nil
    }

    private static func cleanedProjectID(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, value.utf8.count <= 256
        else { return nil }
        return value
    }

    static func parseQuotaResponse(_ data: Data, identity: String?) -> UsageSnapshot? {
        guard data.count <= Self.maximumResponseBytes,
            let response = try? JSONDecoder().decode(QuotaResponse.self, from: data),
            let buckets = response.buckets, !buckets.isEmpty
        else { return nil }

        var byModel: [String: ModelQuota] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                !modelID.isEmpty,
                let remainingFraction = bucket.remainingFraction,
                remainingFraction.isFinite,
                (0...1).contains(remainingFraction)
            else { continue }
            if let existing = byModel[modelID],
                existing.remainingFraction <= remainingFraction
            {
                continue
            }
            byModel[modelID] = ModelQuota(
                remainingFraction: remainingFraction, resetTime: bucket.resetTime)
        }

        let lowercased = byModel.map { ($0.key.lowercased(), $0.value) }
        let pro = lowercased.filter { $0.0.contains("pro") }.map(\.1)
        let flashLite = lowercased.filter { $0.0.contains("flash-lite") }.map(\.1)
        let flash = lowercased.filter {
            $0.0.contains("flash") && !$0.0.contains("flash-lite")
        }.map(\.1)

        let windows = [
            makeWindow(label: "Pro", quotas: pro),
            makeWindow(label: "Flash", quotas: flash),
            makeWindow(label: "Flash Lite", quotas: flashLite),
        ].compactMap(\.self)
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            providerID: .geminiCLI, windows: windows, costLine: nil, identity: identity)
    }

    private static func makeWindow(label: String, quotas: [ModelQuota]) -> UsageWindow? {
        guard
            let quota = quotas.min(by: {
                $0.remainingFraction < $1.remainingFraction
            })
        else { return nil }
        return UsageWindow(
            label: label,
            percent: 100 - quota.remainingFraction * 100,
            tokens: nil,
            resetsAt: quota.resetTime.flatMap(UsageDateParsing.parseISO8601Fractional))
    }

    private static func email(fromIDToken token: String?) -> String? {
        guard let token, token.utf8.count <= 16 * 1_024 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].utf8.count <= 8 * 1_024 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload), data.count <= 8 * 1_024,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = object["email"] as? String
        else { return nil }
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 320 else { return nil }
        return cleaned
    }
}

nonisolated enum GeminiCLIProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .geminiCLI,
        displayName: "Gemini CLI",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads ~/.gemini/oauth_creds.json and ~/.gemini/settings.json; sends only the access token to cloudcode-pa.googleapis.com/v1internal:loadCodeAssist and cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota (and cloudresourcemanager.googleapis.com/v1/projects only when needed) to fetch usage numbers.",
        defaultEnabled: false,
        makeStrategies: { _ in [GeminiCLILocalTokenStrategy()] }
    )
}
