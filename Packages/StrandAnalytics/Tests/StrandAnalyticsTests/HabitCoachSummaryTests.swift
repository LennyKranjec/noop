import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-A.6 — the coach's habit block: bounded, dated, priority-truncated, and sealed.
final class HabitCoachSummaryTests: XCTestCase {

    private func row(_ habit: HabitId, _ label: String, _ est: Double, _ strengthMcid: Double = 1) -> HabitAssociationRow {
        HabitAssociationRow(habit: habit, habitLabel: label, outcome: .nightHrvLn, label: .possibleLink, yesCount: 11,
                            noCount: 64, estimate: est, lower: est - 0.05, upper: est + 0.05, mcid: strengthMcid,
                            pValue: 0.001, bhSignificant: true, absence: nil, cooccursWith: [HabitCatalog.lateMeal],
                            cooccurLabels: ["Eating close to bedtime"], secondaries: [])
    }

    private var report: HabitAssociationReport {
        HabitAssociationReport(asOf: "2026-09-29", windowStart: "2026-07-02", windowEnd: "2026-09-28",
                               rows: [row(HabitCatalog.alcohol, "Alcohol in the evening", -0.08, 0.04),
                                      row(HabitCatalog.sauna, "Sauna", 0.05, 0.04),
                                      row(HabitCatalog.reading, "Reading before bed", 0.06, 0.04),
                                      row(HabitCatalog.lateWorkout, "Late workout", -0.12, 0.04)],
                               alsoLogged: [], sourceCounts: [:])
    }

    private var running: HabitTrialProgress {
        HabitTrialProgress(trialId: "screensOff60.2026-09-18", interventionId: "screensOff60", dayNumber: 12,
                           lengthDays: 28, todayOn: true, adherence: 0.83, unanswered: 1, validOn: 5, validOff: 6,
                           plannedPerArm: 14, sealedUntil: "2026-10-16")
    }

    private func finished(_ id: String, _ day: String, _ verdict: HabitTrialVerdict, _ est: Double?) -> HabitCoachFinishedTrial {
        let reg = TrialSim.registration(seed: 1, mcid: 0.04)
        let base = HabitTrialAnalysis.stoppedEarly(registration: reg, storedHash: reg.hash)
        let result = HabitTrialResult(
            trialId: base.trialId, interventionId: id, primaryOutcome: .nightHrvLn, direction: .increase, mcid: 0.04,
            recordIntact: true, verdict: verdict, gate: nil, estimate: est, lower: est.map { $0 - 0.05 },
            upper: est.map { $0 + 0.05 }, pOneSided: nil, permutations: 0, lengthDays: 28, plannedPerArm: 14,
            nOn: 12, nOff: 12, missingOn: 2, missingOff: 2, droppedForCovariate: 0, washoutDays: 0, onDays: 14,
            offDays: 14, adherenceOn: 0.9, contaminationOff: 0.1, illnessDays: 0, meanOn: nil, meanOff: nil,
            residualLag1: nil, moreValidDaysNeeded: nil, recommendedLengthDays: nil, perProtocol: nil,
            secondaries: [], alcoholExcluded: nil)
        return HabitCoachFinishedTrial(result: result, endedOn: day)
    }

