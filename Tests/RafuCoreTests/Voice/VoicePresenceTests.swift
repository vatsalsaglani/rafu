import CoreGraphics
import Foundation
import RafuCore
import Testing

@Suite("Voice presence")
struct VoicePresenceTests {
    // MARK: Pose

    @Test("Each state has the pose from the design table")
    func poses() {
        let idle = VoiceOrbPose.pose(for: .idle, micOpen: false, latched: false)
        #expect(idle.driver == .still)
        #expect(idle.eyes == .closed)
        #expect(idle.ringOpacity == 0)

        let connecting = VoiceOrbPose.pose(for: .connecting, micOpen: true, latched: false)
        #expect(connecting.scale == 0.7)
        #expect(connecting.brightness == 0.5)
        #expect(connecting.ripple == .repeating)

        let held = VoiceOrbPose.pose(for: .listeningHeld, micOpen: true, latched: false)
        #expect(held.driver == .input)
        #expect(held.eyes == .open)
        #expect(held.eyesLookUp)
        #expect(held.ringWidth == 1)
        #expect(held.ringOpacity == 0.6)

        let latched = VoiceOrbPose.pose(for: .listeningLatched, micOpen: true, latched: true)
        #expect(latched.ringWidth == 2)
        #expect(latched.driver == .input)

        let thinking = VoiceOrbPose.pose(for: .thinking, micOpen: false, latched: false)
        #expect(thinking.driver == .turning)
        #expect(thinking.eyes == .half)
        #expect(thinking.brightness == 0.8)
        #expect(thinking.ringOpacity == 0.3)

        let speaking = VoiceOrbPose.pose(for: .speaking, micOpen: false, latched: false)
        #expect(speaking.driver == .output)
        #expect(speaking.lightShift == 0.15)
        #expect(speaking.ringOpacity == 0)
        #expect(VoiceOrbPose.pose(for: .speaking, micOpen: true, latched: true).ringOpacity > 0)

        let checkIn = VoiceOrbPose.pose(for: .checkIn, micOpen: true, latched: true)
        #expect(checkIn.ripple == .once)
        #expect(checkIn.driver == .still)
        #expect(checkIn.eyesLookUp)

        let paused = VoiceOrbPose.pose(for: .paused, micOpen: false, latched: false)
        #expect(paused.scale == 0.8)
        #expect(paused.desaturation == 0.4)
        #expect(paused.driver == .still)

        let confirm = VoiceOrbPose.pose(for: .needsConfirm, micOpen: false, latched: false)
        #expect(confirm.ringWidth == 2)
        #expect(confirm.ringOpacity == 1)
        #expect(confirm.eyes == .open)
        #expect(!confirm.eyesLookUp)

        let error = VoiceOrbPose.pose(for: .error("x"), micOpen: false, latched: false)
        #expect(error.brightness == 0.4)
        #expect(error.desaturation == 1)
    }

    @Test("Increase Contrast makes every shown ring at least 2 pt")
    func contrastRing() {
        let held = VoiceOrbPose.pose(
            for: .listeningHeld, micOpen: true, latched: false, increaseContrast: true)
        #expect(held.ringWidth == 2)
        #expect(held.ringOpacity >= 0.8)
        let idle = VoiceOrbPose.pose(
            for: .idle, micOpen: false, latched: false, increaseContrast: true)
        #expect(idle.ringOpacity == 0)
    }

    // MARK: Smoother

    @Test("The level rises at once, falls by 0.72 a tick, and writes only real changes")
    func smoothing() throws {
        let pose = VoiceOrbPose.pose(for: .listeningLatched, micOpen: true, latched: true)
        var smoother = VoiceLevelSmoother()
        let firstStep = smoother.step(raw: 0.8, pose: pose)
        let first = try #require(firstStep)
        #expect(first.level == 0.8)
        let secondStep = smoother.step(raw: 0, pose: pose)
        let second = try #require(secondStep)
        #expect(abs(second.level - 0.8 * 0.72) < 1e-9)
        // A tiny change is not written.
        var steady = VoiceLevelSmoother()
        _ = steady.step(raw: 0.5, pose: pose)
        let small = steady.step(raw: 0.51, pose: pose)
        #expect(small == nil)
    }

