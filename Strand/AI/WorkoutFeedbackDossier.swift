import Foundation
import WhoopStore
import StrandAnalytics

/// The hidden context behind a Today "AI feedback" tap: one workout, written out in full for the coach.
///
/// The wearer sees a short question in the chat ("Analyse my Running on 18 Sep"); the model sees this
/// dossier alongside it, rebuilt into the data context on every turn of the thread (the same channel
/// as `AICoachEngine.QuestContext`), so a follow-up like "and the pacing?" still has the session in view.
///
/// PURE. Every value is handed in by `WorkoutFeedbackGatherer`, so the arithmetic (drift, peak windows,
/// pace, the comparison against recent sessions) and the wording are unit-testable with no store.
/// Missing values are written as "not recorded" rather than left out, so the model never reads an absent
/// field as a zero.
enum WorkoutFeedbackDossier {

    /// One heart-rate point over the session: a bucket mean (the same series the workout detail charts).
    struct HRPoint: Equatable {
        let ts: Int
        let bpm: Double
    }

    /// The day the workout sits in, as the rest of the app scores it.
    struct DayContext: Equatable {
        var dayKey: String
        /// NOOP Charge 0–100.
        var charge: Double?
        /// NOOP day Effort 0–100.
        var dayEffort: Double?
        /// NOOP Rest 0–100.
        var rest: Double?
        /// WHOOP's own recovery %, when WHOOP scored the day.
        var whoopRecovery: Double?
        /// The day's recommended Effort band (0–100), from the day's recovery.
        var effortTargetLow: Double?
        var effortTargetHigh: Double?
        /// The night before (the sleep that ended that morning).
        var sleepMin: Double?
        var deepMin: Double?
        var remMin: Double?
        var sleepEfficiency: Double?   // stored 0–1 or 0–100; normalised on output
        var hrv: Double?
        var restingHr: Int?
    }

    struct Input {
        var sport: String              // display name
        var source: String
        var startTs: Int
        var endTs: Int
        var durationS: Double?
        var energyKcal: Double?
        var avgHr: Int?
        var maxHr: Int?
        /// Session Effort on the 0–100 scale (`WorkoutRow.strain`).
        var effort: Double?
        var distanceM: Double?
        var steps: Int?
        var notes: String?
        var isRecovery: Bool
        /// Bucketed HR over the session window, any order.
        var hr: [HRPoint]
        /// Z1…Z5 minutes, or nil when unknown.
        var zoneMinutes: [Double]?
        var zonesFromImport: Bool
        /// The wearer's display/training zones (Karvonen %HRR unless custom).
        var zoneSet: HRZoneSet?
        /// The HRmax Effort is scored against (override else age formula).
        var effortHRmax: Int?
        var hrRecovery: HeartRateRecovery.Result?
        /// The stress (0–3) of the opening and closing five minutes, as the Today tile shows it.
        var stressStart: Double?
        var stressEnd: Double?
        /// GPS route recorded on this device, if any.
        var routeDistanceM: Double?
        var routePointCount: Int
        var day: DayContext?
        /// Workouts from the 14 days before this one (any order; this session is filtered out).
        var recent: [WorkoutRow]
        var imperial: Bool
        var timeZone: TimeZone
    }

    // MARK: - The question the wearer sees

    /// The short, visible chat line. Localized, so a German wearer asks (and is answered) in German.
    static func visiblePrompt(sport: String, start: Date, locale: Locale = AppLanguage.activeLocale) -> String {
        let date = start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return String(localized: "Analyse my \(sport) on \(date)")
    }

    // MARK: - The dossier

