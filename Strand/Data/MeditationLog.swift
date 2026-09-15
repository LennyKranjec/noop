import Foundation
import WhoopStore

// MeditationLog.swift — the meditation log's storage contract.
//
// Swift twin of the Android `MeditationStore`. One row per local day holding the MINUTES meditated on
// it, on the same generic metric-series seam hydration uses — same table, same (source, day, key)
// uniqueness, no schema change.
//
// THE KEYS ARE PART OF THE PARITY CONTRACT. A wearer who exports on one platform and imports on the
// other must land on the same rows, so the source id and the series key are spelled out here and must
// match `MeditationStore.SOURCE_ID` / `MeditationStore.KEY` byte for byte.
//
// MINUTES, NOT A TICK. The level only asks whether a day had a meditation, but the Focus screen shows
// the total ever sat, and a boolean cannot be summed into one. Storing the duration gives both: the sum
// is the headline, and "was there one" is "is the figure above zero".
//
// THE THREE-DAY WINDOW IS A WINDOW, NOT A STREAK. `daysInWindow` counts the days in the last three that
// have any minutes at all, which is exactly the figure the level's focus term multiplies by. It slides:
// a day drops out when it falls past the third, which is what makes the three circles on screen fill
// and empty rather than fill and stay.

enum MeditationLog {

    /// The generic metric-series key the day's minutes are banked under.
    static let key = "meditation_min"

    /// Its own local-only source, so it is never confused with an imported or computed metric.
    static let source = "meditation"

    /// How many days the level's focus term looks back over. Three, matching every other window.
    static let windowDays = 3

    /// A session shorter than this is not logged: a mis-tap should not light the day's circle.
    static let minSessionSeconds = 30

    /// Whether a session of `seconds` is long enough to store.
    ///
    /// Pure, and separate from any write, so the threshold can be tested without a database behind it —
    /// this is the decision that once made the Android button look broken, and it is worth its own test.
    static func isLoggable(seconds: Int) -> Bool { seconds >= minSessionSeconds }

    /// How many days in a window carried a meditation.
    static func countDays(window: [Double]) -> Int { window.filter { $0 > 0 }.count }

    /// What a `log` actually did, so the screen can say it rather than appear to do nothing.
    enum Outcome {
        /// Stored. The day's circle lights and the total moves.
        case logged
        /// Under `minSessionSeconds`. Deliberately not stored — and deliberately REPORTED.
        case tooShort
        /// The write itself failed. Rare, and the one case the wearer can do nothing about.
        case failed
    }

    /// The outcome, and the day's total after it.
    struct LogResult {
        let outcome: Outcome
        let dayMinutes: Double
    }
}

// MARK: - Persistence (Repository extension)
//
// A DAY ACCUMULATES. Two sessions on one day add up rather than the second replacing the first — the
// stopwatch logs what was actually sat, and someone who sits twice has meditated twice. The tall
// table holds one row per (deviceId, day, key), so a write reads the day's running total and
// re-upserts the sum, exactly as hydration does.

extension Repository {

    /// Today's local calendar day, as the rows are keyed.
    var meditationToday: String { Repository.localDayKey(Date()) }

    /// Minutes meditated on `day`. Zero when nothing was logged — here that genuinely means none.
    func meditationMinutes(day: String? = nil) async -> Double {
        let key = day ?? meditationToday
        guard let store = await storeHandle() else { return 0 }
        let pts = (try? await store.metricSeries(deviceId: MeditationLog.source,
                                                 key: MeditationLog.key,
                                                 from: key, to: key)) ?? []
        return pts.last?.value ?? 0
    }

    /// Every minute ever logged. The headline figure on the Focus screen.
    func meditationLifetimeMinutes() async -> Double {
        await series(key: MeditationLog.key, source: MeditationLog.source, fullHistory: true)
            .reduce(0) { $0 + $1.value }
    }

    /// Minutes per day for the `windowDays` ending `asOf`, oldest first. Always that many entries.
    func meditationWindow(asOf: Date = Date(), calendar: Calendar = .current) async -> [Double] {
        var byDay: [String: Double] = [:]
        if let store = await storeHandle() {
            let from = calendar.date(byAdding: .day, value: -(MeditationLog.windowDays - 1), to: asOf) ?? asOf
            let pts = (try? await store.metricSeries(
                deviceId: MeditationLog.source,
                key: MeditationLog.key,
                from: Repository.localDayKey(from),
                to: Repository.localDayKey(asOf))) ?? []
            for p in pts { byDay[p.day] = p.value }
        }
        return (0..<MeditationLog.windowDays).reversed().map { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: asOf) else { return 0 }
            return byDay[Repository.localDayKey(date)] ?? 0
        }
    }

    /// How many of the last `windowDays` days had a meditation, 0–3.
    ///
    /// The figure the level's focus term multiplies by. It SLIDES: a day drops out of the count when it
    /// falls past the third, which is why the circles on screen empty as well as fill.
    func meditationDaysInWindow(asOf: Date = Date(), calendar: Calendar = .current) async -> Int {
        MeditationLog.countDays(window: await meditationWindow(asOf: asOf, calendar: calendar))
    }

    /// Add `seconds` of meditation to `day`.
    ///
    /// A session under `minSessionSeconds` is dropped: starting and immediately stopping the timer is a
    /// mis-tap, and letting it light the day's circle would put a meditation into the level that nobody
    /// sat. It is dropped OUT LOUD, though — a short session that silently returned the unchanged total
    /// looked exactly like a broken button, which is how it was reported on the Android lane.
    @discardableResult
    func logMeditation(seconds: Int, day: String? = nil) async -> MeditationLog.LogResult {
        let key = day ?? meditationToday
        guard MeditationLog.isLoggable(seconds: seconds) else {
            return .init(outcome: .tooShort, dayMinutes: await meditationMinutes(day: key))
        }
        let next = await meditationMinutes(day: key) + Double(seconds) / 60
        let ok = await writeMeditation(day: key, minutes: next)
        return .init(outcome: ok ? .logged : .failed, dayMinutes: await meditationMinutes(day: key))
    }

    /// Throw away `day`'s meditation entirely.
    ///
    /// Clears the DAY rather than the last session, because the store holds a day's total and
    /// subtracting a session it does not remember would be arithmetic on a guess.
    func clearMeditation(day: String? = nil) async {
        _ = await writeMeditation(day: day ?? meditationToday, minutes: 0)
    }

    /// Store `day`'s total. True when it landed.
    ///
    /// The result is RETURNED rather than swallowed. A failure that goes nowhere turns a broken write
    /// into a button that does nothing, and the wearer cannot tell that apart from a button that was
    /// never wired up.
    private func writeMeditation(day: String, minutes: Double) async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            _ = try await store.upsertMetricSeries(
                [MetricPoint(day: day, key: MeditationLog.key, value: minutes)],
                deviceId: MeditationLog.source)
            return true
        } catch {
            return false
        }
    }
}
