import Foundation

/// The facts about this Mac and this Rafu build that start each diagnostics
/// file and fill `header.json` of an export. Read when a file is first
/// written, never at launch.
public struct MeetingDiagnosticsHeader: Hashable, Codable, Sendable {
    public var macOSVersion: String
    public var macOSBuild: String
    public var macModel: String
    public var rafuVersion: String
    public var rafuBuild: String
    public var rafuVariant: String
    public var timeZoneOffsetSeconds: Int

    public init(
        macOSVersion: String, macOSBuild: String, macModel: String, rafuVersion: String,
        rafuBuild: String, rafuVariant: String, timeZoneOffsetSeconds: Int
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.macModel = macModel
        self.rafuVersion = rafuVersion
        self.rafuBuild = rafuBuild
        self.rafuVariant = rafuVariant
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
    }

    /// The header for this process. The Mac model comes from `sysctl hw.model`
    /// (for example `Mac17,13`), the OS build from `kern.osversion`.
    public static func current(
        identity: RafuAppIdentity = .current, bundle: Bundle = .main,
        timeZone: TimeZone = .current
    ) -> MeetingDiagnosticsHeader {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = bundle.infoDictionary
        return MeetingDiagnosticsHeader(
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            macModel: sysctlString("hw.model") ?? "unknown",
            rafuVersion: info?["CFBundleShortVersionString"] as? String
                ?? RafuBuildInformation.version,
            rafuBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            rafuVariant: identity.isLightning ? "lightning" : "release",
            timeZoneOffsetSeconds: timeZone.secondsFromGMT()
        )
    }

    /// The header as a diagnostic event (each string is cut to 128 bytes).
    public var event: MeetingDiagnosticEvent {
        .header(
            macOSVersion: MeetingDiagnosticString(macOSVersion),
            macOSBuild: MeetingDiagnosticString(macOSBuild),
            macModel: MeetingDiagnosticString(macModel),
            rafuVersion: MeetingDiagnosticString(rafuVersion),
            rafuBuild: MeetingDiagnosticString(rafuBuild),
            rafuVariant: MeetingDiagnosticString(rafuVariant),
            timeZoneOffsetSeconds: timeZoneOffsetSeconds)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 256 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
