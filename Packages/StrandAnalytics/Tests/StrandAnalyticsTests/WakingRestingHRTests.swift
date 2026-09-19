import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// O7: the WAKING resting HR the Uth / Karvonen / Keytel / HUNT formulas were fitted on, measured as the
/// day's waking floor (P10 of waking per-minute means outside detected sleep), else sleep RHR + 6 bpm.
final class WakingRestingHRTests: XCTestCase {

    /// 2026-01-02T00:00:00Z — local == UTC in these fixtures (tzOffsetSeconds 0).
    private let midnight = 1_767_312_000

    /// `minutes` consecutive minutes at `bpm`, one sample every 10 s, starting `startMin` after midnight.
    private func block(startMin: Int, minutes: Int, bpm: Int) -> [HRSample] {
        (0..<(minutes * 6)).map { HRSample(ts: midnight + startMin * 60 + $0 * 10, bpm: bpm) }
    }

    // MARK: - fallback / resolve

    func testSleepFallbackAddsTheDocumentedOffset() {
        XCTAssertEqual(WakingRestingHR.fromSleep(54)!, 54 + WakingRestingHR.sleepToWakingOffsetBpm, accuracy: 1e-12)
        XCTAssertEqual(WakingRestingHR.sleepToWakingOffsetBpm, 6.0)
        XCTAssertNil(WakingRestingHR.fromSleep(nil))
        XCTAssertNil(WakingRestingHR.fromSleep(0))
    }

    func testResolvePrefersTheMeasuredDaytimeFloor() {
        XCTAssertEqual(WakingRestingHR.resolve(daytime: 63, sleepRestingHR: 52)!, 63, accuracy: 1e-12)
        XCTAssertEqual(WakingRestingHR.resolve(daytime: nil, sleepRestingHR: 52)!, 58, accuracy: 1e-12)
        XCTAssertNil(WakingRestingHR.resolve(daytime: nil, sleepRestingHR: nil))
        // An implausible "measurement" is not trusted over the fallback.
        XCTAssertEqual(WakingRestingHR.resolve(daytime: 20, sleepRestingHR: 52)!, 58, accuracy: 1e-12)
    }

    func testTypicalIsTheMedianOfTheResolvedDays() {
        let days: [(daytime: Double?, sleep: Double?)] = [
            (daytime: 64, sleep: 55), (daytime: nil, sleep: 54), (daytime: 66, sleep: nil),
            (daytime: nil, sleep: nil), (daytime: 70, sleep: 60),
        ]
        // Resolved: 64, 60, 66, 70 → median (64 + 66) / 2.
        XCTAssertEqual(WakingRestingHR.typical(days)!, 65, accuracy: 1e-12)
        XCTAssertNil(WakingRestingHR.typical([(daytime: nil, sleep: nil)]))
    }

    // MARK: - daytime estimate

