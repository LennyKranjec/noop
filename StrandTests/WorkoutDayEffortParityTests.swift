import XCTest
import StrandAnalytics
@testable import Strand

/// THE LIVE-WORKOUT SCREEN SHOWS THE DAY'S EFFORT THE SAME WAY TODAY AND THE WIDGET DO.
///
/// Reported (translated): "during workouts the day's strain is shown differently in the workout screen
/// than in the Today tab or the widget". The in-exercise card resolved the day figure and its target
/// ITSELF — a calendar-day key instead of Today's logical day, its own recovery precedence for the band,
/// and its own `StrainCombine` sum of the in-progress session on top of the day — so the two surfaces
/// printed two numbers for the same day at the same moment.
///
/// The card now prints the shared resolutions verbatim: `Repository.todayEffortNow()` through
/// `TodayEffortNow.display(scale:)` (the string Today's hero builds) and `Repository.todayEffortTarget()`
/// through `TodayEffortTarget.display(scale:)`. These pin the pure halves of that: the rendered text IS
/// the resolver's output on both scales, the in-progress session is in neither, and the target comes from
/// one band lookup.
///
/// Touches the real `UserDefaults` calibration key (O8 reaches every Effort read-out), so the calibration
/// is cleared for the linear-mapping cases and restored in `tearDown`.
@MainActor
final class WorkoutDayEffortParityTests: XCTestCase {

    private var savedCalibration: Data?

    override func setUp() {
        super.setUp()
        savedCalibration = UserDefaults.standard.data(forKey: StrainCalibration.storageKey)
        StrainCalibration.store(nil)
    }

    override func tearDown() {
        if let savedCalibration {
            StrainCalibration.store(try? JSONDecoder().decode(EffortStrainCalibration.self,
                                                              from: savedCalibration))
        } else {
            StrainCalibration.store(nil)
        }
        super.tearDown()
    }

    /// The app's own Effort for today, as the shared resolver returns it.
    private func own(_ effort100: Double) -> TodayEffortNow {
        TodayEffortNow(day: "2026-06-14", own: effort100, cloudStrain21: nil)
    }

    /// A day that yielded to WHOOP's own strain (the app's own was a zero the strap did not earn).
    private func yieldedToCloud(_ strain21: Double) -> TodayEffortNow {
        TodayEffortNow(day: "2026-06-14", own: nil, cloudStrain21: strain21)
    }

    // MARK: - The card renders exactly what the resolver returns

