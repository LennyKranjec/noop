import Foundation
import StrandAnalytics
import WhoopStore

// WindowStress.swift — stress over a few minutes, and what a recovery session did to it.
//
// ONE READING, THREE SURFACES. The live stress on the lock-screen strip, the live change during a
// meditation on the Live Activity, and the before/after on a finished session in Today's list are all
// the same question — how stressed over THESE minutes, against the day's own calm reference — so they
// share one function rather than three windows that could disagree about the same minutes.
//
// FIVE MINUTES A SIDE FOR A SESSION. Five minutes is the standard short-term HRV window, and it keeps the
// start and end readings apart on any session of ten minutes or more: the opening five are how the
// wearer arrived, the closing five are how they left.

@MainActor
enum WindowStress {

    /// The live window: the last ten minutes, the same span the Today tile reads.
    static let liveWindowSeconds = 10 * 60

    /// Stress (0–3) over `[from, to]`, or nil when there is too little heart rate, the wearer was moving,
    /// or the day has no scored hour yet to measure against.
    static func level(repo: Repository, from: Int, to: Int,
                      dayHours: [DaytimeStress.HourPoint]) async -> Double? {
        guard to > from, !dayHours.isEmpty else { return nil }
        let hr = await repo.hrSamples(from: from, to: to, limit: 5_000)
        guard hr.count >= DaytimeStress.liveMinHRSamples else { return nil }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 10_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 6_000)
        return await Task.detached(priority: .utility) {
            DaytimeStress.live(hr: hr, rr: rr, gravity: gravity, dayHours: dayHours)
        }.value
    }

    /// Stress over the last ten minutes, against today's hours.
    static func now(repo: Repository, dayHours: [DaytimeStress.HourPoint]) async -> Double? {
        let to = Int(Date().timeIntervalSince1970)
        return await level(repo: repo, from: to - liveWindowSeconds, to: to, dayHours: dayHours)
    }

    /// Past days' scored hours, kept for the session: a day that is over does not rescore differently.
    private static var hoursByDay: [String: [DaytimeStress.HourPoint]] = [:]

    /// The day's scored hours — the calm reference a window on that day is measured against.
    ///
    /// Today's come from the shared curve (memoised on the heart-rate fingerprint). A past day is scored
    /// once, off the main actor, and kept.
    static func dayHours(repo: Repository, for date: Date,
                         calendar: Calendar = .current) async -> [DaytimeStress.HourPoint] {
        let key = Repository.localDayKey(date)
        if key == Repository.localDayKey(Date()) {
            return await StressDayCurve.today(repo: repo)?.result.hours ?? []
        }
        if let hit = hoursByDay[key] { return hit }
        let start = calendar.startOfDay(for: date)
        let from = Int(start.timeIntervalSince1970)
        let to = from + 86_400
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            hoursByDay[key] = []
            return []
        }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
        let tz = TimeZone.current.secondsFromGMT(for: date)
        let result = await runUnescalated {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, mode: .dayRelative)
        }
        hoursByDay[key] = result.hours
        return result.hours
    }
}

/// What a recovery session did to stress: the opening five minutes against the closing five.
@MainActor
enum WorkoutStressDelta {

    static let windowSeconds = 5 * 60

    struct Delta: Equatable {
        let start: Double
        let end: Double
        /// Negative is calmer.
        var change: Double { end - start }
    }

    /// Finished sessions are kept: the minutes they cover do not change. Keyed by start and sport; an
    /// empty entry records a session that could not be read, so it is not re-scored on every refresh.
    private static let storeKey = "workout.stressDelta.v1"

    static func key(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    private static var store: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storeKey) }
    }

    /// The session's before/after, or nil when either end could not be read.
    static func compute(repo: Repository, row: WorkoutRow) async -> Delta? {
        let k = key(row)
        if let stored = store[k] {
            return stored.count == 2 ? Delta(start: stored[0], end: stored[1]) : nil
        }
        guard row.endTs - row.startTs >= 2 * windowSeconds else { return nil }
        let hours = await WindowStress.dayHours(repo: repo, for: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        let start = await WindowStress.level(repo: repo, from: row.startTs, to: row.startTs + windowSeconds,
                                             dayHours: hours)
        let end = await WindowStress.level(repo: repo, from: row.endTs - windowSeconds, to: row.endTs,
                                           dayHours: hours)
        // Only a session well over is written down either way: the strap may still be uploading the
        // last minutes of one that just ended.
        let settled = Int(Date().timeIntervalSince1970) - row.endTs > 30 * 60
        if let start, let end {
            if settled { store[k] = [start, end] }
            return Delta(start: start, end: end)
        }
        if settled { store[k] = [] }
        return nil
    }
}

extension WorkoutCatalog {
    /// Whether a session is RECOVERY rather than load: sitting, breathing, stretching, heat, cold.
    ///
    /// Such a session is judged by what it did to stress, not by the effort it cost — a meditation's
    /// effort is near zero by design, and showing it as a weak workout reads the session backwards.
    static func isRecovery(_ sport: String) -> Bool {
        let s = sport.lowercased()
        let words = ["meditat", "mindful", "breath", "stretch", "recovery", "sauna", "cold plunge",
                     "ice bath", "massage", "nap", "relax", "yoga nidra", "foam roll"]
        return words.contains { s.contains($0) }
    }
}
