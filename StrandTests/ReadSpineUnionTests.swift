import XCTest
import WhoopStore
@testable import Strand

/// #-: the per-column duplicate-day coalesce (`Repository.coalesceDay`). Byte-identical twin of the Android
/// `ReadSpineUnionTest` cases (same fixtures, same numbers). A day two source ids in the SAME bucket both
/// cover is folded per column — the winner keeps every column it carries and the filler supplies only the
/// nils — with the sleep block and the raw red/IR pair moving as whole groups. Ported from
/// tanarchytan/noop @de370b85.
final class ReadSpineUnionTests: XCTestCase {

    /// Swift `DailyMetric` carries no `deviceId` (external to the row); the value columns are the parity
    /// contract, so the fixtures set only those.
    private func dm(_ day: String,
                    totalSleepMin: Double? = nil, efficiency: Double? = nil, deepMin: Double? = nil,
                    remMin: Double? = nil, lightMin: Double? = nil, disturbances: Int? = nil,
                    restingHr: Int? = nil, avgHrv: Double? = nil, recovery: Double? = nil,
                    strain: Double? = nil, exerciseCount: Int? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
                    steps: steps)
    }

    /// A hollow winner (steps and nothing else) keeps every column the other strap's fully-scored row
    /// carries, instead of the old whole-row first-wins that discarded it.
    func testAHollowWinningRowKeepsTheOtherStrapsColumns() {
        let day = "2026-07-29"
        let active = dm(day, steps: 10_775)
        let other = dm(day, totalSleepMin: 435, efficiency: 91, deepMin: 96, remMin: 110, lightMin: 229,
                       restingHr: 64, avgHrv: 37.06, recovery: 93.2, strain: 8.4)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.steps, 10_775)          // the winner's own reading survives
        XCTAssertEqual(merged.totalSleepMin, 435)
        XCTAssertEqual(merged.deepMin, 96)
        XCTAssertEqual(merged.recovery, 93.2)
        XCTAssertEqual(merged.restingHr, 64)
        XCTAssertEqual(merged.avgHrv ?? 0, 37.06, accuracy: 1e-9)
        XCTAssertEqual(merged.strain, 8.4)
    }

    /// A measured zero is a READING, not an absence — a 0 steps / 0 strain / 0 HRV winner is kept.
    func testAMeasuredZeroIsAValueNotAnAbsence() {
        let day = "2026-07-29"
        let active = dm(day, avgHrv: 0, strain: 0, steps: 0)
        let other = dm(day, avgHrv: 42, strain: 14.7, steps: 9_120)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.steps, 0)
        XCTAssertEqual(merged.strain, 0)
        XCTAssertEqual(merged.avgHrv, 0)
    }

    /// The sleep block moves as a GROUP: a winner carrying a sleep total keeps its OWN (nil) stages rather
    /// than borrowing the other strap's — a total never sits beside foreign stages.
    func testASleepBlockIsNeverAssembledFromTwoStraps() {
        let day = "2026-07-29"
        let active = dm(day, totalSleepMin: 402)
        let other = dm(day, totalSleepMin: 435, deepMin: 96, remMin: 110, lightMin: 229)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.totalSleepMin, 402)     // the winner's total stands
        XCTAssertNil(merged.deepMin)                  // stages must not be borrowed
        XCTAssertNil(merged.remMin)
        XCTAssertNil(merged.lightMin)
    }
    /// Nightly SDNN is an independent column: the winner's stands, the filler's fills a nil. It used to be
    /// dropped (nil) on every coalesced day. Matches the Kotlin twin, which carries it the same way.
    func testNightlySdnnIsCoalescedNotDropped() {
        let day = "2026-07-29"
        let base = dm(day, avgHrv: 40)
        func withSdnn(_ row: DailyMetric, _ sdnn: Double?) -> DailyMetric {
            DailyMetric(day: row.day, totalSleepMin: row.totalSleepMin, efficiency: row.efficiency,
                        deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin,
                        disturbances: row.disturbances, restingHr: row.restingHr, avgHrv: row.avgHrv,
                        recovery: row.recovery, strain: row.strain, exerciseCount: row.exerciseCount,
                        avgSdnn: sdnn)
        }
        XCTAssertEqual(Repository.coalesceDay(withSdnn(base, 55), withSdnn(base, 70)).avgSdnn, 55)
        XCTAssertEqual(Repository.coalesceDay(withSdnn(base, nil), withSdnn(base, 70)).avgSdnn, 70)
        XCTAssertNil(Repository.coalesceDay(withSdnn(base, nil), withSdnn(base, nil)).avgSdnn)
    }

    /// Filling a day's steps from an activity file rebuilds the row; every other column must survive it,
    /// including the nightly SDNN and the HR-only staging flag it used to drop.
    func testActivityFileStepsKeepEveryOtherColumn() {
        let day = "2026-07-29"
        let existing = DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 100,
                                   lightMin: 240, disturbances: 3, restingHr: 52, avgHrv: 61, recovery: 77,
                                   strain: 9.5, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0.2,
                                   respRateBpm: 14.5, steps: nil, activeKcalEst: 2100, spo2Red: 1000,
                                   spo2Ir: 2000, avgSdnn: 58, skinTempC: 34.1, sleepHrOnly: true)
        let file = DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                               lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                               strain: nil, exerciseCount: nil, steps: 4321)
        let merged = Repository.mergeActivityFileSteps(into: [existing], [file])
        let expected = DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 100,
                                   lightMin: 240, disturbances: 3, restingHr: 52, avgHrv: 61, recovery: 77,
                                   strain: 9.5, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0.2,
                                   respRateBpm: 14.5, steps: 4321, activeKcalEst: 2100, spo2Red: 1000,
                                   spo2Ir: 2000, avgSdnn: 58, skinTempC: 34.1, sleepHrOnly: true)
        XCTAssertEqual(merged, [expected])
    }
}
