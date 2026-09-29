import XCTest
import StrandAnalytics
@testable import Strand

/// Audit items 5, 6, 7, 8 and 9 — the Repository/Today half. Each test names the reported symptom.
@MainActor
final class AccuracyAuditRepositoryTests: XCTestCase {

    // MARK: - Item 5: what may be BANKED as the wearer's VO₂max

    /// THE BUG. `.hrRatio` carries `sessions == 0` by construction: it is what the estimator returns when
    /// nothing about this wearer's exercise has been measured at all. Banked, it produced the reported day-one
    /// figure (age 40, one night, sleep RHR 44 → 55.1 on the Level screen) out of two numbers that say nothing
    /// about aerobic capacity.
    func testAnHrRatioEstimateWithNoSessionsIsNotBanked() {
        let ratio = VO2MaxEstimator.Estimate(vo2max: 55.1, method: .hrRatio, sessions: 0)
        XCTAssertFalse(Repository.isBankableVo2Max(ratio))
    }

    /// Everything resting on measured sessions or the activity index still banks.
    func testMeasuredAndActivityModelEstimatesStillBank() {
        XCTAssertTrue(Repository.isBankableVo2Max(
            .init(vo2max: 48, method: .submaximal, sessions: 3)))
        XCTAssertTrue(Repository.isBankableVo2Max(
            .init(vo2max: 44, method: .blended, sessions: 2)))
        XCTAssertTrue(Repository.isBankableVo2Max(
            .init(vo2max: 41, method: .activityModel, sessions: 0)))
    }

    /// THE MISSING MINIMUM-N. The resting HR came from `days.suffix(7)` with no floor, so a single night's
    /// figure became "the wearer's resting HR" and — through Uth, monotone in it — a banked VO₂max on day one.
    /// The bar is the one the other VO₂max path already clears.
    func testRestingHrNeedsTheSameCoverageTheOtherVo2maxPathRequires() {
        func day(_ sleep: Double?) -> (daytime: Double?, sleep: Double?) { (daytime: nil, sleep: sleep) }
        XCTAssertFalse(Repository.hasEnoughRestingHrDays([day(44)]), "one night is not a resting HR")
        XCTAssertFalse(Repository.hasEnoughRestingHrDays([day(44), day(45), day(nil)]))
        XCTAssertTrue(Repository.hasEnoughRestingHrDays([day(44), day(45), day(46), day(47)]))
        XCTAssertEqual(FitnessAgeEngine.minCoverageDays, 4, "the shared bar, pinned so it can't drift apart")
    }

    /// TWO KEYS, ONE METRIC. The Level screen and the coach read `Repository.noopVo2Key` while the Health tab,
    /// Today's tile, Liquid Today and the metric explorer read `vo2max_est` — two numbers for the same day,
    /// each labelled VO₂max. One key now.
    func testTheTwoVo2maxSeriesHaveCollapsedToOneKey() {
        XCTAssertEqual(Repository.noopVo2Key, "vo2max_est")
    }

    // MARK: - Item 7: three tiles showed the newest banked point regardless of its date

    /// THE BUG. Bank one VO₂max on day 3, take two workout-free weeks, and the tile still reads the day-3
    /// figure as the current one.
    func testAFortnightOldBankedScalarNoLongerCarries() {
        let points = [(day: "2026-09-05", value: 55.1)]
        XCTAssertEqual(points.last?.value, 55.1, "the fixture reproduces the report: it IS the newest point")
        XCTAssertNil(Repository.carriedSeriesValue(points, todayKey: "2026-09-19"))
    }

    /// A weekly value inside its window still carries — a Saturday figure read on the Friday after is current.
    func testAValueInsideTheCarryWindowStillReads() {
        XCTAssertEqual(Repository.carriedSeriesValue([(day: "2026-09-19", value: 48.0)],
                                                     todayKey: "2026-09-25"), 48.0)
        XCTAssertEqual(Repository.carriedSeriesValue([(day: "2026-09-19", value: 48.0)],
                                                     todayKey: "2026-09-26"), 48.0,
                       "exactly `vitalCarryDays` old is still admitted, as elsewhere")
        XCTAssertNil(Repository.carriedSeriesValue([(day: "2026-09-19", value: 48.0)],
                                                   todayKey: "2026-09-27"))
    }

