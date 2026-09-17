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
        // Median of [60, 100, 110, 120] = 105.
        XCTAssertEqual(byDay["2026-06-15"] ?? 0, 120.0 / 105.0, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-06-25"] ?? 0, 120.0 / 105.0, accuracy: 1e-9)
        XCTAssertNil(byDay["2026-05-31"])
    }
}
