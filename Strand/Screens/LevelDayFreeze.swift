import Foundation
import StrandAnalytics

// LevelDayFreeze.swift — the day's level, set at 06:40 and held.
//
// The level used to be recomputed on every refresh from whatever the day had accumulated so far: steps
// that start at zero, stress minutes that pile up through the afternoon, a workout logged at six. So
// the number the wearer woke to was not the number they went to bed with, and neither was a verdict on
// anything — it drifted with the clock. A level that moves every time you look at it is a live meter,
// and a live meter is not a level.
//
// SO A DAY HAS ONE LEVEL. It is computed for the day once the day begins at 06:40 — the same moment
// the morning briefing speaks — and then frozen until 06:40 the next morning.
//
// WHAT IT IS COMPUTED FROM is the part that makes freezing it honest rather than merely static. At 06:40
// the day's own activity has barely begun: a step count of 300 would hit the step penalty in full and
// lock it in for the next twenty-four hours. So the day's level reads the NIGHT that ended this morning
// (sleep, HRV, resting HR, breathing) and the activity of the last COMPLETE day (steps, stress,
// meditation, training). Both are finished facts by 06:40, which is what lets the number stand all day.
//
// BEFORE THE DAY'S DATA HAS ARRIVED IT IS NOT FROZEN. A strap that has not synced the night, or a cloud
// that has not scored it, leaves nothing to compute this morning's half from; freezing then would hold
// an empty verdict all day. The last settled level stays up — marked as still pending — until the night
// lands, and the day is written to the ledger then (see `LevelLedger` for what "landed" means, and for the
// 14:00 deadline after which a night that never fully arrived is written down as it stands).
//
// EVERY DAY IS KEPT, NOT ONLY THE CURRENT ONE. This used to hold a single frozen day and recompute every
// other one — yesterday, three days ago, the month, the whole timeline — live from whatever the store
// held now. Late syncs, cloud rewrites and baselines freezing later all moved those past levels, so
// yesterday's number could rise after the fact. Every past figure now comes from `LevelLedger`, written
// once per day and never again.

/// The day's level, as stored.
///
/// A Codable mirror of `LevelBreakdown` rather than the type itself: the analytics package is shared
/// with the Kotlin twin and its types stay plain, while persistence is the app's concern.
///
/// EVERY DOUBLE IS FINITE BY CONSTRUCTION. JSON has no NaN or infinity, and a VO₂max or strength input
/// that divided by zero used to make the whole record fail to encode — silently, under a `try?` — so the
/// day was never stored and was recomputed, differently, on every refresh. The initialiser cleans every
/// figure before it is kept, so what reaches the encoder always encodes.
struct FrozenLevel: Codable, Equatable {
    struct Part: Codable, Equatable {
        let part: LevelPart
        let score: Double?
        let effectiveWeight: Double
    }

    /// The day this level is FOR.
    let day: String
    let parts: [Part]
    let raw: Double
    let stepPenalty: Double
    let level: Double
    let coverage: Double
    let drivers: [LevelPart: LevelDriver]
    /// The inputs the level was computed without, as `LevelMissingInput` raw values.
    let missing: [String]
    /// Written at the deadline with the night only partly in — see `LevelLedger`.
    let partial: Bool
    /// Written by the one-off backfill of days from before the ledger existed, rather than on the day.
    let backfilled: Bool
    let computedAt: Date

