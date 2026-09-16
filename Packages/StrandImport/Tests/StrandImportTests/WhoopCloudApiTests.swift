import Foundation
import XCTest
@testable import StrandImport

/// Parity pin for the WHOOP cloud parser. The same bodies MUST produce the same rows as the Android
/// twin `com.noop.ingest.WhoopCloudApiTest`.
///
/// Three rules carry this file, and each of them is a bug that already happened on the Android lane:
///
///   * AN UNSCORED RECORD IS SKIPPED, NOT ZEROED. A pending night written as zero puts a terrible
///     recovery on a day WHOOP has simply not graded yet, and it is overwritten hours later — so the
///     wearer watches their history change under them.
///   * THE DAY COMES FROM THE RECORD'S OWN OFFSET. Bucketing by the phone's current zone shifts a
///     travelled week by one, which looks exactly like missing data.
///   * A CYCLE ID MAY BE A NUMBER OR A UUID. v1 numbers its cycles and v2 moved to UUIDs; reading it
///     as an integer makes every v2 recovery unplaceable and the whole endpoint look empty.
final class WhoopCloudApiTests: XCTestCase {

    // MARK: - Cycles

    func testACycleIsFiledUnderTheDayItStartedOnInItsOwnZone() {
        // 23:40 in +09:00 is still the 14th THERE, and that is the day the cycle belongs to — even
        // though the same instant is the 14th at 14:40 UTC and could be the 14th or 15th elsewhere.
        let body = """
        {"records":[{"id":123,"start":"2026-09-14T14:40:00.000Z","timezone_offset":"+09:00",
        "score_state":"SCORED","score":{"strain":14.9}}]}
        """
        let parsed = WhoopCloudApi.parseCycles(body)
        XCTAssertEqual(parsed.dayById["123"], "2026-09-14")
        XCTAssertEqual(parsed.byDay["2026-09-14"]?.strain ?? 0, 14.9, accuracy: 0.0001)
    }

    func testAnUnscoredCycleStillPlacesItsDayButCarriesNoStrain() {
        // The day map is what the recovery endpoint is placed through, so it must be built even for a
        // cycle WHOOP has not finished scoring — otherwise a recovery for that day is silently dropped.
        let body = """
        {"records":[{"id":"abc","start":"2026-09-14T06:00:00Z","timezone_offset":"+00:00",
        "score_state":"PENDING_SCORE"}]}
        """
        let parsed = WhoopCloudApi.parseCycles(body)
        XCTAssertEqual(parsed.dayById["abc"], "2026-09-14")
        XCTAssertNil(parsed.byDay["2026-09-14"])
    }

    // MARK: - Recovery

    func testRecoveryIsKeyedThroughTheCycleAndReadsTheCycleIdAsAString() {
        let cycles = ["c-9f3e-uuid": "2026-09-14"]
        let body = """
        {"records":[{"cycle_id":"c-9f3e-uuid","score_state":"SCORED",
        "score":{"recovery_score":71,"resting_heart_rate":48,"hrv_rmssd_milli":65.4}}]}
        """
        let day = WhoopCloudApi.parseRecovery(body, cycleDayById: cycles)["2026-09-14"]
        XCTAssertEqual(day?.recovery ?? 0, 71, accuracy: 0.0001)
        XCTAssertEqual(day?.restingHr, 48)
        XCTAssertEqual(day?.hrv ?? 0, 65.4, accuracy: 0.0001)
    }

    func testACalibratingRecoveryIsNotStored() {
        // WHOOP itself says the figure is not yet meaningful. Storing it shows a number the source does
        // not stand behind.
        let body = """
        {"records":[{"cycle_id":"1","score_state":"SCORED",
        "score":{"recovery_score":33,"user_calibrating":true}}]}
        """
        XCTAssertTrue(WhoopCloudApi.parseRecovery(body, cycleDayById: ["1": "2026-09-14"]).isEmpty)
    }

    func testARecoveryWhoseCycleIsUnknownIsDroppedRatherThanGuessed() {
        let body = """
        {"records":[{"cycle_id":"999","score_state":"SCORED","score":{"recovery_score":71}}]}
        """
        XCTAssertTrue(WhoopCloudApi.parseRecovery(body, cycleDayById: ["1": "2026-09-14"]).isEmpty)
    }

    // MARK: - HRV units

