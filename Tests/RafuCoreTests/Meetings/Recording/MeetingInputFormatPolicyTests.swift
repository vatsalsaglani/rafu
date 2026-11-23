import Testing

@testable import RafuCore

@Suite("Meeting input format policy")
struct MeetingInputFormatPolicyTests {
    private func format(rate: Double, channels: Int = 1, interleaved: Bool = true)
        -> MeetingTapFormat
    {
        MeetingTapFormat(
            sampleRate: rate, channelCount: channels, bitsPerChannel: 32,
            isInterleaved: interleaved)
    }

    @Test("48 kHz mono uses the nominal rate")
    func fortyEightMono() throws {
        let layout = try MeetingInputFormatPolicy.layout(
            streamFormat: format(rate: 48_000), isFloat32: true, nominalRate: 48_000)
        #expect(
            layout == MeetingInputLayout(channelCount: 1, isInterleaved: true, sampleRate: 48_000))
        #expect(layout.stride == 1)
    }

    @Test("A call-mode headset at 24 kHz uses the nominal rate over the stream rate")
    func twentyFourMono() throws {
        let layout = try MeetingInputFormatPolicy.layout(
            streamFormat: format(rate: 48_000), isFloat32: true, nominalRate: 24_000)
        #expect(layout.sampleRate == 24_000)
        #expect(layout.channelCount == 1)
    }

    @Test("16 kHz is kept")
    func sixteen() throws {
        let layout = try MeetingInputFormatPolicy.layout(
            streamFormat: format(rate: 16_000), isFloat32: true, nominalRate: 16_000)
        #expect(layout.sampleRate == 16_000)
    }

    @Test("A nominal rate of 0, nil or not finite falls back to the stream rate")
    func fallbackToStreamRate() throws {
        for nominal in [0, nil, Double.nan, Double.infinity, -1] as [Double?] {
            let layout = try MeetingInputFormatPolicy.layout(
                streamFormat: format(rate: 44_100), isFloat32: true, nominalRate: nominal)
            #expect(layout.sampleRate == 44_100)
        }
    }

    @Test("No usable rate throws")
    func bothZeroThrows() {
        #expect(throws: MeetingInputFormatError.noSampleRate) {
            try MeetingInputFormatPolicy.layout(
                streamFormat: format(rate: 0), isFloat32: true, nominalRate: 0)
        }
        #expect(throws: MeetingInputFormatError.noSampleRate) {
            try MeetingInputFormatPolicy.layout(
                streamFormat: format(rate: 0), isFloat32: true, nominalRate: nil)
        }
    }

    @Test("A format that is not 32-bit float throws")
    func notFloatThrows() {
        #expect(throws: MeetingInputFormatError.unsupportedFormat) {
            try MeetingInputFormatPolicy.layout(
                streamFormat: format(rate: 48_000), isFloat32: false, nominalRate: 48_000)
        }
    }

    @Test("A stream with no channels throws")
    func noChannelsThrows() {
        #expect(throws: MeetingInputFormatError.noChannels) {
            try MeetingInputFormatPolicy.layout(
                streamFormat: format(rate: 48_000, channels: 0), isFloat32: true,
                nominalRate: 48_000)
        }
    }

    @Test("Three non-interleaved channels read channel 0 with stride 1")
    func threeChannelsNonInterleaved() throws {
        let layout = try MeetingInputFormatPolicy.layout(
            streamFormat: format(rate: 48_000, channels: 3, interleaved: false), isFloat32: true,
            nominalRate: 48_000)
        #expect(layout.channelCount == 3)
        #expect(!layout.isInterleaved)
        #expect(layout.stride == 1)
    }

    @Test("Two interleaved channels read channel 0 with stride 2")
    func twoChannelsInterleaved() throws {
        let layout = try MeetingInputFormatPolicy.layout(
            streamFormat: format(rate: 48_000, channels: 2, interleaved: true), isFloat32: true,
            nominalRate: nil)
        #expect(layout.stride == 2)
    }
}
