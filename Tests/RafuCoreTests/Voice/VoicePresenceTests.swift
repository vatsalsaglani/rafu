import CoreGraphics
import Foundation
import RafuCore
import Testing

@Suite("Voice presence")
struct VoicePresenceTests {
    // MARK: Orb face

    @Test("Each session state maps to one face; only three faces carry a badge")
    func faces() {
        #expect(VoiceOrbFace.face(for: .idle) == .off)
        #expect(VoiceOrbFace.face(for: .connecting) == .connecting)
        #expect(VoiceOrbFace.face(for: .listeningHeld) == .listening)
        #expect(VoiceOrbFace.face(for: .listeningLatched) == .listening)
        #expect(VoiceOrbFace.face(for: .thinking) == .thinking)
        #expect(VoiceOrbFace.face(for: .speaking) == .speaking)
        #expect(VoiceOrbFace.face(for: .checkIn) == .checkIn)
        #expect(VoiceOrbFace.face(for: .paused) == .paused)
        #expect(VoiceOrbFace.face(for: .needsConfirm) == .needsConfirm)
        #expect(VoiceOrbFace.face(for: .error("x")) == .error)
        let badged = VoiceOrbFace.allCases.filter { $0.badgeSymbol != nil }
        #expect(badged == [.paused, .needsConfirm, .error])
    }

    @Test("Listening and Paused differ in the face, not only in colour")
    func listeningVersusPaused() {
        let listening = VoiceOrbExpression.target(for: .listening)
        let paused = VoiceOrbExpression.target(for: .paused)
        #expect(listening.lids == 1)
        #expect(paused.lids < 0.5)
        #expect(paused.gazeY > listening.gazeY)
        #expect(VoiceOrbFace.paused.badgeSymbol == "pause.fill")
        #expect(VoiceOrbFace.listening.badgeSymbol == nil)
        #expect(VoiceOrbExpression.target(for: .off).lids == 0)
        #expect(VoiceOrbExpression.target(for: .success).happy == 1)
    }

    @Test("Done shows over working faces, never over Confirm, Error or Off")
    func doneFace() {
        #expect(VoiceOrbFace.listening.withDone(true) == .success)
        #expect(VoiceOrbFace.thinking.withDone(true) == .success)
        #expect(VoiceOrbFace.needsConfirm.withDone(true) == .needsConfirm)
        #expect(VoiceOrbFace.error.withDone(true) == .error)
        #expect(VoiceOrbFace.off.withDone(true) == .off)
        #expect(VoiceOrbFace.paused.withDone(false) == .paused)
    }

    // MARK: Orb motion

    @Test("A change of face eases in and then settles exactly")
    func easing() {
        var motion = VoiceOrbMotion(face: .listening)
        var ticks = 0
        while !motion.isSettled(face: .paused), ticks < 60 {
            motion.step(face: .paused, mic: 0, output: 0)
            ticks += 1
        }
        #expect(ticks > 3)
        #expect(ticks < 30)
        #expect(motion.drawn.expression == .target(for: .paused))
        // Settled: another tick changes nothing.
        let changed = motion.step(face: .paused, mic: 0, output: 0)
        #expect(!changed)
    }

    @Test("Silence while listening draws nothing new")
    func silenceIsStill() {
        var motion = VoiceOrbMotion(face: .listening)
        for _ in 0..<40 {
            let changed = motion.step(face: .listening, mic: 0, output: 0)
            #expect(!changed)
        }
        #expect(!motion.hearing)
        #expect(!motion.isSettled(face: .listening))
    }

    @Test("Speech turns Listening into Hearing, with hysteresis")
    func hearing() {
        var motion = VoiceOrbMotion(face: .listening)
        motion.step(face: .listening, mic: 0.5, output: 0)
        #expect(motion.hearing)
        #expect(motion.shown(.listening) == .hearing)
        #expect(motion.drawn.level == 0.5)
        motion.step(face: .listening, mic: 0.05, output: 0)
        #expect(motion.hearing)
        motion.step(face: .listening, mic: 0.01, output: 0)
        #expect(!motion.hearing)
        motion.step(face: .thinking, mic: 0.9, output: 0)
        #expect(!motion.hearing)
    }