    func testHrvArrivingInSecondsIsConvertedAndMillisecondsAreLeftAlone() {
        // The field is documented as milliseconds and has been observed arriving as seconds. A resting
        // RMSSD below 1 ms is not something a living person produces, so the value decides.
        XCTAssertEqual(WhoopCloudApi.hrvMilliseconds(0.0654) ?? 0, 65.4, accuracy: 0.0001)
        XCTAssertEqual(WhoopCloudApi.hrvMilliseconds(65.4) ?? 0, 65.4, accuracy: 0.0001)
        XCTAssertNil(WhoopCloudApi.hrvMilliseconds(0))
        XCTAssertNil(WhoopCloudApi.hrvMilliseconds(-3))
    }

    // MARK: - Sleep

    func testANightIsFiledUnderTheDayItEndsOnAndTotalsOnlyTheAsleepStages() {
        // In-bed time is reported separately, and adding it would turn "you slept" into "you lay there".
        let body = """
        {"records":[{"nap":false,"score_state":"SCORED","end":"2026-09-15T06:30:00Z",
        "timezone_offset":"+02:00","score":{"sleep_performance_percentage":81,
        "sleep_efficiency_percentage":93.5,"respiratory_rate":14.2,
        "stage_summary":{"total_slow_wave_sleep_time_milli":3600000,
        "total_rem_sleep_time_milli":5400000,"total_light_sleep_time_milli":9000000,
        "total_awake_time_milli":1800000}}}]}
        """
        let day = WhoopCloudApi.parseSleep(body)["2026-09-15"]
        XCTAssertEqual(day?.sleepPerformance ?? 0, 81, accuracy: 0.0001)
        XCTAssertEqual(day?.deepMin ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(day?.remMin ?? 0, 90, accuracy: 0.0001)
        XCTAssertEqual(day?.lightMin ?? 0, 150, accuracy: 0.0001)
        XCTAssertEqual(day?.totalSleepMin ?? 0, 300, accuracy: 0.0001, "awake time is not sleep")
        XCTAssertEqual(day?.efficiency ?? 0, 93.5, accuracy: 0.0001)
        XCTAssertEqual(day?.respRateBpm ?? 0, 14.2, accuracy: 0.0001)
    }

    func testANapIsNotANight() {
        let body = """
        {"records":[{"nap":true,"score_state":"SCORED","end":"2026-09-15T13:00:00Z",
        "timezone_offset":"+00:00","score":{"sleep_performance_percentage":12}}]}
        """
        XCTAssertTrue(WhoopCloudApi.parseSleep(body).isEmpty)
    }

    // MARK: - Merge

    func testMergeFillsGapsAndNeverBlanksAFieldAnotherEndpointMeasured() {
        let cycles = ["2026-09-14": WhoopCloudApi.CloudDay(day: "2026-09-14", strain: 14.9)]
        let recovery = ["2026-09-14": WhoopCloudApi.CloudDay(day: "2026-09-14", recovery: 71)]
        let sleep = ["2026-09-15": WhoopCloudApi.CloudDay(day: "2026-09-15", sleepPerformance: 81)]
        let merged = WhoopCloudApi.merge([cycles, recovery, sleep])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].day, "2026-09-14", "sorted by day, oldest first")
        XCTAssertEqual(merged[0].strain ?? 0, 14.9, accuracy: 0.0001)
        XCTAssertEqual(merged[0].recovery ?? 0, 71, accuracy: 0.0001)
        XCTAssertEqual(merged[1].sleepPerformance ?? 0, 81, accuracy: 0.0001)
    }

    // MARK: - Workouts
    //
    // The one endpoint here whose UNSCORED records are KEPT. A session WHOOP has not finished grading
    // still happened — it has a start, an end and a sport — and dropping it takes a real workout off the
    // list to avoid showing one missing number.

    func testAWorkoutIsParsedWithItsScoreAndKilojoulesBecomeKilocalories() {
        let body = """
        {"records":[{"id":"w-1","start":"2026-09-14T06:00:00.000Z","end":"2026-09-14T07:14:00.000Z",
        "timezone_offset":"+02:00","sport_id":0,"score_state":"SCORED",
        "score":{"strain":11.4,"average_heart_rate":148,"max_heart_rate":179,
        "kilojoule":2510.0,"distance_meter":13400.5}}]}
        """
        let out = WhoopCloudApi.parseWorkouts(body)
        XCTAssertEqual(out.count, 1)
        let w = out[0]
        XCTAssertEqual(w.id, "w-1")
        XCTAssertEqual(WhoopCloudApi.displaySport(name: w.sportName, id: w.sportId), "Running")
        XCTAssertEqual(w.strain ?? 0, 11.4, accuracy: 0.0001)
        XCTAssertEqual(w.averageHeartRate, 148)
        XCTAssertEqual(w.maxHeartRate, 179)
        XCTAssertEqual(w.distanceMetre ?? 0, 13400.5, accuracy: 0.0001)
        // 2510 kJ / 4.184 = 599.9 kcal.
        XCTAssertEqual(w.energyKcal ?? 0, 599.9, accuracy: 0.1)
        XCTAssertEqual(w.end.timeIntervalSince(w.start), 74 * 60, accuracy: 0.5)
    }

    func testAnUnscoredWorkoutIsKeptWithoutItsStrain() {
        let body = """
        {"records":[{"id":"w-2","start":"2026-09-14T06:00:00Z","end":"2026-09-14T06:40:00Z",
        "timezone_offset":"+00:00","sport_id":45,"score_state":"PENDING_SCORE"}]}
        """
        let out = WhoopCloudApi.parseWorkouts(body)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].strain)
        XCTAssertNil(out[0].energyKcal)
        // No `sport_name` and an id outside the three that never move: honest, not guessed.
        XCTAssertEqual(WhoopCloudApi.displaySport(name: out[0].sportName, id: out[0].sportId), "Workout")
    }

    func testAWorkoutWithNoUsableSpanIsDropped() {
        // No end, and an end before its start. Neither is a session; storing either would put a row on
        // the list with a negative duration.
        let body = """
        {"records":[{"id":"w-3","start":"2026-09-14T06:00:00Z","timezone_offset":"+00:00"},
        {"id":"w-4","start":"2026-09-14T08:00:00Z","end":"2026-09-14T07:00:00Z",
        "timezone_offset":"+00:00"}]}
        """
        XCTAssertTrue(WhoopCloudApi.parseWorkouts(body).isEmpty)
    }

    func testAnUnknownSportIsNamedHonestlyRatherThanGuessed() {
        // WHOOP's catalogue changes without notice. An id with no name reads "Workout", which is true,
        // instead of whatever sport a remembered table puts next to it.
        XCTAssertEqual(WhoopCloudApi.displaySport(name: nil, id: 9_999), "Workout")
        XCTAssertEqual(WhoopCloudApi.displaySport(name: nil, id: nil), "Workout")
    }

    func testWhoopsOwnSportNameWinsOverTheId() {
        // The regression this pins: id 45 is Weightlifting, and the first table called it Yoga. With a
        // name present, the id is not consulted at all.
        let body = """
        {"records":[{"id":"w-9","start":"2026-09-14T06:00:00Z","end":"2026-09-14T07:00:00Z",
        "timezone_offset":"+00:00","sport_id":45,"sport_name":"weightlifting","score_state":"SCORED",
        "score":{"strain":9.1}}]}
        """
        let w = WhoopCloudApi.parseWorkouts(body)[0]
        XCTAssertEqual(w.sportName, "weightlifting")
        XCTAssertEqual(WhoopCloudApi.displaySport(name: w.sportName, id: w.sportId), "Weightlifting")
    }

    func testSportNamesAreSpelledTheWayTheRestOfTheAppStoresThem() {
        // Spaces and title case, because the cross-source dedup folds case and whitespace but NOT
        // hyphens — "functional-fitness" would never match a strap-logged "Functional Fitness".
        XCTAssertEqual(WhoopCloudApi.prettySport("functional-fitness"), "Functional Fitness")
        XCTAssertEqual(WhoopCloudApi.prettySport("hiking_rucking"), "Hiking Rucking")
        XCTAssertEqual(WhoopCloudApi.prettySport("RUNNING"), "Running")
    }

    // MARK: - Paging

    func testNextTokenIsReadAndAnAbsentOneIsTheLastPage() {
        XCTAssertEqual(WhoopCloudApi.nextToken(#"{"records":[],"next_token":"abc="}"#), "abc=")
        XCTAssertNil(WhoopCloudApi.nextToken(#"{"records":[]}"#))
        XCTAssertNil(WhoopCloudApi.nextToken(#"{"records":[],"next_token":""}"#))
        XCTAssertNil(WhoopCloudApi.nextToken("not json at all"))
    }

    func testRecordCountSurvivesRubbish() {
        XCTAssertEqual(WhoopCloudApi.recordCount(#"{"records":[{"id":1},{"id":2}]}"#), 2)
        XCTAssertEqual(WhoopCloudApi.recordCount("<html>gateway timeout</html>"), 0)
    }
}
