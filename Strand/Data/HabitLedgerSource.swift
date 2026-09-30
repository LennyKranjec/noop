import Foundation
import StrandAnalytics
import WhoopStore

// HabitLedgerSource.swift — reads every behaviour and outcome the app records into one `HabitLedgerInputs`.
//
// HEALTH_V2 §S1-A.8. The pure rules (what counts as yes / no / absent, how an event is keyed to a night)
// live in `HabitModel.swift`; this file only reads the stores and hands their records to those rules:
//
//   journal (merged imported + native) · dream answers · caffeine daily summary · workouts · bedroom
//   climate summary · breathing / meditation sessions · WiZ wind-down record — and outcomes from
//   `repo.days` plus sleep timings.
//
// ABSENT STAYS ABSENT. A night the app cannot see produces no observation and no outcome value. Outcomes the
// app cannot trust are dropped here, before any statistic sees them: an HRV night outside the
// `Baselines.hrvCfg` plausibility bounds, an RHR outside `Baselines.restingHRCfg`, and nights whose score
// input was still `calibrating` (`charge_confidence` / `rest_confidence` ordinal 0).
//
// NOT INCLUDED, AND WHY: `auto:bedtimeOnTarget` needs the bedtime target that applied on each PAST night,
// and the sleep-anchor plan keeps only the current plans; judging old nights against today's target would
// be a fabricated comparison, so that habit stays unobserved until a per-night target history exists.
// `dayStressMean` has no stored daily series (only high-stress minutes are banked), so it is absent.
//
// BREATHING MINUTES (`breath_session_min`, source `noop-habits`, written by `BreathSessionLog`). The habit is
// timed ("a ≥ 5-min session ended between 17:00 and onset"), so the timed sessions in `breath-sessions.json`
// stay its source. The day series adds the days the JSON cannot see (it is in the database backup, the JSON
// is not; the JSON is also bounded): such an UNTIMED day counts toward "active in the last 14 days" when it
// lies wholly inside that window, and it WITHDRAWS a "no" for a night whose evening it could have covered
// (clock time unknown ⇒ neither yes nor no is honest ⇒ absent). It never creates a "yes". There is no
// zero-filling: a day without a row is simply not a breathing day, exactly as before.

@MainActor
enum HabitLedgerSource {

    static let lookbackDays = 120
    static let habitsSource = "noop-habits"
    nonisolated static let breathingActiveDays = 14
    /// `HabitRules.breathingSession`'s floor for one session. An untimed day totalling less cannot hold one.
    nonisolated static let breathingMinSessionMinutes = 5.0

    /// Everything the association analysis and the trials read.
    struct Snapshot {
        let inputs: HabitLedgerInputs
        /// Sleep timings keyed by wake day.
        let timings: [String: SleepTiming]
    }

    // MARK: Build

