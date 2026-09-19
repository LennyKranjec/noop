import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge breakdown wiring (pure, testable)
//
// The fold-and-score wiring behind the "What shaped it" sheet, lifted out of the two views that had
// byte-identical private copies of it (TodayView.chargeBreakdown / CoupledView.chargeBreakdown). They
// differed only in which row they display and where their sleep-performance number comes from, both of
// which are inputs, so one function serves both.
//
// Extracted so it can be TESTED. Living inside a `View` struct as a private method meant the only way to
// exercise it was to render the view, so the iOS side of this path had no test at all while the Android
// twin did. Kotlin twin: `TodayScoring.recoveryChargeDrivers`.
//
// Pure: no SwiftUI state, no I/O, no store access. Nothing here invents a number. The drivers come from
// `RecoveryScorer.chargeDrivers` and the tier is SURFACED from `ScoreConfidence.charge` against the same
// folded HRV baseline the drivers scored with, so the header and the rows agree by construction.
enum ChargeBreakdownWiring {

    /// E7: UserDefaults key holding the respiration DEVICE-ERA cut (epoch seconds, 0 = none) the engine's
    /// Charge pass last used (`Baselines.deviceEraEpoch` over the per-night respiration SOURCE). The sheet
    /// only has merged `DailyMetric` rows — the source brand is gone by then — so it cannot derive the cut
    /// itself; the engine publishes it here. Absent = 0 = no cut, byte-identical to a single-brand history.
    static let respEraEpochKey = "noop.charge.respDeviceEraEpoch"

    /// The ordered Charge driver rows for `row` plus its confidence tier, folded from the visible `days`
    /// history, or nil when the night cannot honestly score (missing HRV or resting HR, or an HRV
    /// baseline that is not yet usable) so the sheet hides rather than showing fabricated rows.
    ///
    /// `sleepPerfPercent` is the Rest composite on a 0-100 scale, divided by 100 here to match
    /// `AnalyticsEngine`'s `sleepPerf` form, so the Sleep row scores against the headline's own input.
    ///
    /// The resting-HR and respiration baselines are passed only when usable. `RecoveryScorer` and
    /// `chargeDrivers` both apply that gate themselves since #1990, so these are belt-and-braces rather
    /// than load-bearing; they are kept because they say the intent at the call site, which is where a
    /// reader looks first.
    ///
    /// E7 — THE SAME EPOCHS AS THE HEADLINE. This folded with no epochs at all while the engine honours
    /// the manual HRV recalibration (`hrvBaselineEpoch`), the Charge-wide one (`recoveryBaselineEpoch`,
    /// resting HR + respiration) and the respiration device-era cut, so after a Recalibrate the rows were
    /// scored against a baseline the headline had thrown away. The epochs default to the persisted values
    /// the engine reads (nil = read them), and the fold is the engine's own point-in-time
    /// `foldHistoryAsOf`, so pre-epoch days get the same pre-epoch baseline too (E8).
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvEpoch: Double? = nil,
                          recoveryEpoch: Double? = nil,
                          respEraEpoch: Double? = nil) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        let hrvCut = hrvEpoch ?? Baselines.hrvBaselineEpoch()
        let recoveryCut = recoveryEpoch ?? Baselines.recoveryBaselineEpoch()
        let respCut = max(recoveryCut, respEraEpoch ?? UserDefaults.standard.double(forKey: respEraEpochKey))
        // PERF: one pass per series. The two private copies this replaces each re-folded the full history
        // per body evaluation of the open sheet; the guard above still runs before any fold.
        // F3: only the nights BEFORE this row's day, matching the engine's point-in-time Charge baseline
        // (the headline is no longer scored against a baseline holding its own night or later ones).
        // `foldHistoryAsOf` needs ascending keys; a merged `repo.days` is not guaranteed to be sorted.
        let history = days.filter { $0.day < row.day }.sorted { $0.day < $1.day }
        let keys = history.map(\.day)
        func fold(_ values: [Double?], _ cfg: MetricCfg, _ epoch: Double) -> BaselineState {
            Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch,
                                      asOf: [row.day])[row.day]
                ?? Baselines.foldHistory(values, cfg: cfg)
        }
        let hrvBase = fold(history.map(\.avgHrv), Baselines.hrvCfg, hrvCut)
        guard hrvBase.usable else { return nil }
        let rhrBase = fold(history.map { $0.restingHr.map(Double.init) }, Baselines.restingHRCfg, recoveryCut)
        let respBase = fold(history.map(\.respRateBpm), Baselines.respCfg, respCut)
        // E6: the HRV row is scored on ln(RMSSD) exactly as the headline is — both derive the ln baseline
        // from this same ms fold (no `hrvLnBaseline` passed on either side).
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: row.skinTempDevC)
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }
}
