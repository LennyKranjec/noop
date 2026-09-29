import Foundation
import WhoopStore
import StrandAnalytics

// StressDailyLog.swift — banking the day's non-activity high-stress minutes.
//
// Swift twin of the Android `com.noop.analytics.StressDailyStore`. `DaytimeStress` costs a whole day
// of heart rate and R-R to compute — three windowed reads and a scoring pass. That is affordable once,
// for today, on a screen that is showing it. It is not affordable a year of times inside a strip that
// has to paint in a frame, which is what a streak over the same figure would need.
//
// SO THE DAY'S RESULT IS WRITTEN DOWN when it is computed anyway, on the same generic metric-series
// seam hydration and meditation use, and the streak reads the series instead of recomputing it.
//
// A DAY BEFORE THIS EXISTED HAS NO ROW, and that is the honest state: it is unmeasured, not zero. The
// streak spans unmeasured days without counting them, so the figure simply starts accumulating from
// the first day the app saw — rather than awarding a streak for a year nobody measured.
//
// NON-ACTIVITY IS BY CONSTRUCTION. `DaytimeStress` masks ambulatory hours as exertion and leaves them
// unscored, so the banked minutes only ever count hours the wearer was still through. Nothing is
// subtracted here; there is nothing to subtract.
//
// THE KEYS ARE PART OF THE PARITY CONTRACT and must match `StressDailyStore.KEY` / `.SOURCE_ID` byte
// for byte, or an export from one platform lands in a different row on the other.

enum StressDailyLog {

    /// The generic metric-series key the day's high-stress minutes are banked under.
    static let key = "stress_high_min"

    /// Its own local-only source: this is a COMPUTED figure, not one any device reported.
    static let source = "stress-daily"

    /// The day's mean RMSSD over its still, scored waking hours.
    static let daytimeRmssdKey = "daytime_rmssd"

    /// Still, scored hours of R-R a banked `daytime_rmssd` needs before it is written down.
    ///
    /// ALIGNED WITH THE SCORING GATE. Daytime RMSSD off the wrist is artefact-dominated — hourly values
    /// swing ~40→430 ms as posture, motion and talking break the R-R stream — which is why
    /// `DaytimeStress.daytimeRMSSDScoringEnabled` keeps the quantity out of the live stress score
    /// entirely, and why `DaytimeStress.foldAggregates` refuses a daytime-RMSSD baseline until
    /// `Baselines.minNightsSeed` days have carried one. Banking used to have `!values.isEmpty` as its
    /// only guard, so a single hour of twenty beats was persisted as a day's "daytime calm" and read
    /// back by the level's focus part as if it were the whole day. Same quantity, same artefacts, so the
    /// same count of units has to back it. A day that does not clear it writes NO row, which is the
    /// honest state the series already has a meaning for: unmeasured, not calm.
    static let minRmssdHours = Baselines.minNightsSeed

    /// How far back the streak strip reads. A year of streak plus slack for a stale clock.
    static let lookbackDays = 400

    /// The day's daytime calm — mean RMSSD over its STILL, SCORED waking hours — or nil when too few of
    /// them carried R-R for the figure to mean anything (`minRmssdHours`). Masked and unscored hours are
    /// already excluded by `level != nil`.
    ///
    /// Pure and separate from the write so the gate is testable without a store, and so there is ONE
    /// place that decides what a bankable daytime RMSSD is.
    static func daytimeRmssdMean(hours: [DaytimeStress.HourPoint]) -> Double? {
        let values = hours.filter { $0.level != nil }.compactMap(\.rmssd)
        guard values.count >= minRmssdHours else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Persistence (Repository extension)

extension Repository {

    /// Write `minutes` for `day`, replacing whatever was there.
    ///
    /// REPLACES rather than accumulates: the figure is a recomputation of the whole day, so a second
    /// pass later in the afternoon is a better answer to the same question, not more of it.
    /// Best-effort — a failed write costs this day's row and nothing else, and the streak treats it as
    /// unmeasured.
    func bankStressMinutes(day: String, minutes: Int) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: day, key: StressDailyLog.key, value: Double(minutes))],
            deviceId: StressDailyLog.source)
    }

    /// Bank the day's daytime calm: mean RMSSD over the still, scored waking hours.
    ///
    /// The level's focus part reads it (`LevelMetric.daytimeRmssd`). Written whenever the day's curve is
    /// scored, REPLACING the day's value, so the figure the frozen level reads tomorrow is the whole of
    /// today. Nothing is written until at least `StressDailyLog.minRmssdHours` still, scored hours
    /// carried R-R — see that constant for why one hour is not a day's calm.
    func bankDaytimeRmssd(hours: [DaytimeStress.HourPoint], day: Date = Date()) async {
        guard let mean = StressDailyLog.daytimeRmssdMean(hours: hours),
              let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: Repository.localDayKey(day), key: StressDailyLog.daytimeRmssdKey, value: mean)],
            deviceId: StressDailyLog.source)
    }

    /// Every banked day's daytime calm.
    func bankedDaytimeRmssd() async -> [String: Double] {
        let rows = await series(key: StressDailyLog.daytimeRmssdKey, source: StressDailyLog.source,
                                days: StressDailyLog.lookbackDays)
        var out: [String: Double] = [:]
        for row in rows { out[row.day] = row.value }
        return out
    }

    /// Every banked day in the lookback, keyed by local day. Empty when nothing has been banked.
    func bankedStressMinutes(lookbackDays: Int = StressDailyLog.lookbackDays) async -> [String: Double] {
        let rows = await series(key: StressDailyLog.key, source: StressDailyLog.source, days: lookbackDays)
        var out: [String: Double] = [:]
        for row in rows { out[row.day] = row.value }
        return out
    }
}
