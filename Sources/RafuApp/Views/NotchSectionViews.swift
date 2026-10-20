import AppKit
import SwiftUI

// The four sections of the open notch panel. Each reads only
// `NotchCompanionModel` and scrolls inside the panel's fixed height; none
// starts a process, sends input, or transmits anything on its own.

// MARK: - Ensembles

/// Open windows, each with its open Ensembles and the agents running in them
/// (and agents in terminals outside any Ensemble). Replaces Cider's Agents
/// tab: Rafu's agents live in Ensemble nodes. Every row is a button that
/// takes the person there.
struct CompanionEnsemblesSectionView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearchFieldVisible {
                CompanionSearchFieldView(model: model)
            }
            if model.visibleEditorRows.isEmpty {
                Text(emptyStateText)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                        ForEach(model.visibleEditorRows) { row in
                            CompanionWindowGroupView(model: model, row: row)
                        }
                        TrackedAgentsNotchView(model: model)
                    }
                    .padding(.horizontal, RafuMetrics.space3)
                    .padding(.bottom, RafuMetrics.space3)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var emptyStateText: String {
        guard !model.searchQuery.isEmpty else { return "No open editors" }
        return "No editors match “\(model.searchQuery)”"
    }
}

/// One window: its row (focuses the window), then its Ensembles and loose
/// agents.
struct CompanionWindowGroupView: View {
    let model: NotchCompanionModel
    let row: CompanionEditorRow

    var body: some View {
        let agents = model.windowAgents(for: row.id)
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            CompanionEditorRowView(row: row) {
                model.focusEditor(row.id)
            }
            ForEach(agents.ensembles) { ensemble in
                CompanionEnsembleBlockView(model: model, windowID: row.id, ensemble: ensemble)
            }
            if !agents.looseAgents.isEmpty {
                CompanionLooseAgentsView(model: model, agents: agents.looseAgents)
            }
        }
    }
}

/// One open Ensemble: a header that opens it, then its agents.
struct CompanionEnsembleBlockView: View {
    let model: NotchCompanionModel
    let windowID: UUID
    let ensemble: NotchEnsembleRow
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                model.openEnsemble(windowID: windowID, boardID: ensemble.id)
            } label: {
                HStack(spacing: RafuMetrics.space2) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ink.secondary)
                        .accessibilityHidden(true)
                    Text(ensemble.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: RafuMetrics.space2)
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundStyle(ink.muted)
                        .lineLimit(1)
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this Ensemble")
            .accessibilityLabel("Ensemble \(ensemble.title), \(summaryText)")
            .accessibilityHint("Activates to open this Ensemble")
            if ensemble.agents.isEmpty {
                Text("No agents here yet")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.muted)
                    .padding(.leading, RafuMetrics.space4)
            } else {
                ForEach(ensemble.agents) { agent in
                    CompanionAgentRowView(model: model, row: agent)
                }
            }
        }
        .padding(.leading, RafuMetrics.space2)
    }

    private var summaryText: String {
        let summary = ensemble.summary
        guard summary.live > 0 else { return "\(ensemble.cardCount) nodes" }
        var parts = ["\(summary.live) agent\(summary.live == 1 ? "" : "s")"]
        if summary.attention > 0 { parts.append("\(summary.attention) waiting") }
        return parts.joined(separator: " · ")
    }
}

/// Agents in terminals that are not part of any open Ensemble.
struct CompanionLooseAgentsView: View {
    let model: NotchCompanionModel
    let agents: [NotchAgentRow]
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Terminals")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchInk(theme: theme).muted)
                .padding(.leading, RafuMetrics.space2)
            ForEach(agents) { agent in
                CompanionAgentRowView(model: model, row: agent)
            }
        }
        .padding(.leading, RafuMetrics.space2)
    }
}

