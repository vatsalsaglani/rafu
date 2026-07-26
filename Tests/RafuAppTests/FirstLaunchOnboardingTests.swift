import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// First-launch onboarding ("The Unfolding," pass 1): `OnboardingCompletionStore`'s
/// round-trip against an injected suite, `OnboardingAssetCatalog` resolving
/// every pass-1 step's still in both grades, `OnboardingGrade` resolution,
/// and `FirstLaunchExperienceModel`'s pure step transitions
/// (`advance`/`back`/`skip`/`finish`/`relinquishHost`/`hosts`). The
/// auto-advance timer itself is a thin `Task.sleep` wrapper, not business
/// logic — exercised through direct transition calls rather than waited on
/// with a real sleep.
@Suite("First-launch onboarding")
struct FirstLaunchOnboardingTests {

    // MARK: - OnboardingCompletionStore

    @Test("OnboardingCompletionStore round-trips completion against an injected suite")
    func completionStoreRoundTrips() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)

        #expect(store.hasCompleted == false)
        store.markCompleted()
        #expect(store.hasCompleted == true)
    }

    @Test("OnboardingCompletionStore.reset re-arms a completed store")
    func completionStoreResets() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        store.markCompleted()
        #expect(store.hasCompleted == true)

        store.reset()
        #expect(store.hasCompleted == false)
    }

    // MARK: - OnboardingAssetCatalog

    @Test("Every still-backed step resolves a still URL that exists on disk, in both grades")
    func everyStepResolvesStillsInBothGrades() {
        for step in OnboardingScript.passOne where step.usesStill {
            for grade: OnboardingGrade in [.indigo, .khadi] {
                let url = OnboardingAssetCatalog.stillURL(step.assetName, grade: grade)
                #expect(url != nil, "missing still for \(step.assetName)/\(grade.rawValue)")
                if let url {
                    #expect(FileManager.default.fileExists(atPath: url.path))
                }
            }
        }
    }

    // MARK: - OnboardingGrade

    @Test("OnboardingGrade.resolve maps dark to indigo and light to khadi")
    func gradeResolvesFromColorScheme() {
        #expect(OnboardingGrade.resolve(for: .dark) == .indigo)
        #expect(OnboardingGrade.resolve(for: .light) == .khadi)
    }

    // MARK: - OnboardingScript

    @Test("The finale step never auto-advances")
    func finaleStepHasNoDwell() throws {
        let finale = try #require(OnboardingScript.passOne.last)
        #expect(finale.dwell == nil)
        #expect(finale.isFinale == true)
    }

    @Test("Every pass-1 step's textZone matches the cinematic design spec")
    func textZonesMatchDesignSpec() {
        let expected: [String: OnboardingTextZone] = [
            "V0-knot": .lowerCenter,
            "V2-bobbins": .lowerCenter,
            "I1-native": .upperLeading,
            "I2-private": .upperLeading,
            "I3-quiet": .center,
            "dye": .center,
            "agents": .center,
            "notch": .center,
            "finale": .finaleSplit,
        ]

        for step in OnboardingScript.passOne {
            #expect(
                step.textZone == expected[step.assetName],
                "unexpected textZone for \(step.assetName)"
            )
        }
    }

    @Test("Interactive steps never auto-advance and never claim a still")
    func interactiveStepsWaitForTheUser() {
        let interactive = OnboardingScript.passOne.filter(\.isInteractive)
        #expect(interactive.map(\.assetName) == ["dye", "agents", "notch"])
        for step in interactive {
            #expect(step.dwell == nil, "\(step.assetName) must wait for the user")
            #expect(step.usesStill == false)
            #expect(step.isFinale == false)
        }
    }

    // MARK: - FirstLaunchExperienceModel

    @MainActor
    @Test("offerOnFirstLaunch presents the intro at step 0 for a fresh store")
    func offerPresentsForFreshStore() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = FirstLaunchExperienceModel(
            store: OnboardingCompletionStore(suiteName: suiteName))
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)

        #expect(model.isPresented == true)
        #expect(model.stepIndex == 0)
        #expect(model.hosts(session) == true)
    }

    @MainActor
    @Test("offerOnFirstLaunch is a no-op when the store already reports completion")
    func offerIsNoOpWhenAlreadyCompleted() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        store.markCompleted()
        let model = FirstLaunchExperienceModel(store: store)
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)

        #expect(model.isPresented == false)
    }

    @MainActor
    @Test("advance() walks every step and finish() marks completion past the last one")
    func advanceWalksAllStepsThenFinishes() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        let model = FirstLaunchExperienceModel(store: store)
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)
        let stepCount = OnboardingScript.passOne.count
        for _ in 1..<stepCount {
            model.advance()
        }
        #expect(model.stepIndex == stepCount - 1)
        #expect(model.isPresented == true)

        model.advance()

        #expect(model.isPresented == false)
        #expect(store.hasCompleted == true)
    }

    @MainActor
    @Test("skip() from step 0 marks the store complete and dismisses")
    func skipFromFirstStepCompletes() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        let model = FirstLaunchExperienceModel(store: store)
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)
        model.skip()

        #expect(model.isPresented == false)
        #expect(store.hasCompleted == true)
    }

    @MainActor
    @Test("back() clamps at step 0 and never goes negative")
    func backClampsAtZero() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = FirstLaunchExperienceModel(
            store: OnboardingCompletionStore(suiteName: suiteName))
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)
        model.back()
        model.back()

        #expect(model.stepIndex == 0)
    }

    @MainActor
    @Test("hosts(_:) is true only for the session passed to offerOnFirstLaunch")
    func hostsOnlyMatchesTheOfferedSession() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = FirstLaunchExperienceModel(
            store: OnboardingCompletionStore(suiteName: suiteName))
        let hosted = WorkspaceSession()
        let other = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: hosted)

        #expect(model.hosts(hosted) == true)
        #expect(model.hosts(other) == false)
    }

    @MainActor
    @Test("relinquishHost dismisses without marking completion")
    func relinquishDoesNotComplete() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        let model = FirstLaunchExperienceModel(store: store)
        let session = WorkspaceSession()

        model.offerOnFirstLaunch(hostedBy: session)
        model.relinquishHost(session)

        #expect(model.isPresented == false)
        #expect(store.hasCompleted == false)
        #expect(model.hosts(session) == false)
    }

    @MainActor
    @Test("replay ignores prior completion")
    func replayIgnoresCompletion() {
        let suiteName = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(suiteName: suiteName)
        store.markCompleted()
        let model = FirstLaunchExperienceModel(store: store)
        let session = WorkspaceSession()

        model.replay(hostedBy: session)

        #expect(model.isPresented == true)
        #expect(model.stepIndex == 0)
    }
}
