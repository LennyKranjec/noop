import Foundation

// StrengthProgression.swift — is this lift moving, and what should the next set be.
//
// `StrengthIndex` answers "how strong am I overall" as one number per day. This answers the question a
// wearer actually asks in the gym, which is about ONE exercise: is the bench press going up, has it
// stopped, and what should I put on it next time. That cannot be read off a session summary — volume
// load, set count and top set do not contain "this exercise's working weight over time" — so this reads
// the stored SETS (`liftSession` / `liftSet`, store v46) grouped by exercise name.
//
// PURE. No store, no SwiftUI, no dates beyond the calendar handed in. Everything it returns is either a
// figure it can defend or nil, and every threshold is a named constant at the top of the type rather
// than a literal buried in a branch.
//
// WHICH FORMULA IS PRIMARY, AND WHY IT IS EPLEY. Both are computed: Epley `w × (1 + r/30)` and Brzycki
// `w / (1.0278 − 0.0278r)`. Epley is the primary and the one every headline figure and every trend uses,
// for one reason that outweighs the usual arguments about which fits better at which rep count: the app
// ALREADY banks an Epley estimate per exercise as `strength_index`, and the coach quotes it. Making a
// different formula primary here would put two "estimated 1RM" figures for the same lift on the same
// wearer's screen, disagreeing by a couple of kilograms, both labelled the same thing — §4.10's
// duplicated-values failure, manufactured on purpose. Brzycki is carried alongside as a cross-check (it
// runs slightly higher above ~8 reps and slightly lower below) and is never mixed into a trend.
//
// THE DEFENSIBLE REP WINDOW IS 1–12, and outside it this ABSTAINS rather than extrapolating. Both
// formulas are linear-ish fits to sets people actually do; at twenty reps they are predicting a maximal
// effort from an endurance set, and Brzycki's denominator marches toward zero (at 36 reps it IS zero).
// A set of 20 therefore produces NO estimate — not a capped one, not a flagged one — and a session whose
// every set sat outside the window has no best e1RM at all. The window is `StrengthIndex.maxReps`, not a
// second copy of the number.
//
// A BODYWEIGHT-ADDED LOAD IS NOT A LOAD. Alphaprog writes a weighted hyperextension as `+10`, which is
// ten kilograms ADDED to a bodyweight the file never states. Those sets are EXCLUDED from every estimate
// and counted in `excludedBodyweightSets`, so the screen can say so. Reading them as flat 10 kg lifts
// would drop a hyperextension into a progression list next to real machine loads, stall-flag it forever
// (bodyweight barely moves) and suggest 12.5 kg for it.
//
// THE INCREMENT IS THE WEARER'S OWN. Machines step 2.5 kg, some step 5, some plate-loaded lifts step
// 1.25 — so the suggestion never assumes a number. It takes the SMALLEST positive gap between distinct
// weights this wearer has actually used on THIS exercise. With fewer than two distinct weights there is
// no observed increment, and then there is no weight suggestion either: the double-progression rule can
// still say "add a rep", and past the top of the rep range this returns nil rather than picking a step.

public enum StrengthProgression {

    // MARK: - Thresholds
    //
    // Every one of these is a judgement call, so each carries the reasoning rather than a bare value.

    /// Sessions carrying a usable estimate before ANY figure is reported for an exercise.
    ///
    /// Two sessions is a line between two points and reads as a trend when it is a pair of days. Three is
    /// the smallest number where "it went up, then up again" and "it went up, then back" are different
    /// shapes. Below this the exercise reports `abstained` and the screen shows the not-enough-sessions
    /// state — no current figure, no trend, no suggestion.
    public static let minSessions = 3

    /// Sessions since the best estimate was first reached before the exercise is called stalled.
    public static let stallSessions = 3

    /// …and days, over the same span. BOTH must hold.
    ///
    /// The session count alone flags someone who trains a lift three times in one week and has simply not
    /// had time to adapt; the day count alone flags someone who trained it twice in a month. Strength
    /// adaptation is measured in weeks, so two weeks with no new best across at least three attempts is
    /// the earliest point at which "stalled" is a description rather than a guess.
    public static let stallMinDays = 14

