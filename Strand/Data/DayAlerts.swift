import Foundation

// DayAlerts.swift — the day's one-off full-screen notices, raised on Today and shown over every tab.
//
// THE OPTIMUM. When today's effort reaches the top of its recommended band — the notch on Today's
// effort ring — the system says so once, full screen. Once a day; a day that goes past it does not hear
// it again.
//
// HEALTH_V2 H2 — WHAT IT MAY CLAIM. The band is a population lookup on this morning's Charge
// (`CoupledView.optimalStrainRange`), not the wearer's own, so the notice no longer says "anything more
// now is paid for tomorrow": it says where the day is against the range this morning's Charge suggests,
// and leaves the rest to the wearer (`optimumMessage`). It is also NOT raised while the illness heads-up
// is up — that day is already a rest day and the heads-up banner carries the message.
//
// (H2b, once S3 lands: the trigger moves from the population band to the week plan's `DayGuidance`.)

@MainActor
final class DayAlerts: ObservableObject {
    static let shared = DayAlerts()

    /// The optimum notice waiting to be shown: effort and target as the wearer's scale shows them.
    struct Optimum: Equatable {
        let effort: String
        let target: String

        /// The notice's body. One source for the words, so the shell cannot keep the old overclaim.
        var message: String { DayAlerts.optimumMessage }
    }

    /// H2a: no claim of a certain cost.
    static let optimumMessage = "Today's effort has reached the top of the range suggested for this "
        + "morning's Charge. More is your call — keep it easy if you want tomorrow fresh."

    @Published private(set) var optimum: Optimum?

    private static let optimumDayKey = "dayAlerts.optimum.day"

    /// Whether the optimum notice may be raised at all right now. Pure: H2c — never over an illness
    /// heads-up.
    static func mayRaiseOptimum(illnessHeadsUp: Bool) -> Bool { !illnessHeadsUp }

    /// Raise the optimum notice, unless it has already been raised today or an illness heads-up is up.
    ///
    /// A day held back by the heads-up is NOT marked as having heard it: nothing was shown.
    func reachOptimum(effort: String, target: String, now: Date = Date()) {
        let headsUp = resolvedAppModel(nil)?.healthAlert != nil
        guard Self.mayRaiseOptimum(illnessHeadsUp: headsUp) else { return }
        let today = Repository.localDayKey(now)
        guard UserDefaults.standard.string(forKey: Self.optimumDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.optimumDayKey)
        optimum = Optimum(effort: effort, target: target)
    }

    func dismissOptimum() { optimum = nil }
}
