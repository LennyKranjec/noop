import Foundation
import StrandAnalytics
import WhoopStore

/// TODAY'S EFFORT, NOW — the one figure the Today hero ring, the Key Metrics tile, the Effort detail
/// screen and the lock-screen widget all show for today.
///
/// Built from the same inputs Today's hero reads — the live in-progress value Today last scored
/// (`TodayView.publishedLiveStrain`), the app's own computed row (`noopScores`), the merged row, and WHOOP's
/// own strain for the day — through the one pure resolver (`StrainScorer.resolvedOwnEffort`). The detail
/// screen used to show the merged row alone, which lags the live value and can differ from the computed
/// lane, so tapping the tile opened a screen with a different number.
struct TodayEffortNow {
    /// The logical-day key this figure is for (Today's `selectedDayKey` at offset 0).
    let day: String
    /// The app's own Effort (0–100), nil when the day yields to WHOOP's own strain.
    let own: Double?
    /// WHOOP's own strain (0–21) for the day, when `own` yielded to it.
    let cloudStrain21: Double?

    /// On the app's 0–100 axis: the own figure, else WHOOP's strain through the inverse calibration (the
    /// axis the hero ring fills on).
    var effort100: Double? { own ?? cloudStrain21.map { StrainCalibration.effort100(strain21: $0) } }

    /// The read-out as the hero builds it: WHOOP's own strain verbatim on the WHOOP scale, else the shared
    /// Effort formatter.
    func display(scale: EffortScale) -> String? {
        if own == nil, scale == .whoop, let cloud = cloudStrain21 { return String(format: "%.1f", cloud) }
        return effort100.map { UnitFormatter.effortDisplay($0, scale: scale) }
    }
}

extension Repository {
    /// The key Today resolves at offset 0: `today`'s own day (pre-04:00 rule included), else the logical day.
    func todayEffortDayKey(now: Date = Date()) -> String {
        today?.day ?? Repository.logicalDayKey(now)
    }

    /// See `TodayEffortNow`.
    func todayEffortNow(now: Date = Date()) async -> TodayEffortNow {
        let key = todayEffortDayKey(now: now)
        let row = today ?? days.last { $0.day == key }
        let cloud = await whoopCloudDay(key)?.strain
        let computed = await noopScores(day: key).effort
        let own = StrainScorer.resolvedOwnEffort(live: TodayView.publishedLiveStrain(day: key),
                                                 computed: computed,
                                                 merged: row?.strain,
                                                 cloudStrain21: cloud)
        return TodayEffortNow(day: key, own: own, cloudStrain21: own == nil ? cloud : nil)
    }
}