    /// Below this, a change in estimated 1RM is not a change.
    ///
    /// Epley turns a 2.5 kg plate step at eight reps into about 3.3 kg of estimate, and one extra rep at
    /// 75 kg into 2.5 kg — so real progress clears half a kilogram comfortably. What does not clear it is
    /// the arithmetic: a weight stored after a pound conversion, or the same set logged with a rounding
    /// difference. Without this floor an unchanged lift reports a 0.03 kg gain and never stalls.
    public static let improvementEpsilonKg = 0.5

    /// The rep window in which the formulas are defensible. Shared with `StrengthIndex`, not restated.
    public static let maxReps = StrengthIndex.maxReps
    public static let minReps = 1

    /// The smallest gap between two used weights that can be believed as a deliberate increment.
    ///
    /// A pound-denominated log converts to kilograms at 0.4536, so two "same" weights can differ by
    /// hundredths; treating that as the wearer's step would suggest 75.02 kg. Nothing below this counts.
    public static let minIncrementKg = 0.5

    /// And the largest. A wearer who jumped 20 kg once did not discover a 20 kg increment, so a gap this
    /// size is not evidence of a step and is ignored when smaller gaps exist.
    public static let maxIncrementKg = 5.0

    /// How many recent sessions the working rep range is read from.
    ///
    /// The range has to be the wearer's CURRENT one: a lift that ran 5s in a strength block last spring
    /// and runs 10s now would otherwise carry a 5–12 range, and the double-progression rule would think
    /// there were seven reps of room to add.
    public static let repRangeSessions = 5

    /// Trend windows, in weeks.
    public static let trendWindowsWeeks = [4, 8, 12]

    // MARK: - Estimated one-rep max

    /// Epley — the primary. Delegates to `StrengthIndex.e1rm` so the app has exactly one Epley.
    ///
    /// Nil outside 1…`maxReps` reps or without a positive weight. Note Epley returns slightly MORE than
    /// the bar weight at one rep (`w × 31/30`); that is the formula as published and as already banked in
    /// `strength_index`, and it is left alone rather than special-cased into a third variant.
    public static func epley(weightKg: Double, reps: Int) -> Double? {
        StrengthIndex.e1rm(weightKg: weightKg, reps: reps)
    }

    /// Brzycki — the cross-check, never the headline. Same guards, so the two abstain together.
    public static func brzycki(weightKg: Double, reps: Int) -> Double? {
        guard weightKg > 0, reps >= minReps, reps <= maxReps else { return nil }
        let denominator = 1.0278 - 0.0278 * Double(reps)
        // Cannot be hit inside 1…12 (at 12 it is 0.6942). Guarded anyway, because the thing that makes
        // this formula unusable at high reps is a denominator crossing zero, and a future change to
        // `maxReps` must not turn that into a division blow-up.
        guard denominator > 0.01 else { return nil }
        return weightKg / denominator
    }

    // MARK: - Input

    /// One session's sets, as the store holds them.
    public struct Session: Sendable, Equatable {
        public let start: Date
        public let sets: [LiftingSetRecord]

        public init(start: Date, sets: [LiftingSetRecord]) {
            self.start = start
            self.sets = sets
        }
    }

    // MARK: - Output

    /// Why an exercise reports no figures. Non-nil means every figure on it is nil.
    public enum Abstention: Sendable, Equatable {
        /// Fewer than `minSessions` sessions carry a usable estimate.
        case tooFewSessions(have: Int, need: Int)
        /// Sessions exist, but not one set in them had both a real load and a defensible rep count.
        case noUsableSets
    }

