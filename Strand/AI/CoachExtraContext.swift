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

    static func block(repo: Repository) async -> String {
        var sections: [String] = []
        let today = Repository.localDayKey(Date())
        func dayKey(_ back: Int) -> String {
            Repository.localDayKey(Date().addingTimeInterval(-Double(back) * 86_400))
        }

        // 1. The dream journal and the morning answers, last seven mornings.
        let dreams = DreamJournalStore.shared.entries.prefix(7)
        if !dreams.isEmpty {
            var lines = ["DREAM JOURNAL AND MORNING ANSWERS (their own words and taps, newest first):"]
            for entry in dreams {
                var line = "  \(entry.day): "
                let answers = DreamJournalStore.summary(entry)
                line += answers.isEmpty ? "no answers" : answers.joined(separator: "; ")
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { line += ". Dream: \"" + String(text.prefix(280)) + "\"" }
                lines.append(line)
            }
            sections.append(lines.joined(separator: "\n"))
        }

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
        if UserDefaults.standard.bool(forKey: HydrationStore.enabledKey) {
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
        if let e = CoachDaySnapshot.energy {
            day.append(String(format: "  Energy bank: %.0f of %.0f left (spent %.0f on strain, %.0f on stress; %.0f back from calm)",
                              e.balance, e.opening, e.strainSpend, e.stressSpend, e.restReturn))
        }
        let running = CoachDaySnapshot.streaks.filter { $0.days > 0 }
        if !running.isEmpty {
            day.append("  Streaks: " + running.map {
                "\($0.kind) \($0.days) days\($0.todaySecured ? " (today secured)" : " (today still open)")"
            }.joined(separator: ", "))
        }

        // 5. Stress now, and through the day.
        if let live = LiveStressMonitor.shared.current {
            day.append(String(format: "  Stress now (last 10 min, at rest, 0-3): %.1f", live))
        }
        if let curve = await StressDayCurve.today(repo: repo) {
            let scored = curve.result.hours.compactMap { h -> String? in
                guard let level = h.level else { return nil }
                return String(format: "%02d:00 %.1f", h.hour, level)
            }
            if !scored.isEmpty { day.append("  Stress by hour today (0-3): " + scored.joined(separator: ", ")) }
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
        if !body.isEmpty { sections.append((["LEVEL INPUTS:"] + body).joined(separator: "\n")) }

        // 9. The bedroom and the lights.
        var home: [String] = []
        if let r = BedroomClimate.shared.latest {
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

        return sections.joined(separator: "\n\n")
    }
}
