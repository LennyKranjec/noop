import XCTest
@testable import StrandAnalytics

/// F3 — `Baselines.foldHistoryAsOf`: each scored day D gets the baseline as it stood after night D−1.
///
/// The bug it replaces: pass 2 folded the whole history up to the newest night and re-scored every day in
/// the window against that ONE final state, so a day's Charge was measured against a baseline containing
/// its own night and every later one, and a stored past score moved whenever a new night arrived.
final class BaselinesAsOfTests: XCTestCase {

    private let keys = (1...12).map { String(format: "2026-03-%02d", $0) }
    private let values: [Double?] = [62, 58, nil, 65, 60, 55, 70, 61, nil, 57, 64, 59]

    /// The contract: the as-of state for D equals the plain epoch-aware fold over the nights before D.
    func testAsOfEqualsFoldOverStrictlyEarlierNights() {
        let asOf = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: Baselines.hrvCfg,
                                             baselineEpoch: 0, asOf: keys)
        for (i, day) in keys.enumerated() {
            let expected = Baselines.foldHistory(Array(values[..<i]), dayKeys: Array(keys[..<i]),
                                                 cfg: Baselines.hrvCfg, baselineEpoch: 0)
            XCTAssertEqual(asOf[day], expected, "as-of state for \(day)")
        }
    }

    /// A day's baseline must NOT contain its own night (the self-inclusion half of F3).
    func testScoredNightIsExcludedFromItsOwnBaseline() {
        let asOf = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: Baselines.hrvCfg,
                                             baselineEpoch: 0, asOf: ["2026-03-07"])
        let withOwnNight = Baselines.foldHistory(Array(values[...6]), cfg: Baselines.hrvCfg)
        let priorOnly = Baselines.foldHistory(Array(values[..<6]), cfg: Baselines.hrvCfg)
        XCTAssertEqual(asOf["2026-03-07"], priorOnly)
        XCTAssertNotEqual(asOf["2026-03-07"], withOwnNight)
    }

    /// Later nights never reach an earlier day's baseline, so a past day's score is stable when history
    /// grows (the "stored Charge keeps changing" half of F3).
    func testLaterNightsDoNotMoveAPastDaysBaseline() {
        let day = "2026-03-06"
        let short = Baselines.foldHistoryAsOf(Array(values[..<8]), dayKeys: Array(keys[..<8]),
                                              cfg: Baselines.hrvCfg, baselineEpoch: 0, asOf: [day])
        let long = Baselines.foldHistoryAsOf(values + [99, 20, 45], dayKeys: keys + ["2026-03-13", "2026-03-14", "2026-03-15"],
                                             cfg: Baselines.hrvCfg, baselineEpoch: 0, asOf: [day])
        XCTAssertEqual(short[day], long[day])
    }

    /// A requested day with no night of its own (or beyond the history) still gets the prior state, and a
    /// day before any night gets the same empty calibrating seed `foldHistory` returns.
    func testGapDaysAndColdStart() {
        let asOf = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: Baselines.hrvCfg, baselineEpoch: 0,
                                             asOf: ["2026-02-01", "2026-03-20"])
        XCTAssertEqual(asOf["2026-02-01"], Baselines.foldHistory([], cfg: Baselines.hrvCfg))
        XCTAssertEqual(asOf["2026-02-01"]?.nValid, 0)
        XCTAssertEqual(asOf["2026-03-20"], Baselines.foldHistory(values, cfg: Baselines.hrvCfg))
    }

    /// The recalibration epoch is honoured exactly as the day-keyed fold honours it — for every day on or
    /// after the epoch. A day BEFORE it keeps the baseline it had before the recalibration (E8): the plain
    /// fold of the nights before it, never the empty seed that would null its Charge on re-persist.
    func testRecalibrationEpochMatchesTheDayKeyedFold() {
        // 2026-03-05T00:00:00Z — nights dated before it are dropped for days on/after it.
        let epoch = 1_772_668_800.0
        let asOf = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: Baselines.hrvCfg,
                                             baselineEpoch: epoch, asOf: keys)
        for (i, day) in keys.enumerated() {
            let preEpoch = day < "2026-03-05"
            let expected = preEpoch
                ? Baselines.foldHistory(Array(values[..<i]), cfg: Baselines.hrvCfg)
                : Baselines.foldHistory(Array(values[..<i]), dayKeys: Array(keys[..<i]),
                                        cfg: Baselines.hrvCfg, baselineEpoch: epoch)
            XCTAssertEqual(asOf[day], expected, "epoch-aware as-of state for \(day)")
        }
    }

    /// E8: a recalibration must not erase the baseline of the days before it.
    func testDaysBeforeTheEpochKeepAUsableBaseline() {
        let epoch = 1_772_668_800.0   // 2026-03-05
        let asOf = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: Baselines.hrvCfg,
                                             baselineEpoch: epoch, asOf: ["2026-03-04", "2026-03-05"])
        let before = Baselines.foldHistory(Array(values[..<3]), cfg: Baselines.hrvCfg)
        XCTAssertEqual(asOf["2026-03-04"], before)
        XCTAssertGreaterThan(asOf["2026-03-04"]?.nValid ?? 0, 0, "not the empty seed")
        // ...while the epoch day itself re-learns from scratch, exactly as before.
        XCTAssertEqual(asOf["2026-03-05"]?.nValid, 0)
    }
}
