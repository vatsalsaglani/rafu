import Foundation

/// Maps a track peak in dBFS to the 0...1 value of a level meter.
public enum MeetingLevelScale {
    /// At or below this level the meter shows nothing.
    public static let floorDBFS: Double = -60

    /// -60 dBFS or less gives 0, 0 dBFS gives 1, linear between.
    public static func unit(fromDBFS dbfs: Double) -> Double {
        guard dbfs.isFinite else { return 0 }
        return min(max((dbfs - floorDBFS) / -floorDBFS, 0), 1)
    }
}

/// A warning of the live recording. The app maps each one to its own
/// message and symbol.
public enum MeetingLiveWarningKind: String, Hashable, Sendable, CaseIterable {
    case themNoSound
    case themSilent
    case meSilent
    case headsetMicrophone
    case speakersEcho
}

/// The warnings of one recording. Problems and start facts add warnings;
/// sound on a track removes the warnings of that track. The headset and
/// speakers warnings stay for the recording.
public struct MeetingLiveWarningRules: Hashable, Sendable {
    /// A track peak above this level removes the silence warnings of that
    /// track.
    public static let clearAboveDBFS: Double = -50

    private var active: Set<MeetingLiveWarningKind> = []
    /// The peak of each track when its warning came. The recorder keeps the
    /// last block peak when no block arrives, so an unchanged value is not
    /// new sound.
    private var peakAtWarning: [MeetingTrack: Double] = [:]

    public init() {}

    /// The warnings now, in a stable order.
    public var warnings: [MeetingLiveWarningKind] {
        MeetingLiveWarningKind.allCases.filter(active.contains)
    }

    /// A non-fatal recorder problem. `lastPeaks` are the track peaks read
    /// last (dBFS).
    public mutating func apply(
        problem: MeetingCaptureProblem, lastPeaks: [MeetingTrack: Double] = [:]
    ) {
        let kind: MeetingLiveWarningKind
        let track: MeetingTrack
        switch problem {
        case .noBuffers: (kind, track) = (.themNoSound, .them)
        case .missingSystemAudioPermission: (kind, track) = (.themSilent, .them)
        case .missingMicrophonePermission: (kind, track) = (.meSilent, .me)
        case .deviceLost, .diskFull: return
        }
        active.insert(kind)
        peakAtWarning[track] = lastPeaks[track]
    }

    /// The facts of the started recording.
    public mutating func apply(usesHeadsetMicrophone: Bool, outputWasSpeakers: Bool) {
        if usesHeadsetMicrophone { active.insert(.headsetMicrophone) }
        if outputWasSpeakers { active.insert(.speakersEcho) }
    }

    /// One level sample of each track (dBFS).
    public mutating func apply(meDBFS: Double, themDBFS: Double) {
        if hasSound(themDBFS, track: .them) {
            active.remove(.themNoSound)
            active.remove(.themSilent)
            peakAtWarning[.them] = nil
        }
        if hasSound(meDBFS, track: .me) {
            active.remove(.meSilent)
            peakAtWarning[.me] = nil
        }
    }

    private func hasSound(_ dbfs: Double, track: MeetingTrack) -> Bool {
        guard dbfs > Self.clearAboveDBFS else { return false }
        return peakAtWarning[track] != dbfs
    }
}

/// The title of a meeting when the user gave none.
public enum MeetingDefaultTitle {
    /// For example "Meeting 23 Nov 2026, 10:30".
    public static func text(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        let month = months[min(max((parts.month ?? 1) - 1, 0), 11)]
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let clock = (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
        return "Meeting \(parts.day ?? 1) \(month) \(parts.year ?? 1970), \(clock)"
    }
}
