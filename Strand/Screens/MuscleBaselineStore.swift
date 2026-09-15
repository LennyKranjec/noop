import Foundation
import StrandAnalytics
import StrandImport

// MuscleBaselineStore.swift — keeping the body's yardstick still.
//
// Swift twin of the Android `com.noop.analytics.MuscleBaselineStore`. `LevelBaselineStore`'s rule,
// applied per muscle group: a group's mean and spread are written once and then returned verbatim
// forever. The colour on the figure therefore means the same thing in December as it did in March.
//
// A GROUP FREEZES WHEN IT CAN, NOT WHEN THE FIRST ONE DOES. Someone who has been importing chest work
// for a year and squatted for the first time yesterday has a scale for their chest and none for their
// quadriceps. `resolve` adds the groups that have become derivable and never touches the ones already
// stored — so a new group joining the scale can never move an old group's colour.

enum MuscleBaselineStore {

    /// Version 2 of the key, and the reason is the one case where a frozen scale MUST be thrown away.
    ///
    /// The first scales were derived from an Alphaprog parse that found 26 of the file's 96 sessions and
    /// piled the other seventy into one fabricated day. The distribution behind those numbers never
    /// existed, so every group sat five to eleven SD above its "normal" and the whole body painted one
    /// colour. A scale is frozen so that a colour keeps its meaning — not so that a wrong one does.
    private static let key = "muscle.baselines.v2"
    private static let frozenAtKey = "muscle.baselinesFrozenAt"
    private static let lastAttemptDayKey = "muscle.baselinesAttemptedOn"

    /// Whether it is worth reading the whole lifting history again to look for a group to freeze.
    ///
    /// ONCE A DAY, at most. A group that has never been trained can never be frozen (there is nothing to
    /// be a deviation from), so "are all thirteen frozen yet" is a question that stays false forever for
    /// most wearers — and using it as the guard meant re-reading five years of series on every open of
    /// Today. The windows are daily, so a group can become freezable at most once a day; asking more
    /// often than that cannot find anything.
    private static func shouldAttempt(today: String, _ d: UserDefaults) -> Bool {
        d.string(forKey: lastAttemptDayKey) != today
    }

    /// Whether a caller should pay for the history read at all.
    ///
    /// Exposed because the read is an async one and `resolve` takes a plain closure: without this the
    /// caller would gather five years of series and then be told they were not needed.
    static func needsDerivation(today: String = dayKey(), _ d: UserDefaults = .standard) -> Bool {
        read(d).count < MuscleGroup.allCases.count && shouldAttempt(today: today, d)
    }

    /// The frozen per-group scales, freezing any group that has become derivable since the last call.
    ///
    /// `history` is one rolling-window series per group. It is a closure because reading a wearer's
    /// whole lifting history is expensive and is only needed when some group is still unfrozen — which,
    /// after the first month, is never.
    static func resolve(
        today: String = dayKey(),
        _ d: UserDefaults = .standard,
        history: () -> [MuscleGroup: [Double]]
    ) -> [MuscleGroup: MuscleBaseline] {
        let stored = read(d)
        if stored.count == MuscleGroup.allCases.count { return stored }
        guard shouldAttempt(today: today, d) else { return stored }
        d.set(today, forKey: lastAttemptDayKey)
        let derived = MuscleBaselines.deriveAll(history())
        // Stored LAST so it wins: a group already frozen keeps the scale it was frozen with, whatever
        // the freshly derived numbers say. This is the whole contract in one line.
        var merged = derived
        for (group, baseline) in stored { merged[group] = baseline }
        if merged != stored { write(merged, d) }
        return merged
    }

    /// What is stored today. Empty when nothing has ever been frozen.
    static func read(_ d: UserDefaults = .standard) -> [MuscleGroup: MuscleBaseline] {
        guard let raw = d.string(forKey: key) else { return [:] }
        return decode(raw)
    }

    /// When a group was last ADDED to the scale, or nil when none ever was.
    static func frozenAt(_ d: UserDefaults = .standard) -> Date? {
        let t = d.double(forKey: frozenAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Derive every group again from current history, replacing what was stored.
    ///
    /// The only way an existing group's scale moves. Every colour the wearer has seen was measured
    /// against the old one, so a caller must treat this as a visible change and not as maintenance.
    @discardableResult
    static func refreeze(history: [MuscleGroup: [Double]], _ d: UserDefaults = .standard) -> [MuscleGroup: MuscleBaseline] {
        let derived = MuscleBaselines.deriveAll(history)
        write(derived, d)
        return derived
    }

    private static func write(_ baselines: [MuscleGroup: MuscleBaseline], _ d: UserDefaults) {
        d.set(encode(baselines), forKey: key)
        d.set(Date().timeIntervalSince1970, forKey: frozenAtKey)
    }

    /// `yyyy-MM-dd` in the wearer's own zone.
    static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - The wire format
    //
    // JSON keyed on the ANDROID enum name (`UPPER_BACK`), not on Swift's rawValue, for the same reason
    // `MuscleGroup.volumeKey` is spelled out: a settings blob exported on one platform has to read the
    // same on the other, and `upperBack` and `UPPER_BACK` are not the same key.

    static func encode(_ baselines: [MuscleGroup: MuscleBaseline]) -> String {
        var root: [String: [String: Double]] = [:]
        for (group, b) in baselines {
            root[androidName(group)] = ["mean": b.mean, "sd": b.sd]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    /// Read a stored set back.
    ///
    /// A group whose entry is missing or unreadable is ABSENT rather than defaulted: there is no sensible
    /// table value for "kilograms of volume a shoulder normally does", and inventing one would be the
    /// fabricated metric the design rules forbid.
    static func decode(_ raw: String) -> [MuscleGroup: MuscleBaseline] {
        guard let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var out: [MuscleGroup: MuscleBaseline] = [:]
        for group in MuscleGroup.allCases {
            guard let o = root[androidName(group)] as? [String: Any],
                  let mean = (o["mean"] as? NSNumber)?.doubleValue,
                  let sd = (o["sd"] as? NSNumber)?.doubleValue,
                  mean.isFinite, sd.isFinite, mean > 0
            else { continue }
            out[group] = MuscleBaseline(mean: mean, sd: sd)
        }
        return out
    }

    /// The Kotlin enum constant's name, which is what the stored JSON is keyed on.
    static func androidName(_ group: MuscleGroup) -> String {
        switch group {
        case .chest: return "CHEST"
        case .upperBack: return "UPPER_BACK"
        case .lats: return "LATS"
        case .shoulders: return "SHOULDERS"
        case .biceps: return "BICEPS"
        case .triceps: return "TRICEPS"
        case .forearms: return "FOREARMS"
        case .abs: return "ABS"
        case .lowerBack: return "LOWER_BACK"
        case .glutes: return "GLUTES"
        case .quadriceps: return "QUADRICEPS"
        case .hamstrings: return "HAMSTRINGS"
        case .calves: return "CALVES"
        }
    }
}