    /// The newest point is the one tested, and an empty series is nil rather than a substituted number.
    func testTheNewestPointIsWhatIsBoundedAndEmptyIsNil() {
        let points = [(day: "2026-09-01", value: 40.0), (day: "2026-09-26", value: 47.0)]
        XCTAssertEqual(Repository.carriedSeriesValue(points, todayKey: "2026-09-27"), 47.0)
        XCTAssertNil(Repository.carriedSeriesValue([], todayKey: "2026-09-27"))
    }

    // MARK: - Item 6: the history-wide snapshot was restored across the 04:00 rollover

    /// THE BUG. A strap not synced overnight never bumps `refreshSeq`, so the seq-only gate served
    /// yesterday's stress / fitness age / VO₂max / vitality as today's: backgrounded at 23:00, reopened at
    /// 05:10.
    func testTheHistoryWideSnapshotIsNotServedAcrossTheRollover() {
        let banked = Date()
        XCTAssertFalse(TodayView.historyWideCacheHit(loadedSeq: 7, currentSeq: 7,
                                                     loadedDayKey: "2026-09-28",
                                                     currentDayKey: "2026-09-29",
                                                     bankedAt: banked, now: banked))
    }

    /// The #849 short-circuit it exists for still holds: same data state, same logical day, fresh snapshot.
    func testTheSnapshotIsStillServedForAnUnchangedSameDayRemount() {
        let banked = Date()
        XCTAssertTrue(TodayView.historyWideCacheHit(loadedSeq: 7, currentSeq: 7,
                                                    loadedDayKey: "2026-09-29",
                                                    currentDayKey: "2026-09-29",
                                                    bankedAt: banked,
                                                    now: banked.addingTimeInterval(5)))
    }

    /// And it is age-bounded like its day-scoped twin: today is still forming, so a stale snapshot pays a
    /// genuine reload even when nothing new was synced.
    func testAnOldSnapshotIsRefusedEvenOnTheSameDayAndSeq() {
        let banked = Date()
        XCTAssertFalse(TodayView.historyWideCacheHit(loadedSeq: 7, currentSeq: 7,
                                                     loadedDayKey: "2026-09-29",
                                                     currentDayKey: "2026-09-29",
                                                     bankedAt: banked,
                                                     now: banked.addingTimeInterval(TodayView.todayCacheMaxAge + 1)))
    }

    /// A new data state still misses, as before.
    func testANewRefreshSeqStillMisses() {
        let banked = Date()
        XCTAssertFalse(TodayView.historyWideCacheHit(loadedSeq: 7, currentSeq: 8,
                                                     loadedDayKey: "2026-09-29",
                                                     currentDayKey: "2026-09-29",
                                                     bankedAt: banked, now: banked))
    }

    // MARK: - Item 8: a CIVIL day shifted with ABSOLUTE time

