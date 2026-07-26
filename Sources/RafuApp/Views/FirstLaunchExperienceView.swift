import SwiftUI

/// The first-launch cinematic overlay ("The Unfolding") — presented once,
/// full-bleed above the workspace, pinned to exactly one hosting
/// `WorkspaceSession` by `FirstLaunchExperienceModel`. Presentation only:
/// durable state lives on `model`/`session`; the small per-step presentation
/// state here (`@State`) is driven by `.task(id:)`.
///
/// Design language (2026-07-27, rev. 2 — from the user's motion-design
/// reference boards): quiet dark frames where type carries the composition.
/// Photography runs full-bleed with a slow Ken Burns drift and *nothing
/// boxed on top of it* — no caption plates, no glass panels; text sits
/// directly on the image with a soft halo, seated by a zone-anchored
/// gradient wash. The finale drops photography entirely for a brand
/// gradient-glow scene (soft radial accent bloom on the app background)
/// centered on the Rafu icon. Controls are flat and minimal: an accent
/// capsule, a hairline capsule, naked progress dots, a plain-text Skip.
struct FirstLaunchExperienceView: View {
    let model: FirstLaunchExperienceModel
    let session: WorkspaceSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.rafuTheme) private var theme

    @AppStorage("themeChoice") private var themeChoiceRaw = RafuThemeChoice.system.rawValue

    @State private var stageStillURL: URL?
    @State private var stageImage: NSImage?
    @State private var kenBurnsScale: CGFloat = 1
    @State private var glowPulse: CGFloat = 1
    @State private var visibleBlockCount = 0
    @State private var agentOptions: [AgentTerminalOption]?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                stage
                    .accessibilityHidden(true)
                legibilityWash
                    .accessibilityHidden(true)
                overlayContent(in: geometry.size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.appBackground)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            guard !step.isFinale, !step.isInteractive else { return }
            model.advance()
        }
        .background(keyboardBridge)
        .onExitCommand { model.skip() }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.8),
            value: model.stepIndex
        )
        .task(id: model.stepIndex) {
            await loadStageAssets()
            startAmbientMotion()
            if step.assetName == "agents", agentOptions == nil {
                async let reveal: Void = runRevealSequence()
                let options = await AgentTerminalLaunchService(
                    workspaceRoot: FileManager.default.homeDirectoryForCurrentUser
                ).options()
                withAnimation(.easeInOut(duration: 0.45)) {
                    agentOptions = options
                }
                await reveal
            } else if step.assetName == "notch" {
                await runRevealSequence()
                // The live demo: the real companion waves from the notch a
                // beat after the illustration settles. Cleared by the model
                // on every path out of this scene.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                model.showNotchDemo()
            } else {
                await runRevealSequence()
            }
        }
    }

    private var grade: OnboardingGrade { OnboardingGrade.resolve(for: colorScheme) }
    private var step: OnboardingStep { OnboardingScript.passOne[model.stepIndex] }

    /// Cosmetic progress-dot grouping: Knot, Fabric, the three truth cards
    /// treated as one movement, then Dye, Agents, Notch, and the finale.
    private var movementCount: Int { 7 }
    private var currentMovement: Int {
        switch model.stepIndex {
        case 0: return 0
        case 1: return 1
        case 2, 3, 4: return 2
        case 5: return 3
        case 6: return 4
        case 7: return 5
        default: return 6
        }
    }

    // MARK: - Stage

    /// Gradient-backdrop scenes (dye/agents/notch/finale) render brand
    /// gradients instead of a photograph; every other step shows its graded
    /// still, resolved once per step by `loadStageAssets` rather than
    /// decoded on every body evaluation.
    @ViewBuilder
    private var stage: some View {
        ZStack {
            if !step.usesStill {
                gradientBackdrop(glowStrength: step.isFinale ? 1 : 0.55)
                    .transition(.opacity)
            } else if let stageImage {
                Image(nsImage: stageImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(kenBurnsScale)
                    .id(stageStillURL)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// The gradient-glow scene from the reference boards, in brand color:
    /// the app background deepening toward the edges with one soft accent
    /// bloom. The finale runs it at full strength; the interactive scenes
    /// keep it quieter so their content leads.
    private func gradientBackdrop(glowStrength: Double) -> some View {
        ZStack {
            LinearGradient(
                colors: [theme.palette.editorBackground, theme.palette.appBackground],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [
                    theme.palette.accent.opacity(
                        (colorScheme == .dark ? 0.32 : 0.4) * glowStrength),
                    theme.palette.accent.opacity(0.06 * glowStrength),
                    .clear,
                ],
                center: UnitPoint(x: 0.5, y: step.isFinale ? 0.42 : 0.24),
                startRadius: 0, endRadius: 520
            )
            .scaleEffect(glowPulse)
            .blur(radius: 40)
        }
    }

    private func loadStageAssets() async {
        guard step.usesStill else {
            stageStillURL = nil
            stageImage = nil
            return
        }
        if let stillURL = OnboardingAssetCatalog.stillURL(step.assetName, grade: grade) {
            stageStillURL = stillURL
            stageImage = NSImage(contentsOf: stillURL)
        } else {
            stageStillURL = nil
            stageImage = nil
        }
    }

    /// Ken Burns drift on stills; a slow breathing pulse on the finale
    /// glow. Both skipped entirely under Reduce Motion.
    private func startAmbientMotion() {
        kenBurnsScale = 1
        glowPulse = 1
        guard !reduceMotion else { return }
        if !step.usesStill {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                glowPulse = 1.08
            }
        } else if stageImage != nil {
            let duration = step.dwell?.timeInterval ?? 14
            withAnimation(.linear(duration: duration)) {
                kenBurnsScale = 1.06
            }
        }
    }

    /// A zone-anchored gradient wash — never a full-frame scrim, never a
    /// box — that seats type against the photograph. The finale needs none:
    /// its backdrop is already brand-colored.
    @ViewBuilder
    private var legibilityWash: some View {
        let wash = theme.palette.appBackground
        if !step.usesStill {
            EmptyView()
        } else {
            washBody(wash)
        }
    }

    @ViewBuilder
    private func washBody(_ wash: Color) -> some View {
        switch step.textZone {
        case .lowerCenter:
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: wash.opacity(0.6), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        case .upperLeading:
            LinearGradient(
                stops: [
                    .init(color: wash.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.6),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        case .center:
            RadialGradient(
                colors: [wash.opacity(0.45), .clear],
                center: .center, startRadius: 40, endRadius: 640
            )
            .allowsHitTesting(false)
        case .finaleSplit:
            EmptyView()
        }
    }

    /// Layered halo that lifts on-image type off the photograph — dark
    /// bloom over the Indigo grade, a soft light glow over Khadi.
    private var typeHalo: Color {
        colorScheme == .dark ? Color.black.opacity(0.6) : Color.white.opacity(0.65)
    }

    // MARK: - Zones

    @ViewBuilder
    private func overlayContent(in size: CGSize) -> some View {
        ZStack {
            zoneLayout(in: size)
            VStack {
                Spacer()
                footerRow
            }
            .padding(RafuMetrics.space5)
        }
    }

    @ViewBuilder
    private func zoneLayout(in size: CGSize) -> some View {
        switch step.textZone {
        case .lowerCenter:
            copyContent
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, size.height * 0.14)
        case .upperLeading:
            copyContent
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, size.height * 0.11)
                .padding(.leading, size.width * 0.09)
        case .center:
            copyContent
                .frame(maxWidth: step.isInteractive ? 760 : 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * (step.isInteractive ? 0.14 : 0.3))
        case .finaleSplit:
            finaleScene
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Reveal choreography

    private func revealDelays(for step: OnboardingStep) -> [Duration] {
        switch step.assetName {
        case "V0-knot":
            return [.milliseconds(900), .milliseconds(1500)]
        case "V2-bobbins":
            return [.milliseconds(500), .milliseconds(3500), .milliseconds(6500)]
        case "finale":
            return [.zero, .milliseconds(500), .milliseconds(1000)]
        case "dye", "agents", "notch":
            return [.zero, .milliseconds(350), .milliseconds(700)]
        default:
            return [.zero, .milliseconds(450)]
        }
    }

    /// Cancellation-safe staged reveal, restarted by `.task(id:)` on step
    /// change; every sleep guards `Task.isCancelled` before animating.
    private func runRevealSequence() async {
        let delays = revealDelays(for: step)
        guard !reduceMotion else {
            visibleBlockCount = delays.count
            return
        }
        visibleBlockCount = 0
        var elapsed: Duration = .zero
        for delay in delays {
            let wait = delay - elapsed
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.75, bounce: 0.18)) {
                visibleBlockCount += 1
            }
            elapsed = delay
        }
    }

    private var revealTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.985))
    }

    // MARK: - Copy

    @ViewBuilder
    private var copyContent: some View {
        switch step.assetName {
        case "V0-knot": knotCopy
        case "V2-bobbins": fabricCopy
        case "dye": dyeScene
        case "agents": agentsScene
        case "notch": notchScene
        default: cardCopy
        }
    }

    /// The Rafu app icon, used on the title card and the finale. Falls back
    /// to nothing rather than a generic placeholder outside a real bundle.
    @ViewBuilder
    private func appIcon(size: CGFloat) -> some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: size * 0.18, y: size * 0.07)
        }
    }

    /// V0: the app icon, then "Rafu" as a display title, then the
    /// definition line — all directly on the image, nothing boxed.
    private var knotCopy: some View {
        VStack(spacing: RafuMetrics.space4) {
            if visibleBlockCount >= 1 {
                appIcon(size: 88)
                    .transition(revealTransition)
                Text(step.headline ?? "Rafu")
                    .font(.system(size: 88, weight: .semibold, design: .serif))
                    .tracking(1)
                    .foregroundStyle(theme.palette.textPrimary)
                    .shadow(color: typeHalo, radius: 18, y: 2)
                    .shadow(color: typeHalo.opacity(0.7), radius: 3)
                    .transition(revealTransition)
            }
            if visibleBlockCount >= 2, let definition = step.lines.first {
                Text(definition)
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(theme.palette.textSecondary)
                    .shadow(color: typeHalo, radius: 10, y: 1)
                    .transition(revealTransition)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// The fabric movement: three lines landing as a timed sequence directly
    /// on the image — earlier lines stay at reduced opacity as the next
    /// arrives.
    private var fabricCopy: some View {
        // Enumerated pairs, never `step.lines[index]` inside the ForEach:
        // during the crossfade the outgoing step's ForEach children are
        // re-evaluated against the incoming step's (shorter) `lines`, and a
        // live subscript crashes with index-out-of-range.
        VStack(spacing: RafuMetrics.space3) {
            ForEach(Array(step.lines.enumerated()), id: \.offset) { index, line in
                if index < visibleBlockCount {
                    Text(line)
                        .font(
                            .system(
                                size: index == step.lines.count - 1 ? 30 : 22,
                                weight: index == step.lines.count - 1 ? .semibold : .medium,
                                design: index == step.lines.count - 1 ? .serif : .default
                            )
                        )
                        .foregroundStyle(theme.palette.textPrimary)
                        .shadow(color: typeHalo, radius: 12, y: 2)
                        .shadow(color: typeHalo.opacity(0.7), radius: 2)
                        .opacity(index == visibleBlockCount - 1 ? 1 : 0.6)
                        .transition(revealTransition)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    /// I1–I3: serif headline and body, both directly on the image with a
    /// halo — the wash provides the seat, not a plate behind the text.
    private var cardCopy: some View {
        let leading = step.textZone == .upperLeading
        return VStack(alignment: leading ? .leading : .center, spacing: RafuMetrics.space4) {
            if visibleBlockCount >= 1, let headline = step.headline {
                Text(headline)
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.palette.textPrimary)
                    .shadow(color: typeHalo, radius: 14, y: 2)
                    .shadow(color: typeHalo.opacity(0.7), radius: 2)
                    .multilineTextAlignment(leading ? .leading : .center)
                    .transition(revealTransition)
            }
            if visibleBlockCount >= 2 {
                // Enumerated pairs for the same reason as `fabricCopy`.
                VStack(alignment: leading ? .leading : .center, spacing: RafuMetrics.space2) {
                    ForEach(Array(step.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 15.5, weight: .regular))
                            .foregroundStyle(theme.palette.textSecondary)
                            .shadow(color: typeHalo, radius: 10, y: 1)
                            .multilineTextAlignment(leading ? .leading : .center)
                            .lineSpacing(5)
                    }
                }
                .frame(maxWidth: 460, alignment: leading ? .leading : .center)
                .transition(revealTransition)
            }
        }
    }

    // MARK: - Interactive scenes (dye, agents, notch)

    /// The shared header + Continue frame every interactive scene uses.
    /// Copy is passed explicitly (not read off `step`) so a scene can phase
    /// it — the agents scene swaps its headline as the probe resolves — with
    /// `.contentTransition(.opacity)` crossfading the swap.
    private func interactiveScene<Content: View>(
        headline: String?,
        body: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: RafuMetrics.space5) {
            if visibleBlockCount >= 1, let headline {
                Text(headline)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.45), value: headline)
                    .transition(revealTransition)
            }
            if visibleBlockCount >= 2, let body {
                Text(body)
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 520)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.45), value: body)
                    .transition(revealTransition)
            }
            if visibleBlockCount >= 3 {
                content()
                    .transition(revealTransition)
                Button {
                    model.advance()
                } label: {
                    Text("Continue")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.palette.onAccent)
                        .padding(.horizontal, RafuMetrics.space5)
                        .padding(.vertical, RafuMetrics.space3 - 2)
                        .background(Capsule().fill(theme.palette.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, RafuMetrics.space2)
                .transition(revealTransition)
            }
        }
    }

    /// The dye bath: every bundled theme as a cloth swatch. Picking one
    /// applies it immediately — the whole overlay re-dyes live, because it
    /// sits inside `WorkspaceSceneRoot`'s `.rafuTheme` chain.
    private var dyeScene: some View {
        interactiveScene(headline: step.headline, body: step.lines.first) {
            let columns = [
                GridItem(.adaptive(minimum: 132, maximum: 150), spacing: RafuMetrics.space3)
            ]
            LazyVGrid(columns: columns, spacing: RafuMetrics.space3) {
                ForEach(RafuThemeChoice.allCases) { choice in
                    themeSwatch(choice)
                }
            }
            .frame(maxWidth: 640)
        }
    }

    private func themeSwatch(_ choice: RafuThemeChoice) -> some View {
        let palette = RafuThemeCatalog.resolved(
            identifier: choice.rawValue, systemScheme: colorScheme
        ).palette
        let isSelected = themeChoiceRaw == choice.rawValue
        return Button {
            themeChoiceRaw = choice.rawValue
        } label: {
            VStack(spacing: RafuMetrics.space2) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.appBackground)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.editorBackground)
                        .padding(.leading, 34)
                        .padding([.top, .trailing, .bottom], 7)
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 9, height: 9)
                        .padding(8)
                }
                .frame(height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected ? theme.palette.accent : theme.palette.borderStrong,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                Text(choice.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected ? theme.palette.textPrimary : theme.palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Agent discovery: one row per known CLI, live from the same
    /// availability probe Agent Terminals use — found CLIs lead, missing
    /// ones stay dim. The copy phases with the probe: a searching line
    /// while it runs, the crew line once anyone turns up, and an honest
    /// empty-house line when nobody does.
    private var agentsScene: some View {
        let anyInstalled = agentOptions?.contains { option in
            if case .notInstalled = option.availability { return false }
            return true
        }
        let headline: String? =
            switch anyInstalled {
            case nil: "Taking attendance…"
            case true?: step.headline
            case false?: "No crew yet. Just you and the loom."
            }
        let body: String? =
            switch anyInstalled {
            case nil:
                "Rafu is peeking around your machine for agent CLIs — Claude Code, Codex, OpenCode, and friends. Won't be a moment."
            case true?: step.lines.first
            case false?:
                "Nobody's home today. Install Claude Code, Codex, or any of their friends and they'll show up here — the Ensemble can wait."
            }
        return interactiveScene(headline: headline, body: body) {
            Group {
                if let options = agentOptions {
                    let columns = [
                        GridItem(.adaptive(minimum: 168, maximum: 200), spacing: RafuMetrics.space3)
                    ]
                    LazyVGrid(columns: columns, spacing: RafuMetrics.space3) {
                        ForEach(options) { option in
                            agentTile(option)
                        }
                    }
                    .frame(maxWidth: 680)
                    .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, RafuMetrics.space5)
                        .transition(.opacity)
                }
            }
        }
    }

    private func agentTile(_ option: AgentTerminalOption) -> some View {
        let found = option.availability.executableURL != nil
        let needsAuth: Bool = {
            if case .notAuthenticated = option.availability { return true }
            return false
        }()
        return HStack(spacing: RafuMetrics.space2 + 2) {
            FileIconView(icon: option.icon, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(found ? "Found" : needsAuth ? "Sign in to use" : "Not installed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        found
                            ? theme.palette.success
                            : needsAuth ? theme.palette.warning : theme.palette.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2 + 2)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.palette.borderStrong.opacity(found ? 1 : 0.5), lineWidth: 1)
        }
        .opacity(found || needsAuth ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    /// The notch movement: a small abstract illustration — a screen's top
    /// edge, the notch, and one glowing activity sliver beside it.
    private var notchScene: some View {
        interactiveScene(headline: step.headline, body: step.lines.first) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 16
                )
                .strokeBorder(theme.palette.borderStrong, lineWidth: 1)
                .frame(width: 420, height: 84)
                HStack(spacing: RafuMetrics.space2) {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 130, height: 20)
                    Capsule()
                        .fill(theme.palette.accent)
                        .frame(width: 34, height: 12)
                        .shadow(color: theme.palette.accent.opacity(0.6), radius: 8)
                        .scaleEffect(glowPulse)
                }
                .padding(.top, 6)
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Finale

    /// Icon over the glow, the two closing lines, then the actions —
    /// a single centered column on the gradient scene.
    private var finaleScene: some View {
        VStack(spacing: RafuMetrics.space5) {
            if visibleBlockCount >= 1 {
                appIcon(size: 96)
                    .transition(revealTransition)
            }
            if visibleBlockCount >= 2 {
                // Enumerated pairs for the same reason as `fabricCopy`.
                VStack(spacing: RafuMetrics.space2) {
                    ForEach(Array(step.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 32, weight: .semibold, design: .serif))
                            .foregroundStyle(theme.palette.textPrimary)
                            .multilineTextAlignment(.center)
                    }
                }
                .transition(revealTransition)
            }
            if visibleBlockCount >= 3 {
                VStack(spacing: RafuMetrics.space3) {
                    HStack(spacing: RafuMetrics.space3) {
                        Button {
                            session.requestOpenFolder()
                            model.finish()
                        } label: {
                            Text("Open Folder…")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.palette.onAccent)
                                .padding(.horizontal, RafuMetrics.space5)
                                .padding(.vertical, RafuMetrics.space3 - 2)
                                .background(Capsule().fill(theme.palette.accent))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)

                        Button {
                            model.finish()
                        } label: {
                            Text("Just let me type")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.palette.textPrimary)
                                .padding(.horizontal, RafuMetrics.space5)
                                .padding(.vertical, RafuMetrics.space3 - 2)
                                .background {
                                    Capsule().strokeBorder(
                                        theme.palette.borderStrong, lineWidth: 1
                                    )
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Encore anytime: Help ▸ Play the Intro Again.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .padding(.top, RafuMetrics.space3)
                .transition(revealTransition)
            }
        }
        .padding(.bottom, RafuMetrics.space5)
    }

    // MARK: - Footer chrome (Skip, progress dots)

    private var footerRow: some View {
        ZStack {
            progressDots
            HStack {
                skipButton
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        // Skip is sacred but stays out of the very first frame.
        if model.stepIndex >= 1 {
            Button("Skip intro") { model.skip() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .shadow(color: typeHalo, radius: 8)
                .opacity(0.75)
                .transition(.opacity)
        }
    }

    private var progressDots: some View {
        HStack(spacing: RafuMetrics.space2) {
            ForEach(0..<movementCount, id: \.self) { index in
                let isCurrent = index == currentMovement
                Circle()
                    .fill(isCurrent ? theme.palette.accent : theme.palette.textMuted.opacity(0.5))
                    .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
                    .animation(.spring(duration: 0.4, bounce: 0.4), value: currentMovement)
            }
        }
    }

    /// Hidden, zero-size buttons that give →/⏎ the same "advance" action as
    /// a click, and ← "back" — the finale replaces ⏎-advances with its own
    /// `[Open Folder…]` default-action button instead.
    @ViewBuilder
    private var keyboardBridge: some View {
        Group {
            if !step.isFinale {
                Button(action: { model.advance() }) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: [])
                Button(action: { model.advance() }) { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Button(action: { model.back() }) { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

extension Duration {
    /// `Duration` → seconds for `withAnimation(.linear(duration:))`, which
    /// takes a `TimeInterval`.
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