/// One agent: its vendor icon, name, and state as a glyph plus a word.
struct CompanionAgentRowView: View {
    let model: NotchCompanionModel
    let row: NotchAgentRow
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        Button {
            model.focusAgent(row)
        } label: {
            HStack(spacing: RafuMetrics.space2) {
                AgentIconView(cli: row.cli, size: 14)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: RafuMetrics.space2)
                Image(systemName: row.phase.symbol)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(row.phase.label)
                    .font(
                        .system(size: 10, weight: row.phase.needsAttention ? .semibold : .regular))
            }
            .foregroundStyle(row.phase.needsAttention ? ink.accent : ink.secondary)
            .padding(.horizontal, RafuMetrics.space2)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(Color.white.opacity(row.phase.needsAttention ? 0.1 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(row.title) in its window")
        .accessibilityLabel("\(row.title), \(row.cli.displayName), \(row.phase.label)")
        .accessibilityHint("Activates to show this agent")
    }
}

// MARK: - Up next

/// Cider's To-do, repurposed: the attention queue. Cards for sessions with a
/// pending feed entry (with inline reply), then compact rows for any other
/// agent that needs you or has a reply ready. Opening one clears it.
struct CompanionUpNextSectionView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let waiting = model.upNextRows.filter { row in
            !model.feedItems.contains { $0.sessionID == row.id }
        }
        if model.feedItems.isEmpty && waiting.isEmpty {
            VStack(spacing: RafuMetrics.space2) {
                RafuMascotView(
                    state: RafuMascotState.resolve(agents: []), engaged: true, size: 44,
                    claimBounce: { _ in false })
                Text("Nothing is waiting for you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.primary)
                Text("An agent that finishes or asks a question shows up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, RafuMetrics.space4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    CompanionAttentionFeedView(model: model)
                    if !waiting.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(waiting) { row in
                                CompanionAgentRowView(model: model, row: row)
                            }
                        }
                        .padding(.horizontal, RafuMetrics.space3)
                    }
                }
                .padding(.bottom, RafuMetrics.space3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
    }
}

// MARK: - Now Playing

/// What is playing, ported from Cider's Now Playing tab (see
/// `NotchNowPlaying`): system media through the bundled adapter, or Music
/// and Spotify as the fallback. On the fallback, until the person connects,
/// Rafu sends no Apple events; the track still appears when a player
/// announces it.
struct CompanionNowPlayingSectionView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed

    private var player: NotchNowPlaying { model.nowPlaying }
    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        VStack(spacing: RafuMetrics.space3) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(ink.accent)
                        .accessibilityHidden(true)
                }
            VStack(spacing: 3) {
                Text(player.hasTrack ? player.title : "Your music, right here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.muted)
                    .lineLimit(3)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            controls
            waveform
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RafuMetrics.space4)
    }

    private var detail: String {
        if player.hasTrack {
            return [player.artist, player.source].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if player.isSystemMedia { return "Play something in any app on this Mac." }
        if player.needsPermission {
            return
                "Allow Rafu to control Music and Spotify in System Settings ▸ Privacy & Security ▸ Automation."
        }
        if player.unavailable { return "Couldn’t read playback. Try again." }
        if !player.isConnected {
            return
                "Rafu can show what Music or Spotify is playing. macOS asks before Rafu may talk to them."
        }
        return "Play something in Music or Spotify."
    }

    @ViewBuilder
    private var controls: some View {
        if player.hasTrack {
            HStack(spacing: RafuMetrics.space5) {
                transport("Previous track", symbol: "backward.fill") { player.previous() }
                transport(
                    player.playing ? "Pause" : "Play",
                    symbol: player.playing ? "pause.fill" : "play.fill"
                ) { player.togglePlayback() }
                transport("Next track", symbol: "forward.fill") { player.next() }
            }
        } else if player.isSystemMedia {
            transport("Check now playing", symbol: "arrow.clockwise") { player.refresh() }
        } else if player.needsPermission {
            Button("Open Automation Settings") { Self.openAutomationSettings() }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Open System Settings to allow Rafu to control Music and Spotify")
        } else if !player.isConnected {
            Button("Connect Music and Spotify") { player.connect() }
                .buttonStyle(RafuProminentButtonStyle(compact: true))
                .help("Let Rafu ask Music and Spotify what is playing")
        } else {
            transport("Check now playing", symbol: "arrow.clockwise") { player.refresh() }
                .disabled(player.refreshing)
        }
    }

    private func transport(_ label: String, symbol: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(ink.primary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// A calm wave while music plays; still under Reduce Motion, while the
    /// panel is hidden or the screen is locked, and flat when paused.
    private var waveform: some View {
        let moving = player.playing && !reduceMotion && motionAllowed
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) {
            context in
            Canvas { drawing, size in
                let time = moving ? context.date.timeIntervalSinceReferenceDate : 0
                for layer in 0..<3 {
                    var path = Path()
                    let width = Double(size.width)
                    let middle = Double(size.height) / 2
                    for x in stride(from: 0.0, through: width, by: 2) {
                        let envelope: Double = sin(x / width * .pi)
                        let swing: Double = player.playing ? 9.0 : 2.0
                        let phase: Double = x / 18 + time * 3 + Double(layer)
                        let y: Double = middle + sin(phase) * envelope * swing
                        if x == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    drawing.stroke(
                        path, with: .color(ink.accent.opacity(0.8 - Double(layer) * 0.2)),
                        lineWidth: 1.5)
                }
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private static func openAutomationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Usage

/// Cider's Usage tab: one compact card per provider — brand icon, name,
/// "Just updated" or a spinner, up to three rings with reset countdowns, and
/// one pace line. Token-only providers keep a compact text line. Read-only
/// and refreshed on a TTL; the model owns the reads. "Connect for exact
/// usage…" opens Settings ▸ Usage, where the Connect flow and its
/// explanation live.
struct CompanionUsageSectionView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let snapshots = model.usageFrontLine + model.usageOverflow
        VStack(spacing: 0) {
            HStack {
                Text("Agent usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.secondary)
                Spacer()
                Button {
                    model.refreshUsage(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(ink.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isUsageRefreshing)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
            }
            .padding(.horizontal, RafuMetrics.space3)
            if snapshots.isEmpty {
                Text("No usage data yet. Turn providers on in Settings ▸ Usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RafuMetrics.space4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: RafuMetrics.space2) {
                        ForEach(snapshots, id: \.providerID) { snapshot in
                            CompanionUsageCardView(
                                model: model, providerID: snapshot.providerID,
                                openUsageSettings: { openUsageSettings() })
                        }
                    }
                    .padding(.horizontal, RafuMetrics.space3)
                    .padding(.bottom, RafuMetrics.space3)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshUsage() }
    }

    /// The notch panel never takes the app's activation, so activate first;
    /// then open Settings on the Usage pane.
    private func openUsageSettings() {
        SettingsPaneRouter.shared.request(.usage)
        NSApp.activate()
        openSettings()
    }
}

/// One provider in the notch: the compact `UsageProviderCardView`.
struct CompanionUsageCardView: View {
    let model: NotchCompanionModel
    let providerID: UsageProviderID
    let openUsageSettings: @MainActor () -> Void
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        model: NotchCompanionModel, providerID: UsageProviderID,
        openUsageSettings: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.providerID = providerID
        self.openUsageSettings = openUsageSettings
    }

    var body: some View {
        let descriptor = UsageProviderRegistry.descriptor(for: providerID)
        UsageProviderCardView(
            card: model.usageCard(for: providerID), providerID: providerID,
            displayName: descriptor?.displayName ?? providerID.rawValue,
            authPattern: descriptor?.authPattern ?? .unavailable,
            mode: model.usageDisplayMode, isRefreshing: model.isUsageRefreshing,
            compact: true,
            ink: .notch(
                theme: theme, palette: model.usageRingPalette,
                increasedContrast: contrast == .increased),
            connect: openUsageSettings)
    }
}
