import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// CoachExtraContext.swift — everything else the app knows about the day, for the coach.
//
// The data context used to stop at the scores, the vitals, the level and the workouts. The rest of what
// the app holds — the dream journal and the morning's answers, the journal itself, water, the
// energy bank, the streaks, stress now and through the day, the quests, meditation, what the level is
// missing, VO₂max and strength, the bedroom and the lights — was on screen and invisible to the coach.
// This is that rest, as compact lines, each section present only when there is something in it.
//
// ONLY WITH DATA ACCESS. It is appended to the same context `buildFullContext` builds, so it rides the
// same consent: without it none of this is sent.
//
// FIGURES THE SCREENS COMPUTE ARE READ, NOT RECOMPUTED. The energy bank and the streaks are derived on
// Today from a dozen inputs; Today leaves its latest result in `CoachDaySnapshot`, so the coach quotes
// exactly the figure the wearer is looking at.

/// Today's derived figures as Today last computed them.
@MainActor
enum CoachDaySnapshot {
    static var energy: EnergyBalance?
    static var streaks: [Streak] = []
}

@MainActor
enum CoachExtraContext {

    /// `Repository.hydrationTotal(day:)` for each of `days`, from one range read per hydration series.
    /// That call is `manual + imported`, each the FIRST row the single-day read returns for the day, or 0
    /// (0 for every day when there is no store). A range read returns the same rows ordered by day, so
    /// taking each day's first row gives the same two addends, summed in the same order.
    private static func hydrationTotals(repo: Repository, days: [String]) async -> [String: Double] {
        guard let lo = days.min(), let hi = days.max() else { return [:] }
        guard let store = await repo.storeHandle() else {
            return Dictionary(days.map { ($0, 0.0) }, uniquingKeysWith: { first, _ in first })
        }
        func firstPerDay(_ key: String) async -> [String: Double] {
            let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId, key: key,
                                                     from: lo, to: hi)) ?? []
            var out: [String: Double] = [:]
            for p in pts where out[p.day] == nil { out[p.day] = p.value }
            return out
        }
        let manual = await firstPerDay(HydrationStore.key)
        let imported = await firstPerDay(HydrationStore.importedKey)
        var totals: [String: Double] = [:]
        for day in days { totals[day] = (manual[day] ?? 0) + (imported[day] ?? 0) }
        return totals
    }

    /// How many exercises the progression section lists before it says how many it left out.
    ///
    /// A wearer with two years of training has thirty lifts, and thirty lines of estimates would crowd out
    /// the sleep, the journal and the day itself in a context the model reads once. Stalled-first ordering
    /// means the cut falls on the lifts that are fine, and the count of the remainder is stated rather than
    /// the list quietly ending.
    private static let coachProgressionLimit = 12

    /// One exercise as a line of context. ENGLISH and unlocalized, like every other line in this file: it
    /// is written for the model, not shown to the wearer, and the screen has its own localized copy.
    ///
    /// Numbers are formatted here rather than through `StrengthProgressionCopy`, whose job is the wearer's
    /// locale — a German decimal comma inside a model prompt is a number the model may misread.
    private static func coachLine(for exercise: StrengthProgression.Exercise) -> String {
        func kg(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        if let reason = exercise.abstained {
            switch reason {
            case .tooFewSessions(let have, let need):
                return "\(exercise.name): only \(have) of \(need) readable sessions — NO estimate, say so if asked"
            case .noUsableSets:
                return "\(exercise.name): no set carried both a weight and a rep count — NO estimate"
            }
        }
        var parts: [String] = []
        if let current = exercise.currentE1rmKg, let date = exercise.currentDate {
            parts.append("est. 1RM \(kg(current)) kg on \(Repository.localDayKey(date))")
        }
        if let best = exercise.bestEverE1rmKg, let when = exercise.bestEverDate {
            parts.append("best \(kg(best)) kg (first reached \(Repository.localDayKey(when)))")
        }
        if let weight = exercise.topWorkingWeightKg, let reps = exercise.topWorkingReps {
            parts.append("top working set \(kg(weight)) kg x \(reps)")
        }
        for weeks in StrengthProgression.trendWindowsWeeks.sorted() {
            guard let trend = exercise.trends[weeks] else { continue }
            parts.append("\(weeks)w trend " + String(format: "%+.1f kg", trend.deltaKg))
        }
        if let stall = exercise.stall {
            let at = stall.stuckAtKg.map { " at \(kg($0)) kg" } ?? ""
            parts.append("STALLED: \(stall.sessions) sessions\(at) over \(stall.days) days with no new best")
        }
        if let suggestion = exercise.suggestion {
            let step = suggestion.step == .addWeight
                ? "add weight (\(suggestion.incrementKg.map { kg($0) } ?? "?") kg step)"
                : "add a rep"
            parts.append("next: \(kg(suggestion.weightKg)) kg x \(suggestion.reps) — \(step), "
                         + "range \(suggestion.repRangeLow)-\(suggestion.repRangeHigh)")
        } else {
            parts.append("no next-step suggestion this app can defend")
        }
        if exercise.excludedBodyweightSets > 0 {
            parts.append("\(exercise.excludedBodyweightSets) sets excluded (log records weight ADDED to "
                         + "bodyweight, absolute load unknown)")
        }
        return "\(exercise.name): " + parts.joined(separator: "; ")
    }

    static func block(repo: Repository) async -> String {
        var sections: [String] = []
        let today = Repository.localDayKey(Date())
        func dayKey(_ back: Int) -> String {
            Repository.localDayKey(Date().addingTimeInterval(-Double(back) * 86_400))
        }

        // 1. THE DREAM JOURNAL IS LAST, not here. It used to be the FIRST section, in front of the
        // journal, the water, the day, the quests and the level: several hundred characters of half-awake
        // prose at the top of the block a small model reads once, which is exactly the crowding-out that
        // makes it answer from the story instead of from the numbers. It is now built at the end of this
        // function, capped, and labelled with the night it belongs to. See `CoachDreamContext`.

        // 2. The journal itself, entry by entry, last seven days.
        let floor = dayKey(6)
        let journal = await repo.journalEntries(days: 8).filter { $0.day >= floor && $0.question != "Dream" }
        if !journal.isEmpty {
            var lines = ["JOURNAL (logged by them; yes/no, numbers, notes), newest first:"]
            for day in Set(journal.map(\.day)).sorted(by: >) {
                let items = journal.filter { $0.day == day }.map { e -> String in
                    var s = e.question + ": "
                    if let v = e.numericValue {
                        s += v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
                    } else {
                        s += e.answeredYes ? "yes" : "no"
                    }
                    if let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        s += " (\"" + String(notes.prefix(200)) + "\")"
                    }
                    return s
                }
                lines.append("  \(day): " + items.joined(separator: "; "))
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // 3. Water. (Food is left out on purpose: water is what they track.)
        var intake: [String] = []
        if HydrationStore.isEnabled {
            var water: [String] = []
            // PERF: the seven days + today in ONE range read per series, instead of two single-day reads
            // per day. Each day's figure is `hydrationTotal`'s exactly: manual + imported, each the day's
            // row or 0 (see `hydrationTotals`).
            let waterDays = (0..<7).map { dayKey($0) }
            let totals = await hydrationTotals(repo: repo, days: waterDays + [today])
            for key in waterDays {
                let ml = totals[key] ?? 0
                if ml > 0 { water.append("\(key) \(Int(ml)) ml") }
            }
            intake.append("  Water today: \(Int(totals[today] ?? 0)) ml of a "
                          + "\(repo.hydrationGoalML(profileSex: UserDefaults.standard.string(forKey: "profile.sex") ?? "")) ml goal")
            if !water.isEmpty { intake.append("  Water, last 7 days: " + water.joined(separator: ", ")) }
        }
        if !intake.isEmpty { sections.append((["WATER:"] + intake).joined(separator: "\n")) }

        // 4. The energy bank and the streaks, as Today shows them.
        var day: [String] = []
        // EVERY LINE IN THIS SECTION CARRIES ITS DAY. These four were the undated ones: an energy bank, a
        // streak and a stress curve stated without a date read as timeless facts, and the model then
        // offered them as an answer about tomorrow.
        if let e = CoachDaySnapshot.energy {
            day.append(String(format: "  Energy bank for %@ (today, so far): %.0f of %.0f left (spent %.0f on strain, %.0f on stress; %.0f back from calm). It resets at midnight and does not carry to another day.",
                              today, e.balance, e.opening, e.strainSpend, e.stressSpend, e.restReturn))
        }
        let running = CoachDaySnapshot.streaks.filter { $0.days > 0 }
        if !running.isEmpty {
            day.append("  Streaks as of \(today): " + running.map {
                "\($0.kind) \($0.days) days\($0.todaySecured ? " (today secured)" : " (today still open)")"
            }.joined(separator: ", "))
        }

        // 5. Stress now, and through the day.
        if let live = LiveStressMonitor.shared.current {
            day.append(String(format: "  Stress right now (the last 10 minutes of %@, at rest, 0-3): %.1f", today, live))
        }
        if let curve = await StressDayCurve.today(repo: repo) {
            let scored = curve.result.hours.compactMap { h -> String? in
                guard let level = h.level else { return nil }
                return String(format: "%02d:00 %.1f", h.hour, level)
            }
            if !scored.isEmpty {
                day.append("  Stress by hour on \(today) (0-3, local clock): " + scored.joined(separator: ", "))
            }
        }

        // 6. Meditation minutes, last seven days.
        let meditation = await repo.meditationMinutesByDay(days: 8)
        let sat = (0..<7).compactMap { back -> String? in
            guard let m = meditation[dayKey(back)], m > 0 else { return nil }
            return "\(dayKey(back)) \(Int(m.rounded())) min"
        }
        day.append("  Meditation, last 7 days: " + (sat.isEmpty ? "none" : sat.joined(separator: ", ")))
        if !day.isEmpty { sections.append((["THE DAY:"] + day).joined(separator: "\n")) }

        // 7. Quests: carried, and how the last two weeks' went.
        let quests = QuestStore.shared.quests.filter { $0.dayKey >= dayKey(13) }
        if !quests.isEmpty {
            var lines = ["QUESTS (last 14 days):"]
            for q in quests.sorted(by: { $0.createdAtMs > $1.createdAtMs }) {
                let state: String
                switch q.state {
                case .active: state = "in progress"
                case .offered: state = "offered, not yet accepted"
                case .completed: state = "completed"
                case .declined: state = "declined or expired unfinished"
                }
                // The wearer's own tasks say so: "they set this themselves" reads differently from a
                // directive the system issued.
                let origin = q.kind == .custom ? " (set by them)" : ""
                lines.append("  \(q.dayKey) \"\(q.title)\"\(origin): \(q.target) — \(state)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // 8. What the level is missing, VO₂max and strength.
        var body: [String] = []
        let missing = LevelBarModel.lastMissing
        if !missing.isEmpty {
            body.append("  The level is computed WITHOUT: " + missing.map(\.label).joined(separator: ", "))
        }
        var vo2 = await repo.series(key: Repository.noopVo2Key, source: "\(repo.deviceId)-noop", days: 120)
        if vo2.isEmpty { vo2 = await repo.series(key: "vo2max_est", source: "\(repo.deviceId)-noop", days: 120) }
        vo2.sort { $0.day < $1.day }
        if let last = vo2.last {
            var line = String(format: "  VO2max (the app's own estimate from runs, walks and weekly zones): %.1f ml/kg/min on %@",
                              last.value, last.day)
            if let first = vo2.first, first.day != last.day {
                line += String(format: " (%.1f on %@)", first.value, first.day)
            }
            body.append(line)
        }
        let strength = await repo.series(key: StrengthIndex.key, source: "lifting", days: 120).sorted { $0.day < $1.day }
        if let last = strength.last {
            var line = String(format: "  Strength index (best estimated 1RM over each lift's own median; 1.0 = typical): %.2f on %@",
                              last.value, last.day)
            if let first = strength.first, first.day != last.day {
                line += String(format: " (%.2f on %@)", first.value, first.day)
            }
            body.append(line)
        }
        if !body.isEmpty {
            sections.append((["LEVEL INPUTS (each figure is dated; the level itself is frozen on the morning "
                              + "of its date and today's activity shows up in TOMORROW's level):"] + body)
                .joined(separator: "\n"))
        }

        // 8b. Per-exercise progression — the SAME numbers the Progression section shows.
        //
        // Read through `StrengthProgressionSource`, not recomputed here, for the reason the energy bank is
        // read rather than recomputed: the wearer asks "how is my bench going" straight after looking at
        // that card, and a coach quoting a different figure than the screen is the error they notice first.
        // The abstentions travel too — an exercise with too few sessions is reported AS having too few,
        // so the model says so instead of estimating from the two it can see.
        if let store = await repo.storeHandle() {
            let progression = await StrengthProgressionSource.load(store: store)
            if !progression.isEmpty {
                var lines = ["PER-EXERCISE STRENGTH PROGRESSION (estimated one-rep max, Epley, from their "
                             + "logged sets of 1-\(StrengthProgression.maxReps) reps; stalled lifts first):"]
                for exercise in progression.prefix(coachProgressionLimit) {
                    lines.append("  " + coachLine(for: exercise))
                }
                if progression.count > coachProgressionLimit {
                    lines.append("  (\(progression.count - coachProgressionLimit) further exercises not listed)")
                }
                lines.append("  A suggestion above is double progression — reps to the top of their own "
                             + "observed range first, then ONE of their own observed weight increments. "
                             + "Never propose a bigger jump than the one stated.")
                sections.append(lines.joined(separator: "\n"))
            }
        }

        // 9. The bedroom and the lights.
        var home: [String] = []
        if let r = BedroomClimate.shared.latest {
            home.append("  (Everything under HOME is the state RIGHT NOW on \(today); none of it is a "
                        + "forecast for another day.)")
            // Judged for the window the day is in: focus (20–22.5 °C) by day, sleep (16–19.5 °C) from
            // the wind-down on. The same verdict the Today tile shows.
            let ctx = RoomClimatePlan.context(for: r)
            home.append(String(format: "  Bedroom now: %.1f °C, %.0f %% humidity — %@ window, fit %d/100 (%@). Next: %@ window from %@",
                               r.temperatureC, r.humidityPct, ctx.mode.label.lowercased(), ctx.score,
                               ctx.isGood ? "within target" : ctx.issues.joined(separator: " "),
                               ctx.nextMode.label.lowercased(),
                               ctx.nextStart.formatted(date: .omitted, time: .shortened)))
            let night = ClimateHistory.since(Date().addingTimeInterval(-14 * 3600)).filter {
                let h = Calendar.current.component(.hour, from: $0.at)
                return h >= 22 || h < 8
            }
            if let lo = night.map(\.temperatureC).min(), let hi = night.map(\.temperatureC).max() {
                home.append(String(format: "  Bedroom last night: %.1f–%.1f °C", lo, hi))
            }
        }
        let wiz = WizLightStore.shared
        if !wiz.bulbs.isEmpty {
            let on = wiz.bulbs.filter { wiz.pilots[$0.id]?.on == true }.count
            var line = "  WiZ lights: \(wiz.bulbs.count) connected, \(on) on"
            if wiz.wakeLightOn { line += String(format: "; morning daylight at %02d:%02d", wiz.wakeMinute / 60, wiz.wakeMinute % 60) }
            if wiz.windDownOn { line += String(format: "; evening wind-down at %02d:%02d", wiz.windDownMinute / 60, wiz.windDownMinute % 60) }
            home.append(line)
        }
        if !home.isEmpty { sections.append((["HOME:"] + home).joined(separator: "\n")) }

        // 10. The dream journal and the morning's answers — AFTER every figure above, for the reason
        // stated at section 1. Dated by the night that ended on the morning of the entry, capped per
        // entry and in total, oldest text dropped first. See `CoachDreamContext`.
        //
        // RIDES THE SAME CONSENT AS EVERYTHING ELSE IN THIS FILE: this block is only reached from
        // `buildFullContext()`, so with data access off no dream text is sent at all.
        let dreams = CoachDreamContext.block(entries: DreamJournalStore.shared.entries)
        if !dreams.isEmpty { sections.append(dreams) }

        return sections.joined(separator: "\n\n")
    }
}