    static func build(repo: Repository, asOf: String, calendar: Calendar = .current) async -> Snapshot {
        let timings = await repo.sleepTimingsByDay(days: lookbackDays)
        let (outcomes, effort) = await outcomeSeries(repo: repo, timings: timings)
        var obs: [HabitObservation] = []
        var customIds = Set<HabitId>()
        var custom: [HabitDefinition] = []

        // 1. Journal. The row's day key IS the night key (an answer describes "the night and day leading
        //    into this morning"); evening logs from the Tonight sheet are written under tomorrow's key.
        let journal = await repo.journalEntries(days: lookbackDays)
        for row in journal {
            guard let id = HabitCatalog.journalHabitId(question: row.question) else { continue }
            let state: ObservationState?
            if row.numericValue != nil {
                state = HabitRules.journalNumeric(value: row.numericValue)
            } else {
                state = HabitRules.journalBool(answeredYes: row.answeredYes)
            }
            guard let s = state else { continue }
            obs.append(HabitObservation(nightKey: row.day, habit: id, state: s, source: .journal))
            if HabitCatalog.definition(id) == nil, !customIds.contains(id) {
                customIds.insert(id)
                custom.append(HabitCatalog.custom(question: row.question))
            }
        }

        // 2. Dream answers (wake-day keyed, recalled the next morning). Stored 0-based; the rules are 1-based.
        for entry in DreamJournalStore.shared.entries {
            if let s = HabitRules.dreamScreen(option: entry.answers["screen"].map { $0 + 1 }) {
                obs.append(HabitObservation(nightKey: entry.day, habit: HabitCatalog.dreamScreen, state: s,
                                            source: .dream, recalled: true))
            }
            if let s = HabitRules.dreamMeal(option: entry.answers["meal"].map { $0 + 1 }) {
                obs.append(HabitObservation(nightKey: entry.day, habit: HabitCatalog.dreamMeal, state: s,
                                            source: .dream, recalled: true))
            }
        }

        // 3. Caffeine: the day's last intake → the night after that day.
        let caffeine = await repo.series(key: CaffeineDailySummary.lastMinuteKey, source: habitsSource,
                                         days: lookbackDays)
        for point in caffeine {
            guard let night = HabitNightKey.nightAfter(point.day),
                  let s = HabitRules.lateCaffeine(lastIntakeMinute: Int(point.value)) else { continue }
            obs.append(HabitObservation(nightKey: night, habit: HabitCatalog.lateCaffeineAuto, state: s,
                                        source: .caffeineLog))
        }

        // 4. Workouts ending in the 3 h before onset. Coverage: nights inside the span the workout table
        //    has any record for (before the first ever workout the table says nothing either way).
        // Meditation / mindfulness "activities" live in the same table and are not training.
        let workouts = await repo.workoutRows(days: lookbackDays).filter { !MeditationLog.isMeditation(sport: $0.sport) }
        let workoutEnds = workouts.map { Int64($0.endTs) }
        let firstWorkout = workouts.map { $0.startTs }.min()
        var onsets: [String: Date] = [:]
        for (wakeDay, timing) in timings {
            guard let onset = onsetDate(wakeDay: wakeDay, timing: timing, calendar: calendar) else { continue }
            onsets[wakeDay] = onset
            let onsetSec = Int64(onset.timeIntervalSince1970)
            let covered = firstWorkout.map { Int64($0) <= onsetSec } ?? false
            if let s = HabitRules.lateWorkout(workoutEndsEpochSec: workoutEnds, onsetEpochSec: onsetSec,
                                              hasWorkoutCoverage: covered) {
                obs.append(HabitObservation(nightKey: wakeDay, habit: HabitCatalog.lateWorkout, state: s,
                                            source: .workouts))
            }
        }

        // 5. Bedroom climate over the first 90 min of the night (written only at ≥ 60 % coverage).
        let bedroom = await repo.series(key: BedroomNightSummary.tempKey, source: habitsSource, days: lookbackDays)
        for point in bedroom {
            if let s = HabitRules.warmBedroom(meanC: point.value, slotCoverage: 1) {
                obs.append(HabitObservation(nightKey: point.day, habit: HabitCatalog.warmBedroom, state: s,
                                            source: .climate))
            }
        }

        // 6. Evening breathing: stored breath sessions and meditation activities.
        var sessions: [(endEpochSec: Int64, minutes: Double)] = []
        for s in BreathSessionLog.shared.sessions {
            sessions.append((endEpochSec: Int64(s.startTs) + Int64(s.pacedMinutes * 60), minutes: s.pacedMinutes))
        }
        let meditations = await repo.meditationSessions(days: lookbackDays)
        for w in meditations {
            let minutes = (w.durationS ?? Double(w.endTs - w.startTs)) / 60
            sessions.append((endEpochSec: Int64(w.endTs), minutes: minutes))
        }
        let breathSeries = await repo.series(key: BreathSessionLog.key, source: BreathSessionLog.source,
                                             days: lookbackDays)
        let untimed = untimedBreathMinutes(series: breathSeries,
                                           timedDays: Set(BreathSessionLog.shared.sessions.map(\.day)))
        for (wakeDay, onset) in onsets {
            guard let evening = HabitDay.adding(-1, to: wakeDay),
                  let eveningStart = localDate(day: evening, minute: 17 * 60, calendar: calendar) else { continue }
            let eveningSec = Int64(eveningStart.timeIntervalSince1970)
            let activeFrom = eveningSec - Int64(breathingActiveDays) * 86_400
            let active = sessions.contains { $0.endEpochSec >= activeFrom && $0.endEpochSec < eveningSec }
                || untimedBreathActive(untimed, evening: evening)
            guard let s = HabitRules.breathingSession(activeInLast14Days: active, sessions: sessions,
                                                      eveningStartEpochSec: eveningSec,
                                                      onsetEpochSec: Int64(onset.timeIntervalSince1970)) else { continue }
            let onsetAfterMidnight = timings[wakeDay].map { $0.onsetMinute <= $0.wakeMinute } ?? false
            if s == .no, untimedBreathMayCoverNight(untimed, evening: evening, wakeDay: wakeDay,
                                                    onsetAfterMidnight: onsetAfterMidnight) { continue }
            obs.append(HabitObservation(nightKey: wakeDay, habit: HabitCatalog.breathingSession, state: s,
                                        source: .breathLog))
        }

        // 7. WiZ wind-down: 1 ran / 0 enabled-but-not-by-onset / no row when disabled.
        let wiz = await repo.series(key: WizDailyRecord.key, source: habitsSource, days: lookbackDays)
        for point in wiz {
            guard let night = HabitNightKey.nightAfter(point.day),
                  let s = HabitRules.lightsDimmed(winddownRan: point.value) else { continue }
            obs.append(HabitObservation(nightKey: night, habit: HabitCatalog.lightsDimmed, state: s, source: .wiz))
        }

        _ = asOf
        return Snapshot(inputs: HabitLedgerInputs(observations: obs, outcomes: outcomes, effortByDay: effort,
                                                  customDefinitions: custom),
                        timings: timings)
    }

    // MARK: Outcomes

