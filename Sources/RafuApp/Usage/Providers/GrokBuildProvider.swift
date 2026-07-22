// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum GrokBuildProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .grokBuild,
        displayName: "Grok Build",
        authPattern: .cookieImport,
        disclosure:
            "Reads a local bearer token from ~/.grok/auth.json first, then may send the cached grok.com sso and sso-rw cookies you explicitly imported to grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig to fetch credit usage.",
        defaultEnabled: false,
        makeStrategies: { _ in [GrokBuildLocalBearerStrategy(), GrokBuildCachedCookieStrategy()] }
    )
}

nonisolated enum GrokBuildUsageError: Error, Sendable, Equatable {
    case missingCredential
    case invalidCredentials
    case invalidResponse
}

nonisolated struct GrokBuildLocalBearerStrategy: UsageFetchStrategy {
    let id = "grok-build.local-bearer"

    private static let authPath = ".grok/auth.json"
    private static let maximumAuthFileBytes = 64 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = Self.credential(in: context) else {
            throw GrokBuildUsageError.missingCredential
        }
        return try await GrokBuildBillingClient.fetch(
            authorization: .bearer(credential.accessToken),
            identity: credential.email,
            context: context)
    }

    func shouldFallback(on error: Error) -> Bool {
        guard let error = error as? GrokBuildUsageError else { return false }
        return error == .missingCredential || error == .invalidCredentials
    }

    private struct Credential: Sendable {
        let accessToken: String
        let email: String?
    }

    private static func credential(in context: UsageFetchContext) -> Credential? {
        guard let contents = context.readFile(Self.authPath),
            contents.utf8.count <= Self.maximumAuthFileBytes,
            let data = contents.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let entries: [(scope: String, value: [String: Any])] = root.compactMap { scope, value in
            guard let value = value as? [String: Any], Self.cleaned(value["key"] as? String) != nil
            else { return nil }
            return (scope, value)
        }
        let preferred =
            entries
            .filter { $0.scope.hasPrefix("https://auth.x.ai::") }
            .sorted { $0.scope < $1.scope }
            .first
            ?? entries
            .filter {
                $0.scope == "https://accounts.x.ai/sign-in" || $0.scope.contains("/sign-in")
            }
            .sorted { $0.scope < $1.scope }
            .first
        guard let entry = preferred,
            let accessToken = Self.cleaned(entry.value["key"] as? String)
        else { return nil }

        if let expiresAt = Self.parseDate(entry.value["expires_at"]), expiresAt <= context.now {
            return nil
        }
        return Credential(
            accessToken: accessToken,
            email: Self.cleanedIdentity(entry.value["email"] as? String))
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        return UsageDateParsing.parseISO8601Fractional(value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= Self.maximumAuthFileBytes,
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
}

nonisolated struct GrokBuildCachedCookieStrategy: UsageFetchStrategy {
    let id = "grok-build.cached-cookie"

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.cookieHeader(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let cookieHeader = Self.cookieHeader(in: context) else {
            throw GrokBuildUsageError.missingCredential
        }
        return try await GrokBuildBillingClient.fetch(
            authorization: .cookie(cookieHeader),
            identity: nil,
            context: context)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private static func cookieHeader(in context: UsageFetchContext) -> String? {
        guard
            let value = context.cookieHeader(.grokBuild)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= CookieReadRequest.maximumHeaderBytes,
            !value.contains("\r"),
            !value.contains("\n"),
            !value.contains("\0")
        else { return nil }
        return value
    }
}

private nonisolated enum GrokBuildBillingAuthorization: Sendable {
    case bearer(String)
    case cookie(String)
}

private nonisolated enum GrokBuildBillingClient {
    private static let endpoint = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    static func fetch(
        authorization: GrokBuildBillingAuthorization,
        identity: String?,
        context: UsageFetchContext
    ) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 0, 0, 0, 0])
        switch authorization {
        case .bearer(let accessToken):
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        case .cookie(let cookieHeader):
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("Rafu", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await context.http.send(request, provider: .grokBuild)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw GrokBuildUsageError.invalidCredentials
        } catch UsageHTTPError.httpStatus(let status) where (300..<400).contains(status) {
            throw GrokBuildUsageError.invalidCredentials
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw GrokBuildUsageError.invalidResponse
        }
        guard !Self.looksSignedOut(data: data, response: response) else {
            throw GrokBuildUsageError.invalidCredentials
        }

        try Self.validateGRPCStatus(
            rawStatus: response.value(forHTTPHeaderField: "grpc-status"),
            rawMessage: response.value(forHTTPHeaderField: "grpc-message"))
        if let trailer = Self.grpcWebTrailerFields(data) {
            try Self.validateGRPCStatus(
                rawStatus: trailer["grpc-status"],
                rawMessage: trailer["grpc-message"])
        }
        let parsed = try Self.parseGRPCWebResponse(data, now: context.now)
        return UsageSnapshot(
            providerID: .grokBuild,
            windows: [
                UsageWindow(
                    label: Self.windowLabel(resetsAt: parsed.resetsAt, now: context.now),
                    percent: parsed.percent,
                    tokens: nil,
                    resetsAt: parsed.resetsAt)
            ],
            costLine: nil,
            identity: identity)
    }

    private static func windowLabel(resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "usage" }
        let duration = resetsAt.timeIntervalSince(now)
        guard duration > 3_600 else { return "usage" }
        let days = Int((duration / 86_400).rounded(.toNearestOrAwayFromZero))
        if (4...12).contains(days) { return "weekly" }
        if (20...45).contains(days) { return "monthly" }
        return "usage"
    }

    private struct ParsedBilling: Sendable {
        let percent: Double
        let resetsAt: Date?
    }

    private struct ProtobufScan {
        struct Fixed32Field {
            let path: [UInt64]
            let value: Float
            let order: Int
        }

        struct VarintField {
            let path: [UInt64]
            let value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func parseGRPCWebResponse(_ data: Data, now: Date) throws -> ParsedBilling {
        var payloads = Self.grpcWebDataFrames(data)
        if payloads.isEmpty, Self.looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw GrokBuildUsageError.invalidResponse }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(Self.scanProtobuf(payload, depth: 0))
        }
        let parsedPercent = scan.fixed32Fields
            .filter {
                $0.path.last == 1 && $0.value.isFinite && (0...100).contains($0.value)
            }
            .min {
                $0.path.count == $1.path.count ? $0.order < $1.order : $0.path.count < $1.path.count
            }
            .map { Double($0.value) }

        let futureResets = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            guard (1_700_000_000...2_100_000_000).contains(field.value) else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(field.value))
            return date > now ? (field.path, date) : nil
        }
        let resetsAt =
            futureResets
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min()
            ?? futureResets.map(\.date).min()
        let hasUsagePeriod = scan.varintFields.contains {
            $0.path.starts(with: [1, 6])
                || ($0.path == [1, 8, 1] && ($0.value == 1 || $0.value == 2))
        }
        let noUsageYet =
            parsedPercent == nil && scan.fixed32Fields.isEmpty
            && resetsAt != nil && hasUsagePeriod
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw GrokBuildUsageError.invalidResponse
        }
        return ParsedBilling(percent: percent, resetsAt: resetsAt)
    }

    private static func grpcWebDataFrames(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return [] }
            let flags = bytes[index]
            let length =
                (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    private static func grpcWebTrailerFields(_ data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length =
                (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard end <= bytes.count else { return nil }
            if flags & 0x80 != 0,
                let text = String(data: Data(bytes[start..<end]), encoding: .utf8)
            {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    fields[key] = value.removingPercentEncoding ?? value
                }
            }
            index = end
        }
        return fields.isEmpty ? nil : fields
    }

    private static func validateGRPCStatus(rawStatus: String?, rawMessage: String?) throws {
        guard let rawStatus, let status = Int(rawStatus), status != 0 else { return }
        let message = (rawMessage?.removingPercentEncoding ?? rawMessage ?? "").lowercased()
        if status == 16 || (status == 7 && Self.messageDescribesInvalidCredentials(message)) {
            throw GrokBuildUsageError.invalidCredentials
        }
        throw GrokBuildUsageError.invalidResponse
    }

    private static func messageDescribesInvalidCredentials(_ message: String) -> Bool {
        message.contains("bad-credentials")
            || message.contains("unauthenticated")
            || (message.contains("oauth2") && message.contains("could not be validated"))
            || (message.contains("access token")
                && (message.contains("invalid") || message.contains("expired")
                    || message.contains("could not be validated")))
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        Self.scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: ProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = Self.readVarint(bytes, index: &index) {
                    scan.varintFields.append(.init(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                    length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let end = index + Int(length)
                if depth < 4 {
                    let nested = Self.scanProtobuf(
                        Data(bytes[index..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern =
                    UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(
                    .init(
                        path: fieldPath,
                        value: Float(bitPattern: bitPattern),
                        order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }
        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && [0, 1, 2, 5].contains(wireType)
    }

    private static func looksSignedOut(data: Data, response: HTTPURLResponse) -> Bool {
        let host = response.url?.host?.lowercased() ?? ""
        let path = response.url?.path.lowercased() ?? ""
        if host == "accounts.x.ai" || path.contains("sign-in") || path.contains("signin")
            || path.contains("login")
        {
            return true
        }
        if response.mimeType?.lowercased() == "text/html" { return true }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }
}
