import Foundation

// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

/// Reads Kimi Code CLI's reusable OAuth credential at
/// `~/.kimi-code/credentials/kimi-code.json`. The credential must remain
/// valid for more than 60 seconds, matching CodexBar. Rafu never refreshes
/// or rewrites it and never creates a missing device ID.
nonisolated struct KimiLocalTokenStrategy: UsageFetchStrategy {
    let id = "kimi.local-token"

    // `UsageFetchContext.readFile` paths are home-relative, so these
    // resolve to the observed `~/.kimi-code/...` files in production.
    private static let credentialsPath = ".kimi-code/credentials/kimi-code.json"
    private static let deviceIDPath = ".kimi-code/device_id"
    private static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private static let maximumLocalFileBytes = 64 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.loadAccessToken(context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let accessToken = Self.loadAccessToken(context) else {
            throw UsageLocalDataError.noData
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rafu", forHTTPHeaderField: "User-Agent")
        request.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        if let deviceID = Self.loadDeviceID(context) {
            request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        }

        let (data, _) = try await context.http.send(request, provider: .kimi)
        guard data.count <= Self.maximumResponseBytes,
            let snapshot = Self.parseUsageResponse(data)
        else {
            throw UsageLocalDataError.noData
        }
        return snapshot
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private struct Credential: Decodable {
        let accessToken: String?
        let expiresAt: Double?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.accessToken = try? container.decode(String.self, forKey: .accessToken)
            if let value = try? container.decode(Double.self, forKey: .expiresAt) {
                self.expiresAt = value
            } else if let value = try? container.decode(String.self, forKey: .expiresAt) {
                self.expiresAt = Double(value)
            } else {
                self.expiresAt = nil
            }
        }
    }

    private struct APIResponse: Decodable {
        let usage: UsageDetail
        let limits: [RateLimit]?
    }

    private struct RateLimit: Decodable {
        let window: Window
        let detail: UsageDetail
    }

    private struct Window: Decodable {
        let duration: Int
        let timeUnit: String
    }

    private struct UsageDetail: Decodable {
        let limit: Double
        let used: Double?
        let remaining: Double?
        let resetTime: String?

        private enum CodingKeys: String, CodingKey {
            case limit
            case used
            case remaining
            case resetTime
            case resetAt
            case resetTimeSnake = "reset_time"
            case resetAtSnake = "reset_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let limit = Self.doubleValue(in: container, forKey: .limit) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.limit,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Kimi usage limit is missing"))
            }
            self.limit = limit
            self.used = Self.doubleValue(in: container, forKey: .used)
            self.remaining = Self.doubleValue(in: container, forKey: .remaining)
            self.resetTime =
                Self.stringValue(in: container, forKey: .resetTime)
                ?? Self.stringValue(in: container, forKey: .resetAt)
                ?? Self.stringValue(in: container, forKey: .resetTimeSnake)
                ?? Self.stringValue(in: container, forKey: .resetAtSnake)
        }

        private static func doubleValue(
            in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
            return nil
        }

        private static func stringValue(
            in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
        ) -> String? {
            if let value = try? container.decode(String.self, forKey: key) { return value }
            if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
            if let value = try? container.decode(Double.self, forKey: key) {
                return String(value)
            }
            return nil
        }
    }

    private static func loadAccessToken(_ context: UsageFetchContext) -> String? {
        guard let contents = context.readFile(Self.credentialsPath),
            contents.utf8.count <= Self.maximumLocalFileBytes,
            let data = contents.data(using: .utf8),
            let credential = try? JSONDecoder().decode(Credential.self, from: data),
            let accessToken = cleanedHeaderValue(
                credential.accessToken, maximumBytes: Self.maximumLocalFileBytes),
            let expiresAt = credential.expiresAt, expiresAt.isFinite,
            expiresAt > context.now.addingTimeInterval(60).timeIntervalSince1970
        else { return nil }
        return accessToken
    }

    private static func loadDeviceID(_ context: UsageFetchContext) -> String? {
        cleanedHeaderValue(context.readFile(Self.deviceIDPath), maximumBytes: 256)
    }

    private static func cleanedHeaderValue(_ raw: String?, maximumBytes: Int) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, value.utf8.count <= maximumBytes,
            !value.contains("\r"), !value.contains("\n")
        else { return nil }
        return value
    }

    static func parseUsageResponse(_ data: Data) -> UsageSnapshot? {
        guard data.count <= Self.maximumResponseBytes,
            let response = try? JSONDecoder().decode(APIResponse.self, from: data)
        else { return nil }

        var windows: [UsageWindow] = []
        if let weekly = makeWindow(label: "Weekly", detail: response.usage) {
            windows.append(weekly)
        }
        if let rateLimit = response.limits?.first,
            let window = makeWindow(
                label: label(for: rateLimit.window), detail: rateLimit.detail)
        {
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            providerID: .kimi, windows: windows, costLine: nil, identity: nil)
    }

    private static func makeWindow(label: String, detail: UsageDetail) -> UsageWindow? {
        let limit = detail.limit
        guard limit.isFinite, limit > 0 else { return nil }
        let used: Double
        if let reportedUsed = detail.used, reportedUsed.isFinite {
            used = reportedUsed
        } else if let remaining = detail.remaining, remaining.isFinite {
            used = max(0, limit - remaining)
        } else {
            return nil
        }
        let percent = min(100, max(0, used / limit * 100))
        return UsageWindow(
            label: label,
            percent: percent,
            tokens: nil,
            resetsAt: detail.resetTime.flatMap(UsageDateParsing.parseISO8601Fractional))
    }

    private static func label(for window: Window) -> String {
        guard window.duration > 0 else { return "usage" }
        switch window.timeUnit.uppercased() {
        case "TIME_UNIT_MINUTE", "MINUTE", "MINUTES":
            if window.duration.isMultiple(of: 24 * 60) {
                return "\(window.duration / (24 * 60))d"
            }
            if window.duration.isMultiple(of: 60) {
                return "\(window.duration / 60)h"
            }
            return "\(window.duration)m"
        case "TIME_UNIT_HOUR", "HOUR", "HOURS":
            return "\(window.duration)h"
        case "TIME_UNIT_DAY", "DAY", "DAYS":
            return "\(window.duration)d"
        default:
            return "usage"
        }
    }
}

nonisolated enum KimiProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .kimi,
        displayName: "Kimi",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads ~/.kimi-code/credentials/kimi-code.json and optional ~/.kimi-code/device_id; sends only the access token to api.kimi.com/coding/v1/usages to fetch usage numbers.",
        defaultEnabled: false,
        makeStrategies: { _ in [KimiLocalTokenStrategy()] }
    )
}
