import XCTest
@testable import StrandAnalytics

/// The coach's goals block (DESIGN_V2 decision 14): dated, compact, every number the verdict rests on,
/// cut at whole lines under its length cap and saying how many goals were left out.
final class GoalCoachSummaryTests: XCTestCase {

    private let today = "2026-09-30"

    private func assessment(_ i: Int, verdict: GoalVerdict = .ambitiousButPlausible) -> GoalAssessment {
        let g = Goal(id: "g\(i)", metric: .restingHR, target: Double(50 + i), targetDate: "2026-12-\(10 + i)",
                     createdOn: "2026-09-01", startValue: 60, direction: .decrease)
        return GoalAssessment(goal: g, verdict: verdict, current: 58, currentWeek: "2026-09-21", weeksLeft: 10,
                              requiredPerWeek: -0.5, projectedAtDate: ProjectionBand(weeksAhead: 10, weekStart: "2026-12-07",
                                                                                     center: 55, low: 53, high: 57),
                              noBandReason: nil, plausible: nil, plausiblePerWeek: 0.5,
                              realisticDate: verdict == .unrealistic ? "2027-02-01" : nil,
                              realisticValue: verdict == .unrealistic ? 54 : nil, review: nil, caveats: [])
    }

    func testEmptyWithoutGoals() {
        XCTAssertEqual(GoalCoachSummary.block([], asOf: today), "")
        XCTAssertEqual(GoalCoachSummary.shortBlock([], asOf: today), "")
    }

    func testFullBlockCarriesTheDatedNumbers() {
        let block = GoalCoachSummary.block([assessment(1, verdict: .unrealistic)], asOf: today, maxChars: 2000)
        XCTAssertTrue(block.hasPrefix("GOALS (as of 2026-09-30; 1 active)"))
        XCTAssertTrue(block.contains("target 51 bpm by 2026-12-11"))
        XCTAssertTrue(block.contains("now 58 bpm (week of 2026-09-21)"))
        XCTAssertTrue(block.contains("needs \u{2212}0.5 bpm/wk"), "a rate carries one decimal more, with a true minus")
        XCTAssertTrue(block.contains("trend band at date 53–57"))
        XCTAssertTrue(block.contains("unrealistic at this date"))
        XCTAssertTrue(block.contains("realistic date 2027-02-01"))
        XCTAssertTrue(block.contains("too ambitious"), "the rule tells the coach to say so plainly")
    }

    func testLengthCapIsHonouredAtWholeLines() {
        let many = (1...12).map { assessment($0) }
        for cap in [120, 250, 400, 600, 900] {
            let full = GoalCoachSummary.block(many, asOf: today, maxChars: cap)
            XCTAssertLessThanOrEqual(full.count, cap, "cap \(cap)")
            let short = GoalCoachSummary.shortBlock(many, asOf: today, maxChars: cap)
            XCTAssertLessThanOrEqual(short.count, cap, "short cap \(cap)")
            // Never a half line: every goal line that appears is complete (ends with its verdict).
            for line in full.split(separator: "\n") where line.hasPrefix("- ") {
                XCTAssertTrue(line.hasSuffix("ambitious but plausible"), String(line))
            }
        }
        let trimmed = GoalCoachSummary.block(many, asOf: today, maxChars: 600)
        XCTAssertTrue(trimmed.contains("more goals not shown"))
        let all = GoalCoachSummary.block(many, asOf: today, maxChars: 20_000)
        XCTAssertFalse(all.contains("not shown"))
        XCTAssertEqual(all.split(separator: "\n").filter { $0.hasPrefix("- ") }.count, 12)
    }

    func testShortBlockIsShorterThanTheFull() {
        let some = (1...3).map { assessment($0) }
        let full = GoalCoachSummary.block(some, asOf: today, maxChars: 5000)
        let short = GoalCoachSummary.shortBlock(some, asOf: today, maxChars: 5000)
        XCTAssertLessThan(short.count, full.count)
        XCTAssertEqual(short.split(separator: "\n").filter { $0.hasPrefix("- ") }.count, 3)
    }

    func testArchivedGoalsAreLeftOut() {
        var a = assessment(1)
        var g = a.goal
        g.archived = true
        a = GoalAssessment(goal: g, verdict: a.verdict, current: a.current, currentWeek: a.currentWeek,
                           weeksLeft: a.weeksLeft, requiredPerWeek: a.requiredPerWeek,
                           projectedAtDate: a.projectedAtDate, noBandReason: nil, plausible: nil,
                           plausiblePerWeek: nil, realisticDate: nil, realisticValue: nil, review: nil, caveats: [])
        XCTAssertEqual(GoalCoachSummary.block([a], asOf: today), "")
    }
}
