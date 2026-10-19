import SwiftUI

/// One provider's usage card, ported from Cider's `UsageProviderCard`. The
/// notch uses the compact form (up to three small rings, reset countdowns,
/// one pace line); Settings ▸ Usage uses the full form (bigger rings, a pace
/// note and hourly average per window, the data source, and the stale
/// notice). A `TimelineView` re-renders the countdowns once a minute, and
/// only while the card is on screen. The card reads no store and starts no
/// work: `connect` is the caller's action.
struct UsageProviderCardView: View {
    let card: UsageProviderCardModel?
    let providerID: UsageProviderID
    let displayName: String
    let authPattern: UsageAuthPattern
    let mode: UsageDisplayMode
    let isRefreshing: Bool
    let compact: Bool
    let ink: UsageCardInk
    let connect: (@MainActor () -> Void)?

    init(
        card: UsageProviderCardModel?, providerID: UsageProviderID, displayName: String,
        authPattern: UsageAuthPattern, mode: UsageDisplayMode, isRefreshing: Bool,
        compact: Bool, ink: UsageCardInk, connect: (@MainActor () -> Void)?
    ) {
        self.card = card
        self.providerID = providerID
        self.displayName = displayName
        self.authPattern = authPattern
        self.mode = mode
        self.isRefreshing = isRefreshing
        self.compact = compact
        self.ink = ink
        self.connect = connect
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            UsageProviderCardContent(
                card: card, providerID: providerID, displayName: displayName,
                authPattern: authPattern, mode: mode, isRefreshing: isRefreshing,
                compact: compact, ink: ink, connect: connect, now: context.date)
        }
    }
}

/// The card at one moment. Split from `UsageProviderCardView` so the
/// timeline closure stays small.
private struct UsageProviderCardContent: View {
    let card: UsageProviderCardModel?
    let providerID: UsageProviderID
    let displayName: String
    let authPattern: UsageAuthPattern
    let mode: UsageDisplayMode
    let isRefreshing: Bool
    let compact: Bool
    let ink: UsageCardInk
    let connect: (@MainActor () -> Void)?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            UsageCardHeader(
                providerID: providerID, displayName: displayName,
                observedAt: card?.observedAt, isRefreshing: isRefreshing, compact: compact,
                ink: ink, now: now)
            if let card {
                UsageCardBody(
                    card: card, displayName: displayName, authPattern: authPattern, mode: mode,
                    compact: compact, ink: ink, connect: connect, now: now)
            } else {
                Text(isRefreshing ? "Reading usage…" : "No usage yet")
                    .font(compact ? .system(size: 10) : .caption)
                    .foregroundStyle(ink.secondary)
            }
        }
        .padding(.horizontal, compact ? 10 : 0)
        .padding(.vertical, compact ? 8 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let fill = ink.cardBackground {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(fill)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayName) usage")
    }
}

/// Brand icon, name, and "Just updated" / "5m ago" or a spinner.
private struct UsageCardHeader: View {
    let providerID: UsageProviderID
    let displayName: String
    let observedAt: Date?
    let isRefreshing: Bool
    let compact: Bool
    let ink: UsageCardInk
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            UsageProviderBrandIcon(providerID: providerID, size: compact ? 16 : 22, ink: ink)
            Text(displayName)
                .font(compact ? .system(size: 11, weight: .semibold) : .headline)
                .foregroundStyle(ink.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing \(displayName) usage")
            } else if let observedAt {
                Text(UsageWindowPresentation.ageLabel(observedAt: observedAt, now: now))
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(ink.muted)
                    .monospacedDigit()
            }
        }
    }
}

/// The agent icon for providers Rafu knows as agents, else a neutral gauge.
private struct UsageProviderBrandIcon: View {
    let providerID: UsageProviderID
    let size: CGFloat
    let ink: UsageCardInk

