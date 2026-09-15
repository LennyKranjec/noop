import Foundation

// MuscleBaselines.swift — what a colour on the body means.
//
// Swift twin of the Android `com.noop.analytics.MuscleBaselines` (the cross-platform parity contract):
// same window, same population SD, same constant ends, so a muscle shaded on one platform is shaded
// the same on the other.
//
// The figure used to be shaded by each group's share of the HEAVIEST group that week. That is a
// ranking, and a ranking re-scales itself every time you look at it: train nothing but chest and the
// chest is scarlet; train everything hard and the chest is the same scarlet. The colour could not tell
// you whether a week was heavy — only which muscle got the most of it.
//
// IT IS NOW A Z-SCORE AGAINST THE GROUP'S OWN FROZEN NORMAL. Every group carries a mean and a spread,
// derived once from the wearer's own training history and then never moved — the same discipline, and
// the same reason, as `LevelBaselines`. Mid-scale is "a normal week for this muscle"; the top of the
// scale is two standard deviations above it. So a light week now LOOKS light, and next March's scarlet
// means exactly what this March's did.
//
// THE MAPPING IS A CONSTANT. `zFloor` and `zCeiling` never change and are not per-wearer: they are
// what makes one colour comparable to another colour, on another muscle, in another month. Without a
// fixed pair of ends the z-score would just be a ranking again, wearing statistics.
//
// EACH GROUP FREEZES ON ITS OWN, the first time it has enough history. Freezing a group that has never
// been trained would hand it a mean of zero and no spread, and the first set it ever saw would light
// it to the top of the scale. A group with no baseline yet is simply not z-scored.

/// One muscle group's frozen normal, in kilograms of trailing-7-day volume load.
///
/// The unit is the SAME figure the card puts on screen beside the group — a rolling weekly sum — so
/// the colour and the number are two views of one quantity rather than two different measurements.
public struct MuscleBaseline: Equatable, Sendable, Codable {
    public let mean: Double
    public let sd: Double

    public init(mean: Double, sd: Double) {
        self.mean = mean
        self.sd = sd
    }

    /// Guards a degenerate spread.
    ///
    /// Half the mean rather than a literal 1.0: the scale here is kilograms, and a 1 kg standard
    /// deviation on a 4,000 kg week would make every reading read as ±4000 SD. A wearer whose weekly
    /// volume genuinely never moves is being told "half a typical week is one SD", which is a coarse
    /// claim but a true-to-scale one.
    public var safeSd: Double {
        if sd > 1e-6 { return sd }
        if mean > 1e-6 { return mean * 0.5 }
        return 1
    }

    /// How unusual `kg` is for this group. 0 = a normal week, +2 = twice its usual swing above.
    public func z(_ kg: Double) -> Double { (kg - mean) / safeSd }
}

public enum MuscleBaselines {

    /// The ends of the colour scale, in standard deviations. CONSTANT, by design.
    ///
    /// Two SD either side covers ~95 % of a normal spread, so the scale spends its resolution on weeks
    /// that actually happen instead of on the tails. A week beyond either end is clipped rather than
    /// given a colour of its own: there is no shade past "as heavy as this muscle gets".
    public static let zFloor: Double = -2
    public static let zCeiling: Double = 2

    /// How many rolling windows a group needs before its scale is frozen.
    ///
    /// Four weeks of days. Fewer, and the spread is estimated from one training block — and since the
    /// result is permanent, a thin estimate here is a permanently wrong yardstick.
    public static let minWindows = 28

    /// The trailing window, in days, that one sample covers.
    public static let windowDays = 7

    /// Where `kg` lands on the 0–1 colour scale for this group.
    ///
    /// The only mapping from a z-score to a shade, so the body and the legend dot read the same scale.
    public static func fraction(_ baseline: MuscleBaseline, _ kg: Double) -> Double {
        let raw = (baseline.z(kg) - zFloor) / (zCeiling - zFloor)
        return Swift.min(Swift.max(raw, 0), 1)
    }

    /// Freeze one group's scale from its rolling-window history, or nil when there is not enough.
    ///
    /// `windows` is one trailing-7-day sum PER DAY, INCLUDING the days that sum to zero: the card shows
    /// a trailing week on whatever day you open it, so the distribution the colour is judged against
    /// has to be the distribution of that same figure — rest days and all. Dropping the zeros would ask
    /// "how heavy is this week compared with the weeks you trained", and answer a question nobody asked.
    ///
    /// Population SD (divide by n), matching `LevelBaselines.derive` and the Android lane.
    public static func derive(windows: [Double]) -> MuscleBaseline? {
        let xs = windows.filter { $0.isFinite }
        guard xs.count >= minWindows else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        // A group that has never been trained has nothing to be a deviation FROM. Freezing it would set
        // mean 0 with no spread, and the first set the wearer ever did for it would paint it at the top
        // of the scale forever after.
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return MuscleBaseline(mean: mean, sd: variance.squareRoot())
    }

    /// Freeze whichever groups have the history for it. Groups that do not are simply absent.
    ///
    /// GENERIC OVER THE KEY rather than typed to `MuscleGroup`, because the group enum lives in
    /// `StrandImport` (it is an import-attribution concept) and this package does not depend on it.
    /// The call site supplies `[MuscleGroup: [Double]]` and gets `[MuscleGroup: MuscleBaseline]` back,
    /// which is what the Android signature says; nothing here needs to know what a key is.
    public static func deriveAll<Key: Hashable>(_ history: [Key: [Double]]) -> [Key: MuscleBaseline] {
        var out: [Key: MuscleBaseline] = [:]
        for (group, windows) in history {
            if let baseline = derive(windows: windows) { out[group] = baseline }
        }
        return out
    }

    /// Turn a day-keyed series of daily volume into one trailing-`days`-day sum per day.
    ///
    /// Runs over the CALENDAR days between the first and last entry, not over the entries: a day the
    /// wearer did not lift has no row at all, and skipping it would compress a fortnight of rest into
    /// no time passing and leave the spread looking far tighter than it is.
    public static func rollingWindows(
        daily: [String: Double],
        days: Int = windowDays,
        calendar: Calendar = .current
    ) -> [Double] {
        guard !daily.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let keys = daily.keys.sorted()
        guard let first = formatter.date(from: keys[0]),
              let last = formatter.date(from: keys[keys.count - 1]) else { return [] }

        var out: [Double] = []
        var cursor = first
        while cursor <= last {
            var sum: Double = 0
            for back in 0..<days {
                guard let day = calendar.date(byAdding: .day, value: -back, to: cursor) else { continue }
                sum += daily[formatter.string(from: day)] ?? 0
            }
            out.append(sum)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}
