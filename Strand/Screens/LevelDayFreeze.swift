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
// an empty verdict all day. Yesterday's level stays up until the night lands, and the day freezes then.

/// The day's level, as stored.
///
/// A Codable mirror of `LevelBreakdown` rather than the type itself: the analytics package is shared
/// with the Kotlin twin and its types stay plain, while persistence is the app's concern.
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

    init(day: String, breakdown: LevelBreakdown, drivers: [LevelPart: LevelDriver]) {
        self.day = day
        self.parts = breakdown.components.map {
            Part(part: $0.part, score: $0.score, effectiveWeight: $0.effectiveWeight)
        }
        self.raw = breakdown.raw
        self.stepPenalty = breakdown.stepPenalty
        self.level = breakdown.level
        self.coverage = breakdown.coverage
        self.drivers = drivers
    }

    var breakdown: LevelBreakdown {
        LevelBreakdown(
            components: parts.map {
                LevelComponent(part: $0.part, score: $0.score, effectiveWeight: $0.effectiveWeight)
            },
            raw: raw, stepPenalty: stepPenalty, level: level, coverage: coverage)
    }
}

enum LevelDayFreeze {

    /// When a day's level is set. The same minute the morning briefing runs.
    static let hour = 6
    static let minute = 40

    /// v1 of the stored shape. Bumped if `FrozenLevel` changes, so an old record is recomputed rather
    /// than half-decoded.
    private static let key = "level.frozenDay.v1"

    /// The day whose level is current at `now`: today from 06:40, yesterday before it.
    static func levelDay(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let setAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
        return now >= setAt ? start : (calendar.date(byAdding: .day, value: -1, to: start) ?? start)
    }

    static func stored(_ d: UserDefaults = .standard) -> FrozenLevel? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FrozenLevel.self, from: data)
    }

    static func store(_ level: FrozenLevel, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(level) else { return }
        d.set(data, forKey: key)
    }

    /// Forget the frozen day, so the next load recomputes it. For a baseline reset or a re-import that
    /// rewrote history — a wearer who replaced their data expects the level to follow it.
    static func clear(_ d: UserDefaults = .standard) {
        d.removeObject(forKey: key)
    }
}