    func testLayoutDatedAndOrdered() {
        let text = HabitCoachSummary.render(
            report: report,
            trials: HabitCoachTrials(running: running, finished: [
                finished("breathing10", "2026-09-10", .noMeaningfulEffect(pointedOtherWay: false), 0.01),
                finished("dinner3h", "2026-08-01", .inconclusive(.imprecise), 0.02),
                finished("caffeineCutoff14", "2026-05-01", .helped, 0.1),   // older than 90 days: dropped
            ]),
            proposals: [TrialProposal(entryId: "caffeineCutoff14", reason: "x", fromOwnData: false),
                        TrialProposal(entryId: "dinner3h", reason: "y", fromOwnData: true)],
            asOf: "2026-09-29", maxChars: 5000)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("HABITS (as of 2026-09-29; nights 2026-07-02..2026-09-28"))
        XCTAssertTrue(lines[1].hasPrefix("Rules:"))
        XCTAssertTrue(lines[2].hasPrefix("TRIAL RUNNING screensOff60: day 12/28, adherence 83%"))
        XCTAssertTrue(lines[2].contains("sealed until 2026-10-16"))
        XCTAssertTrue(lines[2].contains("Do not advise on evening screens"))
        XCTAssertTrue(lines[3].hasPrefix("TRIAL DONE 2026-09-10 breathing10"))
        XCTAssertTrue(lines[4].hasPrefix("TRIAL DONE 2026-08-01 dinner3h"))
        XCTAssertFalse(text.contains("caffeineCutoff14 -> "), "a trial older than 90 days is not listed")
        // Inconclusive is reported with no numbers, so nobody reads a trend into it.
        XCTAssertFalse(lines[4].contains("%"))
        // Possible links: at most 3, strongest (|β|/MCID) first → late workout (3.0), alcohol (2.0), reading (1.5).
        XCTAssertTrue(lines[5].hasPrefix("- late workout:"))
        XCTAssertTrue(lines[6].hasPrefix("- alcohol in the evening:"))
        XCTAssertTrue(lines[7].hasPrefix("- reading before bed:"))
        XCTAssertTrue(lines[8].hasPrefix("CANDIDATE TRIALS: caffeineCutoff14 (untested), dinner3h"))
        XCTAssertEqual(lines.count, 9)
    }

    func testNeverExceedsMaxCharsAndDropsWholeLinesFromTheBottom() {
        for maxChars in [60, 150, 300, 450, 600, 900] {
            let text = HabitCoachSummary.render(
                report: report,
                trials: HabitCoachTrials(running: running,
                                         finished: [finished("breathing10", "2026-09-10", .helped, 0.08)]),
                proposals: [TrialProposal(entryId: "caffeineCutoff14", reason: "x", fromOwnData: false)],
                asOf: "2026-09-29", maxChars: maxChars)
            XCTAssertLessThanOrEqual(text.count, maxChars, "maxChars \(maxChars)")
            // Whatever survives is a prefix of the full layout: priority order, never cut mid-line.
            let full = HabitCoachSummary.render(
                report: report,
                trials: HabitCoachTrials(running: running,
                                         finished: [finished("breathing10", "2026-09-10", .helped, 0.08)]),
                proposals: [TrialProposal(entryId: "caffeineCutoff14", reason: "x", fromOwnData: false)],
                asOf: "2026-09-29", maxChars: 100_000)
            XCTAssertTrue(full.hasPrefix(text))
            if !text.isEmpty, text.count < full.count {
                XCTAssertEqual(full[full.index(full.startIndex, offsetBy: text.count)], "\n")
            }
        }
        // The default budget holds a realistic block.
        let text = HabitCoachSummary.render(report: report, trials: HabitCoachTrials(running: running),
                                            proposals: [], asOf: "2026-09-29")
        XCTAssertLessThanOrEqual(text.count, 900)
        XCTAssertTrue(text.contains("TRIAL RUNNING"))
    }

    func testRunningTrialLineNeverContainsAnEstimate() {
        let text = HabitCoachSummary.render(report: nil, trials: HabitCoachTrials(running: running), proposals: [],
                                            asOf: "2026-09-29")
        let line = text.components(separatedBy: "\n").first { $0.hasPrefix("TRIAL RUNNING") }!
        // The only numbers allowed: day count, adherence, and the seal date.
        let stripped = line.replacingOccurrences(of: "2026-10-16", with: "")
            .replacingOccurrences(of: "12/28", with: "")
            .replacingOccurrences(of: "83%", with: "")
            .replacingOccurrences(of: "60", with: "")    // the id "screensOff60"
        XCTAssertNil(stripped.rangeOfCharacter(from: .decimalDigits), line)
        XCTAssertFalse(line.contains("ms"))
        XCTAssertFalse(line.contains("["))
    }

    func testNoReportStillDated() {
        let text = HabitCoachSummary.render(report: nil, trials: HabitCoachTrials(), proposals: [], asOf: "2026-09-29")
        XCTAssertTrue(text.hasPrefix("HABITS (as of 2026-09-29"))
        XCTAssertFalse(text.lowercased().contains("causes "))
    }
}
