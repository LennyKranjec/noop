import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The workout dossier the coach is handed on an "AI feedback" tap: the arithmetic (drift, peak windows,
/// pace), the comparison window, and that the text carries what the model needs and says so when a
/// value is missing.
final class WorkoutFeedbackDossierTests: XCTestCase {

    private typealias D = WorkoutFeedbackDossier
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-18 07:00 UTC.
    private let t0 = 1_789_714_800

    private func row(_ start: Int, sport: String = "Running", minutes: Double = 45, strain: Double? = 40,
                     avgHr: Int? = 150, distanceM: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + Int(minutes * 60), sport: sport, source: "manual",
                   durationS: minutes * 60, energyKcal: 400, avgHr: avgHr, maxHr: 175, strain: strain,
                   distanceM: distanceM, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func input(hr: [D.HRPoint] = [], recent: [WorkoutRow] = [], isRecovery: Bool = false,
                       kcal: Double? = 512, stress: (Double, Double)? = nil,
                       zoneMinutes: [Double]? = [5, 10, 20, 8, 2]) -> D.Input {
        D.Input(sport: "Running", source: "manual", startTs: t0, endTs: t0 + 2_700, durationS: 2_700,
                energyKcal: kcal, avgHr: 152, maxHr: 178, effort: 55.5, distanceM: 9_000, steps: nil,
                notes: "felt heavy", isRecovery: isRecovery, hr: hr, zoneMinutes: zoneMinutes,
                zonesFromImport: false, zoneSet: HRZones.zones(maxHR: 190, restingHR: 50),
                effortHRmax: 188, hrRecovery: nil, stressStart: stress?.0, stressEnd: stress?.1,
                routeDistanceM: nil, routePointCount: 0,
                day: D.DayContext(dayKey: "2026-09-18", charge: 72, dayEffort: 61, rest: 80,
                                  whoopRecovery: nil, effortTargetLow: 67, effortTargetHigh: 86,
                                  sleepMin: 450, deepMin: 90, remMin: 100, sleepEfficiency: 0.91,
                                  hrv: 64, restingHr: 52),
                recent: recent, imperial: false, timeZone: utc)
    }

    /// One point every 30 s for `minutes`, at `bpm(minute)`.
    private func trace(minutes: Int, _ bpm: (Int) -> Double) -> [D.HRPoint] {
        (0..<(minutes * 2)).map { i in D.HRPoint(ts: t0 + i * 30, bpm: bpm(i / 2)) }
    }

    // MARK: - Arithmetic

    func testDriftComparesTheTwoHalves() {
        let pts = trace(minutes: 40) { $0 < 20 ? 140 : 154 }
        let d = D.drift(pts)
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.first, 140, accuracy: 0.001)
        XCTAssertEqual(d!.second, 154, accuracy: 0.001)
        XCTAssertEqual(d!.percent, 10, accuracy: 0.001)
    }

    func testDriftNeedsPointsInBothHalves() {
        XCTAssertNil(D.drift([D.HRPoint(ts: t0, bpm: 120), D.HRPoint(ts: t0 + 60, bpm: 130)]))
        XCTAssertNil(D.drift([]))
    }

    func testPeakWindowFindsTheHardestStretchAndWhereItStarts() {
        let pts = trace(minutes: 60) { (10..<15).contains($0) ? 170 : 130 }
        let p = D.peakWindow(pts, seconds: 300)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.avg, 170, accuracy: 0.001)
        XCTAssertEqual(p!.offsetS, 600)
    }

    func testPeakWindowOverTheWholeSessionIsAnswerable() {
        // 60 min at 30 s spacing: the last point stands for its own 30 s, so a 60-min window fits.
        let pts = trace(minutes: 60) { _ in 140 }
        XCTAssertEqual(D.peakWindow(pts, seconds: 3_600)?.avg ?? 0, 140, accuracy: 0.001)
    }

    func testPeakWindowLongerThanTheTraceIsNil() {
        XCTAssertNil(D.peakWindow(trace(minutes: 10) { _ in 140 }, seconds: 1_200))
    }

    func testPace() {
        XCTAssertEqual(D.paceText(distanceM: 5_000, seconds: 1_500, imperial: false), "5:00 /km")
        XCTAssertEqual(D.paceText(distanceM: 1_609.344, seconds: 480, imperial: true), "8:00 /mi")
        XCTAssertEqual(D.paceText(distanceM: 10_000, seconds: 3_125, imperial: false), "5:13 /km")
        XCTAssertNil(D.paceText(distanceM: 50, seconds: 600, imperial: false))
        XCTAssertNil(D.paceText(distanceM: 5_000, seconds: 0, imperial: false))
    }

    // MARK: - The dossier text

    func testDossierCarriesTheSessionTheZonesAndTheDay() {
        let text = D.build(input(hr: trace(minutes: 45) { $0 < 22 ? 145 : 158 }))
        XCTAssertTrue(text.contains("THE WORKOUT THIS CONVERSATION IS ABOUT"))
        XCTAssertTrue(text.contains("what went well"))
        XCTAssertTrue(text.contains("what to improve"))
        XCTAssertTrue(text.contains("no tables"))
        XCTAssertTrue(text.contains("Start: 2026-09-18 07:00, end: 2026-09-18 07:45"))
        XCTAssertTrue(text.contains("Duration: 45 min"))
        XCTAssertTrue(text.contains("Effort (0-100): 55.5"))
        XCTAssertTrue(text.contains("the day's total Effort was 61.0"))
        XCTAssertTrue(text.contains("Distance: 9.00 km, average pace 5:00 /km"))
        XCTAssertTrue(text.contains("User's note: felt heavy"))
        XCTAssertTrue(text.contains("Drift: first half avg"))
        XCTAssertTrue(text.contains("Best 5-min average"))
        XCTAssertTrue(text.contains("Z3 148-161: 20 min (44%)"))
        XCTAssertTrue(text.contains("Zone HRmax 190 bpm"))
        XCTAssertTrue(text.contains("zone resting HR 50 bpm"))
        XCTAssertTrue(text.contains("Recommended day Effort band from that recovery: 67-86"))
        XCTAssertTrue(text.contains("Sleep the night before: 7.5 h, deep 1.5 h, REM 1.7 h, efficiency 91%"))
        XCTAssertTrue(text.contains("Overnight HRV: 64 ms, resting HR: 52 bpm"))
    }

    func testMissingValuesAreNamedNotDropped() {
        let text = D.build(input(kcal: nil, zoneMinutes: nil))
        XCTAssertTrue(text.contains("Calories: not recorded"))
        XCTAssertTrue(text.contains("Time in zones: not available"))
        XCTAssertTrue(text.contains("No usable heart-rate trace"))
    }

    func testRecoverySessionCarriesTheStressChange() {
        let text = D.build(input(isRecovery: true, stress: (1.8, 1.1)))
        XCTAssertTrue(text.contains("RECOVERY session"))
        XCTAssertTrue(text.contains("first 5 min 1.8 -> last 5 min 1.1, change -0.7"))
        let unread = D.build(input(isRecovery: true, stress: nil))
        XCTAssertTrue(unread.contains("Stress change: not measurable"))
    }

    func testComparisonIsTheFourteenDaysBeforeAndGroupsTheSameSport() {
        let day = 86_400
        let recent = [
            row(t0 - 2 * day, sport: "Running", minutes: 40, strain: 50, avgHr: 150, distanceM: 8_000),
            row(t0 - 5 * day, sport: "Running", minutes: 60, strain: 60, avgHr: 154),
            row(t0 - 3 * day, sport: "Cycling", minutes: 90),
            row(t0 - 20 * day, sport: "Running"),          // outside the window
            row(t0 + day, sport: "Running"),               // after this session
            row(t0, sport: "Running"),                     // this session itself
        ]
        let text = D.comparison(input(recent: recent))
        XCTAssertTrue(text.contains("Previous 14 days: 3 workout(s), 2 of them Running."))
        XCTAssertTrue(text.contains("Same-sport averages: duration 50 min, Effort 55.0, avg HR 152 bpm"))
        XCTAssertTrue(text.contains("2026-09-16 Running, 40 min, Effort 50.0, avg HR 150, 8.00 km, 5:00 /km"))
        XCTAssertTrue(text.contains("Other sessions:"))
        XCTAssertTrue(text.contains("Cycling"))
    }

    func testNoPriorWorkoutsSaysSo() {
        XCTAssertEqual(D.comparison(input(recent: [])), "Previous 14 days: no other workouts recorded.\n")
    }

    // MARK: - Mobile formatting rule

    @MainActor
    func testMobileFormattingRuleIsAppendedOnce() {
        let once = AICoachEngine.withMobileFormatting("Base prompt.")
        XCTAssertTrue(once.hasPrefix("Base prompt."))
        XCTAssertTrue(once.contains("Do NOT use Markdown tables"))
        XCTAssertEqual(AICoachEngine.withMobileFormatting(once), once)
    }

    @MainActor
    func testDefaultPromptNoLongerInvitesTables() {
        XCTAssertFalse(AICoachEngine.defaultSystemPrompt.contains("small table only for a week-ahead plan"))
        XCTAssertTrue(AICoachEngine.defaultSystemPrompt.contains("avoid Markdown tables"))
    }
}
