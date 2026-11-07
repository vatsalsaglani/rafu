import Testing

@testable import RafuCore

@Suite("Voice output scrubber")
struct VoiceOutputScrubberTests {
    @Test("Each secret shape is redacted")
    func patterns() {
        let samples = [
            "key sk-abcdefgh12345678",
            "token ghp_abcdefABCDEF123",
            "gho_secretvalue",
            "github_pat_11ABCDEF_more",
            "AKIAABCDEFGHIJKLMNOP",
            "xoxb-1234-abcd",
            "Authorization: Bearer abc.def.ghi",
            "password=hunter2",
            "API_KEY: value123",
            "secret = s3cr3t",
            String(repeating: "a1B2", count: 11),
        ]
        for sample in samples {
            let scrubbed = VoiceOutputScrubber.scrub(lines: [sample])
            #expect(scrubbed.contains("[redacted]"), Comment(rawValue: sample))
        }
        #expect(!VoiceOutputScrubber.scrub(lines: ["password=hunter2"]).contains("hunter2"))
    }

    @Test("A private key block is removed across lines")
    func privateKey() {
        let scrubbed = VoiceOutputScrubber.scrub(lines: [
            "before", "-----BEGIN RSA PRIVATE KEY-----", "MIIEabc", "def",
            "-----END RSA PRIVATE KEY-----", "after",
        ])
        #expect(!scrubbed.contains("MIIEabc"))
        #expect(!scrubbed.contains("def\n"))
        #expect(scrubbed.hasPrefix("before"))
        #expect(scrubbed.hasSuffix("after"))
    }

    @Test("Plain output survives; empty lines and control characters go")
    func plain() {
        let scrubbed = VoiceOutputScrubber.scrub(lines: [
            "Build complete", "", "   ", "tests\u{1B}[0m passed",
        ])
        #expect(scrubbed == "Build complete\ntests [0m passed")
    }

    @Test("Bounds: last lines, bytes per line, bytes in all")
    func bounds() {
        let lines = (0..<100).map { "line \($0)" }
        let scrubbed = VoiceOutputScrubber.scrub(lines: lines, maxLines: 40)
        let kept = scrubbed.split(separator: "\n")
        #expect(kept.count == 40)
        #expect(kept.last == "line 99")
        let long = VoiceOutputScrubber.scrub(
            lines: [String(repeating: "x y ", count: 200)], maxLineBytes: 200)
        #expect(long.utf8.count <= 200)
        let total = VoiceOutputScrubber.scrub(
            lines: (0..<40).map { _ in String(repeating: "word ", count: 39) }, maxBytes: 4_096)
        #expect(total.utf8.count <= 4_096)
    }
}
