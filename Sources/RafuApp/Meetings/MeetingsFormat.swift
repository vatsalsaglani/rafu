import Foundation
import RafuCore

/// The one duration and date format of every Meetings surface: the window
/// list, the navigator, the Welcome card and the meeting tab. No surface
/// formats a duration or a day on its own.
nonisolated enum MeetingsFormat {
    /// "32 s", "6 min", "1 h 12 min", "2 h". Nil below one second and for a
    /// value that is not finite, so a caller leaves the part out.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let clamped = min(seconds, 1_000_000_000)
        if clamped < 60 { return "\(Int(clamped)) s" }
        let minutes = Int((clamped / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "Today", "Yesterday", "21 Nov", or "21 Nov 2025" for another year.
    static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        var style = Date.FormatStyle().month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The clock time in the user's format, for example "12:06".
    static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "Today 12:06", "Yesterday 16:05", "21 Nov 09:00".
    static func dayAndTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        day(date, now: now, calendar: calendar, locale: locale) + " "
            + time(date, calendar: calendar, locale: locale)
    }

    /// The second line of a ready meeting: "Today 12:06 · 6 min". A zero
    /// duration is left out. There is no size and no turn count.
    static func meetingLine(
        start: Date, duration: TimeInterval, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        let when = dayAndTime(start, now: now, calendar: calendar, locale: locale)
        guard let length = self.duration(duration) else { return when }
        return when + " · " + length
    }

    /// The running clock, for example "02:13" or "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        MeetingClockText.text(seconds)
    }

    /// "12 minutes 47 seconds", "1 hour 0 minutes 5 seconds", "5 seconds".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 1_000_000_000))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) " + (hours == 1 ? "hour" : "hours")) }
        if hours > 0 || minutes > 0 {
            parts.append("\(minutes) " + (minutes == 1 ? "minute" : "minutes"))
        }
        parts.append("\(rest) " + (rest == 1 ? "second" : "seconds"))
        return parts.joined(separator: " ")
    }

    /// "57 percent", for a fraction 0...1.
    static func spokenPercent(_ fraction: Double) -> String {
        "\(percent(fraction)) percent"
    }

    /// 0...100, rounded.
    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction.isFinite ? fraction : 0, 0), 1) * 100).rounded())
    }
}