    var body: some View {
        Group {
            if let cli = Self.cli(for: providerID) {
                AgentIconView(cli: cli, size: size)
            } else {
                Image(systemName: "gauge.medium")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(ink.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    static func cli(for id: UsageProviderID) -> ConductorCLIID? {
        switch id {
        case .claude: .claudeCode
        case .codex: .codex
        case .openCode: .openCode
        case .cline: .cline
        case .kimi: .kimi
        case .geminiCLI: .geminiCLI
        case .cursor: .cursor
        default: nil
        }
    }
}

/// Rings, token and cost lines, pace, source, stale notice, and Connect.
private struct UsageCardBody: View {
    let card: UsageProviderCardModel
    let displayName: String
    let authPattern: UsageAuthPattern
    let mode: UsageDisplayMode
    let compact: Bool
    let ink: UsageCardInk
    let connect: (@MainActor () -> Void)?
    let now: Date

    private var snapshot: UsageSnapshot { card.snapshot }

    var body: some View {
        let cluster = UsageRingClusterBuilder.make(
            snapshot: snapshot, observedAt: card.observedAt, mode: mode, displayName: displayName,
            now: now)
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            if let cluster {
                UsageRingClusterView(cluster: cluster, ink: ink, compact: compact)
            }
            if let tokenLine = UsageCardPresentation.tokenLine(snapshot) {
                Text(tokenLine)
                    .font(.system(size: compact ? 10.5 : 12, design: .monospaced))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .accessibilityLabel("\(displayName) tokens: \(tokenLine)")
            }
            if let costLine = snapshot.costLine {
                Text(costLine)
                    .font(.system(size: compact ? 10.5 : 12, design: .monospaced))
                    .foregroundStyle(ink.secondary)
            }
            if compact, cluster != nil,
                let summary = UsageCardPresentation.paceSummary(
                    snapshot, observedAt: card.observedAt, now: now)
            {
                // `showGlyph: false` — the summarised window's own legend
                // row already shows one triangle (see `UsageRingClusterView`'s
                // `UsageRingLegendRow` doc comment).
                UsagePaceLine(
                    text: summary.text, warning: summary.warning, compact: true, ink: ink,
                    showGlyph: false
                )
                .help(
                    summary.text
                        + ". Estimated from the window's average so far; model limits are separate."
                )
            }
            if !compact {
                if cluster != nil {
                    Text(
                        "Estimates use each window's average so far and assume the same pace until reset. Model limits are separate; they are not extra capacity."
                    )
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let source = UsageCardPresentation.sourceLabel(
                    for: snapshot, displayName: displayName)
                {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(ink.secondary)
                }
            }
            if card.isStale {
                Label("Showing the last successful update", systemImage: "clock.arrow.circlepath")
                    .font(compact ? .system(size: 9.5) : .caption2)
                    .foregroundStyle(ink.secondary)
            }
            if let prompt = UsageCardPresentation.connectPrompt(
                for: snapshot, authPattern: authPattern,
                hasNetworkConsent: card.hasNetworkConsent)
            {
                UsageConnectPromptRow(
                    prompt: prompt, snapshot: snapshot, displayName: displayName,
                    compact: compact, ink: ink, connect: connect)
            }
        }
    }
}

/// A pace note. A warning keeps the warning colour and tint; the leading
/// glyph is opt-out (`showGlyph`) because `UsageRingClusterView`'s legend
/// row already shows ONE triangle for the same window — this line must not
/// repeat it. Shared with that legend row, so it is not `private`.
struct UsagePaceLine: View {
    let text: String
    let warning: Bool
    let compact: Bool
    let ink: UsageCardInk
    var showGlyph: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            if warning, showGlyph {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(compact ? 1 : 2)
        }
        .font(compact ? .system(size: 9.5) : .caption)
        .foregroundStyle(warning ? ink.warning : ink.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warning ? "Warning: \(text)" : text)
    }
}

/// "Estimated from local transcripts" plus "Connect for exact usage…".
private struct UsageConnectPromptRow: View {
    let prompt: UsageConnectPrompt
    let snapshot: UsageSnapshot
    let displayName: String
    let compact: Bool
    let ink: UsageCardInk
    let connect: (@MainActor () -> Void)?

    var body: some View {
        let source =
            UsageCardPresentation.sourceLabel(for: snapshot, displayName: displayName)
            ?? "Local data only"
        let detail =
            prompt == .reconnect
            ? "\(source). Exact usage is not available now; the saved sign-in may have expired."
            : source
        VStack(alignment: .leading, spacing: 4) {
            if compact || prompt == .reconnect {
                Text(detail)
                    .font(compact ? .system(size: 9.5) : .caption)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let connect {
                if compact {
                    Button(prompt.buttonTitle, action: connect)
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .help("Open Settings ▸ Usage to connect \(displayName) for exact usage")
                        .accessibilityHint("Opens Usage settings")
                } else {
                    Button(prompt.buttonTitle, action: connect)
                        .help("Connect \(displayName) to read exact usage")
                }
            }
        }
    }
}