    @Test("Silence never moves the lobes; Thinking turns them with time")
    func silenceIsStill() {
        let listening = VoiceOrbPose.pose(for: .listeningLatched, micOpen: true, latched: true)
        var smoother = VoiceLevelSmoother()
        for _ in 0..<40 {
            let step = smoother.step(raw: 0, pose: listening)
            #expect(step == nil)
        }
        #expect(smoother.phase == 0)

        let thinking = VoiceOrbPose.pose(for: .thinking, micOpen: false, latched: false)
        var turning = VoiceLevelSmoother()
        var writes = 0
        for _ in 0..<20 where turning.step(raw: 0, pose: thinking) != nil { writes += 1 }
        #expect(writes == 20)
        // 0.1 turn per second: one second is 2π × 0.1 rad.
        #expect(abs(turning.phase - 2 * Double.pi * 0.1) < 1e-9)
    }

    @Test("A connecting ripple repeats every 1.2 s; a check-in ripple runs once")
    func ripples() {
        var repeating = VoiceLevelSmoother()
        let connecting = VoiceOrbPose.pose(for: .connecting, micOpen: true, latched: false)
        var zeros = 0
        for _ in 0..<(VoiceLevelSmoother.rippleTicks * 2) {
            _ = repeating.step(raw: 0, pose: connecting)
            if repeating.ripple == 0 { zeros += 1 }
        }
        #expect(zeros == 2)

        var once = VoiceLevelSmoother()
        let checkIn = VoiceOrbPose.pose(for: .checkIn, micOpen: true, latched: true)
        for _ in 0..<(VoiceLevelSmoother.rippleTicks * 3) { _ = once.step(raw: 0, pose: checkIn) }
        #expect(once.ripple == 0)
        let after = once.step(raw: 0, pose: checkIn)
        #expect(after == nil)
    }

    @Test("Reset returns to a still frame and keeps the phase")
    func reset() {
        let pose = VoiceOrbPose.pose(for: .speaking, micOpen: false, latched: false)
        var smoother = VoiceLevelSmoother()
        _ = smoother.step(raw: 1, pose: pose)
        let phase = smoother.phase
        smoother.reset()
        #expect(smoother.written.level == 0)
        #expect(smoother.written.phase == phase)
        #expect(smoother.written.ripple == 0)
    }

    // MARK: Captions

    @Test("A caption keeps its newest 160 scalars, cut at a word")
    func captionBound() {
        var caption = VoiceCaption(speaker: .rafu)
        for _ in 0..<60 { caption.append("word ") }
        #expect(caption.text.unicodeScalars.count <= VoiceCaption.maximumScalars)
        #expect(caption.text.hasPrefix("word"))
        #expect(caption.revision == 60)
        caption.append("")
        #expect(caption.revision == 60)
        #expect(!VoiceCaption(speaker: .you, text: "a\nb").text.contains("\n"))
    }

    @Test("Rafu's words show as a window of the newest 12")
    func captionWindow() {
        let words = (1...20).map(String.init).joined(separator: " ")
        let window = VoiceCaption.window(words)
        #expect(window == "…" + (9...20).map(String.init).joined(separator: " "))
        #expect(VoiceCaption.window("Done. All set.") == "Done. All set.")
        #expect(VoiceCaption(speaker: .rafu, text: "Done.").endsSentence)
        #expect(!VoiceCaption(speaker: .rafu, text: "Done and").endsSentence)
    }

    // MARK: Card

    private func update(_ kind: VoiceAgentUpdate.Kind) -> VoiceAgentUpdate {
        VoiceAgentUpdate(
            cardID: "c1", kind: kind, agent: "Codex", title: "“Tests”", excerpt: nil,
            queuedAt: .zero)
    }

