import Foundation

/// Stub — lands in phase W8 (docs/plans/phases/usage-providers/
/// W8-alibaba-providers.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W8 lands.
/// Cookie-only (agent-usage-providers.md, roster item 19): eligible
/// precisely because cookie import is an allowed auth pattern.
nonisolated enum QoderProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .qoder,
        displayName: "Qoder",
        authPattern: .cookieImport,
        disclosure:
            "Not yet supported. Will use a browser cookie you import to fetch Qoder's big-model-credits usage (dual-region).",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
