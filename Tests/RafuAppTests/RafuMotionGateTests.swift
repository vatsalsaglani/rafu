import Foundation
import Testing

@testable import RafuApp

/// The motion gate, the mascot's idle schedule and the spinner gate: pure
/// value logic, no windows and no notifications.

// MARK: - Motion conditions

@Test("RafuMotionConditions: motion runs only in a visible window on an active screen")
func motionConditionsCombinations() {
    let active = RafuMotionConditions()
    #expect(active.isScreenActive)
    #expect(active.allowsMotion(windowVisible: true))
    #expect(!active.allowsMotion(windowVisible: false))

    for hidden in [
        RafuMotionConditions(screenLocked: true),
        RafuMotionConditions(displaysAsleep: true),
        RafuMotionConditions(sessionInactive: true),
        RafuMotionConditions(screenLocked: true, displaysAsleep: true, sessionInactive: true),
    ] {
        #expect(!hidden.isScreenActive)
        #expect(!hidden.allowsMotion(windowVisible: true))
        #expect(!hidden.allowsMotion(windowVisible: false))
    }
}

@Test("RafuMotionConditions: each event sets only its own flag, and its pair clears it")
func motionConditionsEvents() {
    let locked = RafuMotionConditions().applying(.screenLocked)
    #expect(locked == RafuMotionConditions(screenLocked: true))
    // Waking the displays does not unlock the screen.
    let lockedAwake = locked.applying(.displaysSlept).applying(.displaysWoke)
    #expect(lockedAwake == locked)
    #expect(!lockedAwake.isScreenActive)
    #expect(lockedAwake.applying(.screenUnlocked).isScreenActive)

    let asleep = RafuMotionConditions().applying(.displaysSlept)
    #expect(asleep == RafuMotionConditions(displaysAsleep: true))
    #expect(asleep.applying(.displaysWoke).isScreenActive)

    let switchedAway = RafuMotionConditions().applying(.sessionResignedActive)
    #expect(switchedAway == RafuMotionConditions(sessionInactive: true))
    #expect(switchedAway.applying(.sessionBecameActive).isScreenActive)
}

@Test("RafuMotionGate.handle: an unstarted gate follows the events it is given")
@MainActor
func motionGateHandlesEvents() {
    let gate = RafuMotionGate()
    #expect(gate.isScreenActive)
    gate.handle(.screenLocked)
    #expect(!gate.isScreenActive)
    gate.handle(.displaysSlept)
    gate.handle(.screenUnlocked)
    #expect(!gate.isScreenActive)
    gate.handle(.displaysWoke)
    #expect(gate.isScreenActive)
}

// MARK: - Mascot idle schedule

@Test("RafuMascotIdleMotion: the idle mood breathes only while engaged")
func mascotIdleMotionResolves() {
    #expect(RafuMascotIdleMotion.resolve(engaged: false) == .still)
    #expect(RafuMascotIdleMotion.resolve(engaged: true) == .breathing)
}

@Test("RafuMascotIdleMotion.stillCycle: discrete beats, animating under a tenth of the time")
func mascotStillCycleIsDiscrete() {
    let cycle = RafuMascotIdleMotion.stillCycle
    #expect(!cycle.isEmpty)
    #expect(cycle.contains { $0.action == .blink })
    // Every beat holds still for at least a second before it acts, so no
    // animation is ever chained to the next.
    for beat in cycle {
        #expect(beat.pause >= .seconds(1))
    }
    let still = cycle.reduce(Duration.zero) { $0 + $1.pause } / .seconds(1)
    let animated = Double(cycle.count) * RafuMascotIdleMotion.longestActionSeconds
    #expect(animated / (still + animated) < 0.1)
    // A glance away always looks back before the cycle repeats.
    let glances = cycle.compactMap { beat -> CGSize? in
        if case .glance(let offset) = beat.action { return offset }
        return nil
    }
    #expect(glances.last == .zero)
}

@Test("RafuMascotIdleMotion.breathPose: phase 0 is the still pose and the breath stays small")
func mascotBreathPose() {
    let rest = RafuMascotIdleMotion.breathPose(phase: 0)
    #expect(rest.inhale == 0)
    #expect(rest.sway == 0)
    let full = RafuMascotIdleMotion.breathPose(
        phase: RafuMascotIdleMotion.breathPhase(elapsed: RafuMascotIdleMotion.breathPeriod / 2))
    #expect(abs(full.inhale - 1) < 0.000_1)
    for step in 0..<50 {
        let pose = RafuMascotIdleMotion.breathPose(phase: Double(step) * 0.37)
        #expect(pose.inhale >= 0 && pose.inhale <= 1)
        #expect(abs(pose.sway) <= 5)
    }
    // At most 15 writes a second, not one per display frame.
    #expect(RafuMascotIdleMotion.breathFrameInterval >= 1.0 / 15)
}

// MARK: - Spinner gate

@Test("AgentActivityGlyph.spins: Reduce Motion, a hidden window or a locked screen stop it")
func agentGlyphSpinGate() {
    #expect(AgentActivityGlyph.spins(animates: true, reduceMotion: false, motionAllowed: true))
    #expect(!AgentActivityGlyph.spins(animates: false, reduceMotion: false, motionAllowed: true))
    #expect(!AgentActivityGlyph.spins(animates: true, reduceMotion: true, motionAllowed: true))
    #expect(!AgentActivityGlyph.spins(animates: true, reduceMotion: false, motionAllowed: false))
}