    /// Outcome series in analysis units keyed by wake day, and day Effort keyed by calendar day.
    static func outcomeSeries(repo: Repository,
                              timings: [String: SleepTiming]) async -> ([HabitOutcome: [String: Double]], [String: Double]) {
        let noopSource = repo.deviceId + "-noop"
        func calibratingDays(_ key: String) async -> Set<String> {
            let pts = await repo.series(key: key, source: noopSource, days: lookbackDays)
            return Set(pts.filter { ScoreConfidence.from(ordinal: $0.value) == .calibrating }.map { $0.day })
        }
        let chargeCalibrating = await calibratingDays(ScoreConfidence.SeriesKey.charge)
        let restCalibrating = await calibratingDays(ScoreConfidence.SeriesKey.rest)
        let hrvCfg = Baselines.hrvCfg
        let rhrCfg = Baselines.restingHRCfg

        var hrv: [String: Double] = [:], rhr: [String: Double] = [:], tst: [String: Double] = [:]
        var eff: [String: Double] = [:], charge: [String: Double] = [:], onset: [String: Double] = [:]
        var effort: [String: Double] = [:]
        for d in repo.days {
            if let s = d.strain, s.isFinite, s >= 0 { effort[d.day] = s }
            if !chargeCalibrating.contains(d.day) {
                if let v = d.avgHrv, v >= hrvCfg.minVal, v <= hrvCfg.maxVal { hrv[d.day] = log(v) }
                if let v = d.restingHr, Double(v) >= rhrCfg.minVal, Double(v) <= rhrCfg.maxVal { rhr[d.day] = Double(v) }
                if let v = d.recovery, v.isFinite { charge[d.day] = v }
            }
            if !restCalibrating.contains(d.day) {
                if let v = d.totalSleepMin, v > 0, v.isFinite { tst[d.day] = v }
                if let v = d.efficiency, v > 0, v.isFinite {
                    let pct = v <= 1 ? v * 100 : v
                    if pct <= 100 { eff[d.day] = pct }
                }
            }
        }
        for (wakeDay, t) in timings where !restCalibrating.contains(wakeDay) {
            onset[wakeDay] = HabitOutcome.onsetClockValue(onsetMinute: t.onsetMinute)
        }
        return ([.nightHrvLn: hrv, .nightRhr: rhr, .totalSleepMin: tst, .sleepEfficiency: eff,
                 .nextMorningCharge: charge, .onsetClockMin: onset], effort)
    }

    /// Wake days of nights after an evening with alcohol logged "yes" (for the trials' exploratory
    /// sensitivity analysis).
    static func alcoholNights(_ inputs: HabitLedgerInputs) -> Set<String> {
        Set(inputs.observations.filter { $0.habit == HabitCatalog.alcohol && $0.state == .yes }.map { $0.nightKey })
    }

    // MARK: Untimed breathing days (pure)

    /// Days with banked breathing minutes (`breath_session_min`) but no timed session in the JSON log.
    /// Only positive, finite totals count; a day without a row stays absent (never 0).
    nonisolated static func untimedBreathMinutes(series: [(day: String, value: Double)],
                                                 timedDays: Set<String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for p in series where p.value.isFinite && p.value > 0 && !timedDays.contains(p.day) {
            out[p.day] = p.value
        }
        return out
    }

    /// Whether an untimed day makes the wearer "active" before `evening`: only days WHOLLY inside the
    /// 14 days before that evening's 17:00 (evening − 13 … evening − 1) qualify, whatever their clock time.
    nonisolated static func untimedBreathActive(_ untimed: [String: Double], evening: String) -> Bool {
        (1..<breathingActiveDays).contains { k in HabitDay.adding(-k, to: evening).map { untimed[$0] != nil } ?? false }
    }

    /// Whether an untimed day could hold the ≥ 5-min session that would turn this night's "no" into a
    /// "yes": the evening's own day, or the wake day when onset fell after midnight (the window then runs
    /// past 00:00). The clock time is unknown, so such a night is left unobserved.
    nonisolated static func untimedBreathMayCoverNight(_ untimed: [String: Double], evening: String,
                                                       wakeDay: String, onsetAfterMidnight: Bool) -> Bool {
        if (untimed[evening] ?? 0) >= breathingMinSessionMinutes { return true }
        return onsetAfterMidnight && (untimed[wakeDay] ?? 0) >= breathingMinSessionMinutes
    }

    // MARK: Time helpers

    /// The local instant of the onset of the night that ended on `wakeDay`.
    nonisolated static func onsetDate(wakeDay: String, timing: SleepTiming, calendar: Calendar = .current) -> Date? {
        // An onset clock-time later than the wake clock-time was the previous evening.
        let day = timing.onsetMinute > timing.wakeMinute ? HabitDay.adding(-1, to: wakeDay) : wakeDay
        guard let d = day else { return nil }
        return localDate(day: d, minute: timing.onsetMinute, calendar: calendar)
    }

    /// `day` at `minute` after local midnight.
    nonisolated static func localDate(day: String, minute: Int, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = minute / 60
        c.minute = minute % 60
        return calendar.date(from: c)
    }
}