    /// One session's reading for one exercise.
    public struct SessionPoint: Sendable, Equatable {
        public let date: Date
        /// Best Epley estimate across the session's usable working sets. Nil when none qualified.
        public let bestE1rmKg: Double?
        /// The same session through Brzycki, for the cross-check line. Nil under the same conditions.
        public let bestBrzyckiKg: Double?
        /// The heaviest usable working set, and the reps done at it — "top set" as a wearer means it.
        public let topSetKg: Double?
        public let topSetReps: Int?
        /// Σ(weight × reps) over usable working sets. Transparent arithmetic, never a strain claim.
        public let volumeKg: Double
        /// Working sets that produced an estimate.
        public let usableSets: Int
        /// Working sets that did not: reps outside 1…`maxReps`, no load, or a bodyweight-added load.
        public let unusableSets: Int

        public init(date: Date, bestE1rmKg: Double?, bestBrzyckiKg: Double?,
                    topSetKg: Double?, topSetReps: Int?, volumeKg: Double,
                    usableSets: Int, unusableSets: Int) {
            self.date = date
            self.bestE1rmKg = bestE1rmKg
            self.bestBrzyckiKg = bestBrzyckiKg
            self.topSetKg = topSetKg
            self.topSetReps = topSetReps
            self.volumeKg = volumeKg
            self.usableSets = usableSets
            self.unusableSets = unusableSets
        }
    }

    /// Which way an exercise is going over one window.
    public enum Direction: Sendable, Equatable { case up, flat, down }

    /// A least-squares trend over one window.
    ///
    /// SLOPE, NOT FIRST-VERSUS-LAST. One bad day at either end of a window moves a first-versus-last
    /// difference by the whole of that day's deficit and says the lift fell; the fitted slope weighs every
    /// session in the window instead. `deltaKg` is that slope carried across the NOMINAL window length,
    /// so "4 weeks, +3.1 kg" means the fit rises 3.1 kg per four weeks — not that the window's sessions
    /// happened to span four weeks.
    public struct Trend: Sendable, Equatable {
        public let windowWeeks: Int
        public let deltaKg: Double
        /// `deltaKg` as a fraction of the window's mean estimate. Nil when that mean is not positive.
        public let deltaPct: Double?
        /// Sessions the fit was made from. Always ≥ 2.
        public let sessions: Int

        public var direction: Direction {
            if deltaKg >= improvementEpsilonKg { return .up }
            if deltaKg <= -improvementEpsilonKg { return .down }
            return .flat
        }

        public init(windowWeeks: Int, deltaKg: Double, deltaPct: Double?, sessions: Int) {
            self.windowWeeks = windowWeeks
            self.deltaKg = deltaKg
            self.deltaPct = deltaPct
            self.sessions = sessions
        }
    }

    /// The evidence that an exercise has stopped moving.
    public struct Stall: Sendable, Equatable {
        /// Sessions since the best estimate was first reached.
        public let sessions: Int
        /// Days over the same span.
        public let days: Int
        /// The weight that is not moving — the top set at the session where the best was first reached.
        public let stuckAtKg: Double?

        public init(sessions: Int, days: Int, stuckAtKg: Double?) {
            self.sessions = sessions
            self.days = days
            self.stuckAtKg = stuckAtKg
        }
    }

    /// What to try next session, and the double-progression step it came from.
    ///
    /// STRUCTURED, NOT A SENTENCE. The wording is the screen's job: this package ships no string catalog,
    /// and a sentence built here would reach a German wearer in English. Every number the UI needs to
    /// write the line — and to show its reasoning — is a field.
    public struct Suggestion: Sendable, Equatable {
        public enum Step: Sendable, Equatable {
            /// Same weight, one more rep. The first half of double progression.
            case addReps
            /// Top of the rep range reached, so one increment on the bar and back to the bottom.
            case addWeight
        }

        public let step: Step
        public let weightKg: Double
        public let reps: Int
        /// The increment this used, for `.addWeight`. Nil for `.addReps`, which changes no weight.
        public let incrementKg: Double?
        /// What it is a step up from.
        public let fromWeightKg: Double
        public let fromReps: Int
        /// The rep range it is working inside.
        public let repRangeLow: Int
        public let repRangeHigh: Int

