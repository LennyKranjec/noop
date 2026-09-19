import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The nightly-metrics rework, which moves NOOP's nightly numbers toward how WHOOP defines them:
///   O1 sleep onset/wake follow the HEART RATE settling, not just the wrist going still;
///   O2 resting HR is the mean over the LAST deep run of the MAIN night (not the lowest block of any session);
///   O3 respiration is a SPECTRAL estimate over SLEEP windows (deep preferred) of the main night;
///   O4 nightly HRV is the mean RMSSD over the LAST deep run (not the whole-night mean).
/// Every vector is synthetic and says so; the physiology they plant is the property under test.
final class NightlyMetricsReworkTests: XCTestCase {

    // MARK: - fixtures

    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            GravitySample(ts: start + i, x: Double(i % 2) * 0.5, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// 2026-06-10 00:00:00 UTC + `hour` hours (the detector runs at tzOffset 0 here, so local == UTC).
    private func atHour(_ hour: Int) -> Int { 1_749_513_600 + hour * 3_600 }

    /// Beat-accurate R-R carrying an RSA line at `breathHz(t)` (t = seconds from `start`).
    private func rsaRR(start: Int, durationS: Double, baseMs: Double = 1000, ampMs: Double = 40,
                       breathHz: (Double) -> Double) -> [RRInterval] {
        var rows: [RRInterval] = []
        var t = 0.0
        while t < durationS {
            let rr = baseMs + ampMs * sin(2.0 * Double.pi * breathHz(t) * t)
            t += rr / 1000.0
            rows.append(RRInterval(ts: start + Int(t), rrMs: Int(rr)))
        }
        return rows
    }

    // MARK: - O1 onset / wake trim

    /// Still in bed from 22:00, but the heart rate stays at an awake 72 for the first hour (reading) before
    /// dropping to a sleeping 52. The day before was active at ~80. The gravity run starts at ~22:00; the
    /// session must start where the HR settled, ~23:00, not at the stillness boundary.
    func testOnsetTrimmedWhenHRStaysHighThroughTheFirstStillHour() throws {
        let dayStart = atHour(14)
        let dayDur = 8 * 3_600                          // 14:00–22:00 awake, moving, HR 80
        let stillStart = dayStart + dayDur              // 22:00 still in bed
        let grav = activeGravity(start: dayStart, durationS: dayDur)
            + stillGravity(start: stillStart, durationS: 8 * 3_600)
        let hr = hrStream(start: dayStart, durationS: dayDur, bpm: 80)
            + hrStream(start: stillStart, durationS: 3_600, bpm: 72)          // awake, still, reading
            + hrStream(start: stillStart + 3_600, durationS: 7 * 3_600, bpm: 52)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        // Day median 76, run floor 52 → threshold min(68.4, 52 + 0.35·24 = 60.4) = 60.4: the 72 bpm hour is
        // not settled, the 52 bpm night is. The 5-min rolling median moves the edge by at most ~2 min.
        XCTAssertGreaterThanOrEqual(s.start, stillStart + 55 * 60, "onset must move past the awake hour")
        XCTAssertLessThanOrEqual(s.start, stillStart + 65 * 60, "…and no further than the HR drop")
        // The night's own end is untouched (HR stays settled to the last minute).
        XCTAssertGreaterThan(s.end, stillStart + 8 * 3_600 - 10 * 60)
    }

    /// Same night, but the HR drops to 52 the moment the wearer lies still: nothing to trim, the session keeps
    /// the gravity boundary.
    func testOnsetNotTrimmedWhenHRDropsImmediately() throws {
        let dayStart = atHour(14)
        let dayDur = 8 * 3_600
        let stillStart = dayStart + dayDur
        let grav = activeGravity(start: dayStart, durationS: dayDur)
            + stillGravity(start: stillStart, durationS: 8 * 3_600)
        let hr = hrStream(start: dayStart, durationS: dayDur, bpm: 80)
            + hrStream(start: stillStart, durationS: 8 * 3_600, bpm: 52)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertGreaterThanOrEqual(s.start, stillStart)
        XCTAssertLessThan(s.start, stillStart + 10 * 60, "an immediate HR drop must leave onset at stillness")
    }

    /// The pure helper: onset capped at `onsetTrimMaxMin`, wake mirrored at the other end, and every no-op path.
    func testHRSettledBoundsCapsMirrorsAndStaysSafe() {
        let start = 0
        let end = 8 * 3_600
        let p = SleepStager.Period(stage: "sleep", start: start, end: end)
        // 150 awake minutes → trim capped at 120.
        let longAwake = hrStream(start: 0, durationS: 150 * 60, bpm: 75)
            + hrStream(start: 150 * 60, durationS: end - 150 * 60, bpm: 52)
        let capped = SleepStager.hrSettledBounds(p, hr: longAwake, dayMedian: 76)
        XCTAssertEqual(capped.start, start + SleepStager.onsetTrimMaxMin * 60)
        // The last 30 min awake again (lying there before getting up) → wake moves ~30 min earlier.
        let lateWake = hrStream(start: 0, durationS: end - 30 * 60, bpm: 52)
            + hrStream(start: end - 30 * 60, durationS: 30 * 60, bpm: 75)
        let mirrored = SleepStager.hrSettledBounds(p, hr: lateWake, dayMedian: 76)
        XCTAssertEqual(mirrored.start, start)
        XCTAssertEqual(Double(mirrored.end), Double(end - 30 * 60), accuracy: 3 * 60)
        // No day median → untouched.
        let noBase = SleepStager.hrSettledBounds(p, hr: longAwake, dayMedian: nil)
        XCTAssertEqual(noBase.start, start); XCTAssertEqual(noBase.end, end)
        // Thin HR (< 50% of minutes covered) → untouched, even though what little HR there is reads awake.
        let thin = stride(from: 0, to: end, by: 180).map { HRSample(ts: $0, bpm: $0 < 150 * 60 ? 75 : 52) }
        let sparse = SleepStager.hrSettledBounds(p, hr: thin, dayMedian: 76)
        XCTAssertEqual(sparse.start, start); XCTAssertEqual(sparse.end, end)
        // An HR that never dips under the day median (flat night, flat day) → no settled stretch → untouched.
        let flat = SleepStager.hrSettledBounds(p, hr: hrStream(start: 0, durationS: end, bpm: 60), dayMedian: 60)
        XCTAssertEqual(flat.start, start); XCTAssertEqual(flat.end, end)
    }

    // MARK: - O1 gate: personal overnight band

    /// The personal overnight band can only RESCUE: a run the day-median band drops (median ~59 vs 50×1.05)
    /// is kept when the wearer's own recent nights sit at 54 (×1.15 = 62.1), and a low personal baseline
    /// never rejects a run the day band keeps.
    func testPersonalOvernightBandOnlyRescues() {
        let p = SleepStager.Period(stage: "sleep", start: 0, end: 90 * 60)
        let hr = (0..<(90 * 60)).map { HRSample(ts: $0, bpm: 58 + ($0 / 90) % 3) }
        XCTAssertFalse(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 50))
        XCTAssertTrue(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 50, sleepHRBaseline: 54))
        XCTAssertTrue(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 60, sleepHRBaseline: 40),
                      "a low personal baseline must not reject what the day band keeps")
    }

    func testTrailingSleepHRBaselineSkipsNapsAndNeedsHistory() throws {
        let h = 3_600
        let nights: [(start: Int, end: Int, restingHR: Int?)] = [
            (start: 0, end: 8 * h, restingHR: 54),
            (start: 86_400, end: 86_400 + 7 * h, restingHR: 56),
            (start: 2 * 86_400, end: 2 * 86_400 + 8 * h, restingHR: 55),
            (start: 2 * 86_400 + 14 * h, end: 2 * 86_400 + 15 * h, restingHR: 40),   // a nap: ignored
        ]
        XCTAssertEqual(try XCTUnwrap(SleepStager.trailingSleepHRBaseline(nights: nights)), 55, accuracy: 1e-9)
        XCTAssertNil(SleepStager.trailingSleepHRBaseline(nights: Array(nights.prefix(2))),
                     "fewer than sleepHRBaselineMinNights nights → no personal band (cold start)")
    }

    // MARK: - O2 resting HR

    /// Two deep runs (50 then 56 bpm), light sleep at 60 with one 5-min dip to 45. WHOOP reads the LAST
    /// slow-wave period: 56 — not the floor (45, the old answer) and not the first deep run (50).
    func testRestingHRIsTheLastDeepRunMeanNotTheMinimum() {
        let m = 60
        let stages = [
            StageSegment(start: 0, end: 20 * m, stage: "light"),
            StageSegment(start: 20 * m, end: 40 * m, stage: "deep"),
            StageSegment(start: 40 * m, end: 80 * m, stage: "light"),
            StageSegment(start: 80 * m, end: 100 * m, stage: "deep"),
            StageSegment(start: 100 * m, end: 120 * m, stage: "light"),
        ]
        let hr = (0..<(120 * m)).map { t -> HRSample in
            let bpm: Int
            switch t {
            case (20 * m)..<(40 * m): bpm = 50
            case (60 * m)..<(65 * m): bpm = 45             // a brief dip inside light sleep
            case (80 * m)..<(100 * m): bpm = 56
            default: bpm = 60
            }
            return HRSample(ts: t, bpm: bpm)
        }
        XCTAssertEqual(SleepStager.sessionSleepRestingHR(start: 0, end: 120 * m, hr: hr, stages: stages), 56)
        XCTAssertEqual(SleepStager.sessionRestingHR(start: 0, end: 120 * m, hr: hr), 45,
                       "the legacy floor (still the daytime-guard input) is unchanged")
        // No deep sleep at all → the lowest quartile of the LAST THIRD's blocks (80–120 min: four at 56, four
        // at 60 → the lowest two average 56). The 45 dip sits in the middle third and is not reached.
        let noDeep = [StageSegment(start: 0, end: 120 * m, stage: "light")]
        XCTAssertEqual(SleepStager.sessionSleepRestingHR(start: 0, end: 120 * m, hr: hr, stages: noDeep), 56)
    }

    /// A day with a main night AND a nap: the daily resting HR / HRV are the NIGHT's, never the nap's
    /// (the old `.min()` let a low-HR nap replace the night; the old HRV weighted the nap in).
    func testDailyRestingHRAndHRVIgnoreTheNap() throws {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let nightStart = dayStart - 2 * 3_600, nightEnd = dayStart + 6 * 3_600     // 22:00 → 06:00
        let napStart = dayStart + 13 * 3_600, napEnd = napStart + 3_600            // 13:00 → 14:00
        let provided = [
            SleepSession(start: nightStart, end: nightEnd, efficiency: 0.9,
                         stages: [StageSegment(start: nightStart, end: nightEnd, stage: "light")],
                         restingHR: 55, avgHRV: 40),
            SleepSession(start: napStart, end: napEnd, efficiency: 0.9,
                         stages: [StageSegment(start: napStart, end: napEnd, stage: "light")],
                         restingHR: 48, avgHRV: 80),
        ]
        let hr = stride(from: nightStart, to: napEnd, by: 30).map { HRSample(ts: $0, bpm: 55) }
        let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, profile: UserProfile(age: 30),
                                             providedSleep: provided)
        XCTAssertEqual(res.daily.restingHr, 55, "the nap's lower 48 must not replace the night")
        XCTAssertEqual(try XCTUnwrap(res.daily.avgHrv), 40, accuracy: 1e-9, "the nap must not be weighted in")
    }

    // MARK: - O3 respiration

    /// The spectral estimate recovers a planted 0.25 Hz RSA as 15 ± 1 /min — and, per the repo's rule for
    /// derived signals, it TRACKS a varying input: 0.2 Hz → 12 and 0.3 Hz → 18 too.
    func testSpectralRespRecoversSeveralPlantedRates() {
        let start = 1_700_000_000
        for (hz, expected) in [(0.25, 15.0), (0.2, 12.0), (0.3, 18.0)] {
            let rr = rsaRR(start: start, durationS: 900) { _ in hz }
            let est = SleepStager.respRateFromRR(rr, start: start, end: start + 900)
            XCTAssertEqual(est, expected, accuracy: 1.0, "planted \(hz) Hz")
        }
    }

    /// Deep sleep is preferred: 30 min of deep at 12/min then 30 min of light at 18/min reads 12. Wake
    /// windows never count — an all-wake hypnogram yields no estimate.
    func testSpectralRespPrefersDeepAndExcludesWake() {
        let start = 1_700_000_000
        let rr = rsaRR(start: start, durationS: 3_600) { t in t < 1_800 ? 0.2 : 0.3 }
        let stages = [StageSegment(start: start, end: start + 1_800, stage: "deep"),
                      StageSegment(start: start + 1_800, end: start + 3_600, stage: "light")]
        XCTAssertEqual(SleepStager.respRateFromRR(rr, start: start, end: start + 3_600, stages: stages),
                       12.0, accuracy: 1.0)
        let allWake = [StageSegment(start: start, end: start + 3_600, stage: "wake")]
        XCTAssertTrue(SleepStager.respRateFromRR(rr, start: start, end: start + 3_600, stages: allWake).isNaN)
    }

    // MARK: - O4 HRV

    /// Alternating ±a ms beats give RMSSD = 2a per window. First deep run a=10 (20 ms), light a=25 (50 ms),
    /// last deep run a=15 (30 ms), final wake a=40 (80 ms). WHOOP-style HRV = the LAST deep run: 30 ms.
    func testNightlyHRVIsTheLastDeepRun() throws {
        let m = 60
        let stages = [
            StageSegment(start: 0, end: 30 * m, stage: "deep"),
            StageSegment(start: 30 * m, end: 60 * m, stage: "light"),
            StageSegment(start: 60 * m, end: 90 * m, stage: "deep"),
            StageSegment(start: 90 * m, end: 100 * m, stage: "wake"),
        ]
        let rr = (0..<(100 * m)).map { t -> RRInterval in
            let a: Int
            switch t {
            case 0..<(30 * m): a = 10
            case (30 * m)..<(60 * m): a = 25
            case (60 * m)..<(90 * m): a = 15
            default: a = 40
            }
            return RRInterval(ts: t, rrMs: t % 2 == 0 ? 1000 + a : 1000 - a)
        }
        let hrv = try XCTUnwrap(SleepStager.sessionAvgHRV(start: 0, end: 100 * m, rr: rr, stages: stages))
        XCTAssertEqual(hrv, 30.0, accuracy: 1.0)
        // No deep sleep → every non-wake window (light only here: 50 ms); the wake windows never count.
        let noDeep = [StageSegment(start: 0, end: 90 * m, stage: "light"),
                      StageSegment(start: 90 * m, end: 100 * m, stage: "wake")]
        let nonWake = try XCTUnwrap(SleepStager.sessionAvgHRV(start: 0, end: 100 * m, rr: rr, stages: noDeep))
        XCTAssertLessThan(nonWake, 60.0, "wake windows (80 ms) must be excluded")
        XCTAssertGreaterThan(nonWake, 25.0)
    }
}