    static func build(_ input: Input) -> String {
        var s = "THE WORKOUT THIS CONVERSATION IS ABOUT.\n"
        s += "The user tapped \"AI feedback\" on this session in Today. Their question is about THIS workout "
        s += "unless they plainly change the subject. Everything below is measured on-device.\n"
        s += "Answer in three short parts: (1) what went well, (2) what to improve, (3) one concrete "
        s += "suggestion for the next session of this kind (duration, intensity or zone target, when). "
        s += "Cite their actual numbers, compare with their recent sessions where it helps, and keep it "
        s += "concise: short paragraphs and bullets, no tables.\n"

        // Session
        s += "\nSession:\n"
        s += "- Sport: \(input.sport)" + (input.isRecovery ? " (a RECOVERY session: judge it by what it did to stress, not by effort)" : "") + "\n"
        s += "- Source: \(input.source.isEmpty ? "unknown" : input.source)\n"
        s += "- Start: \(timestamp(input.startTs, input.timeZone)), end: \(timestamp(input.endTs, input.timeZone))\n"
        let span = max(input.endTs - input.startTs, 0)
        let recorded = input.durationS ?? Double(span)
        s += "- Duration: \(minutes(recorded))"
        if let d = input.durationS, abs(d - Double(span)) >= 60 {
            s += " recorded (wall-clock span \(minutes(Double(span))), so roughly \(minutes(max(Double(span) - d, 0))) paused)"
        }
        s += "\n"
        s += "- Effort (0-100): " + (input.effort.map { String(format: "%.1f", $0) } ?? "not recorded")
        if let e = input.effort {
            s += String(format: " (= %.1f on the WHOOP 0-21 scale the app may display)", UnitFormatter.effortValue(e, scale: .whoop))
        }
        if let day = input.day, let de = day.dayEffort {
            s += String(format: "; the day's total Effort was %.1f", de)
            s += String(format: " (= %.1f of 21)", UnitFormatter.effortValue(de, scale: .whoop))
            s += " (Effort is not additive, the day total includes all activity)"
        }
        s += "\n"
        s += "- Calories: " + (input.energyKcal.map { "\(Int($0.rounded())) kcal" } ?? "not recorded") + "\n"
        s += "- Avg HR: " + (input.avgHr.map { "\($0) bpm" } ?? "not recorded")
        s += ", max HR: " + (input.maxHr.map { "\($0) bpm" } ?? "not recorded") + "\n"
        if let steps = input.steps, steps > 0 { s += "- Steps: \(steps)\n" }
        if let notes = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            s += "- User's note: \(notes)\n"
        }

        // Distance / pace / route
        let distance = input.distanceM.flatMap { $0 > 0 ? $0 : nil } ?? input.routeDistanceM.flatMap { $0 > 0 ? $0 : nil }
        if let distance {
            s += "- Distance: \(distanceText(distance, imperial: input.imperial))"
            if let pace = paceText(distanceM: distance, seconds: recorded, imperial: input.imperial) {
                s += ", average pace \(pace)"
            }
            if let kmh = speedKmh(distanceM: distance, seconds: recorded) {
                s += input.imperial ? String(format: ", %.1f mph", kmh / 1.609344) : String(format: ", %.1f km/h", kmh)
            }
            s += "\n"
        }
        if let rd = input.routeDistanceM, rd > 0, input.routePointCount >= 2 {
            s += "- GPS route recorded on the phone: \(distanceText(rd, imperial: input.imperial)), \(input.routePointCount) points\n"
        }

        // Stress delta (the Today tile's figure)
        if input.stressStart != nil || input.isRecovery {
            if let a = input.stressStart, let b = input.stressEnd {
                s += String(format: "- Stress (0-3 scale) first 5 min %.1f -> last 5 min %.1f, change %+.1f (negative = calmer)\n",
                            a, b, b - a)
            } else {
                s += "- Stress change: not measurable (needs the strap's heart rate through the session)\n"
            }
        }

        // Heart rate detail
        s += "\nHeart rate over the session:\n"
        let points = input.hr.sorted { $0.ts < $1.ts }
        if points.count < 4 {
            s += "- No usable heart-rate trace for this window.\n"
        } else {
            if let d = drift(points) {
                s += String(format: "- Drift: first half avg %.0f bpm, second half avg %.0f bpm (%+.1f%%)\n",
                            d.first, d.second, d.percent)
            }
            for w in [60, 300, 1200] {
                guard let p = peakWindow(points, seconds: w) else { continue }
                s += "- Best \(w / 60)-min average: \(Int(p.avg.rounded())) bpm, starting \(p.offsetS / 60) min in\n"
            }
        }
        if let z = input.zoneMinutes, z.count == 5 {
            let total = z.reduce(0, +)
            s += "- Time in zones" + (input.zonesFromImport ? " (imported split)" : " (from the strap's heart rate)") + ":"
            let ranges = input.zoneSet?.bpmRanges ?? []
            var parts: [String] = []
            for i in 0..<5 {
                var p = "Z\(i + 1)"
                if i < ranges.count { p += " \(ranges[i].lower)-\(ranges[i].upper)" }
                let pct = total > 0 ? Int((z[i] / total * 100).rounded()) : 0
                p += ": \(Int(z[i].rounded())) min (\(pct)%)"
                parts.append(p)
            }
            s += " " + parts.joined(separator: "; ") + "\n"
        } else {
            s += "- Time in zones: not available\n"
        }
        if let r = input.hrRecovery, r.hasMeasurement {
            var p = ["peak at the end \(r.endHR) bpm"]
            if let v = r.after1Minute { p.append("1 min after \(v)") }
            if let v = r.after2Minutes { p.append("2 min after \(v)") }
            if let v = r.after5Minutes { p.append("5 min after \(v)") }
            s += "- Heart-rate recovery: " + p.joined(separator: ", ") + "\n"
        }

