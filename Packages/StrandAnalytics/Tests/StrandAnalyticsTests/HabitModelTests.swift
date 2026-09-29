import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-A.2 — one model, keyed to the night, where absence is never "no".
final class HabitModelTests: XCTestCase {

    // MARK: Absent vs "no", per source

    func testJournalBoolAbsentIsNotNo() {
        XCTAssertEqual(HabitRules.journalBool(answeredYes: true), .yes)
        XCTAssertEqual(HabitRules.journalBool(answeredYes: false), .no)
        XCTAssertNil(HabitRules.journalBool(answeredYes: nil))
    }

    func testNumericZeroEnteredIsNo() {
        XCTAssertEqual(HabitRules.journalNumeric(value: 2), .yes)
        XCTAssertEqual(HabitRules.journalNumeric(value: 0), .no, "a 0 the stepper wrote is an answer")
        XCTAssertNil(HabitRules.journalNumeric(value: nil), "no row is no observation")
        XCTAssertNil(HabitRules.journalNumeric(value: .nan))
    }

    func testDreamCutPointsAreFixed() {
        XCTAssertEqual(HabitRules.dreamScreen(option: 1), .yes)
        XCTAssertEqual(HabitRules.dreamScreen(option: 2), .yes)
        XCTAssertEqual(HabitRules.dreamScreen(option: 3), .no)
        XCTAssertEqual(HabitRules.dreamScreen(option: 4), .no)
        XCTAssertNil(HabitRules.dreamScreen(option: nil))
        XCTAssertNil(HabitRules.dreamScreen(option: 5))
        XCTAssertEqual(HabitRules.dreamMeal(option: 2), .yes)
        XCTAssertEqual(HabitRules.dreamMeal(option: 3), .no)
        XCTAssertNil(HabitRules.dreamMeal(option: 0))
    }

    func testLateCaffeineNoIntakeIsAbsent() {
        XCTAssertNil(HabitRules.lateCaffeine(lastIntakeMinute: nil), "no coffee and didn't log look the same")
        XCTAssertEqual(HabitRules.lateCaffeine(lastIntakeMinute: 14 * 60), .no, "14:00 itself is not after 14:00")
        XCTAssertEqual(HabitRules.lateCaffeine(lastIntakeMinute: 14 * 60 + 1), .yes)
        XCTAssertEqual(HabitRules.lateCaffeine(lastIntakeMinute: 1470), .yes, "00:30 attributed to the evening")
    }

    func testLateWorkout() {
        let onset: Int64 = 1_000_000
        XCTAssertNil(HabitRules.lateWorkout(workoutEndsEpochSec: [], onsetEpochSec: nil, hasWorkoutCoverage: true))
        XCTAssertNil(HabitRules.lateWorkout(workoutEndsEpochSec: [onset - 60], onsetEpochSec: onset,
                                            hasWorkoutCoverage: false))
        XCTAssertEqual(HabitRules.lateWorkout(workoutEndsEpochSec: [onset - 2 * 3600], onsetEpochSec: onset,
                                              hasWorkoutCoverage: true), .yes)
        XCTAssertEqual(HabitRules.lateWorkout(workoutEndsEpochSec: [onset - 4 * 3600], onsetEpochSec: onset,
                                              hasWorkoutCoverage: true), .no)
    }

    func testWarmBedroomNeedsCoverage() {
        XCTAssertNil(HabitRules.warmBedroom(meanC: 22, slotCoverage: 0.5))
        XCTAssertEqual(HabitRules.warmBedroom(meanC: 19.6, slotCoverage: 0.6), .yes)
        XCTAssertEqual(HabitRules.warmBedroom(meanC: 19.5, slotCoverage: 1), .no)
        XCTAssertNil(HabitRules.warmBedroom(meanC: nil, slotCoverage: 1))
    }

