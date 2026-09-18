import Foundation

// DayAlerts.swift — the day's one-off full-screen notices, raised on Today and shown over every tab.
//
// THE OPTIMUM. When today's effort reaches the top of its recommended band — the notch on Today's
// effort ring — the system says so once, full screen: the load the night's recovery can carry has been
// spent, and more now is paid for tomorrow. Once a day; a day that goes past it does not hear it again.

@MainActor
final class DayAlerts: ObservableObject {
    static let shared = DayAlerts()

    /// The optimum notice waiting to be shown: effort and target as the wearer's scale shows them.
    struct Optimum: Equatable {
        let effort: String
        let target: String
    }

    @Published private(set) var optimum: Optimum?

    private static let optimumDayKey = "dayAlerts.optimum.day"

    /// Raise the optimum notice, unless it has already been raised today.
    func reachOptimum(effort: String, target: String, now: Date = Date()) {
        let today = Repository.localDayKey(now)
        guard UserDefaults.standard.string(forKey: Self.optimumDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.optimumDayKey)
        optimum = Optimum(effort: effort, target: target)
    }

    func dismissOptimum() { optimum = nil }
}
