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
        // The run's own per-minute HR: 60 of 480 minutes at 72 → P90 = 72, P25 = 52 → awake level
        // max(72·0.97, 52 + 0.6·20, 52 + 10) = 69.84: the 72 bpm hour is clearly awake, the 52 bpm night is
        // not. The 5-min rolling median moves the edge by at most ~2 min.
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
    /// Since review S1 it reads only the run (and the personal baseline) — there is no day-median input.
    func testHRSettledBoundsCapsMirrorsAndStaysSafe() {
        let start = 0
        let end = 8 * 3_600
        let p = SleepStager.Period(stage: "sleep", start: start, end: end)
        // 150 awake minutes at 75 (31% of the run → P90 = 75, level 72.75) → trim capped at 120.
        let longAwake = hrStream(start: 0, durationS: 150 * 60, bpm: 75)
            + hrStream(start: 150 * 60, durationS: end - 150 * 60, bpm: 52)
        let capped = SleepStager.hrSettledBounds(p, hr: longAwake)
        XCTAssertEqual(capped.start, start + SleepStager.onsetTrimMaxMin * 60)
        // The last 30 min awake again (lying there before getting up; 6% of the run, so P90 is still 52 and the
        // level is P25 + 10 = 62) → wake moves ~30 min earlier, onset stays.
        let lateWake = hrStream(start: 0, durationS: end - 30 * 60, bpm: 52)
            + hrStream(start: end - 30 * 60, durationS: 30 * 60, bpm: 75)
        let mirrored = SleepStager.hrSettledBounds(p, hr: lateWake)
        XCTAssertEqual(mirrored.start, start)
        XCTAssertEqual(Double(mirrored.end), Double(end - 30 * 60), accuracy: 3 * 60)
        // S2: each edge can be switched off on its own (a run inside a chain keeps that edge).
        let noOnset = SleepStager.hrSettledBounds(p, hr: longAwake, trimOnset: false)
        XCTAssertEqual(noOnset.start, start)
        let noWake = SleepStager.hrSettledBounds(p, hr: lateWake, trimWake: false)
        XCTAssertEqual(noWake.end, end)
        let neither = SleepStager.hrSettledBounds(p, hr: longAwake, trimOnset: false, trimWake: false)
        XCTAssertEqual(neither.start, start); XCTAssertEqual(neither.end, end)
        // Thin HR (< 50% of minutes covered) → untouched, even though what little HR there is reads awake.
        let thin = stride(from: 0, to: end, by: 180).map { HRSample(ts: $0, bpm: $0 < 150 * 60 ? 75 : 52) }
        let sparse = SleepStager.hrSettledBounds(p, hr: thin)
        XCTAssertEqual(sparse.start, start); XCTAssertEqual(sparse.end, end)
        // A flat night (P90 ≈ P25) has nothing clearly awake → untouched.
        let flat = SleepStager.hrSettledBounds(p, hr: hrStream(start: 0, durationS: end, bpm: 60))
        XCTAssertEqual(flat.start, start); XCTAssertEqual(flat.end, end)
    }

    /// S1: the awake level is the run's own. The ordinary first-cycle HR descent (60 → 52 over the first half
    /// hour, all under P25 + 10 = 62) is sleep and stays in the session; the personal sleep-HR baseline can only
    /// RAISE the level, so a 64 bpm first 20 minutes is trimmed cold-start but kept for a wearer whose own
    /// nights sit at 56 (level ≥ 66).
    func testAwakeLevelKeepsTheFirstCycleAndThePersonalBaselineOnlyRaisesIt() throws {
        let end = 8 * 3_600
        let p = SleepStager.Period(stage: "sleep", start: 0, end: end)
        let descent = (0..<end).map { t -> HRSample in
            HRSample(ts: t, bpm: t < 30 * 60 ? 60 - (8 * t) / (30 * 60) : 52)
        }
        let kept = SleepStager.hrSettledBounds(p, hr: descent)
        XCTAssertEqual(kept.start, 0, "a first-cycle descent below the awake level is sleep, not awake")
        let early = hrStream(start: 0, durationS: 20 * 60, bpm: 64)
            + hrStream(start: 20 * 60, durationS: end - 20 * 60, bpm: 52)
        let cold = SleepStager.hrSettledBounds(p, hr: early)
        XCTAssertEqual(Double(cold.start), Double(20 * 60), accuracy: 3 * 60)
        let personal = SleepStager.hrSettledBounds(p, hr: early, sleepHRBaseline: 56)
        XCTAssertEqual(personal.start, 0, "a personal baseline of 56 lifts the awake level to 66")
        XCTAssertEqual(try XCTUnwrap(SleepStager.onsetTrimAwakeLevel(perMinuteHR: [52, 52, 52, 52],
                                                                    sleepHRBaseline: nil)), 62, accuracy: 1e-9)
    }

    /// S1: the bounds are a property of the NIGHT, not of the read window. The same night (still from 22:00,
    /// 63 bpm for the first hour, 52 after) read in a morning window (2 h of 80 bpm after it) and in an evening
    /// window (16 h of 90 bpm after it) yields the SAME session. The old day-median threshold (61.8 vs 63.55
    /// here) trimmed the first hour in one window and kept it in the other.
    func testTrimDoesNotDependOnTheReadWindow() throws {
        let dayStart = atHour(14)
        let dayDur = 8 * 3_600
        let stillStart = dayStart + dayDur
        let nightDur = 8 * 3_600
        let wakeAt = stillStart + nightDur
        func window(afterS: Int, afterBpm: Int) -> [SleepSession] {
            let grav = activeGravity(start: dayStart, durationS: dayDur)
                + stillGravity(start: stillStart, durationS: nightDur)
                + activeGravity(start: wakeAt, durationS: afterS)
            let hr = hrStream(start: dayStart, durationS: dayDur, bpm: 80)
                + hrStream(start: stillStart, durationS: 3_600, bpm: 63)
                + hrStream(start: stillStart + 3_600, durationS: nightDur - 3_600, bpm: 52)
                + hrStream(start: wakeAt, durationS: afterS, bpm: afterBpm)
            return SleepStager.detectSleep(hr: hr, gravity: grav)
        }
        let morning = window(afterS: 2 * 3_600, afterBpm: 80)
        let evening = window(afterS: 16 * 3_600, afterBpm: 90)
        XCTAssertEqual(morning.count, 1)
        XCTAssertEqual(evening.count, 1)
        let m = try XCTUnwrap(morning.first), e = try XCTUnwrap(evening.first)
        XCTAssertEqual(m.start, e.start, "the same night must keep the same onset whatever the window holds")
        XCTAssertEqual(m.end, e.end)
        // 60 of 480 minutes at 63 → P90 = 63, level max(61.1, 58.6, 62) = 62: the 63 bpm hour is awake.
        XCTAssertGreaterThanOrEqual(m.start, stillStart + 55 * 60)
    }

    /// S2: a bathroom break inside the night. 23:00–03:00 still (30 min awake at 70 before sleeping, 25 min
    /// awake at 70 before getting up), 25 min walking, 03:25–07:00 still (25 min settling back at 70, 20 min
    /// awake at 70 before getting up). Only the night's OUTER edges are trimmed: the first run keeps its end
    /// and the second its start, so the break stays ~the 25 minutes it was instead of a 70+ minute hole.
    func testOnlyTheNightsOuterEdgesAreTrimmed() throws {
        let m = 60
        let dayStart = atHour(14)                                   // 14:00
        let run1Start = atHour(23), run1End = atHour(27)            // 23:00 → 03:00
        let run2Start = run1End + 25 * m, run2End = atHour(31)      // 03:25 → 07:00
        let after = 2 * 3_600
        let grav = activeGravity(start: dayStart, durationS: run1Start - dayStart)
            + stillGravity(start: run1Start, durationS: run1End - run1Start)
            + activeGravity(start: run1End, durationS: run2Start - run1End)
            + stillGravity(start: run2Start, durationS: run2End - run2Start)
            + activeGravity(start: run2End, durationS: after)
        let hr = hrStream(start: dayStart, durationS: run1Start - dayStart, bpm: 80)
            + hrStream(start: run1Start, durationS: 30 * m, bpm: 70)
            + hrStream(start: run1Start + 30 * m, durationS: run1End - run1Start - 55 * m, bpm: 52)
            + hrStream(start: run1End - 25 * m, durationS: 25 * m, bpm: 70)
            + hrStream(start: run1End, durationS: run2Start - run1End, bpm: 75)
            + hrStream(start: run2Start, durationS: 25 * m, bpm: 70)
            + hrStream(start: run2Start + 25 * m, durationS: run2End - run2Start - 45 * m, bpm: 52)
            + hrStream(start: run2End - 20 * m, durationS: 20 * m, bpm: 70)
            + hrStream(start: run2End, durationS: after, bpm: 80)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 2)
        let s1 = try XCTUnwrap(sessions.first), s2 = try XCTUnwrap(sessions.last)
        // The night's onset IS trimmed (the first run opens the night)…
        XCTAssertGreaterThanOrEqual(s1.start, run1Start + 25 * m)
        XCTAssertLessThanOrEqual(s1.start, run1Start + 36 * m)
        // …but the first run's END is not (a sleep run follows within nightContinuationGapMin)…
        XCTAssertGreaterThanOrEqual(s1.end, run1End - 10 * m, "the bathroom break must not be widened")
        // …nor the second run's START (it continues the chain)…
        XCTAssertLessThanOrEqual(s2.start, run2Start + 12 * m)
        // …while the night's final wake IS trimmed (nothing follows).
        XCTAssertGreaterThanOrEqual(s2.end, run2End - 25 * m)
        XCTAssertLessThanOrEqual(s2.end, run2End - 15 * m)
        XCTAssertNotNil(s2.stillRunEnd, "a trimmed session carries its untrimmed run bounds (S9)")
        XCTAssertGreaterThan(try XCTUnwrap(s2.stillRunEnd), s2.end)
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
    /// derived signals, it TRACKS a varying input: 0.2 Hz → 12 and 0.3 Hz → 18 too. S8: each 120 s window is
    /// detrended by its own least-squares line (not an 8 s moving mean, whose uneven response tilted a broad
    /// peak toward lower rates), so the same rates come back on top of a large slow drift (±150 ms over the
    /// 15 minutes, a heart rate settling through the night).
    func testSpectralRespRecoversSeveralPlantedRates() {
        let start = 1_700_000_000
        for (hz, expected) in [(0.25, 15.0), (0.2, 12.0), (0.3, 18.0)] {
            let rr = rsaRR(start: start, durationS: 900) { _ in hz }
            let est = SleepStager.respRateFromRR(rr, start: start, end: start + 900)
            XCTAssertEqual(est, expected, accuracy: 1.0, "planted \(hz) Hz")
            var drifting: [RRInterval] = []
            var t = 0.0
            while t < 900 {
                let v = 1000 + 40 * sin(2 * Double.pi * hz * t) + 150 * sin(2 * Double.pi * t / 900)
                t += v / 1000
                drifting.append(RRInterval(ts: start + Int(t), rrMs: Int(v)))
            }
            XCTAssertEqual(SleepStager.respRateFromRR(drifting, start: start, end: start + 900), expected,
                           accuracy: 1.0, "planted \(hz) Hz under slow drift")
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

    // MARK: - review fixes (S3, S6–S9)

    /// S3: a fever / alcohol night — motionless for 7 h, HR flat at 72–74 against a day median of 60 (×1.2).
    /// The quiescent band for a LONG run is back at 1.30 (78), so the night is kept even at cold start (no
    /// personal band); a short still stretch at the same HR keeps the tighter 1.15 (69) and is still refused.
    func testMotionlessHighHRNightIsKept() throws {
        let dayStart = atHour(8)
        let dayDur = 14 * 3_600                                      // 08:00–22:00 awake, moving, HR 60
        let stillStart = dayStart + dayDur                           // 22:00–05:00 still, HR 72–74
        let nightDur = 7 * 3_600
        let grav = activeGravity(start: dayStart, durationS: dayDur)
            + stillGravity(start: stillStart, durationS: nightDur)
            + activeGravity(start: stillStart + nightDur, durationS: 3_600)
        let hr = hrStream(start: dayStart, durationS: dayDur, bpm: 60)
            + (0..<nightDur).map { HRSample(ts: stillStart + $0, bpm: 72 + ($0 / 90) % 3) }
            + hrStream(start: stillStart + nightDur, durationS: 3_600, bpm: 60)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1, "a high-HR but motionless 7 h night must not be dropped")
        let s = try XCTUnwrap(sessions.first)
        XCTAssertGreaterThan(s.end - s.start, 6 * 3_600 + 30 * 60, "a flat night is not trimmed either")

        let still = stillGravity(start: 0, durationS: 4 * 3_600)
        let flat = (0..<(4 * 3_600)).map { HRSample(ts: $0, bpm: 72 + ($0 / 90) % 3) }
        let long = SleepStager.Period(stage: "sleep", start: 0, end: 4 * 3_600)
        let short = SleepStager.Period(stage: "sleep", start: 0, end: 2 * 3_600)
        XCTAssertTrue(SleepStager.confirmSleepWithHR(long, hr: flat, baseline: 60, grav: still))
        XCTAssertFalse(SleepStager.confirmSleepWithHR(short, hr: flat, baseline: 60, grav: still),
                       "a short still stretch keeps the 1.15 band")
    }

    /// S6: a last deep run of ONE 5-min block (56) is one noisy sample, not a slow-wave period: the value
    /// falls through to every deep block (four at 50 + that one → 51.2 → 51).
    func testRestingHRNeedsTwoBlocksInTheLastDeepRun() {
        let m = 60
        let stages = [
            StageSegment(start: 0, end: 20 * m, stage: "light"),
            StageSegment(start: 20 * m, end: 40 * m, stage: "deep"),
            StageSegment(start: 40 * m, end: 80 * m, stage: "light"),
            StageSegment(start: 80 * m, end: 85 * m, stage: "deep"),
            StageSegment(start: 85 * m, end: 120 * m, stage: "light"),
        ]
        let hr = (0..<(120 * m)).map { t -> HRSample in
            let bpm: Int
            switch t {
            case (20 * m)..<(40 * m): bpm = 50
            case (80 * m)..<(85 * m): bpm = 56
            default: bpm = 60
            }
            return HRSample(ts: t, bpm: bpm)
        }
        XCTAssertEqual(SleepStager.sessionSleepRestingHR(start: 0, end: 120 * m, hr: hr, stages: stages), 51)
    }

    /// S7: a night bridged from two fragments reads the NIGHT's last deep run. Fragment A (0–120 min) holds a
    /// deep run at 50 bpm; fragment B (150–270 min) one at 56. The night's resting HR is 56 — and when B has no
    /// deep sleep at all it is A's 50 (the night's last deep run lives in A), never a per-fragment pick.
    func testBridgedNightRestingHRPoolsTheFragments() {
        let m = 60
        let a = (start: 0, end: 120 * m, stages: [
            StageSegment(start: 0, end: 20 * m, stage: "light"),
            StageSegment(start: 20 * m, end: 40 * m, stage: "deep"),
            StageSegment(start: 40 * m, end: 120 * m, stage: "light"),
        ])
        let bDeep = (start: 150 * m, end: 270 * m, stages: [
            StageSegment(start: 150 * m, end: 200 * m, stage: "light"),
            StageSegment(start: 200 * m, end: 220 * m, stage: "deep"),
            StageSegment(start: 220 * m, end: 270 * m, stage: "light"),
        ])
        let bLight = (start: 150 * m, end: 270 * m, stages: [StageSegment(start: 150 * m, end: 270 * m, stage: "light")])
        let hr = (Array(0..<(120 * m)) + Array((150 * m)..<(270 * m))).map { t -> HRSample in
            let bpm: Int
            switch t {
            case (20 * m)..<(40 * m): bpm = 50
            case (200 * m)..<(220 * m): bpm = 56
            default: bpm = 60
            }
            return HRSample(ts: t, bpm: bpm)
        }
        XCTAssertEqual(SleepStager.nightSleepRestingHR(fragments: [a, bDeep], hr: hr), 56)
        XCTAssertEqual(SleepStager.nightSleepRestingHR(fragments: [bLight, a], hr: hr), 50,
                       "with no deep sleep in B the night's last deep run is A's")
    }

    /// S7: the bridged night's HRV is the NIGHT's last deep run over the pooled windows. A: deep a=10 (20 ms)
    /// then light a=25; B: light a=25 then deep a=15 (30 ms) → 30. With B all light the night's last deep run is
    /// A's (20 ms) — the old duration-weighted blend of A's 20 with B's non-wake 50 read ~35.
    func testBridgedNightHRVIsTheNightsLastDeepRun() throws {
        let m = 60
        func beats(_ from: Int, _ to: Int, _ amp: (Int) -> Int) -> [RRInterval] {
            (from..<to).map { t in RRInterval(ts: t, rrMs: t % 2 == 0 ? 1000 + amp(t) : 1000 - amp(t)) }
        }
        let rr = beats(0, 60 * m) { $0 < 30 * m ? 10 : 25 } + beats(90 * m, 150 * m) { $0 < 120 * m ? 25 : 15 }
        let a = (start: 0, end: 60 * m, stages: [StageSegment(start: 0, end: 30 * m, stage: "deep"),
                                                  StageSegment(start: 30 * m, end: 60 * m, stage: "light")])
        let bDeep = (start: 90 * m, end: 150 * m, stages: [StageSegment(start: 90 * m, end: 120 * m, stage: "light"),
                                                            StageSegment(start: 120 * m, end: 150 * m, stage: "deep")])
        let bLight = (start: 90 * m, end: 150 * m, stages: [StageSegment(start: 90 * m, end: 150 * m, stage: "light")])
        XCTAssertEqual(try XCTUnwrap(SleepStager.nightAvgHRV(fragments: [a, bDeep], rr: rr)), 30, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(SleepStager.nightAvgHRV(fragments: [a, bLight], rr: rr)), 20, accuracy: 1)
    }

    /// S9: the waking resting HR excludes the UNTRIMMED in-bed run ± 30 min. Lying in bed at 50 bpm from 06:00
    /// to 08:00 after a wake trimmed to 06:00 (run untrimmed to 07:30) used to count as waking minutes and set
    /// the P10 at 50; masked, the floor is the day's own 70.
    func testWakingRestingHRMasksTheUntrimmedInBedRun() throws {
        let day0 = 1_749_513_600                                     // 00:00 UTC
        let hr = stride(from: day0 + 6 * 3_600, to: day0 + 22 * 3_600, by: 10).map { ts in
            HRSample(ts: ts, bpm: ts < day0 + 8 * 3_600 ? 50 : 70)
        }
        let session = SleepSession(start: day0 - 2 * 3_600, end: day0 + 6 * 3_600, efficiency: 0.9, stages: [],
                                   restingHR: 50, avgHRV: nil,
                                   stillRunStart: day0 - 3 * 3_600, stillRunEnd: day0 + 7 * 3_600 + 1_800)
        XCTAssertEqual(session.stillRunBounds.end, day0 + 7 * 3_600 + 1_800)
        let trimmedOnly = WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: [(start: session.start,
                                                                                 end: session.end)])
        XCTAssertEqual(try XCTUnwrap(trimmedOnly), 50, accuracy: 1e-9)
        let masked = WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: WakingRestingHR.inBedMask([session.stillRunBounds]))
        XCTAssertEqual(try XCTUnwrap(masked), 70, accuracy: 1e-9)
    }

    /// S9: NEAT is never credited inside the in-bed mask; resting and exercise energy are untouched.
    func testNeatIsNotCreditedInsideTheSleepMask() {
        let hr = (0..<3_600).map { HRSample(ts: 1_000_000 + $0, bpm: 90) }
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let open = Calories.estimateDayEnergy(hr, profile: profile, hrmax: 190, restingHR: 60, includeNEAT: true)
        let masked = Calories.estimateDayEnergy(hr, profile: profile, hrmax: 190, restingHR: 60, includeNEAT: true,
                                                neatExcluding: [(start: 1_000_000, end: 1_003_600)])
        XCTAssertGreaterThan(open.neatKcal, 0)
        XCTAssertEqual(masked.neatKcal, 0)
        XCTAssertEqual(masked.restingKcal, open.restingKcal, accuracy: 1e-9)
        XCTAssertEqual(masked.activeKcal, open.activeKcal, accuracy: 1e-9)
    }
}