        // The user's zones
        s += "\nThe user's heart-rate profile:\n"
        if let zs = input.zoneSet {
            s += "- Zone HRmax \(Int(zs.maxHR.rounded())) bpm (\(zs.source))"
            if let r = zs.restingHR { s += ", zone resting HR \(Int(r.rounded())) bpm (Karvonen / heart-rate reserve zones)" }
            s += "\n"
            let r = zs.bpmRanges.map { "Z\($0.zone) \($0.lower)-\($0.upper)" }.joined(separator: ", ")
            s += "- Zones: \(r)\n"
        } else {
            s += "- Zones: unknown\n"
        }
        if let m = input.effortHRmax { s += "- HRmax used for Effort scoring: \(m) bpm\n" }

        // The day
        s += "\nThat day:\n"
        if let d = input.day {
            s += "- Day: \(d.dayKey)\n"
            s += "- Charge (0-100): \(whole(d.charge))"
            if let w = d.whoopRecovery { s += ", WHOOP recovery \(Int(w.rounded()))%" }
            s += ", Rest (0-100): \(whole(d.rest))\n"
            if let lo = d.effortTargetLow, let hi = d.effortTargetHigh {
                s += "- Recommended day Effort band from that recovery: \(Int(lo.rounded()))-\(Int(hi.rounded()))\n"
            } else {
                s += "- Recommended day Effort band: unknown (no recovery score)\n"
            }
            var sleep = "- Sleep the night before: " + (d.sleepMin.map { String(format: "%.1f h", $0 / 60) } ?? "not recorded")
            if let v = d.deepMin { sleep += String(format: ", deep %.1f h", v / 60) }
            if let v = d.remMin { sleep += String(format: ", REM %.1f h", v / 60) }
            if let e = d.sleepEfficiency { sleep += ", efficiency \(Int((e <= 1 ? e * 100 : e).rounded()))%" }
            s += sleep + "\n"
            s += "- Overnight HRV: " + (d.hrv.map { "\(Int($0.rounded())) ms" } ?? "not recorded")
            s += ", resting HR: " + (d.restingHr.map { "\($0) bpm" } ?? "not recorded") + "\n"
        } else {
            s += "- No day scores available.\n"
        }