        public init(step: Step, weightKg: Double, reps: Int, incrementKg: Double?,
                    fromWeightKg: Double, fromReps: Int, repRangeLow: Int, repRangeHigh: Int) {
            self.step = step
            self.weightKg = weightKg
            self.reps = reps
            self.incrementKg = incrementKg
            self.fromWeightKg = fromWeightKg
            self.fromReps = fromReps
            self.repRangeLow = repRangeLow
            self.repRangeHigh = repRangeHigh
        }
    }

    /// Everything known about one exercise's progression.
    public struct Exercise: Sendable, Equatable {
        /// The name as the export writes it — shown back verbatim, matched case-insensitively.
        public let name: String
        /// Every session that contained this exercise, oldest first.
        public let sessions: [SessionPoint]
        /// Non-nil ⇒ every figure below is nil and the screen shows the abstention, not a number.
        public let abstained: Abstention?

        /// Most recent session that produced an estimate, and its date.
        public let currentE1rmKg: Double?
        public let currentDate: Date?
        /// The same session through Brzycki, for the detail view's cross-check.
        public let currentBrzyckiKg: Double?
        public let bestEverE1rmKg: Double?
        public let bestEverDate: Date?
        /// Heaviest usable working set ever, and the reps at it.
        public let topWorkingWeightKg: Double?
        public let topWorkingReps: Int?
        /// Keyed by window length in weeks; a window with fewer than two sessions is absent.
        public let trends: [Int: Trend]
        /// The wearer's own smallest observed step on this exercise. Nil when the history shows one weight.
        public let incrementKg: Double?
        public let repRangeLow: Int?
        public let repRangeHigh: Int?
        public let stall: Stall?
        public let suggestion: Suggestion?
        /// Sets skipped because the load was written as an addition to bodyweight.
        public let excludedBodyweightSets: Int
        /// Sets skipped because the rep count sat outside the defensible window.
        public let excludedOutOfRangeSets: Int

        /// The e1RM series for the sparkline and the chart: only sessions that produced one.
        public var e1rmSeries: [(date: Date, value: Double)] {
            sessions.compactMap { p in p.bestE1rmKg.map { (date: p.date, value: $0) } }
        }

        /// The SHORTEST trend window that has a fit — the most current signal, and the one the list's arrow
        /// shows. A lift trained twice in the last month has no four-week fit and falls through to eight,
        /// which is a longer claim honestly labelled as one rather than a four-week arrow drawn from
        /// twelve weeks of data.
        public var headlineTrend: Trend? {
            for weeks in StrengthProgression.trendWindowsWeeks.sorted() {
                if let t = trends[weeks] { return t }
            }
            return nil
        }

        /// Ordering for the list: stalled first, then most recently trained.
        ///
        /// A stalled lift is the one the wearer can act on, and it is the one a recency-only sort buries
        /// precisely because a lift that has stopped moving is often one they have stopped prioritising.
        public var needsAttention: Bool { stall != nil }
    }

    // MARK: - Building