    /// The floor is the 10th percentile of WAKING minutes: 10 h at 68 and 2 h at 95 → 68.
    func testDaytimeFloorIsTheLowDecileOfWakingMinutes() {
        let hr = block(startMin: 8 * 60, minutes: 600, bpm: 68) + block(startMin: 18 * 60, minutes: 120, bpm: 95)
        XCTAssertEqual(WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: [])!, 68, accuracy: 1e-9)
    }

    /// Night-time minutes (before 06:00) and minutes inside a detected sleep session never count, however low.
    func testSleepAndNightMinutesAreExcluded() {
        let night = block(startMin: 60, minutes: 240, bpm: 48)                // 01:00–05:00, outside 06–22
        let nap = block(startMin: 13 * 60, minutes: 90, bpm: 50)              // a detected nap
        let day = block(startMin: 7 * 60, minutes: 300, bpm: 66) + block(startMin: 15 * 60, minutes: 240, bpm: 80)
        let napSpan = (start: midnight + 13 * 60 * 60, end: midnight + 13 * 60 * 60 + 90 * 60)
        let v = WakingRestingHR.daytimeEstimate(hr: night + nap + day, sleepWindows: [napSpan])
        XCTAssertEqual(v!, 66, accuracy: 1e-9)
        // Without the nap window the nap's 50 bpm minutes drag the floor down.
        XCTAssertLessThan(WakingRestingHR.daytimeEstimate(hr: night + nap + day, sleepWindows: [])!, 60)
    }

    func testTooLittleWakingWearYieldsNil() {
        let hr = block(startMin: 9 * 60, minutes: WakingRestingHR.minWakingMinutes - 1, bpm: 65)
        XCTAssertNil(WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: []))
    }

    /// Never below the sleeping RHR, and a floor implausibly far above it (a workout-only day) is dropped.
    func testClampedAgainstTheSleepRestingHR() {
        let calm = block(startMin: 8 * 60, minutes: 300, bpm: 55)
        XCTAssertEqual(WakingRestingHR.daytimeEstimate(hr: calm, sleepWindows: [], sleepRestingHR: 58)!, 58,
                       accuracy: 1e-9)
        let busy = block(startMin: 8 * 60, minutes: 300, bpm: 120)
        XCTAssertNil(WakingRestingHR.daytimeEstimate(hr: busy, sleepWindows: [], sleepRestingHR: 55))
    }

    /// The local waking window follows the time zone: at UTC+2, 05:00Z is 07:00 local (waking).
    func testWakingWindowIsLocal() {
        let hr = block(startMin: 5 * 60, minutes: 150, bpm: 62)   // 05:00–07:30Z
        XCTAssertNil(WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: [], tzOffsetSeconds: 0),
                     "at UTC only 06:00–07:30 is waking: 90 minutes, under the 120-minute minimum")
        XCTAssertEqual(WakingRestingHR.daytimeEstimate(hr: hr, sleepWindows: [], tzOffsetSeconds: 7_200)!, 62,
                       accuracy: 1e-9)
    }

    // MARK: - the engine threads it

    /// A day with 12 waking hours of HR and no sleep: the engine measures the waking floor, reports it on
    /// the DayResult, and its energy picks up NEAT from the brisk hour (O10b).
    func testAnalyzeDayReportsTheWakingRestingHRAndActiveEnergy() {
        let hr = block(startMin: 8 * 60, minutes: 660, bpm: 68) + block(startMin: 19 * 60, minutes: 60, bpm: 95)
        let res = AnalyticsEngine.analyzeDay(day: "2026-01-02", hr: hr, profile: UserProfile(age: 30))
        XCTAssertEqual(res.wakingRestingHR ?? 0, 68, accuracy: 1e-9)
        XCTAssertEqual(res.wakingRestingHRUsed ?? 0, 68, accuracy: 1e-9)
        let active = res.activeEnergyKcal ?? 0
        XCTAssertGreaterThan(active, 0, "the 95 bpm hour sits between rest and the gate: NEAT")
        XCTAssertGreaterThan(res.daily.activeKcalEst ?? 0, active, "activeKcalEst is the TOTAL")
    }

    // MARK: - bouts: energy on the waking rest, detection unchanged

    func testBoutEnergyReadsTheWakingRestButDetectionDoesNot() {
        // 20 min at 140 bpm with oscillating gravity: one clear bout against resting 60 / HRmax 190.
        let hr = (0..<1200).map { HRSample(ts: $0, bpm: 140) }
        let grav = (0..<1200).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.5, y: 0, z: 1) }
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 35, sex: "male")
        let legacy = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190,
                                            age: 35, profile: profile)
        let same = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, wakingRestingHR: 60,
                                          maxHR: 190, age: 35, profile: profile)
        let waking = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, wakingRestingHR: 66,
                                            maxHR: 190, age: 35, profile: profile)
        XCTAssertEqual(legacy, same, "nil waking rest is exactly the pre-O7 behaviour")
        XCTAssertEqual(legacy.count, waking.count, "the waking rest must not change which bouts are detected")
        for (a, b) in zip(legacy, waking) {
            XCTAssertEqual(a.start, b.start)
            if let ka = a.caloriesKcal, let kb = b.caloriesKcal {
                // A higher (waking) rest → a lower Uth VO₂max → a lower fitness-adjusted Keytel rate.
                XCTAssertLessThan(kb, ka)
            }
        }
    }
}
