// Owned by the workspace surfaces package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
//
// Four surfaces inside a workspace window: the navigator panel, the meeting
// tab body, the Welcome card and the title-bar record button. Each reads
// `feature.session` and the store. None holds a recorder or an engine, and
// none makes the feature.
import SwiftUI

extension MeetingsFeature {
    func registerWorkspaceParts() {
        register(
            .navigatorView { feature, session in
                AnyView(MeetingsNavigatorView(feature: feature, workspaceSession: session))
            })
        register(
            .meetingTabBody { feature, session, meeting in
                AnyView(
                    MeetingsTabBodyView(
                        feature: feature, workspaceSession: session, meeting: meeting))
            })
        register(
            .welcomeCard { feature, _ in
                AnyView(MeetingsWelcomeCardView(feature: feature))
            })
        register(
            .recordButton { feature, _ in
                AnyView(MeetingsTitleBarRecordButton(feature: feature))
            })
    }
}
