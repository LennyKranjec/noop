import Foundation

// StrengthIndex.swift — how strong the wearer is, as one number per day.
//
// Volume load says how much work was done. It moves with the plan — a heavy block raises it, a deload
// halves it — and says nothing about whether the wearer can lift more than they could. The level wants
// the second: what has been BUILT.
//
// SO: ESTIMATED ONE-REP MAX PER EXERCISE, from every working set (Epley, w × (1 + reps / 30), sets of
// 1–12 reps only — past twelve the estimate drifts too far to trust). For each day, each exercise's BEST
// estimate over the trailing `windowDays` is divided by that exercise's own median estimate OVER THE DAYS
// UP TO THAT DAY, and the index is the mean of those ratios over the exercises trained in the window.
//
//   1.00  = the typical strength for the exercises being trained
//   1.10  = ten per cent above it
//
// THE RATIO IS WHAT MAKES EXERCISES COMPARABLE. A squat and a curl cannot be averaged in kilograms; as a
// fraction of their own typical figure they can, and an exercise added last month counts from the day it
// appears rather than swamping everything else.
//
// A BEST OVER TWELVE WEEKS is deliberate: strength is lost over weeks, not the day a session is skipped,
// so a deload week or a holiday does not drop the index. A window with no session at all ends it — the
// index has no reading for a day with no lifting in the preceding twelve weeks.
//
// THE MEDIAN IS CAUSAL. It used to be taken over the exercise's WHOLE log before the per-day walk began,
// so a day in 2025 was divided by a median that already contained 2026's personal bests, and every
// backfilled day was written once from a figure that could not have been known on it. A ratio is only a
// statement about a day if the yardstick existed on that day.
//
// AND IT NEEDS A SAMPLE. One session of an exercise makes its median equal its own best, the ratio
// exactly 1.0 and the index a confident "an average day" — from a single set. `minSessions` mirrors
// `StrengthProgression.minSessions` and its `.tooFewSessions` outcome: an exercise below it contributes
// no ratio, and a day on which no exercise clears it has NO READING rather than a fabricated one.
//
// WARM-UPS AND BODYWEIGHT-ADDED SETS ARE EXCLUDED, exactly as `StrengthProgression` excludes them and for
// the same reason. A `+10` on a hyperextension records ten added kilograms, not a ten-kilogram lift (see
// `AlphaprogImporter.Set.addedToBodyweight`), so an absolute estimate built from it is a different lift
// wearing the same unit. The sets are read through `Workout.setRecords`, which is the one place those two
// markers live, so this cannot drift from the progression screen's idea of a working set.

public enum StrengthIndex {

    public static let windowDays = 84
    public static let maxReps = 12
    public static let key = "strength_index"

    /// How many distinct sessions of an exercise are needed before its ratio is a reading.
    ///
    /// Three, matching `StrengthProgression.minSessions`. Stated here rather than read from there so the
    /// two constants cannot deadlock on each other's lazy initialisation; they are pinned equal by test.
    public static let minSessions = 3

    /// Epley.
    public static func e1rm(weightKg: Double, reps: Int) -> Double? {
        guard weightKg > 0, reps >= 1, reps <= maxReps else { return nil }
        return weightKg * (1 + Double(reps) / 30)
    }

    /// The daily index from `workouts`, for every day from the first session to `through`.
    public static func daily(_ workouts: [AlphaprogImporter.Workout], through: Date = Date(),
                             calendar: Calendar = .current) -> [(day: String, value: Double)] {
        // Best e1RM per exercise per day, over WORKING sets only.
        var perExerciseDay: [String: [Date: Double]] = [:]
        for w in workouts {
            let day = calendar.startOfDay(for: w.start)
            for record in w.setRecords {
                guard !record.isWarmup, !record.addedToBodyweight,
                      let weight = record.weightKg, let reps = record.reps,
                      let estimate = e1rm(weightKg: weight, reps: reps) else { continue }
                let name = record.exercise.lowercased().trimmingCharacters(in: .whitespaces)
                perExerciseDay[name, default: [:]][day] = max(perExerciseDay[name]?[day] ?? 0, estimate)
            }
        }
        guard !perExerciseDay.isEmpty,
              let first = perExerciseDay.values.flatMap(\.keys).min() else { return [] }

        // Each exercise's sessions in time order, so the walk below can admit them as the cursor reaches
        // them instead of asking the whole log what it will eventually contain.
        let timeline: [String: [(day: Date, value: Double)]] = perExerciseDay.mapValues { days in
            days.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }
        /// How many of each exercise's sessions the cursor has passed.
        var admitted: [String: Int] = [:]
        /// Those sessions' estimates, kept sorted, so the median is an index rather than a re-sort.
        var seen: [String: [Double]] = [:]

        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        var out: [(day: String, value: Double)] = []
        var cursor = first
        let end = calendar.startOfDay(for: through)
        while cursor <= end {
            guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: cursor) else { break }

            for (name, sessions) in timeline {
                var index = admitted[name] ?? 0
                while index < sessions.count, sessions[index].day <= cursor {
                    insertSorted(&seen[name, default: []], sessions[index].value)
                    index += 1
                }
                admitted[name] = index
            }

            var ratios: [Double] = []
            for (name, sessions) in timeline {
                let history = seen[name] ?? []
                // The abstain: too few sessions to have a typical figure to be a ratio OF.
                guard history.count >= minSessions, let typical = median(history), typical > 0 else { continue }
                var best: Double?
                var index = (admitted[name] ?? 0) - 1
                while index >= 0, sessions[index].day >= windowStart {
                    best = max(best ?? 0, sessions[index].value)
                    index -= 1
                }
                if let best { ratios.append(best / typical) }
            }
            if !ratios.isEmpty {
                out.append((fmt.string(from: cursor), ratios.reduce(0, +) / Double(ratios.count)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// The median of an ALREADY SORTED array, or nil when it is empty.
    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Insert into a sorted array, keeping it sorted. Linear, over a per-exercise session count that is
    /// in the hundreds at most — a re-sort per day would be the same work times a log factor.
    private static func insertSorted(_ xs: inout [Double], _ value: Double) {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        xs.insert(value, at: lo)
    }
}