    @Test("Agent lines read as one short sentence")
    func agentLines() {
        #expect(VoiceAgentLine(update: update(.done), sequence: 1).text == "Codex in Tests is done")
        #expect(
            VoiceAgentLine(update: update(.waiting), sequence: 1).text == "Codex in Tests needs you"
        )
        #expect(
            VoiceAgentLine(update: update(.needsApproval), sequence: 1).text
                == "Codex in Tests needs your approval")
        #expect(VoiceAgentLine(update: update(.done), sequence: 1).monogram == "C")
    }

    @Test("Card order: Confirm, error, state words, hint, caption, agent line")
    func cardContent() {
        let line = VoiceAgentLine(update: update(.done), sequence: 3)
        let you = VoiceCaption(speaker: .you, text: "make a note")
        let rafu = VoiceCaption(speaker: .rafu, text: "Done.")
        typealias Policy = VoiceCardPolicy

        #expect(Policy.content(.init(state: .idle, agentLine: line)) == .none)
        #expect(
            Policy.content(.init(state: .needsConfirm, caption: you, hasPendingConfirm: true))
                == .confirm)
        #expect(Policy.content(.init(state: .error("No key"), agentLine: line)) == .error("No key"))
        #expect(Policy.content(.init(state: .connecting)) == .status("Connecting…"))
        #expect(Policy.content(.init(state: .thinking, caption: you)) == .status("Working…"))
        #expect(Policy.content(.init(state: .checkIn)) == .status("Still there?"))
        #expect(
            Policy.content(.init(state: .paused, caption: you, hint: "Hold the key"))
                == .status("Hold the key"))
        // A voice caption always wins over an agent line.
        #expect(
            Policy.content(.init(state: .listeningLatched, caption: you, agentLine: line))
                == .caption(.you, "make a note"))
        #expect(
            Policy.content(.init(state: .speaking, caption: rafu, agentLine: line))
                == .caption(.rafu, "Done."))
        // Rafu's old words do not show while you listen; the agent line does.
        #expect(
            Policy.content(.init(state: .listeningLatched, caption: rafu, agentLine: line))
                == .agent(line))
    }

    @Test("The card stays while Rafu speaks, a Confirm waits, or the pointer is over it")
    func cardStays() {
        typealias Policy = VoiceCardPolicy
        let caption = Policy.Content.caption(.you, "hi")
        #expect(!Policy.staysVisible(caption, state: .listeningLatched, hovering: false))
        #expect(Policy.staysVisible(caption, state: .listeningLatched, hovering: true))
        #expect(Policy.staysVisible(.caption(.rafu, "x"), state: .speaking, hovering: false))
        #expect(Policy.staysVisible(.confirm, state: .needsConfirm, hovering: false))
        #expect(Policy.staysVisible(.error("x"), state: .error("x"), hovering: false))
        #expect(Policy.staysVisible(.status("Working…"), state: .thinking, hovering: false))
        #expect(!Policy.staysVisible(.status("Still there?"), state: .checkIn, hovering: false))
        #expect(Policy.hideAfter == .seconds(4))
    }

    // MARK: Placement

    private let window = CGSize(width: 1_000, height: 700)

    @Test("Corners sit 18 pt in from the edges")
    func cornerOrigins() {
        typealias Placement = VoiceCompanionPlacement
        #expect(Placement.slotOrigin(for: .topLeading, in: window) == CGPoint(x: 18, y: 18))
        #expect(
            Placement.slotOrigin(for: .bottomTrailing, in: window)
                == CGPoint(x: 1_000 - 96 - 18, y: 700 - 96 - 18))
        // A window too small for the slot keeps it at the padding.
        #expect(
            Placement.slotOrigin(for: .bottomTrailing, in: CGSize(width: 50, height: 50))
                == CGPoint(x: 18, y: 18))
    }

    @Test("A drag snaps to the quadrant of its predicted end")
    func dragSnap() {
        typealias Placement = VoiceCompanionPlacement
        #expect(
            Placement.corner(
                afterDragFrom: .bottomTrailing, predicted: CGSize(width: -700, height: -100),
                in: window) == .bottomLeading)
        #expect(
            Placement.corner(
                afterDragFrom: .bottomTrailing, predicted: CGSize(width: -10, height: -500),
                in: window) == .topTrailing)
        #expect(
            Placement.corner(afterDragFrom: .topLeading, predicted: .zero, in: window)
                == .topLeading)
    }

    @Test("Option-arrow moves to the adjacent corner; next goes clockwise")
    func cornerMoves() {
        #expect(VoiceCompanionCorner.bottomTrailing.moved(.left) == .bottomLeading)
        #expect(VoiceCompanionCorner.bottomTrailing.moved(.up) == .topTrailing)
        #expect(VoiceCompanionCorner.bottomTrailing.moved(.right) == .bottomTrailing)
        #expect(VoiceCompanionCorner.topLeading.moved(.down) == .bottomLeading)
        var corner = VoiceCompanionCorner.topLeading
        var seen: [VoiceCompanionCorner] = []
        for _ in 0..<4 {
            seen.append(corner)
            corner = corner.next
        }
        #expect(seen == [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading])
        #expect(corner == .topLeading)
    }

    @Test("The orb tucks only while a card drag is live over it")
    func tuck() {
        typealias Placement = VoiceCompanionPlacement
        let orb = CGRect(x: 100, y: 100, width: 96, height: 96)
        #expect(
            Placement.shouldTuck(dragLive: true, pointer: CGPoint(x: 150, y: 150), orbRect: orb))
        #expect(Placement.shouldTuck(dragLive: true, pointer: CGPoint(x: 95, y: 150), orbRect: orb))
        #expect(
            !Placement.shouldTuck(dragLive: true, pointer: CGPoint(x: 50, y: 150), orbRect: orb))
        #expect(
            !Placement.shouldTuck(dragLive: false, pointer: CGPoint(x: 150, y: 150), orbRect: orb))
        #expect(!Placement.shouldTuck(dragLive: true, pointer: nil, orbRect: orb))
        #expect(Placement.untuckDelay == .milliseconds(400))
    }

    @Test("The card goes above a bottom corner and beside a top one, toward the centre")
    func cardAndPillSides() {
        typealias Placement = VoiceCompanionPlacement
        #expect(Placement.cardSide(for: .bottomTrailing) == .above)
        #expect(Placement.cardSide(for: .bottomLeading) == .above)
        #expect(Placement.cardSide(for: .topLeading) == .trailing)
        #expect(Placement.cardSide(for: .topTrailing) == .leading)
        #expect(Placement.pillSide(for: .bottomTrailing) == .leading)
        #expect(Placement.pillSide(for: .bottomLeading) == .trailing)
        #expect(Placement.pillSide(for: .topLeading) == .below)
    }

    @Test("The corner key is per workspace, stable, and stores no path")
    func cornerKey() {
        typealias Placement = VoiceCompanionPlacement
        let first = Placement.cornerKey(workspacePath: "/Users/me/Projects/api")
        #expect(first == Placement.cornerKey(workspacePath: "/Users/me/Projects/api"))
        #expect(first != Placement.cornerKey(workspacePath: "/Users/me/Projects/web"))
        #expect(first.hasPrefix("voice.companion.corner."))
        #expect(!first.contains("/"))
        #expect(!first.contains("api"))
        #expect(Placement.cornerKey(workspacePath: nil) == "voice.companion.corner.none")
        // FNV-1a 64 of the empty-hash basis is known; pin one value so a
        // change of hash (which would lose every saved corner) fails here.
        #expect(
            Placement.cornerKey(workspacePath: "a") == "voice.companion.corner.af63dc4c8601ec8c")
        #expect(VoiceCompanionCorner(rawValue: "br") == .bottomTrailing)
    }

    @Test("Turn progress reads done of total")
    func progress() {
        #expect(VoiceTurnProgress().chip == nil)
        #expect(VoiceTurnProgress(done: 2, total: 3).chip == "2/3")
        #expect(VoiceTurnProgress(done: 4, total: 3).chip == "3/3")
    }
}
