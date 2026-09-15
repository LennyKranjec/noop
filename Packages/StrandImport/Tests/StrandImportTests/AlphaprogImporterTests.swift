import Foundation
import XCTest
@testable import StrandImport

/// The Alphaprog export, read against the wearer's REAL file — the same fixture the Android twin
/// `com.noop.ingest.AlphaprogImporterTest` runs on, so the two parsers can be compared row for row.
///
/// The fixture is their actual log: 96 sessions across nine months. A hand-written sample would have
/// proved the parser reads what I imagined the format to be; this proves it reads what the exporter
/// writes, including the blank lines, the BOM, the German decimals and the dashes for sets that were
/// printed and never done.
///
/// TWO OF THESE ARE THE IMPORTANT ONES, and both guard failures that look like data rather than like
/// bugs. The SESSION COUNT: a header form the matcher missed did not fail on the Android lane, it
/// appended that session's exercises to the previous one, and a quarter-matched file produced one
/// fabricated 190-exercise day. The ATTRIBUTION COVERAGE: an exercise the table cannot place
/// contributes nothing, silently, and the body view simply stays dark for that muscle.
final class AlphaprogImporterTests: XCTestCase {

    private let zone = TimeZone(identifier: "Europe/Berlin")!

    private func fixture() -> String {
        String(data: Fixtures.data("alphaprog_workouts.csv"), encoding: .utf8) ?? ""
    }

    private func parsed() -> AlphaprogImporter.Parsed {
        AlphaprogImporter.parse(fixture(), timeZone: zone)
    }

    func testEverySessionInTheFileIsFound() {
        // 96, NOT the 26 the first cut of the Android parser found. The duration column has three forms
        // and the clock has one or two digits; a matcher that accepted only `HH:MM` + `N Min.` took a
        // quarter of the headers, and the other seventy sessions' exercises were silently appended to
        // whichever session HAD matched — producing one 190-exercise day holding most of a year. The
        // count is asserted rather than the shape, because that failure had a plausible shape.
        XCTAssertEqual(parsed().workouts.count, 96)
    }

    func testAllThreeDurationFormsAreRead() {
        XCTAssertEqual(AlphaprogImporter.durationMinutes("53 Min."), 53)
        XCTAssertEqual(AlphaprogImporter.durationMinutes("1:19 Std."), 79)
        XCTAssertEqual(AlphaprogImporter.durationMinutes("2:07 Std."), 127)
        // Rounded DOWN: a 45-second session did not last a minute.
        XCTAssertEqual(AlphaprogImporter.durationMinutes("45 s"), 0)
        XCTAssertEqual(AlphaprogImporter.durationMinutes("something else"), 0)
    }

    func testASessionThatStartedBeforeTenIsStillFound() {
        // "2026-09-02 5:18 Uhr" — one digit.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let early = parsed().workouts.filter { calendar.component(.hour, from: $0.start) < 10 }
        XCTAssertGreaterThanOrEqual(early.count, 10, "single-digit clock hours must parse")
        XCTAssertTrue(early.allSatisfy { $0.start.timeIntervalSince1970 > 0 },
                      "and must carry a real timestamp")
    }

    func testALoadedHoldIsNotWeightTimesReps() {
        // `#;KG;SEK` is weight × SECONDS. Reading the second column as reps would turn a 45-second hold
        // into 1,350 kg of volume load: not a wrong magnitude, a different quantity in the same unit.
        //
        // WRITTEN BY HAND, not read off the fixture, because the wearer's own file has exactly one such
        // grid and every row in it is a dash — the format is there, a PERFORMED hold is not. A test that
        // waited for one would have passed today by asserting nothing.
        let text = [
            "\"Lower A (Di)\";\"2026-07-19 19:01 Uhr\";\"2 Min.\"",
            "\"1. Wallsit · Körpergewicht\"",
            "#;KG;SEK",
            "1;30;45",
        ].joined(separator: "\n")
        let workouts = AlphaprogImporter.parse(text, timeZone: zone).workouts
        XCTAssertEqual(workouts.count, 1)
        guard let set = workouts.first?.exercises.first?.sets.first else {
            return XCTFail("the hold should have parsed")
        }
        XCTAssertEqual(set.holdSeconds, 45)
        XCTAssertEqual(set.reps, 0)
        XCTAssertEqual(set.volumeKg, 0, accuracy: 1e-9)
        XCTAssertEqual(set.weightKg, 30, accuracy: 1e-9)
    }

    func testTheFixturesOwnUnperformedHoldContributesNothing() {
        // The real `#;KG;SEK` grid is "1;-;-" three times: printed, never done.
        let wallsit = parsed().workouts.flatMap(\.exercises).filter { $0.name == "Wallsit" }
        XCTAssertFalse(wallsit.isEmpty, "the fixture carries the Wallsit")
        XCTAssertTrue(wallsit.allSatisfy { $0.sets.isEmpty })
    }

    func testATimedEffortCarriesMinutesAndNoLoad() {
        let timed = parsed().workouts.flatMap(\.exercises).flatMap(\.sets).filter { $0.minutes > 0 }
        XCTAssertFalse(timed.isEmpty, "the fixture carries at least one timed effort")
        XCTAssertTrue(timed.allSatisfy { $0.volumeKg == 0 && $0.weightKg == 0 })
    }

