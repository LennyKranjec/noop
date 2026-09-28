import Foundation
import XCTest
@testable import StrandImport

/// Per-exercise progression: the formulas, where they abstain, and every threshold that decides what the
/// wearer is told.
///
/// THE FORMULA VALUES ARE HAND-COMPUTED and written out in the comments, not read off the implementation.
/// An estimated one-rep max is a number nobody lifted, presented beside real machine loads, so a test that
/// merely pins whatever the code currently returns would let a wrong constant look correct forever.
///
/// THE ABSTENTIONS GET AS MUCH COVERAGE AS THE ARITHMETIC. Every one of them is the app declining to show a
/// figure it cannot support — thin data, a rep count outside the defensible window, and above all a
/// bodyweight-ADDED load, which is the one case where a plausible-looking number is available and wrong.
final class StrengthProgressionTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Day `n` of a synthetic history, at noon so no arithmetic here can straddle a midnight.
    private func day(_ n: Int) -> Date {
        Fixtures.utc(2026, 1, 1, 12, 0, 0).addingTimeInterval(Double(n) * 86_400)
    }

    private func set(_ exercise: String, _ weight: Double?, _ reps: Int?,
                     warmup: Bool = false, added: Bool = false) -> LiftingSetRecord {
        LiftingSetRecord(exercise: exercise, weightKg: weight, reps: reps,
                         isWarmup: warmup, addedToBodyweight: added)
    }

    private func build(_ sessions: [StrengthProgression.Session]) -> [StrengthProgression.Exercise] {
        StrengthProgression.build(sessions: sessions, calendar: calendar)
    }

    private func only(_ sessions: [StrengthProgression.Session]) -> StrengthProgression.Exercise {
        let out = build(sessions)
        XCTAssertEqual(out.count, 1, "the fixtures in this file use one exercise unless stated")
        return out[0]
    }

    // MARK: - Epley

    func testEpleyMatchesHandComputedValues() {
        // w x (1 + reps/30).
        //  100 x 1  = 100 x 31/30 = 103.3333…  (Epley reads ABOVE the bar at one rep; that is the
        //                                       published formula and what `strength_index` already banks)
        //  100 x 5  = 100 x 35/30 = 116.6667…
        //   75 x 8  =  75 x 38/30 =  95.0      exactly
        //  100 x 10 = 100 x 40/30 = 133.3333…
        //  100 x 12 = 100 x 42/30 = 140.0      exactly
        XCTAssertEqual(StrengthProgression.epley(weightKg: 100, reps: 1)!, 103.33333, accuracy: 0.0001)
        XCTAssertEqual(StrengthProgression.epley(weightKg: 100, reps: 5)!, 116.66667, accuracy: 0.0001)
        XCTAssertEqual(StrengthProgression.epley(weightKg: 75, reps: 8)!, 95.0, accuracy: 0.000001)
        XCTAssertEqual(StrengthProgression.epley(weightKg: 100, reps: 10)!, 133.33333, accuracy: 0.0001)
        XCTAssertEqual(StrengthProgression.epley(weightKg: 100, reps: 12)!, 140.0, accuracy: 0.000001)
    }

    func testEpleyIsTheOneEpleyInTheApp() {
        // Not a second copy of the formula: the progression model and the strength index must agree to the
        // bit, because both are shown as "estimated 1RM" and the coach quotes the index.
        for reps in 1...StrengthProgression.maxReps {
            XCTAssertEqual(StrengthProgression.epley(weightKg: 82.5, reps: reps),
                           StrengthIndex.e1rm(weightKg: 82.5, reps: reps))
        }
    }

    // MARK: - Brzycki

    func testBrzyckiMatchesHandComputedValues() {
        // w / (1.0278 - 0.0278 x reps).
        //  100 x 1  = 100 / 1.0000 = 100.0        (Brzycki returns the bar exactly at one rep)
        //  100 x 5  = 100 / 0.8888 = 112.511251…
        //  100 x 10 = 100 / 0.7498 = 133.368898…
        //  100 x 12 = 100 / 0.6942 = 144.050706…
        XCTAssertEqual(StrengthProgression.brzycki(weightKg: 100, reps: 1)!, 100.0, accuracy: 0.000001)
        XCTAssertEqual(StrengthProgression.brzycki(weightKg: 100, reps: 5)!, 112.51125, accuracy: 0.0001)
        XCTAssertEqual(StrengthProgression.brzycki(weightKg: 100, reps: 10)!, 133.36890, accuracy: 0.0001)
        XCTAssertEqual(StrengthProgression.brzycki(weightKg: 100, reps: 12)!, 144.05071, accuracy: 0.0001)
    }

    func testBothFormulasAbstainOutsideTheDefensibleRepWindow() {
        // The window is 1…12. Outside it there is NO estimate — not a capped one, not a flagged one.
        for reps in [0, -1, StrengthProgression.maxReps + 1, 15, 20, 36, 100] {
            XCTAssertNil(StrengthProgression.epley(weightKg: 100, reps: reps), "Epley at \(reps) reps")
            XCTAssertNil(StrengthProgression.brzycki(weightKg: 100, reps: reps), "Brzycki at \(reps) reps")
        }
        // …and with no load there is nothing to scale.
        XCTAssertNil(StrengthProgression.epley(weightKg: 0, reps: 8))
        XCTAssertNil(StrengthProgression.brzycki(weightKg: 0, reps: 8))
        XCTAssertNil(StrengthProgression.epley(weightKg: -5, reps: 8))
        XCTAssertNil(StrengthProgression.brzycki(weightKg: -5, reps: 8))
    }

    func testBrzyckiDenominatorCannotBlowUpAcrossTheWholeWindow() {
        // 1.0278 - 0.0278 x 36 is exactly zero. The guard is what stops a future `maxReps` bump turning
        // that into a division by ~0 that returns an enormous "estimate".
        for reps in 30...40 {
            XCTAssertNil(StrengthProgression.brzycki(weightKg: 100, reps: reps))
        }
    }

    // MARK: - Thin data

    func testTwoSessionsReportNoFiguresAtAll() {
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 5)]),
            .init(start: day(7), sets: [set("Bench", 100, 6)]),
        ])
        XCTAssertEqual(exercise.abstained, .tooFewSessions(have: 2, need: 3))
        // EVERY figure, not just the trend: a current estimate from two sessions reads as a trend to a
        // wearer looking at a list of them.
        XCTAssertNil(exercise.currentE1rmKg)
        XCTAssertNil(exercise.bestEverE1rmKg)
        XCTAssertNil(exercise.suggestion)
        XCTAssertNil(exercise.stall)
        XCTAssertTrue(exercise.trends.isEmpty)
    }

    func testThreeSessionsIsTheThreshold() {
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 5)]),
            .init(start: day(7), sets: [set("Bench", 100, 6)]),
            .init(start: day(14), sets: [set("Bench", 100, 7)]),
        ])
        XCTAssertNil(exercise.abstained)
        XCTAssertNotNil(exercise.currentE1rmKg)
        XCTAssertEqual(StrengthProgression.minSessions, 3)
    }

    func testSessionsWithNoReadableSetDoNotCountTowardTheThreshold() {
        // Three sessions exist; only two can be read. That is two, and the app says two.
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 5)]),
            .init(start: day(7), sets: [set("Bench", nil, nil)]),
            .init(start: day(14), sets: [set("Bench", 100, 6)]),
        ])
        XCTAssertEqual(exercise.abstained, .tooFewSessions(have: 2, need: 3))
    }

    func testAnExerciseWithNoWeightedSetAbstainsForThatReasonSpecifically() {
        let exercise = only([
            .init(start: day(0), sets: [set("Plank", nil, nil)]),
            .init(start: day(7), sets: [set("Plank", nil, nil)]),
            .init(start: day(14), sets: [set("Plank", nil, nil)]),
            .init(start: day(21), sets: [set("Plank", nil, nil)]),
        ])
        XCTAssertEqual(exercise.abstained, .noUsableSets)
    }

    // MARK: - A bodyweight-added load can never become a load

    func testBodyweightAddedSetsProduceNoEstimateAndAreCounted() {
        // "+10" x 11 on a hyperextension. Read as a flat 10 kg it would estimate 13.67 kg and sit in the
        // list beside real machine loads, stall-flagged forever. It must produce NOTHING.
        let sessions = (0..<5).map { i in
            StrengthProgression.Session(start: day(i * 7),
                                        sets: [set("Hyperextensions", 10, 11, added: true)])
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.abstained, .noUsableSets)
        XCTAssertNil(exercise.currentE1rmKg)
        XCTAssertNil(exercise.bestEverE1rmKg)
        XCTAssertNil(exercise.topWorkingWeightKg)
        XCTAssertNil(exercise.suggestion)
        XCTAssertEqual(exercise.excludedBodyweightSets, 5)
        // And the number the honest reading refuses is nowhere in the output.
        let fake = StrengthProgression.epley(weightKg: 10, reps: 11)!
        for point in exercise.sessions {
            XCTAssertNil(point.bestE1rmKg)
            XCTAssertNotEqual(point.volumeKg, 10 * 11)
        }
        XCTAssertFalse(exercise.e1rmSeries.contains { abs($0.value - fake) < 0.001 })
    }

    func testABodyweightAddedSetDoesNotPoisonAnExerciseThatAlsoHasRealLoads() {
        // A lift logged both ways keeps the real sets and drops the added ones — it does not abstain
        // wholesale, and it does not average the two kinds of number together.
        let sessions = (0..<4).map { i in
            StrengthProgression.Session(start: day(i * 7), sets: [
                set("Dips", 10, 11, added: true),
                set("Dips", 80, 8),
            ])
        }
        let exercise = only(sessions)
        XCTAssertNil(exercise.abstained)
        XCTAssertEqual(exercise.excludedBodyweightSets, 4)
        // 80 x 8 = 80 x 38/30 = 101.3333…
        XCTAssertEqual(exercise.currentE1rmKg!, 101.33333, accuracy: 0.0001)
        XCTAssertEqual(exercise.topWorkingWeightKg!, 80, accuracy: 0.000001)
    }

    // MARK: - Out-of-range reps

    func testSetsAboveTheRepWindowAreExcludedAndCounted() {
        let sessions = (0..<4).map { i in
            StrengthProgression.Session(start: day(i * 7), sets: [
                set("Leg Press", 140, 20),   // endurance set: no estimate
                set("Leg Press", 160, 10),   // working set: estimated
            ])
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.excludedOutOfRangeSets, 4)
        // 160 x 10 = 160 x 40/30 = 213.3333…
        XCTAssertEqual(exercise.currentE1rmKg!, 213.33333, accuracy: 0.0001)
        // The 20-rep set contributes no volume and no top set either — it is outside the window entirely.
        XCTAssertEqual(exercise.topWorkingWeightKg!, 160, accuracy: 0.000001)
        XCTAssertEqual(exercise.sessions.last!.volumeKg, 1600, accuracy: 0.000001)
    }

    // MARK: - Warm-ups

    func testWarmupsAreNotWorkingSets() {
        let sessions = (0..<4).map { i in
            StrengthProgression.Session(start: day(i * 7), sets: [
                set("Bench", 200, 3, warmup: true),   // an absurd "warm-up" — must not become the top set
                set("Bench", 100, 8),
            ])
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.topWorkingWeightKg!, 100, accuracy: 0.000001)
        XCTAssertEqual(exercise.sessions.last!.usableSets, 1)
        XCTAssertEqual(exercise.sessions.last!.unusableSets, 0, "a warm-up is skipped, not counted as unusable")
    }

    // MARK: - Top set

    func testTopSetIsTheHeaviestSetNotTheBestEstimate() {
        // 60 x 12 estimates 84 kg; 90 x 3 estimates 99 kg. The best ESTIMATE is the 90, but if the reps had
        // been reversed the heaviest set must still be the one reported: a session with 90 kg in it that
        // reported "60 kg" as its top set would be wrong in the plainest possible way.
        let sessions = (0..<4).map { i in
            StrengthProgression.Session(start: day(i * 7), sets: [
                set("Squat", 60, 12),
                set("Squat", 90, 3),
            ])
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.sessions.last!.topSetKg!, 90, accuracy: 0.000001)
        XCTAssertEqual(exercise.sessions.last!.topSetReps!, 3)
    }

    func testAmongEqualWeightsTheTopSetIsTheOneWithMoreReps() {
        let sessions = (0..<4).map { i in
            StrengthProgression.Session(start: day(i * 7), sets: [
                set("Row", 50, 6),
                set("Row", 50, 10),
            ])
        }
        XCTAssertEqual(only(sessions).sessions.last!.topSetReps!, 10)
    }

    // MARK: - Increment inference

    func testIncrementIsTheSmallestGapTheWearerActuallyUsed() {
        // 70 / 72.5 / 75 / 80 → gaps 2.5, 2.5, 5 → the wearer's step is 2.5, not 5 and not an assumed value.
        let weights: [Double] = [70, 72.5, 75, 80]
        XCTAssertEqual(StrengthProgression.increment(usable: weights.map { (date: day(0), weightKg: $0, reps: 8) })!,
                       2.5, accuracy: 0.000001)
    }

    func testOneWeightInTheHistoryMeansNoInferableIncrement() {
        // The honest answer, and the reason the suggestion can end with "no step to suggest" rather than
        // reaching for a conventional 2.5 kg this wearer has never used.
        XCTAssertNil(StrengthProgression.increment(usable: [(date: day(0), weightKg: 75, reps: 8), (date: day(7), weightKg: 75, reps: 9)]))
        XCTAssertNil(StrengthProgression.increment(usable: []))
    }

    func testAOneOffBigJumpIsNotAnIncrement() {
        // 60 → 100 is not the discovery of a 40 kg step. With no smaller gap there is no step at all.
        XCTAssertNil(StrengthProgression.increment(usable: [(date: day(0), weightKg: 60, reps: 8), (date: day(7), weightKg: 100, reps: 8)]))
        // But a big jump alongside a real step leaves the real step standing.
        XCTAssertEqual(StrengthProgression.increment(usable: [
            (date: day(0), weightKg: 60, reps: 8),
            (date: day(7), weightKg: 65, reps: 8),
            (date: day(14), weightKg: 100, reps: 8),
        ])!, 5, accuracy: 0.000001)
    }

    func testPoundConversionDustIsNotAnIncrement() {
        // A pound-denominated log converts to kilograms at 0.45359237, so two "same" weights differ by
        // hundredths. Treating that as the step would suggest 75.02 kg.
        XCTAssertNil(StrengthProgression.increment(usable: [(date: day(0), weightKg: 74.9997, reps: 8), (date: day(7), weightKg: 75.0, reps: 8)]))
    }

    // MARK: - Stall detection

    /// Five sessions a week apart, every one topping out at 75 kg x 8 (e1RM exactly 95 kg).
    private func flatHistory(sessions count: Int, everyDays: Int = 7) -> [StrengthProgression.Session] {
        (0..<count).map { i in
            StrengthProgression.Session(start: day(i * everyDays), sets: [set("Brustpresse", 75, 8)])
        }
    }

    func testAFlatLiftIsStalledOnceItIsBothLongEnoughAndOftenEnough() {
        let exercise = only(flatHistory(sessions: 5))
        XCTAssertNotNil(exercise.stall)
        // The best was first reached at session 0; four sessions have passed since, spanning 28 days.
        XCTAssertEqual(exercise.stall?.sessions, 4)
        XCTAssertEqual(exercise.stall?.days, 28)
        XCTAssertEqual(exercise.stall?.stuckAtKg, 75)
        XCTAssertTrue(exercise.needsAttention)
    }

    func testThreeSessionsInOneWeekIsNotAStall() {
        // The session count clears `stallSessions`, the span does not clear `stallMinDays` — and a lift
        // trained four times in ten days has not had time to adapt, so calling it stalled would be a guess.
        let exercise = only(flatHistory(sessions: 4, everyDays: 3))   // spans 9 days
        XCTAssertEqual(exercise.stall, nil)
        XCTAssertFalse(exercise.needsAttention)
    }

    func testTwoSessionsAMonthApartIsNotAStallEither() {
        // The span clears `stallMinDays`, the session count does not clear `stallSessions`.
        let exercise = only(flatHistory(sessions: 3, everyDays: 30))
        XCTAssertNil(exercise.stall)
    }

    func testAnImprovingLiftIsNotStalled() {
        let exercise = only([
            .init(start: day(0), sets: [set("Brustpresse", 70, 8)]),
            .init(start: day(7), sets: [set("Brustpresse", 72.5, 8)]),
            .init(start: day(14), sets: [set("Brustpresse", 75, 8)]),
            .init(start: day(21), sets: [set("Brustpresse", 77.5, 8)]),
            .init(start: day(28), sets: [set("Brustpresse", 80, 8)]),
        ])
        XCTAssertNil(exercise.stall)
    }

    func testTheStallClockRunsFromWHENTHEBESTWASFIRSTREACHED() {
        // Improving for three sessions, then flat for four. The clock must start at the third session (the
        // first to reach the current best), not at the most recent session that merely EQUALS it — taking
        // the latest equal session would reset the clock on every repeat, and repeating the same weight is
        // exactly what a stall is.
        var sessions: [StrengthProgression.Session] = [
            .init(start: day(0), sets: [set("Brustpresse", 70, 8)]),
            .init(start: day(7), sets: [set("Brustpresse", 72.5, 8)]),
            .init(start: day(14), sets: [set("Brustpresse", 75, 8)]),
        ]
        for i in 3..<7 {
            sessions.append(.init(start: day(i * 7), sets: [set("Brustpresse", 75, 8)]))
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.stall?.sessions, 4, "four sessions since day 14, not since day 42")
        XCTAssertEqual(exercise.stall?.days, 28)
    }

    func testANoiseLevelGainIsNotAnImprovement() {
        // 75.0 → 75.01 kg is arithmetic, not progress. Without the epsilon an unchanged lift would report a
        // gain and never stall.
        var sessions = flatHistory(sessions: 4)
        sessions.append(.init(start: day(28), sets: [set("Brustpresse", 75.01, 8)]))
        let exercise = only(sessions)
        XCTAssertNotNil(exercise.stall, "a hundredth of a kilo does not clear the stall")
        XCTAssertEqual(StrengthProgression.improvementEpsilonKg, 0.5)
    }

    // MARK: - Double progression

    func testDoubleProgressionAddsARepBeforeItAddsWeight() {
        // Recent sets have run 8–12 reps and the last top set was 8. There are four reps of room, so the
        // weight does not move.
        let exercise = only([
            .init(start: day(0), sets: [set("Brustpresse", 75, 12)]),
            .init(start: day(7), sets: [set("Brustpresse", 72.5, 10)]),
            .init(start: day(14), sets: [set("Brustpresse", 75, 8)]),
            .init(start: day(21), sets: [set("Brustpresse", 75, 8)]),
        ])
        let suggestion = exercise.suggestion
        XCTAssertEqual(suggestion?.step, .addReps)
        XCTAssertEqual(suggestion?.weightKg, 75)
        XCTAssertEqual(suggestion?.reps, 9)
        XCTAssertNil(suggestion?.incrementKg, "adding a rep changes no weight")
        XCTAssertEqual(suggestion?.repRangeLow, 8)
        XCTAssertEqual(suggestion?.repRangeHigh, 12)
    }

    func testTopOfTheRangeAddsExactlyOneObservedIncrementAndDropsBackToTheBottom() {
        // The wearer's own history shows 2.5 kg steps (70 → 72.5 → 75), and their recent sets have all been
        // eights — so the range is topped out and the step is 2.5. This is the case in the feature's own
        // worked example: "Brustpresse: 3 sessions at 75 kg, try 77.5 kg x 8".
        let exercise = only([
            .init(start: day(0), sets: [set("Brustpresse", 70, 8)]),
            .init(start: day(7), sets: [set("Brustpresse", 72.5, 8)]),
            .init(start: day(14), sets: [set("Brustpresse", 75, 8)]),
            .init(start: day(21), sets: [set("Brustpresse", 75, 8)]),
            .init(start: day(28), sets: [set("Brustpresse", 75, 8)]),
            .init(start: day(35), sets: [set("Brustpresse", 75, 8)]),
        ])
        XCTAssertEqual(exercise.incrementKg!, 2.5, accuracy: 0.000001)
        let suggestion = exercise.suggestion
        XCTAssertEqual(suggestion?.step, .addWeight)
        XCTAssertEqual(suggestion?.weightKg, 77.5)
        XCTAssertEqual(suggestion?.reps, 8)
        XCTAssertEqual(suggestion?.incrementKg, 2.5)
        XCTAssertEqual(suggestion?.fromWeightKg, 75)
        XCTAssertEqual(suggestion?.fromReps, 8)
        // And it is stalled, which is why it is being suggested a step in the first place.
        XCTAssertNotNil(exercise.stall)
        XCTAssertEqual(exercise.stall?.stuckAtKg, 75)
    }

    func testTheSuggestionNeverExceedsOneObservedIncrement() {
        // A lift climbing 5 kg a session still only gets ONE step. Extrapolating the trend would load a
        // weight the wearer has never lifted.
        let exercise = only([
            .init(start: day(0), sets: [set("Beinpresse", 100, 8)]),
            .init(start: day(7), sets: [set("Beinpresse", 105, 8)]),
            .init(start: day(14), sets: [set("Beinpresse", 110, 8)]),
            .init(start: day(21), sets: [set("Beinpresse", 115, 8)]),
        ])
        XCTAssertEqual(exercise.incrementKg!, 5, accuracy: 0.000001)
        XCTAssertEqual(exercise.suggestion?.weightKg, 120)
        XCTAssertEqual(exercise.suggestion?.step, .addWeight)
    }

    func testNoSuggestionWhenTheRangeIsToppedOutAndNoIncrementCanBeInferred() {
        // One weight in the whole history and no rep room: there is no step this app can defend, so it
        // offers none rather than guessing at a machine it has never seen.
        let exercise = only(flatHistory(sessions: 5))
        XCTAssertNil(exercise.incrementKg)
        XCTAssertNil(exercise.suggestion)
        // The rest of the readout is still real — abstaining from ONE figure is not abstaining from all.
        XCTAssertNil(exercise.abstained)
        XCTAssertEqual(exercise.currentE1rmKg!, 95, accuracy: 0.000001)
        XCTAssertNotNil(exercise.stall)
    }

    func testTheRepRangeIsTheCURRENTOneNotTheWholeHistory() {
        // Fives last spring, tens now. A range of 5–12 read from the whole history would tell the wearer
        // there were seven reps of room to add.
        var sessions: [StrengthProgression.Session] = [
            .init(start: day(0), sets: [set("Squat", 120, 5)]),
            .init(start: day(7), sets: [set("Squat", 120, 5)]),
        ]
        for i in 2..<8 {
            sessions.append(.init(start: day(i * 7), sets: [set("Squat", 100, 10)]))
        }
        let exercise = only(sessions)
        XCTAssertEqual(exercise.repRangeLow, 10)
        XCTAssertEqual(exercise.repRangeHigh, 10)
        XCTAssertEqual(StrengthProgression.repRangeSessions, 5)
    }

    // MARK: - Trend

    func testTrendIsALeastSquaresSlopeCarriedAcrossTheNominalWindow() {
        // Three sessions on days 0 / 14 / 28 at 90 / 95 / 100 kg of estimate.
        //   x = 0, 14, 28   mean 14        y = 90, 95, 100   mean 95
        //   Sxx = 196 + 0 + 196 = 392      Sxy = (-14)(-5) + 0 + (14)(5) = 140
        //   slope = 140 / 392 = 0.3571428… kg/day
        //   4 weeks  → 0.3571428… x 28 = 10.0 kg exactly
        //   8 weeks  → 0.3571428… x 56 = 20.0 kg exactly (same three sessions, twice the window)
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 90, 1)]),
            .init(start: day(14), sets: [set("Bench", 95, 1)]),
            .init(start: day(28), sets: [set("Bench", 100, 1)]),
        ])
        // At one rep Epley scales by 31/30, which is a constant factor — so the hand-computed slope above
        // is in the same units the model reports once the inputs are scaled the same way.
        let scale = 31.0 / 30.0
        XCTAssertEqual(exercise.trends[4]!.deltaKg, 10.0 * scale, accuracy: 0.0001)
        XCTAssertEqual(exercise.trends[8]!.deltaKg, 20.0 * scale, accuracy: 0.0001)
        XCTAssertEqual(exercise.trends[4]!.sessions, 3)
        XCTAssertEqual(exercise.trends[4]!.direction, .up)
        XCTAssertEqual(exercise.trends[4]!.deltaPct!, (10.0 * scale) / (95.0 * scale), accuracy: 0.0001)
    }

    func testAWindowWithOneSessionHasNoTrend() {
        // Three sessions, but only one of them inside four weeks of the last. A one-point "trend" is a
        // direction invented from no elapsed time.
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 5)]),
            .init(start: day(120), sets: [set("Bench", 100, 5)]),
            .init(start: day(240), sets: [set("Bench", 100, 5)]),
        ])
        XCTAssertNil(exercise.trends[4])
        XCTAssertNil(exercise.trends[8])
        XCTAssertNil(exercise.trends[12])
        XCTAssertNil(exercise.headlineTrend)
    }

    func testSessionsAllOnTheSameInstantHaveNoSlope() {
        // A vertical fit has no slope, and inventing one from no elapsed time would report a trend drawn
        // from a single moment. Built as points directly, because the only way to reach this through
        // `build` is a corrupt import where every session carries the same timestamp.
        func point(_ value: Double) -> StrengthProgression.SessionPoint {
            StrengthProgression.SessionPoint(date: day(0), bestE1rmKg: value, bestBrzyckiKg: value,
                                             topSetKg: 100, topSetReps: 5, volumeKg: 500,
                                             usableSets: 1, unusableSets: 0)
        }
        XCTAssertNil(StrengthProgression.trend(scored: [point(100), point(102), point(104)],
                                               endingAt: day(0), weeks: 4, calendar: calendar))
    }

    func testAFallingLiftReportsFalling() {
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 8)]),
            .init(start: day(14), sets: [set("Bench", 95, 8)]),
            .init(start: day(28), sets: [set("Bench", 90, 8)]),
        ])
        XCTAssertEqual(exercise.headlineTrend?.direction, .down)
        XCTAssertLessThan(exercise.trends[4]!.deltaKg, 0)
    }

    func testHeadlineTrendPrefersTheShortestWindowThatHasAFit() {
        // Two sessions 60 days apart: no four-week fit, so the headline is the twelve-week one — a longer
        // claim, honestly labelled as one.
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 90, 8)]),
            .init(start: day(30), sets: [set("Bench", 95, 8)]),
            .init(start: day(60), sets: [set("Bench", 100, 8)]),
        ])
        XCTAssertNil(exercise.trends[4])
        XCTAssertEqual(exercise.headlineTrend?.windowWeeks, 8)
    }

    // MARK: - Identity, ordering and best-ever

    func testCaseAndSpacingVariantsAreOneExercise() {
        let out = build([
            .init(start: day(0), sets: [set("Brustpresse", 70, 8)]),
            .init(start: day(7), sets: [set("brustpresse ", 72.5, 8)]),
            .init(start: day(14), sets: [set("  BRUSTPRESSE", 75, 8)]),
        ])
        XCTAssertEqual(out.count, 1, "one lift, not three thin histories that all abstain")
        XCTAssertNil(out[0].abstained)
        // The display name is the most recent spelling.
        XCTAssertEqual(out[0].name, "  BRUSTPRESSE")
    }

    func testStalledExercisesSortFirstThenMostRecent() {
        var sessions: [StrengthProgression.Session] = []
        // A stalled lift, last trained a while ago.
        for i in 0..<5 {
            sessions.append(.init(start: day(i * 7), sets: [set("Stuck", 75, 8)]))
        }
        // A healthy lift, trained most recently of all.
        for i in 0..<4 {
            sessions.append(.init(start: day(60 + i * 7), sets: [set("Moving", Double(100 + i * 5), 8)]))
        }
        let out = build(sessions)
        XCTAssertEqual(out.map(\.name), ["Stuck", "Moving"],
                       "a stalled lift is the one the wearer can act on, and recency alone buries it")
    }

    func testBestEverIsWhenTheBestWasFIRSTReached() {
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 8)]),
            .init(start: day(7), sets: [set("Bench", 100, 8)]),
            .init(start: day(14), sets: [set("Bench", 90, 8)]),
            .init(start: day(21), sets: [set("Bench", 100, 8)]),
        ])
        XCTAssertEqual(exercise.bestEverDate, day(0))
        // 100 x 8 = 100 x 38/30 = 126.6667…
        XCTAssertEqual(exercise.bestEverE1rmKg!, 126.66667, accuracy: 0.0001)
        // Current is the LATEST reading, which here equals the best but is a different question.
        XCTAssertEqual(exercise.currentDate, day(21))
    }

    func testSessionsWithNoReadableSetLeaveNoPointInTheSeries() {
        // The sparkline and the chart must not pass through a session they cannot read — an interpolated
        // segment across it would look exactly like data.
        let exercise = only([
            .init(start: day(0), sets: [set("Bench", 100, 8)]),
            .init(start: day(7), sets: [set("Bench", 10, 11, added: true)]),
            .init(start: day(14), sets: [set("Bench", 105, 8)]),
            .init(start: day(21), sets: [set("Bench", 110, 8)]),
        ])
        XCTAssertEqual(exercise.sessions.count, 4)
        XCTAssertEqual(exercise.e1rmSeries.count, 3)
        XCTAssertFalse(exercise.e1rmSeries.contains { $0.date == day(7) })
    }
}