    /// Every exercise's progression, sorted stalled-first then most-recent-first.
    ///
    /// `sessions` may arrive in any order and may contain sessions with no sets at all (an import from
    /// before sets were stored): those contribute nothing and are not counted anywhere, which is what
    /// keeps `minSessions` a count of sessions this can actually READ rather than of sessions that exist.
    ///
    /// EXERCISE IDENTITY IS THE TRIMMED, CASE-FOLDED NAME, and the display name is the spelling from the
    /// most recent session. Trackers let people retype a name, so "Brustpresse" and "brustpresse " are one
    /// lift; folding them is the difference between one twelve-session history and two thin ones that both
    /// abstain.
    public static func build(sessions: [Session],
                            calendar: Calendar = .current) -> [Exercise] {
        var byKey: [String: [(date: Date, name: String, sets: [LiftingSetRecord])]] = [:]
        for session in sessions {
            var perExercise: [String: (name: String, sets: [LiftingSetRecord])] = [:]
            for set in session.sets {
                let key = set.exercise.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                perExercise[key, default: (name: set.exercise, sets: [])].sets.append(set)
            }
            for (key, entry) in perExercise {
                byKey[key, default: []].append((date: session.start, name: entry.name, sets: entry.sets))
            }
        }

        let out = byKey.map { _, occurrences in
            exercise(from: occurrences.sorted { $0.date < $1.date }, calendar: calendar)
        }
        return out.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            let aLast = a.sessions.last?.date ?? .distantPast
            let bLast = b.sessions.last?.date ?? .distantPast
            if aLast != bLast { return aLast > bLast }
            // A stable tie-break, so two lifts trained in the same session do not swap places between
            // two builds of the same data.
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// One exercise, from its occurrences oldest first.
    private static func exercise(
        from occurrences: [(date: Date, name: String, sets: [LiftingSetRecord])],
        calendar: Calendar
    ) -> Exercise {
        let name = occurrences.last?.name ?? ""
        var points: [SessionPoint] = []
        var excludedBodyweight = 0
        var excludedOutOfRange = 0
        // Every usable working set, newest-session-last, for the increment and the rep range.
        var usable: [(date: Date, weightKg: Double, reps: Int)] = []

        for occurrence in occurrences {
            var bestEpley: Double?
            var bestBrzycki: Double?
            var topKg: Double?
            var topReps: Int?
            var volume = 0.0
            var usableHere = 0
            var unusableHere = 0

            for set in occurrence.sets where !set.isWarmup {
                // The three ways a set cannot carry an absolute estimate, each counted where the screen
                // can name it. A hold or a timed effort has no reps and lands in `unusableHere` without a
                // more specific bucket: there is nothing wrong with it, it simply is not weight × reps.
                if set.addedToBodyweight {
                    excludedBodyweight += 1
                    unusableHere += 1
                    continue
                }
                guard let weight = set.weightKg, weight > 0, let reps = set.reps, reps > 0 else {
                    unusableHere += 1
                    continue
                }
                guard reps <= maxReps else {
                    excludedOutOfRange += 1
                    unusableHere += 1
                    continue
                }
                guard let e = epley(weightKg: weight, reps: reps) else {
                    unusableHere += 1
                    continue
                }
                usableHere += 1
                volume += weight * Double(reps)
                bestEpley = max(bestEpley ?? 0, e)
                if let b = brzycki(weightKg: weight, reps: reps) { bestBrzycki = max(bestBrzycki ?? 0, b) }
                // TOP SET IS THE HEAVIEST, and among equal weights the one with the most reps — which is
                // the set a wearer would name if asked what they did. It is NOT the set with the best
                // estimate: 60 kg × 12 estimates higher than 90 kg × 3, and reporting 60 kg as the top set
                // of a session that had 90 kg in it would be wrong in the plainest possible way.
                if weight > (topKg ?? -1) || (weight == topKg && reps > (topReps ?? 0)) {
                    topKg = weight
                    topReps = reps
                }
                usable.append((date: occurrence.date, weightKg: weight, reps: reps))
            }

            points.append(SessionPoint(
                date: occurrence.date,
                bestE1rmKg: bestEpley,
                bestBrzyckiKg: bestBrzycki,
                topSetKg: topKg,
                topSetReps: topReps,
                volumeKg: volume,
                usableSets: usableHere,
                unusableSets: unusableHere))
        }

        let scored = points.filter { $0.bestE1rmKg != nil }

        func abstaining(_ reason: Abstention) -> Exercise {
            Exercise(name: name, sessions: points, abstained: reason,
                     currentE1rmKg: nil, currentDate: nil, currentBrzyckiKg: nil,
                     bestEverE1rmKg: nil, bestEverDate: nil,
                     topWorkingWeightKg: nil, topWorkingReps: nil,
                     trends: [:], incrementKg: nil, repRangeLow: nil, repRangeHigh: nil,
                     stall: nil, suggestion: nil,
                     excludedBodyweightSets: excludedBodyweight,
                     excludedOutOfRangeSets: excludedOutOfRange)
        }
        guard !scored.isEmpty else { return abstaining(.noUsableSets) }
        guard scored.count >= minSessions else {
            return abstaining(.tooFewSessions(have: scored.count, need: minSessions))
        }

        let current = scored.last
        let bests = scored.compactMap(\.bestE1rmKg)
        let bestEver = bests.max() ?? 0
        // EARLIEST session within epsilon of the best, not the latest. "Sessions since you last improved"
        // is measured from when the current best was FIRST reached; taking the latest equal session would
        // reset the clock every time the wearer repeated the same weight, and a lift repeating the same
        // weight is exactly what a stall is.
        let prIndex = scored.firstIndex { ($0.bestE1rmKg ?? 0) >= bestEver - improvementEpsilonKg } ?? 0
        let prPoint = scored[prIndex]

        let stall = self.stall(scored: scored, prIndex: prIndex, prPoint: prPoint, calendar: calendar)
        let increment = self.increment(usable: usable)
        let range = repRange(usable: usable, scored: scored)

        var trends: [Int: Trend] = [:]
        if let last = scored.last?.date {
            for weeks in trendWindowsWeeks {
                if let t = trend(scored: scored, endingAt: last, weeks: weeks, calendar: calendar) {
                    trends[weeks] = t
                }
            }
        }

        // The heaviest usable working set across the whole history, and the reps at it.
        var topKg: Double?
        var topReps: Int?
        for entry in usable where entry.weightKg > (topKg ?? -1)
            || (entry.weightKg == topKg && entry.reps > (topReps ?? 0)) {
            topKg = entry.weightKg
            topReps = entry.reps
        }

        return Exercise(
            name: name,
            sessions: points,
            abstained: nil,
            currentE1rmKg: current?.bestE1rmKg,
            currentDate: current?.date,
            currentBrzyckiKg: current?.bestBrzyckiKg,
            bestEverE1rmKg: bestEver,
            bestEverDate: prPoint.date,
            topWorkingWeightKg: topKg,
            topWorkingReps: topReps,
            trends: trends,
            incrementKg: increment,
            repRangeLow: range?.low,
            repRangeHigh: range?.high,
            stall: stall,
            suggestion: suggestion(latest: current, increment: increment, range: range),
            excludedBodyweightSets: excludedBodyweight,
            excludedOutOfRangeSets: excludedOutOfRange)
    }

    // MARK: - Stall

    private static func stall(scored: [SessionPoint], prIndex: Int, prPoint: SessionPoint,
                              calendar: Calendar) -> Stall? {
        let sessionsSince = scored.count - 1 - prIndex
        guard sessionsSince >= stallSessions, let last = scored.last else { return nil }
        let days = calendar.dateComponents([.day], from: prPoint.date, to: last.date).day ?? 0
        guard days >= stallMinDays else { return nil }
        // The weight it is stuck at is the LATEST session's top set, not the PR session's: that is what is
        // on the machine now, and it is the number the suggestion steps up from. A lift whose top set has
        // drifted DOWN while the estimate stood still is still stalled, and saying "stuck at" the old
        // heavier weight would misreport what they are currently doing.
        return Stall(sessions: sessionsSince, days: days, stuckAtKg: last.topSetKg)
    }

    // MARK: - Increment

    /// The wearer's own smallest believable step on this exercise.
    ///
    /// Distinct weights, sorted, consecutive gaps, smallest gap inside [`minIncrementKg`,
    /// `maxIncrementKg`]. Nil when no gap qualifies — including the common honest case of a single weight
    /// in the whole history, which is evidence of nothing.
    static func increment(usable: [(date: Date, weightKg: Double, reps: Int)]) -> Double? {
        // Rounded to the hundredth before de-duplicating, so a pound-converted 74.9997 and 75.0 are one
        // weight rather than a 0.0003 kg "increment" this would then have to reject.
        let weights = Swift.Set(usable.map { ($0.weightKg * 100).rounded() / 100 }).sorted()
        guard weights.count >= 2 else { return nil }
        var smallest: Double?
        for i in 1..<weights.count {
            let gap = weights[i] - weights[i - 1]
            guard gap >= minIncrementKg, gap <= maxIncrementKg else { continue }
            smallest = min(smallest ?? gap, gap)
        }
        return smallest
    }

    // MARK: - Rep range

    /// The rep window the wearer is currently working in, from the last `repRangeSessions` sessions.
    private static func repRange(usable: [(date: Date, weightKg: Double, reps: Int)],
                                 scored: [SessionPoint]) -> (low: Int, high: Int)? {
        let recentDates = Swift.Set(scored.suffix(repRangeSessions).map(\.date))
        let reps = usable.filter { recentDates.contains($0.date) }.map(\.reps)
        guard let low = reps.min(), let high = reps.max() else { return nil }
        return (low, high)
    }

    // MARK: - Trend

    /// Least-squares slope of best e1RM against time, over a window of `weeks` ending at `end`.
    ///
    /// Nil with fewer than two sessions in the window, and nil when every session in it fell on one day —
    /// a vertical fit has no slope, and inventing one from a single day's sessions would report a trend
    /// from no elapsed time at all.
    static func trend(scored: [SessionPoint], endingAt end: Date, weeks: Int,
                      calendar: Calendar) -> Trend? {
        let windowDays = weeks * 7
        guard let from = calendar.date(byAdding: .day, value: -windowDays, to: end) else { return nil }
        let inWindow = scored.filter { $0.date >= from && $0.date <= end }
        guard inWindow.count >= 2 else { return nil }

        // x in DAYS from the window's first session. Seconds would work identically and make every
        // intermediate a ten-digit number; days keep the slope readable as kg/day.
        let origin = inWindow[0].date
        let xs = inWindow.map { $0.date.timeIntervalSince(origin) / 86_400 }
        let ys = inWindow.compactMap(\.bestE1rmKg)
        guard xs.count == ys.count else { return nil }

        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            sxx += dx * dx
            sxy += dx * (ys[i] - meanY)
        }
        guard sxx > 0 else { return nil }
        let slopePerDay = sxy / sxx
        let delta = slopePerDay * Double(windowDays)
        return Trend(windowWeeks: weeks,
                     deltaKg: delta,
                     deltaPct: meanY > 0 ? delta / meanY : nil,
                     sessions: inWindow.count)
    }

