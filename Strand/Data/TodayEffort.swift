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
///
/// AN IN-PROGRESS WORKOUT IS NOT ADDED ON TOP. The day's Effort here is measured from the day's heart
/// rate; a live session's own running Effort (`AppModel.ActiveWorkout.liveStrain`) is a SECOND reading of
/// the same beats, so folding it in would count the overlap twice the moment the strap's history for the
/// session lands. The live-workout screen used to do exactly that (its own `StrainCombine` sum over a
/// separately-resolved baseline), which is why its day figure disagreed with Today and the widget for the
/// whole session. The session's own Effort is shown as its own number next to this one, never inside it.
struct TodayEffortNow {
    /// What every surface prints where there is no figure — never a substituted number.
    static let absentDash = "–"

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

/// TODAY'S EFFORT TARGET — the top of the day's recommended band, resolved the ONE way for every surface
/// that marks or prints it: Today's hero ring mark, the live-workout session card and the lock-screen
/// strip. Three copies of "band lookup, then the inverse calibration" existed, and the live-workout card's
/// copy also fed a DIFFERENT recovery into the lookup (the computed charge lane ahead of the merged row),
/// so it could land in a different band from the mark Today drew for the same day.
///
/// Absent recovery abstains: no band, and the caller renders a dash — never a guessed target.
struct TodayEffortTarget {
    /// The recommended band on WHOOP's 0–21 axis (`CoupledView.optimalStrainRange`).
    let band: ClosedRange<Int>

    /// The band top as WHOOP states it (a whole strain, e.g. 14).
    var upper21: Int { band.upperBound }

    /// The band top on the app's 0–100 axis, through the INVERSE calibration — the axis the hero ring
    /// fills on, so a ring crosses the mark exactly when the day's strain reaches the band top.
    var upper100: Double { StrainCalibration.effort100(strain21: Double(band.upperBound)) }

    /// The band top as a read-out on the wearer's scale: the whole WHOOP strain on the 0–21 scale, the
    /// 0–100 figure rounded otherwise.
    func display(scale: EffortScale) -> String {
        scale == .whoop ? "\(upper21)" : "\(Int(upper100.rounded()))"
    }

    /// The pure lookup. nil for an unknown recovery.
    static func resolve(recovery: Double?) -> TodayEffortTarget? {
        CoupledView.optimalStrainRange(recovery: recovery).map { TodayEffortTarget(band: $0) }
    }
}

extension TodayEffortNow {
    /// The "Day / target" read-out, from the two shared resolutions. Each side abstains on its own: a
    /// missing day figure or a missing target is a dash, and nothing is substituted for either.
    static func dayTargetText(effort: TodayEffortNow?, target: TodayEffortTarget?,
                              scale: EffortScale) -> String {
        let day = effort?.display(scale: scale) ?? absentDash
        return "\(day)/\(target?.display(scale: scale) ?? absentDash)"
    }
}

extension Repository {
    /// The key Today resolves at offset 0: `today`'s own day (pre-04:00 rule included), else the logical day.
    func todayEffortDayKey(now: Date = Date()) -> String {
        today?.day ?? Repository.logicalDayKey(now)
    }

    /// Today's Effort target — see `TodayEffortTarget`. The recovery is the one Today's hero mark reads:
    /// WHOOP's own for the day when it has one, else the merged row's (which already carries the computed
    /// charge where there is no import, so the computed lane needs no separate step here).
    func todayEffortTarget(now: Date = Date()) async -> TodayEffortTarget? {
        let key = todayEffortDayKey(now: now)
        let row = today ?? days.last { $0.day == key }
        let cloudRecovery = await whoopCloudDay(key)?.recovery
        return TodayEffortTarget.resolve(recovery: cloudRecovery ?? row?.recovery)
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
