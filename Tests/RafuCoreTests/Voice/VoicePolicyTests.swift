import Testing

@testable import RafuCore

@Suite("Voice policy")
struct VoicePolicyTests {
    @Test("Mode × risk × grant table")
    func table() {
        typealias Row = (CanvasAgentControlMode, CanvasAgentRisk, Bool, VoiceDecision)
        let rows: [Row] = [
            (.off, .read, false, .run),
            (.off, .edit, false, .deny(VoicePolicy.offMessage)),
            (.off, .sensitive, true, .deny(VoicePolicy.offMessage)),
            (.ask, .read, false, .run),
            (.ask, .edit, false, .runWithNotice),
            (.ask, .sensitive, false, .confirm),
            (.ask, .sensitive, true, .runWithNotice),
            (.allow, .read, false, .run),
            (.allow, .edit, false, .run),
            (.allow, .sensitive, false, .runWithNotice),
        ]
        for (mode, risk, grant, expected) in rows {
            #expect(
                VoicePolicy.decide(mode: mode, risk: risk, alwaysAllowed: grant) == expected,
                "\(mode) \(risk) \(grant)")
        }
    }

    @Test("Terminal output is shared only in Allow with the setting on")
    func tail() {
        #expect(VoicePolicy.sharesTerminalTail(mode: .allow, setting: true))
        #expect(!VoicePolicy.sharesTerminalTail(mode: .allow, setting: false))
        #expect(!VoicePolicy.sharesTerminalTail(mode: .ask, setting: true))
        #expect(!VoicePolicy.sharesTerminalTail(mode: .off, setting: true))
    }
}
