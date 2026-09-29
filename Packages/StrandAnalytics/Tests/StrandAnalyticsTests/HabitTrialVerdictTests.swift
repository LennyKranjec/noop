import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-B.6 — exactly three verdicts, decided mechanically.
final class HabitTrialVerdictTests: XCTestCase {

    private func decide(_ est: Double, _ lo: Double, _ hi: Double, _ dir: EffectDirection = .increase,
                        mcid: Double = 1) -> HabitTrialVerdict {
        HabitTrialVerdict.decide(estimate: est, lower: lo, upper: hi, direction: dir, mcid: mcid, gate: nil)
    }

    func testHelpedNeedsIntervalAboveZeroAndPointAtLeastMCID() {
        XCTAssertEqual(decide(1.5, 0.2, 2.8), .helped)
        XCTAssertEqual(decide(1.0, 0.1, 1.9), .helped, "point exactly at the MCID counts")
        XCTAssertEqual(decide(0.9, 0.1, 1.7), .inconclusive(.imprecise),
                       "clear but maybe below the MCID: not a win, not a clear 'no'")
        XCTAssertEqual(decide(1.5, -0.1, 3.1), .inconclusive(.imprecise), "interval touches zero")
    }

    func testNoMeaningfulEffect() {
        XCTAssertEqual(decide(0.3, 0.1, 0.6), .noMeaningfulEffect(pointedOtherWay: false),
                       "statistically clear but below the MCID is NOT a small win")
        XCTAssertEqual(decide(0.0, -0.5, 0.5), .noMeaningfulEffect(pointedOtherWay: false))
        XCTAssertEqual(decide(-1.5, -2.5, -0.5), .noMeaningfulEffect(pointedOtherWay: true))
    }

    func testInconclusiveWhenTooWide() {
        XCTAssertEqual(decide(0.3, -1.0, 1.6), .inconclusive(.imprecise))
    }

    func testDecreaseDirectionIsMirrored() {
        XCTAssertEqual(decide(-1.5, -2.8, -0.2, .decrease), .helped)
        XCTAssertEqual(decide(1.5, 0.5, 2.5, .decrease), .noMeaningfulEffect(pointedOtherWay: true))
        XCTAssertEqual(decide(-0.3, -0.6, -0.1, .decrease), .noMeaningfulEffect(pointedOtherWay: false))
    }

    func testGatesAndMissingIntervalAreInconclusive() {
        XCTAssertEqual(HabitTrialVerdict.decide(estimate: 3, lower: 2, upper: 4, direction: .increase, mcid: 1,
                                                gate: .adherence), .inconclusive(.adherence))
        XCTAssertEqual(HabitTrialVerdict.decide(estimate: 3, lower: nil, upper: nil, direction: .increase, mcid: 1,
                                                gate: nil), .inconclusive(.imprecise))
    }

    func testHeadlinesAreTheThreeWords() {
        XCTAssertEqual(HabitTrialVerdict.helped.headline, "Helped")
        XCTAssertEqual(HabitTrialVerdict.noMeaningfulEffect(pointedOtherWay: true).headline, "No meaningful effect")
        XCTAssertEqual(HabitTrialVerdict.inconclusive(.stoppedEarly).headline, "Inconclusive")
    }

    func testCopyNeverImpliesFailureAndStoppedEarlyHasNoNumbers() {
        let reg = TrialSim.registration(seed: 7, mcid: 0.5)
        let stopped = HabitTrialAnalysis.stoppedEarly(registration: reg, storedHash: reg.hash)
        let text = HabitTrialCopy.body(verdict: stopped.verdict!, habit: "Screens off", result: stopped)
        XCTAssertTrue(text.contains("Stopped early"))
        XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "no numbers for a stopped trial")
        let none = HabitTrialCopy.body(verdict: .noMeaningfulEffect(pointedOtherWay: false), habit: "Screens off",
                                       result: stopped)
        XCTAssertTrue(none.contains("real result"))
        XCTAssertFalse(none.lowercased().contains("fail"))
    }

    func testEffectFormatting() {
        XCTAssertEqual(HabitTrialCopy.signed(log(1.08), outcome: .nightHrvLn), "+8%")
        XCTAssertEqual(HabitTrialCopy.signed(-12.4, outcome: .onsetClockMin), "−12 min")
        XCTAssertEqual(HabitTrialCopy.signed(-1.46, outcome: .nightRhr), "−1.5 bpm")
        XCTAssertEqual(HabitTrialCopy.better(-12.4, outcome: .onsetClockMin), "about 12 min earlier")
        XCTAssertEqual(HabitTrialCopy.better(log(1.05), outcome: .nightHrvLn), "about 5% higher")
    }
}
