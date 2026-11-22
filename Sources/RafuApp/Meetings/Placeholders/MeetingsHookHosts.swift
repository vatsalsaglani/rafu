import RafuCore
import SwiftUI

// One host view for each Meetings surface. A host draws the registered hook
// of `MeetingsFeature`, or `MeetingsPlaceholderView` when there is none.
//
// Entry points that the user opens (the window, the navigator panel,
// Settings ▸ Meetings, a meeting tab) make the feature on appear. Passive
// surfaces that show at launch (the Welcome card, the title bar record
// button, the notch section) only read an existing feature, so launch never
// makes it.

/// The Meetings window scene's content (`Window("Meetings", id: "meetings")`).
struct MeetingsWindowRoot: View {
    static let windowID = "meetings"

    @Environment(\.openWindow) private var openWindow
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        Group {
            if let feature = factory.feature, let hook = feature.windowView {
                hook(feature)
            } else {
                MeetingsPlaceholderView()
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            factory.resolve()
            MeetingsWindowOpener.shared.capture(openWindow)
        }
    }
}

/// The Meetings navigator panel. The header stays here; the body is the
/// registered navigator hook. It pins to the top and its empty state
/// expands, so an empty panel never floats to the middle.
struct MeetingsNavigatorPanelView: View {
    let session: WorkspaceSession

    @Environment(\.openWindow) private var openWindow
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        VStack(spacing: 0) {
            RafuUtilityPanelHeader(title: "Meetings") {
                EmptyView()
            }
            Group {
                if let feature = factory.feature, let hook = feature.navigatorView {
                    hook(feature, session)
                } else {
                    MeetingsPlaceholderView(compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            factory.resolve()
            MeetingsWindowOpener.shared.capture(openWindow)
        }
    }
}

/// The body of a `.meeting` tab in a workspace window.
struct MeetingsTabHost: View {
    let session: WorkspaceSession
    let meeting: MeetingID

    @Environment(\.openWindow) private var openWindow
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        Group {
            if let feature = factory.feature, let hook = feature.meetingTabBody {
                hook(feature, session, meeting)
            } else {
                MeetingsPlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            factory.resolve()
            MeetingsWindowOpener.shared.capture(openWindow)
        }
    }
}

/// The Settings ▸ Meetings pane body, inside the pane's grouped `Form`.
struct MeetingsSettingsPaneHost: View {
    @Environment(\.openWindow) private var openWindow
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        Group {
            if let feature = factory.feature, let hook = feature.settingsView {
                hook(feature)
            } else {
                Section {
                    Text(MeetingsPlaceholderView.message(for: .current))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Meetings")
                }
            }
        }
        .onAppear {
            factory.resolve()
            MeetingsWindowOpener.shared.capture(openWindow)
        }
    }
}

/// The Meetings card on the Welcome screen. It never makes the feature:
/// the Welcome screen shows at launch.
struct MeetingsWelcomeCardSlot: View {
    let session: WorkspaceSession

    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        Group {
            if let feature = factory.feature, let hook = feature.welcomeCard {
                hook(feature, session)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let reason = MeetingsAvailability.current.unavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(theme.palette.textMuted)
                    } else {
                        Button("Open Meetings", systemImage: "waveform.and.person.filled") {
                            openWindow(id: MeetingsWindowRoot.windowID)
                        }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .help("Open Meetings (⌘⇧M)")
                    }
                }
            }
        }
        .onAppear { MeetingsWindowOpener.shared.capture(openWindow) }
    }
}

/// The record button slot in the title bar. It draws nothing until a
/// package registers the hook, and it never makes the feature.
struct MeetingsRecordButtonSlot: View {
    let session: WorkspaceSession

    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        if let feature = factory.feature, let hook = feature.recordButton {
            hook(feature, session)
                .padding(.trailing, RafuMetrics.space1)
        }
    }
}

/// The notch's Meetings section. The section is offered only after a
/// recorder is registered (`MeetingsCompanionGate`), and this never makes
/// the feature.
struct MeetingsCompanionSectionHost: View {
    private let factory = MeetingsFeatureFactory.shared

    var body: some View {
        if let feature = factory.feature, let hook = feature.companionSection {
            hook(feature)
        } else {
            MeetingsPlaceholderView(compact: true)
        }
    }
}