    func testTheSessionsAreOrderedOldestFirst() {
        let starts = parsed().workouts.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testASessionCarriesItsDurationFromTheHeader() {
        // "…;"2026-09-14 13:44 Uhr";"53 Min."" — the end is the start plus those minutes.
        guard let newest = parsed().workouts.last else { return XCTFail("no sessions") }
        XCTAssertEqual(newest.end.timeIntervalSince(newest.start), 53 * 60, accuracy: 0.5)
    }

    func testGermanDecimalsAreRead() {
        XCTAssertEqual(AlphaprogImporter.germanNumber("27,5") ?? 0, 27.5, accuracy: 1e-9)
        XCTAssertEqual(AlphaprogImporter.germanNumber("30") ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(AlphaprogImporter.germanNumber("1.234,5") ?? 0, 1234.5, accuracy: 1e-9)
    }

    func testAnUnperformedSetIsNotAZero() {
        // "4;-;-" is a row the app printed and the wearer left empty. Counting it as 0 kg × 0 reps is
        // the same arithmetic and a different claim: it would say they did a set of nothing.
        XCTAssertNil(AlphaprogImporter.germanNumber("-"))
        let sets = parsed().workouts.flatMap(\.exercises).flatMap(\.sets)
        XCTAssertTrue(
            sets.allSatisfy { $0.reps > 0 || $0.holdSeconds > 0 || $0.minutes > 0 },
            "a set is either reps, or seconds, or minutes — never nothing at all")
    }

    func testTheFirstSessionMatchesTheFileByHand() {
        // Read off the top of the fixture: rows 30×10, 27.5×7, 27.5×7 with the fourth set left blank.
        guard let rows = parsed().workouts.last?.exercises.first else { return XCTFail("no sessions") }
        XCTAssertEqual(rows.name, "Rudern mit Brustauflage eng")
        XCTAssertEqual(rows.sets.count, 3)
        // Split out and typed: the inline literal sum was one expression the type-checker would not
        // finish in time, which is a compile error rather than a slow test.
        let volume: Double = rows.sets.reduce(0) { $0 + $1.volumeKg }
        let expected: Double = 30.0 * 10.0 + 27.5 * 7.0 + 27.5 * 7.0
        XCTAssertEqual(volume, expected, accuracy: 1e-9)
    }

    func testEveryExerciseInTheFileIsEitherPlacedOrKnowinglyUnplaceable() {
        let p = parsed()
        let names = Swift.Set(p.workouts.flatMap(\.exercises).map(\.name))
        // NOTHING in this file is allowed to go unplaced. Adductors used to be the one deliberate blank;
        // they are the medial thigh, which the hamstrings' own hip-extension group is the honest home
        // for, and leaving them blank lost thirty sessions of leg work off the figure.
        XCTAssertTrue(p.unattributed.isEmpty,
                      "these attribute nothing and would silently lose their volume: \(p.unattributed)")
        XCTAssertGreaterThanOrEqual(names.count, 20, "the fixture carries the wearer's whole vocabulary")
    }

    func testVolumeIsSplitAcrossEveryMoverWithoutBeingDivided() {
        // A row moves lats AND upper back; each gets the FULL set volume, because nothing in a set of
        // rows says the lats took half. The per-muscle total therefore EXCEEDS the session's own.
        guard let session = parsed().workouts.last else { return XCTFail("no sessions") }
        let perMuscle = LiftingImporter.muscleVolume(byExercise: session.volumeByExercise)
            .values.reduce(0, +)
        XCTAssertGreaterThan(perMuscle, session.volumeLoadKg)
    }

    func testTheWholeFileConvertsToStorableSessions() {
        let sessions = AlphaprogImporter.toSessions(parsed())
        XCTAssertEqual(sessions.count, 96)
        XCTAssertTrue(sessions.allSatisfy { $0.start.timeIntervalSince1970 > 0 })
        XCTAssertTrue(sessions.allSatisfy { $0.volumeLoadKg >= 0 })
        XCTAssertTrue(sessions.contains { !$0.muscleVolumeKg.isEmpty },
                      "at least one session must attribute muscle volume")
    }

    func testTheSeriesRowsAreOnePerDayPerGroupAndSummedAcrossSessions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let rows = LiftingImporter.muscleSeriesRows(AlphaprogImporter.toSessions(parsed()),
                                                    calendar: calendar)
        XCTAssertFalse(rows.isEmpty)
        // The tall table holds one row per (deviceId, day, key), so a duplicate here would mean the
        // second session on a day silently replaced the first rather than adding to it.
        let keys = rows.map { "\($0.day)|\($0.key)" }
        XCTAssertEqual(Swift.Set(keys).count, keys.count, "one row per (day, group)")
        XCTAssertTrue(rows.allSatisfy { $0.value > 0 }, "a zero row is an absent row, not a stored one")
    }

    func testAMalformedFileYieldsNothingRatherThanThrowing() {
        // A log somebody spent months filling in should import what it can, not fail on one bad line.
        XCTAssertTrue(AlphaprogImporter.parse("", timeZone: zone).workouts.isEmpty)
        XCTAssertTrue(AlphaprogImporter.parse("garbage;;;\n\n;;", timeZone: zone).workouts.isEmpty)
    }
}