    @Test("Thinking rocks the marble with time; Speaking follows the output")
    func movingFaces() {
        var thinking = VoiceOrbMotion(face: .thinking)
        let start = thinking.drawn.phase
        for _ in 0..<30 { thinking.step(face: .thinking, mic: 0, output: 0) }
        #expect(
            abs(thinking.drawn.phase - start - VoiceOrbExpression.target(for: .thinking).spin)
                < 0.01)

        var speaking = VoiceOrbMotion(face: .speaking)
        speaking.step(face: .speaking, mic: 0, output: 0.8)
        #expect(speaking.drawn.level == 0.8)
        speaking.step(face: .speaking, mic: 0, output: 0)
        #expect(abs(speaking.drawn.level - 0.8 * VoiceOrbMotion.decay) < 1e-9)
    }

    @Test("Connecting repeats a ripple; other faces have none")
    func ripple() {
        var motion = VoiceOrbMotion(face: .connecting)
        var wraps = 0
        var last = 0.0
        for _ in 0..<Int(VoiceOrbMotion.ticksPerSecond * VoiceOrbMotion.rippleSeconds * 2) + 1 {
            motion.step(face: .connecting, mic: 0, output: 0)
            if motion.drawn.ripple < last { wraps += 1 }
            last = motion.drawn.ripple
        }
        #expect(wraps == 2)
        motion.step(face: .listening, mic: 0, output: 0)
        #expect(motion.drawn.ripple == 0)
    }

    @Test("The dots follow the pointer only while listening")
    func pointerGaze() {
        var listening = VoiceOrbMotion(face: .listening)
        for _ in 0..<30 { listening.step(face: .listening, mic: 0, output: 0, pointer: (1, -1)) }
        #expect(listening.drawn.lookX == 1)
        #expect(listening.drawn.lookY == -1)
        var paused = VoiceOrbMotion(face: .paused)
        for _ in 0..<30 { paused.step(face: .paused, mic: 0, output: 0, pointer: (1, -1)) }
        #expect(paused.drawn.lookX == 0)
    }

    @Test("Rest jumps to the still pose and keeps the phase")
    func rest() {
        var motion = VoiceOrbMotion(face: .speaking)
        for _ in 0..<10 { motion.step(face: .speaking, mic: 0, output: 1) }
        let phase = motion.drawn.phase
        motion.rest(face: .paused)
        #expect(motion.drawn.expression == .target(for: .paused))
        #expect(motion.drawn.level == 0)
        #expect(motion.drawn.phase == phase)
        #expect(motion.isSettled(face: .paused))
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
        #expect(Placement.slotRect(for: .topLeading, in: window).origin == CGPoint(x: 18, y: 18))
        #expect(
            Placement.slotRect(for: .bottomTrailing, in: window).origin
                == CGPoint(x: 1_000 - 64 - 18, y: 700 - 64 - 18))
        // A window too small for the slot keeps it at the padding.
        #expect(
            Placement.slotRect(for: .bottomTrailing, in: CGSize(width: 50, height: 50)).origin
                == CGPoint(x: 18, y: 18))
    }

    /// The board's zoom corner in a 1000 x 700 host: the capsule and the
    /// overview's place, 12 pt in from the corner.
    private var zoomCorner: CGRect {
        CGRect(x: 1_000 - 12 - 170, y: 700 - 12 - 126, width: 170, height: 126)
    }

    @Test("The orb sits above the board's zoom corner, on the same vertical line")
    func avoidsChrome() {
        typealias Placement = VoiceCompanionPlacement
        let slot = Placement.slotRect(for: .bottomTrailing, in: window, avoiding: [zoomCorner])
        #expect(
            !slot.intersects(zoomCorner.insetBy(dx: -Placement.chromeGap, dy: -Placement.chromeGap))
        )
        #expect(slot.maxY <= zoomCorner.minY - Placement.chromeGap)
        let trailingX: CGFloat = 1_000 - 64 - 18
        #expect(slot.minX == trailingX, "\(slot)")
        // Chrome in another corner does not move it.
        let other = CGRect(x: 12, y: 12, width: 170, height: 126)
        #expect(
            Placement.slotRect(for: .bottomTrailing, in: window, avoiding: [other])
                == Placement.slotRect(for: .bottomTrailing, in: window))
        // A host too short to stack: beside the chrome instead.
        let short = CGSize(width: 1_000, height: 200)
        let low = CGRect(x: 1_000 - 12 - 170, y: 200 - 12 - 126, width: 170, height: 126)
        let beside = Placement.slotRect(for: .bottomTrailing, in: short, avoiding: [low])
        #expect(!beside.intersects(low))
        #expect(beside.maxX <= low.minX)
    }

    @Test("A drag snaps to the quadrant of its predicted end")
    func dragSnap() {
        typealias Placement = VoiceCompanionPlacement
        let bottomTrailing = Placement.slotRect(for: .bottomTrailing, in: window)
        #expect(
            Placement.corner(
                afterDragFrom: bottomTrailing, predicted: CGSize(width: -700, height: -100),
                in: window) == .bottomLeading)
        #expect(
            Placement.corner(
                afterDragFrom: bottomTrailing, predicted: CGSize(width: -10, height: -500),
                in: window) == .topTrailing)
        #expect(
            Placement.corner(
                afterDragFrom: Placement.slotRect(for: .topLeading, in: window), predicted: .zero,
                in: window) == .topLeading)
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

    @Test("The card goes above a bottom corner and below a top one, in line with the orb")
    func cardRect() {
        typealias Placement = VoiceCompanionPlacement
        let card = CGSize(width: Placement.cardMaxWidth, height: 40)
        let bottom = Placement.slotRect(for: .bottomTrailing, in: window)
        let above = Placement.cardRect(orb: bottom, card: card, corner: .bottomTrailing, in: window)
        #expect(above.side == .above)
        #expect(above.rect.maxY <= bottom.minY)
        #expect(above.rect.maxX == bottom.maxX)
        let top = Placement.slotRect(for: .topLeading, in: window)
        let below = Placement.cardRect(orb: top, card: card, corner: .topLeading, in: window)
        #expect(below.side == .below)
        #expect(below.rect.minX == top.minX)
    }

    @Test("The pill never covers the orb and stays inside the host, at every width")
    func pillStaysInside() {
        typealias Placement = VoiceCompanionPlacement
        let pill = CGSize(width: 260, height: 30)
        for width in stride(from: 300.0, through: 1_600, by: 50) {
            let host = CGSize(width: width, height: 600)
            let bounds = CGRect(origin: .zero, size: host).insetBy(
                dx: Placement.partMargin - 0.5, dy: Placement.partMargin - 0.5)
            for corner in VoiceCompanionCorner.allCases {
                let chrome = CGRect(
                    x: width - 12 - 170, y: 600 - 12 - 126, width: 170, height: 126)
                let orb = Placement.slotRect(for: corner, in: host, avoiding: [chrome])
                let placed = Placement.pillRect(
                    orb: orb, pill: pill, corner: corner, in: host, avoiding: [chrome])
                #expect(!placed.rect.intersects(orb), "\(corner) at \(width)")
                #expect(bounds.contains(placed.rect), "\(corner) at \(width)")
            }
        }
        // In a wide host the pill opens toward the centre, beside the orb.
        let orb = Placement.slotRect(for: .bottomTrailing, in: window)
        let placed = Placement.pillRect(orb: orb, pill: pill, corner: .bottomTrailing, in: window)
        #expect(placed.side == .leading)
        #expect(placed.rect.maxX <= orb.minX)
        #expect(placed.rect.midY == orb.midY)
    }

    @Test("The pill keeps off the card")
    func pillAvoidsCard() {
        typealias Placement = VoiceCompanionPlacement
        let orb = Placement.slotRect(for: .bottomTrailing, in: window)
        // A card beside the orb (a short host): the pill goes above instead.
        let card = CGRect(x: orb.minX - 300, y: orb.minY - 4, width: 290, height: 72)
        let placed = Placement.pillRect(
            orb: orb, pill: CGSize(width: 200, height: 30), corner: .bottomTrailing, in: window,
            card: card)
        #expect(!placed.rect.intersects(card))
        #expect(!placed.rect.intersects(orb))
        #expect(placed.side == .above)
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
