import Foundation

// StrengthIndex.swift — how strong the wearer is, as one number per day.
//
// Volume load says how much work was done. It moves with the plan — a heavy block raises it, a deload
// halves it — and says nothing about whether the wearer can lift more than they could. The level wants
// the second: what has been BUILT.
//
// SO: ESTIMATED ONE-REP MAX PER EXERCISE, from every working set (Epley, w × (1 + reps / 30), sets of
// 1–12 reps only — past twelve the estimate drifts too far to trust). For each day, each exercise's BEST
// estimate over the trailing `windowDays` is divided by that exercise's own median estimate across the
// whole log, and the index is the mean of those ratios over the exercises trained in the window.
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

public enum StrengthIndex {

    public static let windowDays = 84
    public static let maxReps = 12
    public static let key = "strength_index"

    /// Epley.
    public static func e1rm(weightKg: Double, reps: Int) -> Double? {
        guard weightKg > 0, reps >= 1, reps <= maxReps else { return nil }
        return weightKg * (1 + Double(reps) / 30)
    }

    /// The daily index from `workouts`, for every day from the first session to `through`.
    public static func daily(_ workouts: [AlphaprogImporter.Workout], through: Date = Date(),
                             calendar: Calendar = .current) -> [(day: String, value: Double)] {
        // Best e1RM per exercise per day.
        var perExerciseDay: [String: [Date: Double]] = [:]
        for w in workouts {
            let day = calendar.startOfDay(for: w.start)
            for ex in w.exercises {
                let best = ex.sets.compactMap { e1rm(weightKg: $0.weightKg, reps: $0.reps) }.max()
                guard let best else { continue }
                let name = ex.name.lowercased().trimmingCharacters(in: .whitespaces)
                perExerciseDay[name, default: [:]][day] = max(perExerciseDay[name]?[day] ?? 0, best)
            }
        }
        guard !perExerciseDay.isEmpty,
              let first = perExerciseDay.values.flatMap(\.keys).min() else { return [] }

        var medians: [String: Double] = [:]
        for (name, days) in perExerciseDay {
            let v = days.values.sorted()
            let mid = v.count / 2
            medians[name] = v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
        }

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
            var ratios: [Double] = []
            for (name, days) in perExerciseDay {
                let best = days.filter { $0.key >= windowStart && $0.key <= cursor }.values.max()
                if let best, let median = medians[name], median > 0 { ratios.append(best / median) }
            }
            if !ratios.isEmpty {
                out.append((fmt.string(from: cursor), ratios.reduce(0, +) / Double(ratios.count)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}
