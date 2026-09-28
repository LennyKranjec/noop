import Foundation
import XCTest
@testable import StrandImport

/// The progression model against the REAL exports, end to end: bytes → `AlphaprogImporter.parse` →
/// `toSessions` → `StrengthProgression.build`.
///
/// WHY A FIXTURE TEST ON TOP OF THE UNIT TESTS. Everything in `StrengthProgressionTests` is synthetic, built
/// from set records constructed by hand — which proves the arithmetic and proves nothing about whether the
/// sets ever arrive. The failure this guards is the one the importer's own header describes: a plumbing
/// change that reads correctly and carries nothing, whose totals stay plausible. The nine-month file
/// (`alphaprog_workouts.csv`) has 96 sessions, ~20 distinct exercises, a lift repeated 59 times, and a
/// bodyweight-ADDED exercise — so it exercises the identity folding, the increment inference, the stall
/// window and the abstentions against real spellings and real weights rather than round numbers.
final class StrengthProgressionFixtureTests: XCTestCase {

    private let zone = TimeZone(identifier: "Europe/Berlin")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private func sessions(_ fixture: String) -> [StrengthProgression.Session] {
        guard let decoded = ImportText.decode(Fixtures.data(fixture)) else {
            XCTFail("the fixture must decode")
            return []
        }
        let parsed = AlphaprogImporter.parse(decoded.text, timeZone: zone)
        // Through `toSessions`, not off `parsed.workouts` directly: that is the conversion the app actually
        // stores from, so a set list that stops travelling THERE fails here.
        return AlphaprogImporter.toSessions(parsed).map {
            StrengthProgression.Session(start: $0.start, sets: $0.sets)
        }
    }

    private func progression(_ fixture: String) -> [StrengthProgression.Exercise] {
        StrengthProgression.build(sessions: sessions(fixture), calendar: calendar)
    }