    init(day: String, breakdown: LevelBreakdown, drivers: [LevelPart: LevelDriver],
         missing: [LevelMissingInput] = [], partial: Bool = false, backfilled: Bool = false,
         computedAt: Date = Date()) {
        self.day = day
        let parts = breakdown.components.map {
            Part(part: $0.part, score: Self.finite($0.score), effectiveWeight: Self.finite($0.effectiveWeight) ?? 0)
        }
        self.parts = parts
        let stepPenalty = Self.finite(breakdown.stepPenalty) ?? 1
        self.stepPenalty = stepPenalty
        self.coverage = Self.finite(breakdown.coverage) ?? 0
        if let level = Self.finite(breakdown.level), let raw = Self.finite(breakdown.raw) {
            self.raw = raw
            self.level = level
        } else {
            // A LEVEL THAT CAME OUT NOT-A-NUMBER is rebuilt from the parts that are numbers, their weights
            // shared out again over just those — the same arithmetic the engine does for a missing part.
            let scored = parts.filter { $0.score != nil && $0.effectiveWeight > 0 }
            let weight = scored.reduce(0) { $0 + $1.effectiveWeight }
            let sum = scored.reduce(0) { $0 + ($1.score ?? 0) * $1.effectiveWeight }
            let raw = weight > 0 ? sum / weight : 0
            self.raw = raw
            self.level = raw * stepPenalty
        }
        self.drivers = drivers
        self.missing = missing.map(\.rawValue)
        self.partial = partial
        self.backfilled = backfilled
        self.computedAt = computedAt
    }

    private enum CodingKeys: String, CodingKey {
        case day, parts, raw, stepPenalty, level, coverage, drivers, missing, partial, backfilled, computedAt
    }

    /// Reads the v3 single-day record too, which had none of the ledger's fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        parts = try c.decode([Part].self, forKey: .parts)
        raw = try c.decode(Double.self, forKey: .raw)
        stepPenalty = try c.decode(Double.self, forKey: .stepPenalty)
        level = try c.decode(Double.self, forKey: .level)
        coverage = try c.decode(Double.self, forKey: .coverage)
        drivers = try c.decode([LevelPart: LevelDriver].self, forKey: .drivers)
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
        computedAt = try c.decodeIfPresent(Date.self, forKey: .computedAt) ?? Date(timeIntervalSince1970: 0)
    }

    var breakdown: LevelBreakdown {
        LevelBreakdown(
            components: parts.map {
                LevelComponent(part: $0.part, score: $0.score, effectiveWeight: $0.effectiveWeight)
            },
            raw: raw, stepPenalty: stepPenalty, level: level, coverage: coverage)
    }

    var missingInputs: [LevelMissingInput] { missing.compactMap(LevelMissingInput.init(rawValue:)) }

    static func finite(_ x: Double?) -> Double? {
        guard let x, x.isFinite else { return nil }
        return x
    }
}

// THE DAY NOW TURNS WHEN THE WEARER OPENS THE APP, not at 06:40. The first open of a day runs the morning
// flow — the dream, the questions, the daily brief — and the brief is where the day's level is computed
// and frozen, so the number is set at the moment it is first looked at, from a night that has had time to
// sync. Until then the level shown is the last settled day's. An open before 04:00 is still the night before and
// does not count as the morning.

enum LevelDayFreeze {

    /// Before this hour an open is still last night, not this morning.
    static let earliestHour = 4

    /// The day the morning flow last ran for — the day whose level is current.
    private static let briefDayKey = "level.briefDay.v1"

    /// The single frozen day the level used to keep, before the ledger. Read once, to carry it over.
    static let legacyKey = "level.frozenDay.v3"

    /// The day whose level is current at `now`: today once this morning's flow has run, yesterday before.
    static func levelDay(now: Date = Date(), calendar: Calendar = .current,
                         _ d: UserDefaults = .standard) -> Date {
        let start = calendar.startOfDay(for: now)
        let today = LevelWiring.key(from: start, calendar: calendar)
        return d.string(forKey: briefDayKey) == today
            ? start : (calendar.date(byAdding: .day, value: -1, to: start) ?? start)
    }

    /// Whether this morning's flow is still to come: past 04:00 and not yet run today.
    static func morningDue(now: Date = Date(), calendar: Calendar = .current,
                           _ d: UserDefaults = .standard) -> Bool {
        guard calendar.component(.hour, from: now) >= earliestHour else { return false }
        return d.string(forKey: briefDayKey) != LevelWiring.key(from: now, calendar: calendar)
    }

    /// Mark this morning's flow as run: from here on the level shown is today's.
    static func beginDay(now: Date = Date(), calendar: Calendar = .current, _ d: UserDefaults = .standard) {
        d.set(LevelWiring.key(from: now, calendar: calendar), forKey: briefDayKey)
    }
}
