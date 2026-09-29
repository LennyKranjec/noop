import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-B.9 test 1 — the assignment schedule.
final class HabitTrialScheduleTests: XCTestCase {

    func testWeekdayBalancedIsExactlyHalfOnPerWeekday() {
        let seeds: [UInt64] = [1, 2, 3, 20_260_929, 0xFFFF_FFFF]
        for length in [28, 42, 56] {
            for seed in seeds {
                let days = HabitTrialSchedule.make(design: .weekdayBalanced, lengthDays: length,
                                                   startDay: "2026-10-01", seed: seed)
                XCTAssertEqual(days.count, length)
                XCTAssertEqual(days.filter { $0.on }.count, length / 2)
                var onByWeekday: [Int: Int] = [:]
                var allByWeekday: [Int: Int] = [:]
                for d in days {
                    let wd = HabitDay.isoWeekday(d.day)!
                    allByWeekday[wd, default: 0] += 1
                    if d.on { onByWeekday[wd, default: 0] += 1 }
                }
                XCTAssertEqual(allByWeekday.count, 7)
                for wd in 1...7 {
                    XCTAssertEqual(allByWeekday[wd], length / 7)
                    XCTAssertEqual((onByWeekday[wd] ?? 0) * 2, length / 7,
                                   "L=\(length) seed=\(seed): weekday \(wd) not balanced")
                }
                XCTAssertFalse(days.contains { $0.washout })
            }
        }
    }

    func testBlockedDesignHalfOnBlocksWithWashout() {
        for length in [48, 56] {
            let days = HabitTrialSchedule.make(design: .phaseBlocks, lengthDays: length,
                                               startDay: "2026-10-01", seed: 99)
            XCTAssertEqual(days.count, length)
            let blocks = length / 4
            var onBlocks = 0
            for b in 0..<blocks {
                let block = Array(days[(b * 4)..<(b * 4 + 4)])
                XCTAssertTrue(block.allSatisfy { $0.on == block[0].on }, "a block is one arm")
                XCTAssertTrue(block[0].washout, "the first day of every block is a washout day")
                XCTAssertFalse(block[1].washout || block[2].washout || block[3].washout)
                if block[0].on { onBlocks += 1 }
            }
            XCTAssertEqual(onBlocks * 2, blocks)
            XCTAssertEqual(HabitTrialSchedule.analysableDaysPerArm(design: .phaseBlocks, lengthDays: length),
                           blocks / 2 * 3)
        }
    }

    func testSameSeedSameScheduleDifferentSeedsDiffer() {
        let a = HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 28, seed: 12)
        let b = HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 28, seed: 12)
        let c = HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 28, seed: 13)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        // `redraw` (the permutation generator) is the same code path.
        XCTAssertEqual(HabitTrialSchedule.redraw(design: .weekdayBalanced, days: 28, seed: 12), a)
    }

    func testPinnedSchedulesMatchReferenceTwin() {
        let wb = HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 28, seed: 20_260_929)
        XCTAssertEqual(wb.map { $0 ? "1" : "0" }.joined(), "1010101010101010100010101110")
        let bl = HabitTrialSchedule.assignments(design: .phaseBlocks, lengthDays: 48, seed: 20_260_929)
        XCTAssertEqual(bl.map { $0 ? "1" : "0" }.joined(), "111100001111111111110000000000001111111100000000")
    }

    func testInvalidLengthsAreRefused() {
        XCTAssertTrue(HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 21, seed: 1).isEmpty)
        XCTAssertTrue(HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 35, seed: 1).isEmpty)
        // 28-day phase trials are not offered (7 blocks cannot split evenly).
        XCTAssertTrue(HabitTrialSchedule.assignments(design: .phaseBlocks, lengthDays: 28, seed: 1).isEmpty)
        XCTAssertEqual(HabitTrialDesign.phaseBlocks.allowedLengths, [48, 56])
        XCTAssertEqual(HabitTrialDesign.weekdayBalanced.allowedLengths, [28, 42, 56])
        XCTAssertTrue(HabitTrialSchedule.make(design: .weekdayBalanced, lengthDays: 28, startDay: "not-a-day",
                                              seed: 1).isEmpty)
    }

    func testPermutationSeedsAreDistinctAndNotTheRegisteredOne() {
        let seeds = (0..<1000).map { HabitTrialSchedule.permutationSeed(registered: 5, index: $0) }
        XCTAssertEqual(Set(seeds).count, 1000)
        XCTAssertFalse(seeds.contains(5))
    }

    func testDaysRunAcrossDST() {
        // 2026-03-29 is the EU spring-forward day: day keys never skip or repeat.
        let days = HabitTrialSchedule.make(design: .weekdayBalanced, lengthDays: 28, startDay: "2026-03-20", seed: 4)
        XCTAssertEqual(Array(days.map { $0.day }[8..<12]), ["2026-03-28", "2026-03-29", "2026-03-30", "2026-03-31"])
    }
}
