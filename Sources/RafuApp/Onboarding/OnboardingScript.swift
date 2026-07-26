import Foundation

/// Where a step's copy block sits over its footage — script data, not a view
/// switch-statement on step index, so the cinematic layout in
/// `FirstLaunchExperienceView` stays a direct read of the screenplay rather
/// than inferred from position.
///
/// - `lowerCenter`: centered horizontally, sitting in the lower portion of
///   the frame, below the shot's point of interest (V0-knot, V2-bobbins).
/// - `upperLeading`: anchored top-leading, for shots whose lower portion
///   carries the imagery and whose upper two-thirds is calm/empty
///   (I1-native, I2-private).
/// - `center`: centered horizontally but raised above true vertical center —
///   the emptiest frame (I3-quiet) and every gradient-backdrop scene.
/// - `finaleSplit`: the finale's single centered column on the gradient-glow
///   scene.
nonisolated enum OnboardingTextZone: Sendable, Equatable {
    case lowerCenter
    case upperLeading
    case center
    case finaleSplit
}

/// One movement of the first-launch experience ("The Unfolding"): an asset
/// or gradient scene, its copy, and how it advances.
///
/// - `dwell != nil`: ambient — auto-advances after the dwell.
/// - `dwell == nil, isInteractive`: waits for the user (theme picking, agent
///   discovery, notch) behind an explicit Continue control; tapping the
///   backdrop does not advance so stray clicks can't swallow a choice.
/// - `dwell == nil, isFinale`: the closing scene with the real actions.
nonisolated struct OnboardingStep: Identifiable, Sendable {
    let id: String
    let assetName: String
    let headline: String?
    let lines: [String]
    let dwell: Duration?
    let isFinale: Bool
    let isInteractive: Bool
    /// False for gradient-backdrop scenes (theme/agents/notch/finale), which
    /// render brand gradients instead of a bundled photograph.
    let usesStill: Bool
    let textZone: OnboardingTextZone

    init(
        assetName: String,
        headline: String? = nil,
        lines: [String],
        dwell: Duration?,
        isFinale: Bool = false,
        isInteractive: Bool = false,
        usesStill: Bool = true,
        textZone: OnboardingTextZone
    ) {
        self.id = assetName
        self.assetName = assetName
        self.headline = headline
        self.lines = lines
        self.dwell = dwell
        self.isFinale = isFinale
        self.isInteractive = isInteractive
        self.usesStill = usesStill
        self.textZone = textZone
    }
}

/// The sequence, copy taken verbatim from the screenplay's Scenes 0/1/2/7
/// (docs/plans/phases/first-launch-onboarding.md) plus the interactive
/// movements (theme dye, agent discovery, notch) added 2026-07-27. The
/// "Software is fabric" movement backs onto `V2-bobbins` (the loom shot was
/// cut — user decision) and every scene from the dye onward renders a brand
/// gradient-glow backdrop, no photograph. Scenes 5 and 6 of the screenplay
/// (AI/Keychain consent, CLI installer) remain out of scope.
nonisolated enum OnboardingScript {
    static let passOne: [OnboardingStep] = [
        OnboardingStep(
            assetName: "V0-knot",
            headline: "Rafu",
            lines: ["n. — to mend, with thread."],
            dwell: .seconds(6),
            textZone: .lowerCenter
        ),
        OnboardingStep(
            assetName: "V2-bobbins",
            lines: [
                "Software is fabric.",
                "Yours has loose threads — a repo here, an agent there, a terminal screaming somewhere.",
                "Rafu is where you mend.",
            ],
            dwell: .seconds(10),
            textZone: .lowerCenter
        ),
        OnboardingStep(
            assetName: "I1-native",
            headline: "No web view in a trench coat.",
            lines: [
                "Rafu is real macOS — real windows, real menus, your keyboard shortcuts, your accessibility settings. The editor is TextKit. The terminal is a terminal. The only thing Electron about it is that we just said Electron."
            ],
            dwell: .seconds(6),
            textZone: .upperLeading
        ),
        OnboardingStep(
            assetName: "I2-private",
            headline: "Your code doesn't phone home. It doesn't even have our number.",
            lines: [
                "No account. No telemetry. Keys live in your Keychain, diffs go to a model only when you press the button, and 'offline' is a place Rafu works, not an error state."
            ],
            dwell: .seconds(6),
            textZone: .upperLeading
        ),
        OnboardingStep(
            assetName: "I3-quiet",
            headline: "Built to idle under 150 MB.",
            lines: [
                "That's the budget we hold ourselves to — roughly one browser tab's breakfast. Parsing runs only on open files. Nothing polls. The fans stay bored."
            ],
            dwell: .seconds(6),
            textZone: .center
        ),
        OnboardingStep(
            assetName: "dye",
            headline: "Choose your cloth.",
            lines: [
                "Every dye here was mixed by hand. This is only the first coat — change it anytime in Settings."
            ],
            dwell: nil,
            isInteractive: true,
            usesStill: false,
            textZone: .center
        ),
        OnboardingStep(
            assetName: "agents",
            headline: "Your crew was already here.",
            lines: [
                "These are the agent CLIs Rafu found on your machine. Open any of them in a terminal that knows who's inside — or conduct several at once as an Ensemble."
            ],
            dwell: nil,
            isInteractive: true,
            usesStill: false,
            textZone: .center
        ),
        OnboardingStep(
            assetName: "notch",
            headline: "A quiet companion, up top.",
            lines: [
                "When something's running — an agent, a build, a long task — Rafu can surface it in a sliver by the notch. Glanceable, silent, and yours to switch off in Settings."
            ],
            dwell: nil,
            isInteractive: true,
            usesStill: false,
            textZone: .center
        ),
        OnboardingStep(
            assetName: "finale",
            lines: ["Enough about us.", "Open something."],
            dwell: nil,
            isFinale: true,
            usesStill: false,
            textZone: .finaleSplit
        ),
    ]
}