    func testBreathingOnlyObservedWhileActive() {
        let onset: Int64 = 100_000, evening: Int64 = 80_000
        XCTAssertNil(HabitRules.breathingSession(activeInLast14Days: false, sessions: [], eveningStartEpochSec: evening,
                                                 onsetEpochSec: onset))
        XCTAssertEqual(HabitRules.breathingSession(activeInLast14Days: true,
                                                   sessions: [(endEpochSec: 90_000, minutes: 10)],
                                                   eveningStartEpochSec: evening, onsetEpochSec: onset), .yes)
        XCTAssertEqual(HabitRules.breathingSession(activeInLast14Days: true,
                                                   sessions: [(endEpochSec: 90_000, minutes: 3)],
                                                   eveningStartEpochSec: evening, onsetEpochSec: onset), .no)
    }

    func testLightsDimmedAndBedtimeOnTarget() {
        XCTAssertEqual(HabitRules.lightsDimmed(winddownRan: 1), .yes)
        XCTAssertEqual(HabitRules.lightsDimmed(winddownRan: 0), .no)
        XCTAssertNil(HabitRules.lightsDimmed(winddownRan: nil), "disabled automation writes no row")
        XCTAssertEqual(HabitRules.bedtimeOnTarget(onsetMinute: 10, targetMinute: 1420), .yes, "wraps midnight")
        XCTAssertEqual(HabitRules.bedtimeOnTarget(onsetMinute: 1380, targetMinute: 1320), .no)
        XCTAssertNil(HabitRules.bedtimeOnTarget(onsetMinute: 1380, targetMinute: nil))
    }

    // MARK: The keying rule

    func testNightKeyMapping() {
        // Evening coffee on the 28th belongs to the night keyed the 29th.
        XCTAssertEqual(HabitNightKey.fallback(localDay: "2026-03-28", localMinute: 16 * 60), "2026-03-29")
        // After-midnight intake (00:30 on the 29th) is still the 28th's evening → night keyed the 29th.
        XCTAssertEqual(HabitNightKey.fallback(localDay: "2026-03-29", localMinute: 30), "2026-03-29")
        // With a known sleep session, the next onset decides.
        let onset: Int64 = 2_000_000
        XCTAssertEqual(HabitNightKey.forEvent(epochSec: onset - 1800, localDay: "2026-03-29", localMinute: 30,
                                              nightOnsets: [(nightKey: "2026-03-29", onsetEpochSec: onset)]),
                       "2026-03-29")
        // The caffeine summary files an after-midnight intake under the previous day, minute + 1440.
        let s = HabitNightKey.caffeineDay(localDay: "2026-03-29", localMinute: 30)!
        XCTAssertEqual(s.day, "2026-03-28")
        XCTAssertEqual(s.minute, 1470)
        let t = HabitNightKey.caffeineDay(localDay: "2026-03-29", localMinute: 15 * 60)!
        XCTAssertEqual(t.day, "2026-03-29")
    }