    private func find(_ name: String, in list: [StrengthProgression.Exercise])
        -> StrengthProgression.Exercise? {
        list.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - The sets actually arrive

    func testTheSetsSurviveTheWholeImportPath() {
        let sessions = self.sessions("alphaprog_workouts.csv")
        XCTAssertGreaterThan(sessions.count, 50, "the nine-month file holds most of a year of training")
        let sets = sessions.flatMap(\.sets)
        XCTAssertGreaterThan(sets.count, 500, "every performed set has to travel, not just the totals")
        // Every set names its exercise — the whole feature is per-exercise, so an unnamed set is a set the
        // model cannot place.
        XCTAssertTrue(sets.allSatisfy { !$0.exercise.trimmingCharacters(in: .whitespaces).isEmpty })
        // And a weight × reps set carries both halves.
        XCTAssertTrue(sets.contains { $0.weightKg != nil && $0.reps != nil })
    }

    /// Exactly the sets the parser counted arrive, and no others.
    ///
    /// THE PRECISE PROPERTY, rather than "some sets arrived". A row the app printed and the wearer left
    /// empty (`3;-;-`) is not a set and must not travel; a loaded hold and a timed effort ARE sets that
    /// happened and must. Comparing against the parser's own `setCount` pins both directions at once —
    /// dropping a real set and inventing an empty one both fail here.
    private func assertSetCountsMatchTheParser(_ fixture: String) {
        guard let decoded = ImportText.decode(Fixtures.data(fixture)) else {
            return XCTFail("the fixture must decode")
        }
        let parsed = AlphaprogImporter.parse(decoded.text, timeZone: zone)
        let sessions = AlphaprogImporter.toSessions(parsed)
        // `toSessions` drops sessions with an epoch-zero start, so compare over the sessions that survive.
        let expected = parsed.workouts
            .filter { $0.start.timeIntervalSince1970 > 0 }
            .reduce(0) { $0 + $1.setCount }
        XCTAssertEqual(sessions.flatMap(\.sets).count, expected, fixture)
        XCTAssertGreaterThan(expected, 0, fixture)
    }

    func testEveryPerformedSetTravelsAndNoEmptyOneDoes() {
        assertSetCountsMatchTheParser("alphaprog_workouts.csv")
        assertSetCountsMatchTheParser("alphaprog_real_world.csv")
    }

    func testTheRealWorldFixtureCarriesItsSetsToo() {
        // The awkward one: BOM, CRLF, a `#;KG;SEK` grid, a `#;MIN.` grid, `-;-` rows and a `+10` load.
        let sessions = self.sessions("alphaprog_real_world.csv")
        XCTAssertEqual(sessions.count, 3)
        let sets = sessions.flatMap(\.sets)
        XCTAssertFalse(sets.isEmpty)
        // ABSENT, NEVER ZERO. A timed effort has no external load and a hold has no rep count; storing 0 for
        // either would say the wearer lifted nothing or did no repetitions, which is a different claim from
        // "the file does not say". So neither field ever arrives as a zero.
        XCTAssertFalse(sets.contains { $0.weightKg == 0 }, "a missing load must be nil, not 0 kg")
        XCTAssertFalse(sets.contains { $0.reps == 0 }, "a missing rep count must be nil, not 0 reps")
        // And a `+10` row arrives flagged, not as a bare 10 kg load.
        XCTAssertTrue(sets.contains { $0.addedToBodyweight && $0.weightKg == 10 })
    }

    // MARK: - A bodyweight-added lift cannot produce a load

    func testTheBodyweightAddedLiftIsFlaggedAndEstimatesNothing() {
        // "9. Hyperextensions · Körpergewicht · 10 Wdh" with rows `1;+5;10`. Read as a flat 5 kg that is a
        // 6.7 kg "one-rep max" for a lift the wearer does with their whole bodyweight on it.
        let list = progression("alphaprog_workouts.csv")
        guard let hyper = find("Hyperextensions", in: list) else {
            return XCTFail("the fixture logs Hyperextensions")
        }
        XCTAssertGreaterThan(hyper.excludedBodyweightSets, 0,
                             "the `+5` / `+10` rows must be counted as excluded, not silently dropped")
        XCTAssertEqual(hyper.abstained, .noUsableSets,
                       "with only added-weight sets there is no absolute load to estimate from")
        XCTAssertNil(hyper.currentE1rmKg)
        XCTAssertNil(hyper.bestEverE1rmKg)
        XCTAssertNil(hyper.suggestion)
        XCTAssertNil(hyper.topWorkingWeightKg)
    }

    func testTheParserRecordsThePlusRatherThanReadingItAway() {
        // Straight at the parser, because the flag is the only thing that survives `Double("+10") == 10`.
        let parsed = AlphaprogImporter.parse(
            ImportText.decode(Fixtures.data("alphaprog_real_world.csv"))?.text ?? "", timeZone: zone)
        let added = parsed.workouts.flatMap(\.exercises).flatMap(\.sets).filter { $0.addedToBodyweight }
        XCTAssertFalse(added.isEmpty, "the real-world fixture has `+10` rows")
        XCTAssertTrue(added.allSatisfy { $0.weightKg == 10 && $0.reps > 0 })
        // VOLUME IS DELIBERATELY UNCHANGED by the flag: it still reads the added kilograms, which is the
        // documented under-reading, and moving it would rewrite figures already imported.
        XCTAssertEqual(added.first?.volumeKg, 10 * Double(added.first?.reps ?? 0))
        XCTAssertTrue(AlphaprogImporter.isBodyweightAdded(" +10 "))
        XCTAssertFalse(AlphaprogImporter.isBodyweightAdded("10"))
        XCTAssertFalse(AlphaprogImporter.isBodyweightAdded("-"))
    }

    // MARK: - A real, well-trained lift

    func testTheMostTrainedLiftHasARealReadoutWithAnInferredStep() {
        // Brustpresse (chest press) is logged across most of the file at 50 / 55 / 60 / 65 / 70 / 75 kg —
        // machine plates in 5 kg steps, which is what the increment inference has to recover from the
        // wearer's own history rather than assume.
        let list = progression("alphaprog_workouts.csv")
        guard let press = find("Brustpresse", in: list) else {
            return XCTFail("the fixture logs Brustpresse")
        }
        XCTAssertNil(press.abstained, "a lift trained dozens of times is not thin data")
        XCTAssertGreaterThanOrEqual(press.e1rmSeries.count, StrengthProgression.minSessions)
        XCTAssertEqual(press.incrementKg!, 5, accuracy: 0.000001,
                       "the fixture's chest press moves in 5 kg machine steps")
        // The estimate has to be ABOVE the heaviest set actually lifted and below an absurd multiple of it.
        XCTAssertNotNil(press.currentE1rmKg)
        if let current = press.currentE1rmKg, let top = press.topWorkingWeightKg {
            XCTAssertGreaterThanOrEqual(current, top)
            XCTAssertLessThanOrEqual(current, top * 1.4 + 0.0001)
        }
        // A suggestion, and never more than one of their own steps.
        if let suggestion = press.suggestion, suggestion.step == .addWeight {
            XCTAssertEqual(suggestion.weightKg - suggestion.fromWeightKg, 5, accuracy: 0.000001)
        }
    }

    // MARK: - Whole-file invariants
    //
    // These are the assertions that would have caught a wrong sign, a fabricated figure or an abstention
    // that leaks a number — across every exercise in a real file rather than in one hand-picked case.

    func testNoAbstainingExerciseLeaksAFigure() {
        for exercise in progression("alphaprog_workouts.csv") where exercise.abstained != nil {
            XCTAssertNil(exercise.currentE1rmKg, exercise.name)
            XCTAssertNil(exercise.bestEverE1rmKg, exercise.name)
            XCTAssertNil(exercise.topWorkingWeightKg, exercise.name)
            XCTAssertNil(exercise.incrementKg, exercise.name)
            XCTAssertNil(exercise.suggestion, exercise.name)
            XCTAssertNil(exercise.stall, exercise.name)
            XCTAssertTrue(exercise.trends.isEmpty, exercise.name)
        }
    }

    func testEveryReportedEstimateComesFromASetInTheDefensibleWindow() {
        for exercise in progression("alphaprog_workouts.csv") {
            for point in exercise.sessions {
                guard let best = point.bestE1rmKg else { continue }
                XCTAssertGreaterThan(best, 0, exercise.name)
                // Epley over 1…12 reps spans w × 31/30 … w × 42/30, so an estimate can never exceed 1.4 ×
                // the heaviest set it came from. A figure outside that came from a rep count that should
                // have abstained.
                guard let top = point.topSetKg else {
                    return XCTFail("\(exercise.name): a session with an estimate must have a top set")
                }
                XCTAssertLessThanOrEqual(best, top * 1.4 + 0.0001, exercise.name)
                XCTAssertGreaterThanOrEqual(best, top, exercise.name)
            }
        }
    }

    func testEverySuggestionIsAtMostOneObservedIncrement() {
        for exercise in progression("alphaprog_workouts.csv") {
            guard let suggestion = exercise.suggestion else { continue }
            switch suggestion.step {
            case .addReps:
                XCTAssertEqual(suggestion.weightKg, suggestion.fromWeightKg, exercise.name)
                XCTAssertEqual(suggestion.reps, suggestion.fromReps + 1, exercise.name)
            case .addWeight:
                guard let step = suggestion.incrementKg else {
                    XCTFail("\(exercise.name): an add-weight step must name its increment")
                    continue
                }
                XCTAssertEqual(suggestion.weightKg - suggestion.fromWeightKg, step,
                               accuracy: 0.000001, exercise.name)
                XCTAssertEqual(step, exercise.incrementKg ?? -1, accuracy: 0.000001, exercise.name)
                XCTAssertLessThanOrEqual(step, StrengthProgression.maxIncrementKg, exercise.name)
                XCTAssertEqual(suggestion.reps, suggestion.repRangeLow, exercise.name)
            }
        }
    }

    func testStalledExercisesComeFirst() {
        let list = progression("alphaprog_workouts.csv")
        let firstHealthy = list.firstIndex { !$0.needsAttention }
        if let firstHealthy {
            XCTAssertFalse(list[firstHealthy...].contains { $0.needsAttention },
                           "a stalled lift after a healthy one means the sort is not stalled-first")
        }
    }

    func testEveryStallClearsBothThresholds() {
        for exercise in progression("alphaprog_workouts.csv") {
            guard let stall = exercise.stall else { continue }
            XCTAssertGreaterThanOrEqual(stall.sessions, StrengthProgression.stallSessions, exercise.name)
            XCTAssertGreaterThanOrEqual(stall.days, StrengthProgression.stallMinDays, exercise.name)
        }
    }

    func testTimedAndIsometricGridsNeverBecomeRepsOrLoads() {
        // `#;MIN.` (a plank) and `#;KG;SEK` (a wall sit) are real work that is NOT weight × reps. They must
        // reach the model as sets with no rep count, abstain, and never contribute an estimate — the same
        // distinction the parser exists to keep, carried one layer further.
        let list = progression("alphaprog_workouts.csv")
        for name in ["Plank", "Wallsit"] {
            guard let exercise = find(name, in: list) else { continue }
            XCTAssertEqual(exercise.abstained, .noUsableSets, name)
            XCTAssertNil(exercise.currentE1rmKg, name)
        }
    }
}
