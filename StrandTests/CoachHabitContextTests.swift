import XCTest
import StrandAnalytics
@testable import Strand

/// The habit summary as a coach context block (HEALTH_V2 S1-A.6 / H12), which replaced the raw 7-day
/// journal dump and the EffectRanker lines.
///
/// WHAT THESE PIN. The short form exists so the budget can keep the RUNNING TRIAL's line when it cannot
/// afford the whole summary: that line tells the coach which behaviour it must not advise on, and losing it
/// silently would let the coach contaminate the wearer's own experiment. And an empty summary is no block at
/// all, never a heading over nothing.
final class CoachHabitContextTests: XCTestCase {

    private let asOf = "2026-09-29"

    /// A report with no rows: the longest header the renderer writes (the window dates) and nothing else.
    private func emptyReport() throws -> HabitAssociationReport {
        let json = #"{"asOf":"2026-09-29","windowStart":"2026-07-01","windowEnd":"2026-09-28","rows":[],"alsoLogged":[],"sourceCounts":{}}"#
        return try JSONDecoder().decode(HabitAssociationReport.self, from: Data(json.utf8))
    }

    /// A running trial at its widest: three-digit adherence, two-digit day numbers.
    private func running(_ interventionId: String) throws -> HabitTrialProgress {
        let json = """
        {"trialId":"\(interventionId).2026-09-21","interventionId":"\(interventionId)","dayNumber":28,\
        "lengthDays":28,"todayOn":true,"adherence":1.0,"unanswered":0,"validOn":14,"validOff":14,\
        "plannedPerArm":14,"sealedUntil":"2026-10-18"}
        """
        return try JSONDecoder().decode(HabitTrialProgress.self, from: Data(json.utf8))
    }

    func testTheShortFormKeepsEveryRunningTrialsLine() throws {
        let report = try emptyReport()
        for (id, topic) in HabitCoachSummary.trialTopics {
            let short = HabitCoachSummary.render(report: report,
                                                 trials: HabitCoachTrials(running: try running(id)),
                                                 proposals: [], asOf: asOf,
                                                 maxChars: CoachHabitContext.shortMaxChars)
            XCTAssertTrue(short.contains("TRIAL RUNNING \(id)"), "short form lost the running trial \(id)")
            XCTAssertTrue(short.contains("Do not advise on \(topic)."), "short form lost \(id)'s constraint")
            XCTAssertLessThanOrEqual(short.count, CoachHabitContext.shortMaxChars)
        }
    }

    func testAnEmptySummaryIsNoBlock() {
        XCTAssertNil(CoachHabitContext.block(full: "", short: ""))
        XCTAssertNil(CoachHabitContext.block(full: "  \n ", short: "x"))
    }

    func testTheBlockCarriesItsNameValueAndBothForms() {
        let full = "HABITS (as of 2026-09-29; no habit analysis yet)\nRules: …\n- a long line"
        let short = "HABITS (as of 2026-09-29; no habit analysis yet)"
        let block = CoachHabitContext.block(full: full, short: short)
        XCTAssertEqual(block?.name, CoachHabitContext.blockName)
        XCTAssertEqual(block?.value, CoachHabitContext.value)
        XCTAssertEqual(block?.full, full)
        XCTAssertEqual(block?.short, short)
    }

    /// A short form that is empty (the renderer could not fit even its header) or no shorter than the full
    /// one is not a short form: the budget must drop the block whole rather than "shorten" it to itself.
    func testAShortFormThatSavesNothingIsLeftOut() {
        let full = "HABITS (as of 2026-09-29; no habit analysis yet)"
        XCTAssertNil(CoachHabitContext.block(full: full, short: full)?.short)
        XCTAssertNil(CoachHabitContext.block(full: full, short: "")?.short)
        XCTAssertNotNil(CoachHabitContext.block(full: full, short: ""))
    }

    /// Under a tight budget the habit summary is shortened before it is dropped, and the running trial's
    /// line survives the shortening.
    func testUnderATightBudgetTheTrialLineSurvives() throws {
        let report = try emptyReport()
        let trials = HabitCoachTrials(running: try running("screensOff60"))
        let full = HabitCoachSummary.render(report: report, trials: trials, proposals: [], asOf: asOf)
        let short = HabitCoachSummary.render(report: report, trials: trials, proposals: [], asOf: asOf,
                                             maxChars: CoachHabitContext.shortMaxChars)
        let padded = full + "\n" + String(repeating: "- possible link line\n", count: 20)
        let habits = try XCTUnwrap(CoachHabitContext.block(full: padded, short: short))
        let big = CoachContextBlock(name: "big", value: 90, full: String(repeating: "x", count: 2_000))
        let fit = CoachContextBudget.fit([big, habits],
                                         budget: CoachTokens.estimate(big.full) + CoachTokens.estimate(short) + 120,
                                         reserved: 0)
        XCTAssertEqual(fit.shortened, [CoachHabitContext.blockName])
        XCTAssertTrue(fit.text.contains("TRIAL RUNNING screensOff60"))
    }
}