    func testDayMathIsCalendarNotSeconds() {
        // DST days (EU 2026-03-29, 2026-10-25) are just dates.
        XCTAssertEqual(HabitDay.adding(1, to: "2026-03-28"), "2026-03-29")
        XCTAssertEqual(HabitDay.adding(1, to: "2026-03-29"), "2026-03-30")
        XCTAssertEqual(HabitDay.adding(1, to: "2026-10-25"), "2026-10-26")
        XCTAssertEqual(HabitDay.days(from: "2026-03-01", to: "2026-04-01"), 31)
        XCTAssertEqual(HabitDay.adding(1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(HabitDay.adding(1, to: "2026-12-31"), "2027-01-01")
        XCTAssertNil(HabitDay.epochDay("2026-02-30"))
        XCTAssertNil(HabitDay.epochDay("2026-1-5"))
        XCTAssertEqual(HabitDay.epochDay("1970-01-01"), 0)
        XCTAssertEqual(HabitDay.isoWeekday("2026-09-29"), 2)   // a Tuesday
        XCTAssertTrue(HabitDay.isWeekendEvening("2026-10-02"))  // Friday evening
        XCTAssertFalse(HabitDay.isWeekendEvening("2026-10-04")) // Sunday evening leads into Monday
        for e in stride(from: -1000, through: 30_000, by: 97) {
            XCTAssertEqual(HabitDay.epochDay(HabitDay.key(e)), e)
        }
    }

    func testOnsetClockValueIsContinuousAcrossMidnight() {
        XCTAssertEqual(HabitOutcome.onsetClockValue(onsetMinute: 23 * 60 + 50), 1430)
        XCTAssertEqual(HabitOutcome.onsetClockValue(onsetMinute: 10), 1450)
    }

    // MARK: The catalogue

    func testOutcomeLikeAnswersNeverBecomeHabits() {
        for q in ["Felt rested", "Night wakings (felt)", "Dream tone", "Dream recall", "Wake-up", "Dream"] {
            XCTAssertNil(HabitCatalog.journalHabitId(question: q), q)
        }
        // Mirrored dream rows enter through the dream store, not twice through the journal.
        XCTAssertNil(HabitCatalog.journalHabitId(question: "Screen before bed"))
        XCTAssertEqual(HabitCatalog.journalHabitId(question: "Did you drink any alcohol?"), HabitCatalog.alcohol)
        XCTAssertEqual(HabitCatalog.journalHabitId(question: "Cold shower"), HabitId("journal:Cold shower"))
    }

    func testDefinitionsFollowTheTable() {
        func def(_ id: HabitId) -> HabitDefinition { HabitCatalog.definition(id)! }
        XCTAssertEqual(def(HabitCatalog.alcohol).primaryOutcome, .nightHrvLn)
        XCTAssertEqual(def(HabitCatalog.lateCaffeineAuto).primaryOutcome, .totalSleepMin)
        XCTAssertEqual(def(HabitCatalog.dreamScreen).primaryOutcome, .onsetClockMin)
        XCTAssertEqual(def(HabitCatalog.dreamMeal).primaryOutcome, .nightRhr)
        XCTAssertEqual(def(HabitCatalog.stressed).kind, .context)
        XCTAssertEqual(def(HabitCatalog.sick).kind, .context)
        XCTAssertEqual(def(HabitCatalog.sharedBed).kind, .context)
        XCTAssertEqual(def(HabitCatalog.magnesium).kind, .supplement)
        XCTAssertNil(def(HabitCatalog.magnesium).trialId, "a supplement is never trialled")
        for d in HabitCatalog.definitions {
            XCTAssertTrue(d.primaryOutcome.canBePrimary)
            XCTAssertLessThanOrEqual(d.secondaryOutcomes.count, 2)
            XCTAssertEqual(d.direction, d.primaryOutcome.betterDirection)
            if let t = d.trialId { XCTAssertNotNil(HabitTrialCatalog.entry(t), "\(d.id.raw) → \(t)") }
        }
        let custom = HabitCatalog.custom(question: "Late walk", primary: nil)
        XCTAssertEqual(custom.primaryOutcome, .nightHrvLn)
        XCTAssertEqual(custom.kind, .behaviour)
        XCTAssertEqual(HabitCatalog.custom(question: "x", primary: .dayStressMean).primaryOutcome, .nightHrvLn,
                       "an exploratory-only outcome can never become primary")
    }

    func testDuplicateStatesPreferYes() {
        let inputs = HabitLedgerInputs(observations: [
            HabitObservation(nightKey: "2026-09-01", habit: HabitCatalog.alcohol, state: .no, source: .journal),
            HabitObservation(nightKey: "2026-09-01", habit: HabitCatalog.alcohol, state: .yes, source: .journal),
        ], outcomes: [:], effortByDay: [:])
        XCTAssertEqual(inputs.statesByHabit()[HabitCatalog.alcohol]?["2026-09-01"], .yes)
    }
}
