import OSLog

/// Shared `OSSignposter` for the tree-sitter syntax path (lane-1 increment
/// 8a). Intervals wrap the off-main parse and query and the main-actor token
/// apply so typing-latency and parse cost can be measured in Instruments
/// (the strict visible-range gate proof lands in 8b).
///
/// Security (AGENTS.md): only ranges, lengths, and counts are ever logged —
/// never document text, span contents, capture text, or file contents.
nonisolated enum SyntaxSignpost {
    static let signposter = OSSignposter(
        subsystem: "dev.vatsalsaglani.rafu", category: "syntax")
}