        // Comparison
        s += "\n" + comparison(input)
        return s
    }

    // MARK: - Comparison with the last 14 days

    static func comparison(_ input: Input) -> String {
        let windowStart = input.startTs - 14 * 86_400
        let prior = input.recent
            .filter { $0.startTs >= windowStart && $0.startTs < input.startTs }
            .sorted { $0.startTs > $1.startTs }
        guard !prior.isEmpty else { return "Previous 14 days: no other workouts recorded.\n" }
        let key = normalisedSport(input.sport)
        let same = prior.filter { normalisedSport(WorkoutSource.displaySport($0.sport)) == key }
        var s = "Previous 14 days: \(prior.count) workout(s), \(same.count) of them \(input.sport).\n"
        if !same.isEmpty {
            let effs = same.compactMap(\.strain)
            let hrs = same.compactMap(\.avgHr).map(Double.init)
            let durs = same.map { ($0.durationS ?? Double(max($0.endTs - $0.startTs, 0))) / 60 }
            var avg = "- Same-sport averages:"
            avg += " duration \(Int((durs.reduce(0, +) / Double(durs.count)).rounded())) min"
            if !effs.isEmpty { avg += String(format: ", Effort %.1f", effs.reduce(0, +) / Double(effs.count)) }
            if !hrs.isEmpty { avg += ", avg HR \(Int((hrs.reduce(0, +) / Double(hrs.count)).rounded())) bpm" }
            s += avg + "\n"
            for w in same.prefix(6) { s += "  " + line(w, input) + "\n" }
        }
        let others = prior.filter { normalisedSport(WorkoutSource.displaySport($0.sport)) != key }
        if !others.isEmpty {
            s += "- Other sessions:\n"
            for w in others.prefix(6) { s += "  " + line(w, input) + "\n" }
        }
        return s
    }

    private static func line(_ w: WorkoutRow, _ input: Input) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        var p = ["\(dateOnly(w.startTs, input.timeZone)) \(WorkoutSource.displaySport(w.sport))", minutes(secs)]
        if let e = w.strain { p.append(String(format: "Effort %.1f", e)) }
        if let hr = w.avgHr { p.append("avg HR \(hr)") }
        if let d = w.distanceM, d > 0 {
            p.append(distanceText(d, imperial: input.imperial))
            if let pace = paceText(distanceM: d, seconds: secs, imperial: input.imperial) { p.append(pace) }
        }
        return p.joined(separator: ", ")
    }

    private static func normalisedSport(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }
    }

    // MARK: - Pure arithmetic (tested)

    /// Mean HR of the first half of the session against the second, split at the time midpoint.
    /// Nil with fewer than two points in either half.
    static func drift(_ points: [HRPoint]) -> (first: Double, second: Double, percent: Double)? {
        let p = points.sorted { $0.ts < $1.ts }
        guard let a = p.first?.ts, let b = p.last?.ts, b > a else { return nil }
        let mid = a + (b - a) / 2
        let first = p.filter { $0.ts < mid }.map(\.bpm)
        let second = p.filter { $0.ts >= mid }.map(\.bpm)
        guard first.count >= 2, second.count >= 2 else { return nil }
        let f = first.reduce(0, +) / Double(first.count)
        let s = second.reduce(0, +) / Double(second.count)
        guard f > 0 else { return nil }
        return (f, s, (s - f) / f * 100)
    }

    /// The highest mean HR over any `seconds`-long window of the trace, and where it starts (seconds from
    /// the first point). Nil when the trace is shorter than the window.
    static func peakWindow(_ points: [HRPoint], seconds: Int) -> (avg: Double, offsetS: Int)? {
        let p = points.sorted { $0.ts < $1.ts }
        guard seconds > 0, p.count >= 2, let first = p.first?.ts, let last = p.last?.ts else { return nil }
        // A bucket's ts stands for its whole bucket, so the trace effectively ends one spacing after the
        // last point. Using the median spacing keeps a 60-min session's "best 60 min" answerable.
        let gaps = zip(p.dropFirst(), p).map { $0.ts - $1.ts }.filter { $0 > 0 }.sorted()
        let step = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        guard last + step - first >= seconds else { return nil }
        var best: (avg: Double, offsetS: Int)?
        var j = 0
        var sum = 0.0
        for i in 0..<p.count {
            if j < i { j = i; sum = 0 }
            while j < p.count && p[j].ts < p[i].ts + seconds { sum += p[j].bpm; j += 1 }
            // Only full windows count.
            if p[i].ts + seconds > last + step { break }
            let n = j - i
            if n > 0 {
                let avg = sum / Double(n)
                if best == nil || avg > best!.avg { best = (avg, p[i].ts - first) }
            }
            sum -= p[i].bpm
        }
        return best
    }

    /// Average pace as "5:12 /km" (or "/mi"), nil when distance or time is unusable.
    static func paceText(distanceM: Double, seconds: Double, imperial: Bool) -> String? {
        guard distanceM >= 100, seconds > 0 else { return nil }
        let unit = imperial ? 1_609.344 : 1_000.0
        let perUnit = seconds / (distanceM / unit)
        guard perUnit.isFinite, perUnit < 3_600 else { return nil }
        let total = Int(perUnit.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60) + (imperial ? " /mi" : " /km")
    }

    static func speedKmh(distanceM: Double, seconds: Double) -> Double? {
        guard distanceM > 0, seconds > 0 else { return nil }
        let v = distanceM / seconds * 3.6
        return v.isFinite ? v : nil
    }

    static func distanceText(_ m: Double, imperial: Bool) -> String {
        imperial ? String(format: "%.2f mi", m / 1_609.344) : String(format: "%.2f km", m / 1_000)
    }

    // MARK: - Formatting

    private static func minutes(_ seconds: Double) -> String { "\(Int((seconds / 60).rounded())) min" }

    private static func whole(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "not recorded" }

    private static func timestamp(_ ts: Int, _ tz: TimeZone) -> String {
        formatter("yyyy-MM-dd HH:mm", tz).string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func dateOnly(_ ts: Int, _ tz: TimeZone) -> String {
        formatter("yyyy-MM-dd", tz).string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }
}