    // MARK: - Suggestion

    /// Double progression: reps to the top of the range first, then ONE increment and back to the bottom.
    ///
    /// The rule is the standard one and the reason it is this way round is that adding a rep is the
    /// smaller demand — it asks for more work at a load already proven, where adding weight asks for a
    /// load never lifted. Doing weight first and reps second means every jump is into the unknown.
    ///
    /// NEVER MORE THAN ONE INCREMENT, whatever the trend says. A lift climbing fast still only gets the
    /// next step: this suggests what to load, and a two-step jump extrapolated from a good month is the
    /// app inventing a lift the wearer has not done.
    ///
    /// Nil when the last session produced no top set, when there is no rep range, or when the range is
    /// exhausted and no increment can be inferred — the last being the honest end of the line rather than
    /// a guessed 2.5 kg.
    static func suggestion(latest: SessionPoint?, increment: Double?,
                           range: (low: Int, high: Int)?) -> Suggestion? {
        guard let latest, let weight = latest.topSetKg, let reps = latest.topSetReps,
              let range else { return nil }

        if reps < range.high {
            return Suggestion(step: .addReps, weightKg: weight, reps: reps + 1, incrementKg: nil,
                              fromWeightKg: weight, fromReps: reps,
                              repRangeLow: range.low, repRangeHigh: range.high)
        }
        guard let increment else { return nil }
        // Back to the BOTTOM of the range, not to the same reps: a heavier load at the reps that just
        // topped the range out is two steps at once.
        return Suggestion(step: .addWeight, weightKg: weight + increment, reps: range.low,
                          incrementKg: increment,
                          fromWeightKg: weight, fromReps: reps,
                          repRangeLow: range.low, repRangeHigh: range.high)
    }
}
