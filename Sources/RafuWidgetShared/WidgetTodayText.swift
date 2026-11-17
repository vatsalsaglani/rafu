import Foundation

/// The "N% today" text of the Hundred, Seven, and Board widgets.
///
/// "Today" is the user's calendar day, not the current 24-hour slice of the
/// limit window. The app writes `Window.todayStart` (local midnight at its
/// last observation) and `Window.todayUsed` (the used percent since then).
/// The widget compares that day with its own `now`: on the same day it
/// shows the value, on a later day (the app has not observed since) it
/// shows 0. A snapshot from an older app has neither field; the text then
/// falls back to the slice count the card already derives.
///
/// The dots, the seven-day columns, and the remaining-mode pace line keep
/// the window-aligned slices. Only the text and its spoken form change.
public enum WidgetTodayText {
    /// The used percent since local midnight, 0...100. `nil` when the
    /// window has no calendar-day fields, or when its reset has passed.
    public static func percent(
        window: WidgetUsageSnapshot.Window, now: Date, calendar: Calendar = .current
    ) -> Double? {
        if let reset = window.resetsAt, reset <= now { return nil }
        guard let used = window.todayUsed, let start = window.todayStart, used.isFinite else {
            return nil
        }
        guard calendar.isDate(now, inSameDayAs: start) else { return 0 }
        return min(max(used, 0), 100)
    }

    /// `"6% today"`, `"<1% today"` for a use that rounds to 0, or `"0%
    /// today"`. Without the calendar-day fields it shows `sliceCount` (the
    /// slice count of the card), or `nil` when that is `nil` too. `nil` for
    /// a window whose reset has passed.
    public static func text(
        window: WidgetUsageSnapshot.Window, now: Date, calendar: Calendar = .current,
        sliceCount: Int? = nil
    ) -> String? {
        if let reset = window.resetsAt, reset <= now { return nil }
        if let value = percent(window: window, now: now, calendar: calendar) {
            return amount(value) + " today"
        }
        return sliceCount.map { "\($0)% today" }
    }

    /// `"today 6 percent so far"` or `"today less than 1 percent so far"`.
    /// With no calendar-day value it shows `sliceCount`.
    public static func spokenSoFar(
        window: WidgetUsageSnapshot.Window, now: Date, calendar: Calendar = .current,
        sliceCount: Int
    ) -> String {
        guard let value = percent(window: window, now: now, calendar: calendar) else {
            return "today \(sliceCount) percent so far"
        }
        return "today " + spokenAmount(value) + " so far"
    }

    /// `"6 percent today"` or `"less than 1 percent today"`.
    public static func spoken(
        window: WidgetUsageSnapshot.Window, now: Date, calendar: Calendar = .current,
        sliceCount: Int
    ) -> String {
        guard let value = percent(window: window, now: now, calendar: calendar) else {
            return "\(sliceCount) percent today"
        }
        return spokenAmount(value) + " today"
    }

    private static func amount(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 && value > 0 ? "<1%" : "\(rounded)%"
    }

    private static func spokenAmount(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 && value > 0 ? "less than 1 percent" : "\(rounded) percent"
    }
}
