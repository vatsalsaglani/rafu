import Foundation
import Testing

@testable import RafuCore

@Suite("Voice style profile")
struct VoiceStyleProfileTests {
    @Test("Round trip through the stored form")
    func roundTrip() throws {
        var profile = VoiceStyleProfile()
        profile.tone = "brief"
        profile.names = ["Meera": "Rafu AI"]
        profile.commandShapes = ["add a note called X"]
        profile.checkInSeconds = 45
        let data = try profile.encoded()
        #expect(try VoiceStyleProfile.decode(data) == profile)
        #expect(String(decoding: data, as: UTF8.self).contains("command_shapes"))
    }

    @Test("More than 4 KiB is refused")
    func tooLarge() throws {
        var profile = VoiceStyleProfile()
        profile.tone = String(repeating: "x", count: 5_000)
        #expect(throws: VoiceStyleProfileError.self) { try profile.validate() }
        let big = Data(repeating: 0x20, count: 5_000)
        #expect(throws: VoiceStyleProfileError.tooLarge(bytes: 5_000)) {
            try VoiceStyleProfile.decode(big)
        }
    }

    @Test("Unknown keys, such as a transcript, are refused")
    func unknownKey() {
        let data = Data(#"{"version":1,"transcript":"hello"}"#.utf8)
        #expect(throws: VoiceStyleProfileError.unknownKey("transcript")) {
            try VoiceStyleProfile.decode(data)
        }
    }

    @Test("List bounds and the version are checked")
    func bounds() {
        var profile = VoiceStyleProfile()
        profile.commandShapes = (0..<11).map { "shape \($0)" }
        #expect(throws: VoiceStyleProfileError.invalid) { try profile.validate() }
        #expect(throws: VoiceStyleProfileError.unsupportedVersion(2)) {
            try VoiceStyleProfile(version: 2).validate()
        }
    }
}
