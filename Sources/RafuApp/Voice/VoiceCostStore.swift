import Foundation
import RafuCore

/// Saves the voice cost meter in `UserDefaults` (`voice.costMeter.v1`). It
/// holds seconds per month and session ids only.
@MainActor
@Observable
final class VoiceCostStore {
    static let defaultsKey = "voice.costMeter.v1"

    private(set) var meter: VoiceCostMeter
    @ObservationIgnored private let suiteName: String?
    @ObservationIgnored private let now: () -> Date

    init(suiteName: String? = nil, now: @escaping () -> Date = { Date() }) {
        self.suiteName = suiteName
        self.now = now
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        meter =
            defaults.data(forKey: Self.defaultsKey).flatMap {
                try? JSONDecoder().decode(VoiceCostMeter.self, from: $0)
            } ?? VoiceCostMeter()
    }

    var month: String { VoiceCostMeter.monthKey(for: now()) }

    var monthlySeconds: Double { meter.monthlySeconds(month: month) }
    var monthlyCost: Double { meter.monthlyCost(month: month) }

    func allowsNewSession(cap: Double) -> Bool {
        meter.allowsNewSession(cap: cap, month: month)
    }

    func recordUsage(sessionID: String, seconds: Double) {
        meter.recordUsage(sessionID: sessionID, seconds: seconds, month: month)
        save()
    }

    func finish(sessionID: String) {
        meter.finish(sessionID: sessionID)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meter) else { return }
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