    /// THE BUG. The rollover subtracted four hours of elapsed time to shift a calendar day. On a
    /// spring-forward date the local day is 23 h long, so 04:30 local minus four absolute hours landed at
    /// 23:30 the previous evening and "today" resolved to YESTERDAY's row for the whole 04:00–05:00 window.
    func testLogicalDayDoesNotSlipBackwardsOnSpringForward() throws {
        // US Eastern springs forward 2026-03-08 at 02:00 → 03:00.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let at0430 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 3, day: 8,
                                                                hour: 4, minute: 30)))
        // The old arithmetic, spelled out, so the regression is visible rather than asserted abstractly.
        let absoluteShift = at0430.addingTimeInterval(-4 * 3600)
        XCTAssertEqual(cal.component(.day, from: absoluteShift), 7,
                       "the fixture reproduces the report: minus four absolute hours is the 7th")

        let logical = Repository.logicalDay(at0430, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: logical), 8, "04:30 is past the rollover: today is the 8th")
        XCTAssertEqual(cal.component(.hour, from: logical), 0, "and it is that day's local midnight")
    }

    /// The rollover itself is unchanged on an ordinary day: 23:59 stays, 01:00 goes back, 04:01 rolls.
    func testTheRolloverBoundaryIsUnchanged() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func day(_ h: Int, _ m: Int, on d: Int) throws -> Int {
            let t = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 6, day: d,
                                                               hour: h, minute: m)))
            return cal.component(.day, from: Repository.logicalDay(t, calendar: cal))
        }
        XCTAssertEqual(try day(23, 59, on: 10), 10)
        XCTAssertEqual(try day(1, 0, on: 11), 10)
        XCTAssertEqual(try day(3, 59, on: 11), 10)
        XCTAssertEqual(try day(4, 1, on: 11), 11)
    }

    /// The same class, in the recent-day windows: `-(n-1) × 86 400` spanned 6 or 8 dates across a transition.
    /// Calendar arithmetic always spans exactly n.
    func testRecentDayWindowsSpanExactlyNCivilDaysAcrossADstTransition() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // Just after midnight, where the missing hour tips the window over a date boundary.
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 3, day: 10,
                                                             hour: 0, minute: 30)))
        // 7 days ending the 10th = the 4th.
        XCTAssertEqual(Repository.dayKeyOffset(now, days: 6, calendar: cal), "2026-03-04")
        // The old arithmetic, spelled out: 6 × 86 400 s back is the 3rd, so the window spanned 8 dates.
        XCTAssertEqual(cal.component(.day, from: now.addingTimeInterval(-6 * 86_400)), 3,
                       "the fixture reproduces the report: absolute-seconds arithmetic lands a day early")
    }

    // MARK: - Item 9: a substituted resting HR published as a zone input

    /// THE BUG. `publishHRZoneInputs` fires at the end of the FIRST publish, when `days` is still empty, so
    /// `HRZones.zoneRestingHR([], [])` returned the documented 60 bpm substitute tagged `.fallback` and it rode
    /// into `ProfileStore` and the displayed zone table.
    func testAFallbackRestingHrIsNotPublishedAsEvidence() {
        let fallback = HRZones.zoneRestingHR(sleepRestingHRs: [], wakingRestingHRs: [])
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.bpm, HRZones.defaultZoneRestingHR,
                       "the fixture reproduces the report: a substituted 60 bpm")
        XCTAssertFalse(Repository.shouldPublishZoneInputs(observedHRmax: nil,
                                                         restingHRSource: fallback.source))
    }

    /// Either half being real is enough to publish: a measured resting HR, or an observed HRmax to feed the
    /// learned ceiling.
    func testRealEvidenceStillPublishes() {
        XCTAssertTrue(Repository.shouldPublishZoneInputs(observedHRmax: nil, restingHRSource: .sleepMedian))
        XCTAssertTrue(Repository.shouldPublishZoneInputs(observedHRmax: nil, restingHRSource: .waking))
        XCTAssertTrue(Repository.shouldPublishZoneInputs(observedHRmax: 188, restingHRSource: .fallback),
                      "an observed HRmax is real evidence even while the resting half is not")
    }

    /// And the consumer honours the tag too: a `.fallback` resting HR is never stored, so it cannot overwrite
    /// a genuinely measured one, while the read-time placeholder still reports itself as a fallback.
    func testProfileStoreRefusesToStoreAFallbackRestingHr() throws {
        let d = UserDefaults.standard
        let keys = ["profile.zoneRestingHR", "profile.zoneRestingHRSource"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer {
            for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        }
        for k in keys { d.removeObject(forKey: k) }

        let profile = ProfileStore()
        profile.applyZoneInputs(observedHRmax: nil,
                                restingHR: HRZones.ZoneRestingHR(bpm: 52, source: .sleepMedian))
        XCTAssertEqual(profile.zoneRestingHRInput?.bpm, 52)

        profile.applyZoneInputs(observedHRmax: nil,
                                restingHR: HRZones.ZoneRestingHR(bpm: HRZones.defaultZoneRestingHR,
                                                                 source: .fallback))
        XCTAssertEqual(profile.zoneRestingHRInput?.bpm, 52,
                       "a substituted value must not overwrite a measured one")
        XCTAssertEqual(profile.zoneRestingHR.source, .sleepMedian)
    }
}