    /// Both scales: the day half of "Day / target" is character-for-character the resolver's own
    /// `display(scale:)` — the string Today's hero ring prints — and the target half is the one target
    /// resolution's. No second formatting path, so the two surfaces cannot round differently.
    func testCardTextIsTheResolverOutputOnBothScales() {
        let effort = own(41.3)
        guard let target = TodayEffortTarget.resolve(recovery: 72) else {
            return XCTFail("a green recovery must yield a band")
        }
        for scale in [EffortScale.hundred, .whoop] {
            let rendered = TodayEffortNow.dayTargetText(effort: effort, target: target, scale: scale)
            XCTAssertEqual(rendered, "\(effort.display(scale: scale)!)/\(target.display(scale: scale))",
                           "the card must print the shared resolutions, not its own arithmetic")
        }
        // And the literal strings, so a change to either formatter is visible here.
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: effort, target: target, scale: .hundred),
                       "41.3/86", "0–100 scale: the day figure, and 18 of 21 placed back on the 0–100 axis")
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: effort, target: target, scale: .whoop),
                       "8.7/18", "WHOOP scale: 41.3 × 21/100, against the band top as WHOOP states it")
    }

    /// A day showing WHOOP's own strain prints it VERBATIM on the WHOOP scale, exactly as Today's hero
    /// does, instead of round-tripping it through ×100/21 and back.
    func testCloudStrainIsPrintedVerbatimLikeTodaysHero() {
        let effort = yieldedToCloud(9.4)
        let target = TodayEffortTarget.resolve(recovery: 50)
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: effort, target: target, scale: .whoop),
                       "9.4/14", "WHOOP's strain is already on WHOOP's axis")
        // On the app's own axis it goes through the inverse calibration, the axis the ring fills on.
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: effort, target: target, scale: .hundred),
                       "44.8/67")
    }

    /// ABSENT INPUT ABSTAINS, each side on its own: no day figure and/or no band is a dash, never a
    /// substituted number and never a guessed target.
    func testEachSideAbstainsSeparately() {
        let dash = TodayEffortNow.absentDash
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: nil, target: nil, scale: .hundred),
                       "\(dash)/\(dash)")
        // A resolved day figure with an unscored day (nil recovery ⇒ no band) keeps the figure, dashes
        // the target.
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: own(12.0),
                                                    target: TodayEffortTarget.resolve(recovery: nil),
                                                    scale: .hundred),
                       "12.0/\(dash)")
        // Nothing resolved for the day at all, but a known band: dash the figure, keep the target.
        XCTAssertEqual(TodayEffortNow.dayTargetText(effort: nil,
                                                    target: TodayEffortTarget.resolve(recovery: 72),
                                                    scale: .whoop),
                       "\(dash)/18")
        // A resolver that has neither its own figure nor a cloud strain has no day read-out.
        XCTAssertNil(TodayEffortNow(day: "2026-06-14", own: nil, cloudStrain21: nil).display(scale: .whoop))
    }

    // MARK: - The in-progress session is in neither number

    /// THE SESSION IS NOT FOLDED IN. The card's day figure is the resolver's and nothing else, so a
    /// running session cannot move it on this screen while leaving Today's and the widget's where they
    /// are. Pinned against the old behaviour: the `StrainCombine` sum the card used to print is a
    /// genuinely different number, which is exactly what the two surfaces disagreed by.
    func testInProgressSessionDoesNotMoveTheCardsDayFigure() {
        let effort = own(41.3)
        let target = TodayEffortTarget.resolve(recovery: 72)
        let rendered = TodayEffortNow.dayTargetText(effort: effort, target: target, scale: .hundred)
        XCTAssertEqual(rendered, "41.3/86")
        // The session's own running Effort — the hero number on the same screen — is 30 here.
        let combined = StrainScorer.combinedStrain(41.3, 30)
        XCTAssertGreaterThan(combined, 41.3 + 1.0,
                             "the old sum really did print a different day figure")
        XCTAssertNotEqual(UnitFormatter.effortDisplay(combined, scale: .hundred), "41.3")
        // Whatever the session is doing, the day half stays the resolver's string on both scales.
        for scale in [EffortScale.hundred, .whoop] {
            let dayHalf = TodayEffortNow.dayTargetText(effort: effort, target: target, scale: scale)
                .split(separator: "/").first.map { String($0) }
            XCTAssertEqual(dayHalf, effort.display(scale: scale))
        }
    }

    /// The session's own Effort is printed with the STORED-value formatter (the one every other session
    /// read-out uses), not the delta formatter — it is a figure of its own now, not a difference between
    /// two day numbers. On the WHOOP scale a calibration therefore reaches it, as it does elsewhere.
    func testSessionEffortUsesTheSharedStoredValueFormatter() {
        StrainCalibration.store(EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30))
        XCTAssertEqual(UnitFormatter.effortDisplay(30, scale: .whoop),
                       String(format: "%.1f", StrainCalibration.strain21(effort100: 30)))
        XCTAssertEqual(UnitFormatter.effortDisplay(30, scale: .hundred), "30.0")
    }

    // MARK: - One target resolution

    /// The target is the ONE band lookup plus the ONE inverse-calibration placement: no surface may
    /// re-derive either. Swept across the three bands and the unscored day.
    func testTargetIsTheSingleBandLookup() {
        for recovery in [80.0, 67.0, 66.0, 34.0, 20.0] {
            let expected = CoupledView.optimalStrainRange(recovery: recovery)
            let resolved = TodayEffortTarget.resolve(recovery: recovery)
            XCTAssertEqual(resolved?.band, expected, "recovery \(recovery)")
            XCTAssertEqual(resolved?.upper21, expected?.upperBound)
            XCTAssertEqual(resolved?.display(scale: .whoop), expected.map { "\($0.upperBound)" },
                           "the WHOOP scale shows the band top as WHOOP states it")
            XCTAssertEqual(resolved?.upper100 ?? -1,
                           StrainCalibration.effort100(strain21: Double(expected!.upperBound)),
                           accuracy: 1e-9)
        }
        XCTAssertNil(TodayEffortTarget.resolve(recovery: nil), "an unscored day never guesses a band")
    }

    /// With a calibration stored, the target placed on the 0–100 axis reads BACK as exactly the band top
    /// on the WHOOP scale — the property the hero ring's mark depends on, and now the card's number too.
    func testCalibratedTargetReadsBackAsTheBandTop() {
        StrainCalibration.store(EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30))
        guard let target = TodayEffortTarget.resolve(recovery: 72) else {
            return XCTFail("a green recovery must yield a band")
        }
        XCTAssertEqual(UnitFormatter.effortValue(target.upper100, scale: .whoop), 18, accuracy: 1e-9)
        XCTAssertEqual(target.display(scale: .whoop), "18")
        // A day sitting exactly on the mark reads as the band top too, so "past the ceiling" flips on the
        // 0–100 axis at the same instant Today's strain21-vs-band-top comparison does.
        XCTAssertEqual(UnitFormatter.effortDisplay(target.upper100, scale: .whoop), "18.0")
    }

    // MARK: - The day key

    /// THE DAY KEY IS TODAY'S LOGICAL DAY, not the calendar day. The card used to key its reads with
    /// `Repository.localDayKey(Date())`, so for the four hours after midnight it read a different day from
    /// Today, the widget strip and the live value Today publishes under ITS key — a guaranteed mismatch for
    /// anyone training late.
    func testLogicalDayDiffersFromTheCalendarDayBeforeFourAM() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 14; comps.hour = 2
        guard let preDawn = Calendar.current.date(from: comps) else {
            return XCTFail("could not build a local 02:00")
        }
        XCTAssertEqual(Repository.localDayKey(preDawn), "2026-06-14")
        XCTAssertEqual(Repository.logicalDayKey(preDawn), "2026-06-13",
                       "before 04:00 the logical day is still yesterday (#144)")
        // And after the rollover the two agree again.
        comps.hour = 10
        guard let midMorning = Calendar.current.date(from: comps) else {
            return XCTFail("could not build a local 10:00")
        }
        XCTAssertEqual(Repository.logicalDayKey(midMorning), Repository.localDayKey(midMorning))
    }
}
