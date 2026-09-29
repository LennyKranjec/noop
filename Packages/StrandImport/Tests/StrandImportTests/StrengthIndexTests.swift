import XCTest
@testable import StrandImport

/// The estimated-1RM strength index: exercises made comparable as a ratio of their own typical figure,
/// a twelve-week best so a deload does not drop it.
final class StrengthIndexTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ d: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: d, hour: 18))!
    }

    private func workout(_ d: Int, _ name: String, kg: Double, reps: Int) -> AlphaprogImporter.Workout {
        AlphaprogImporter.Workout(title: "", start: day(d), end: day(d).addingTimeInterval(3600),
                                  exercises: [.init(name: name, sets: [.init(weightKg: kg, reps: reps)])])
    }

    func testEpleyAndItsRepLimit() {
        XCTAssertEqual(StrengthIndex.e1rm(weightKg: 100, reps: 5) ?? 0, 100 * (1 + 5.0 / 30), accuracy: 1e-9)
        XCTAssertNil(StrengthIndex.e1rm(weightKg: 60, reps: 20))
        XCTAssertNil(StrengthIndex.e1rm(weightKg: 0, reps: 5))
    }

    func testTheIndexIsTheRatioToTheExercisesOwnMedianAndHoldsThroughADeload() {
        // Squat e1RM on day 1, 8, 15: 100, 110, 120 → median 110 (as e1RM, via 1 rep).
        let log = [
            workout(1, "Squat", kg: 100, reps: 1),
            workout(8, "Squat", kg: 110, reps: 1),
            workout(15, "Squat", kg: 120, reps: 1),
            // A light deload session on day 22 does not lower the twelve-week best.
            workout(22, "Squat", kg: 60, reps: 1),
        ]
        let series = StrengthIndex.daily(log, through: day(25), calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: series.map { ($0.day, $0.value) })
        // On the 15th the median is of the days up TO the 15th — [100, 110, 120] = 110 — not of a log
        // that had not happened yet. It used to be divided by 105, which included the 22nd's deload.
        XCTAssertEqual(byDay["2026-06-15"] ?? 0, 120.0 / 110.0, accuracy: 1e-9)
        // By the 25th the deload is in the past, so the median IS [60, 100, 110, 120] = 105 — and the
        // twelve-week best is still 120, which is the claim this test was written for.
        XCTAssertEqual(byDay["2026-06-25"] ?? 0, 120.0 / 105.0, accuracy: 1e-9)
        XCTAssertNil(byDay["2026-05-31"])
        // The first two sessions are below `minSessions`: one session of an exercise makes its median
        // equal its own best and the ratio exactly 1.0.
        XCTAssertNil(byDay["2026-06-01"])
        XCTAssertNil(byDay["2026-06-08"])
    }

    /// Regression: the medians were taken over the WHOLE log before the per-day walk began, so a day in
    /// June was divided by a figure that already contained a personal best set three weeks later — and
    /// every backfilled day was written once, from a yardstick that could not have existed on it.
    func testTheMedianIsOnlyTheDaysUpToTheDayItself() {
        let log = [
            workout(1, "Squat", kg: 100, reps: 1),
            workout(3, "Squat", kg: 100, reps: 1),
            workout(5, "Squat", kg: 100, reps: 1),
            workout(26, "Squat", kg: 200, reps: 1),
        ]
        let byDay = Dictionary(uniqueKeysWithValues:
            StrengthIndex.daily(log, through: day(27), calendar: calendar).map { ($0.day, $0.value) })
        // On the 5th the wearer's typical squat was 100 and their best was 100: exactly typical.
        XCTAssertEqual(byDay["2026-06-05"] ?? 0, 1.0, accuracy: 1e-9)
        // On the 26th the median is of [100, 100, 100, 200] = 100 and the best is 200.
        XCTAssertEqual(byDay["2026-06-26"] ?? 0, 2.0, accuracy: 1e-9)
    }

    /// Regression: with no minimum-n, one session per exercise made the median equal its own best, the
    /// ratio exactly 1.0 and the index a confident "an average day" — from a single set.
    func testOneSessionIsNotAnAverageDay() {
        XCTAssertEqual(StrengthIndex.minSessions, StrengthProgression.minSessions)
        XCTAssertTrue(StrengthIndex.daily([workout(1, "Squat", kg: 100, reps: 5)],
                                          through: day(25), calendar: calendar).isEmpty)
        XCTAssertTrue(StrengthIndex.daily([workout(1, "Squat", kg: 100, reps: 5),
                                           workout(8, "Squat", kg: 105, reps: 5)],
                                          through: day(25), calendar: calendar).isEmpty)
        XCTAssertFalse(StrengthIndex.daily([workout(1, "Squat", kg: 100, reps: 5),
                                            workout(8, "Squat", kg: 105, reps: 5),
                                            workout(15, "Squat", kg: 110, reps: 5)],
                                           through: day(25), calendar: calendar).isEmpty)
    }

    /// Regression: `ex.sets` was read unfiltered. `+10` on a hyperextension records ten ADDED kilograms,
    /// not a ten-kilogram lift, so it carries no absolute estimate at all — the same exclusion
    /// `StrengthProgression` makes, and the reason `ImportedLiftSets` persists the marker.
    func testABodyweightAddedSetCarriesNoEstimateAtAll() {
        func added(_ d: Int, kg: Double) -> AlphaprogImporter.Workout {
            AlphaprogImporter.Workout(
                title: "", start: day(d), end: day(d).addingTimeInterval(3600),
                exercises: [.init(name: "Hyperextension",
                                  sets: [.init(weightKg: kg, reps: 10, addedToBodyweight: true)])])
        }
        XCTAssertTrue(StrengthIndex.daily([added(1, kg: 10), added(8, kg: 12), added(15, kg: 14)],
                                          through: day(20), calendar: calendar).isEmpty)
        // The same three sessions logged as absolute loads DO carry one.
        XCTAssertFalse(StrengthIndex.daily([workout(1, "Hyperextension", kg: 10, reps: 10),
                                            workout(8, "Hyperextension", kg: 12, reps: 10),
                                            workout(15, "Hyperextension", kg: 14, reps: 10)],
                                           through: day(20), calendar: calendar).isEmpty)
    }
}
