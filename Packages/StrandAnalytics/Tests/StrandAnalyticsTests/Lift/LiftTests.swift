import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Telos Lift (DESIGN_V2 decision 16): the pure half — program edits, template choice, prefill, increments,
/// e1RM, the rest timer, early finish, the finish-screen math, the store mapping and the import dedupe.
final class LiftTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 18, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func exercise(_ name: String, working: Int = 3, warmups: Int = 0, reps: Int? = 10,
                          equipment: String? = "Maschine", rest: Int? = nil) -> LiftExercisePlan {
        var plan = LiftExercisePlan(name: name, equipment: equipment, sets: [], targetReps: reps, restSeconds: rest)
        plan.setWorkingSetCount(working)
        plan.setWarmupCount(warmups)
        return plan
    }

    private func ownersTemplates() -> [LiftDayTemplate] {
        [
            LiftDayTemplate(id: "la", name: "Lower A (Di)", exercises: [exercise("Beinpresse")]),
            LiftDayTemplate(id: "lb", name: "Lower B (Fr)", exercises: [exercise("Beinbeugen im Sitzen")]),
            LiftDayTemplate(id: "ua", name: "Upper A (Mo)", exercises: [exercise("Brustpresse")]),
            LiftDayTemplate(id: "ub", name: "Upper B (Do)", exercises: [exercise("Latzug weit mit Obergriff")]),
        ]
    }

    // MARK: - Program edits

    func testProgramEditsRoundTripThroughJSON() throws {
        var library = LiftLibrary(programs: [LiftProgram(id: "p", name: "Lower", createdOn: "2026-01-05",
                                                         days: [ownersTemplates()[0]])])
        let exId = library.programs[0].days[0].exercises[0].id
        library.updateTemplate(id: "la") { day in
            day.addExercise(self.exercise("Beinstrecken", working: 4))
            day.updateExercise(id: exId) { ex in
                ex.equipment = "Kabelzug"
                ex.targetReps = 12
                ex.restSeconds = 120
                ex.setWorkingSetCount(4)
                ex.setWarmupCount(2)
            }
            day.moveExercise(id: exId, to: 1)
        }
        library.defaultRestSeconds = 165

        let data = try JSONEncoder().encode(library)
        let back = try JSONDecoder().decode(LiftLibrary.self, from: data)
        XCTAssertEqual(back, library)
        let day = back.template(id: "la")!
        XCTAssertEqual(day.exercises.map(\.name), ["Beinstrecken", "Beinpresse"])
        let moved = day.exercises[1]
        XCTAssertEqual(moved.equipment, "Kabelzug")
        XCTAssertEqual(moved.restSeconds, 120)
        XCTAssertEqual(moved.workingSetCount, 4)
        XCTAssertEqual(moved.warmupSetCount, 2)
        XCTAssertEqual(moved.sets.prefix(2).map(\.kind), [.warmup, .warmup], "warm-ups stay first")
        XCTAssertEqual(back.defaultRestSeconds, 165)
    }

    func testSetKindChangeKeepsWarmupsFirstAndCountsFollow() {
        var ex = exercise("Beinpresse", working: 3, warmups: 1)
        let lastWork = ex.sets.last!.id
        ex.setKind(setId: lastWork, to: .warmup)
        XCTAssertEqual(ex.sets.map(\.kind), [.warmup, .warmup, .working, .working])
        let firstWork = ex.sets[2].id
        ex.setKind(setId: firstWork, to: .drop)
        XCTAssertEqual(ex.workingSetCount, 2, "a drop set is still a working set")
        ex.setWorkingSetCount(1)
        XCTAssertEqual(ex.sets.map(\.kind), [.warmup, .warmup, .drop], "removal takes sets off the end")
    }

    func testRemoveExercise() {
        var day = ownersTemplates()[0]
        day.addExercise(exercise("Adduktoren"))
        day.removeExercise(id: day.exercises[0].id)
        XCTAssertEqual(day.exercises.map(\.name), ["Adduktoren"])
    }

    func testReimportKeepsIdsAndRestOverrides() {
        var library = LiftLibrary(programs: [LiftProgram(id: "keep", name: "Lower", days: [
            LiftDayTemplate(id: "old-la", name: "Lower A (Di)", exercises: [exercise("Beinpresse", rest: 180)]),
        ])])
        let oldExId = library.programs[0].days[0].exercises[0].id
        library.merge(imported: [LiftProgram(name: "lower", days: [
            LiftDayTemplate(id: "new-la", name: "Lower A (Di)", exercises: [exercise("Beinpresse", working: 4)]),
            LiftDayTemplate(id: "new-lb", name: "Lower B (Fr)", exercises: [exercise("Adduktoren")]),
        ])])
        XCTAssertEqual(library.programs.count, 1)
        XCTAssertEqual(library.programs[0].id, "keep")
        XCTAssertEqual(library.programs[0].days.map(\.id), ["old-la", "new-lb"])
        let ex = library.programs[0].days[0].exercises[0]
        XCTAssertEqual(ex.id, oldExId)
        XCTAssertEqual(ex.restSeconds, 180, "the export carries no rest times, so import must not wipe the wearer's")
        XCTAssertEqual(ex.workingSetCount, 4, "but the plan's sets come from the file")
    }

    // MARK: - Weekday tags + template selection

    func testWeekdayTags() {
        XCTAssertEqual(LiftWeekday.weekday(inTemplateName: "Lower A (Di)"), 3)
        XCTAssertEqual(LiftWeekday.weekday(inTemplateName: "Upper A (Mo)"), 2)
        XCTAssertEqual(LiftWeekday.weekday(inTemplateName: "Upper B (Do)"), 5)
        XCTAssertEqual(LiftWeekday.weekday(inTemplateName: "Lower B (Fr)"), 6)
        XCTAssertEqual(LiftWeekday.weekday(inTemplateName: "Push (Tue)"), 3)
        XCTAssertNil(LiftWeekday.weekday(inTemplateName: "Push (heavy)"))
        XCTAssertNil(LiftWeekday.weekday(inTemplateName: "Full body"))
    }

    func testRotationIsWeekOrder() {
        XCTAssertEqual(LiftTemplatePicker.rotation(ownersTemplates()).map(\.id), ["ua", "la", "ub", "lb"])
    }

    func testPicksTheTemplateTaggedToday() {
        let tuesday = 3
        let pick = LiftTemplatePicker.pick(templates: ownersTemplates(), weekday: tuesday,
                                           lastCompletedTemplateId: "lb")
        XCTAssertEqual(pick?.template.id, "la")
        XCTAssertEqual(pick?.reason, .weekday)
    }

    func testUntaggedDayFallsToTheNextInRotation() {
        let wednesday = 4
        let pick = LiftTemplatePicker.pick(templates: ownersTemplates(), weekday: wednesday,
                                           lastCompletedTemplateId: "la")
        XCTAssertEqual(pick?.template.id, "ub", "after Lower A (Di) comes Upper B (Do)")
        XCTAssertEqual(pick?.reason, .rotation)
        let wrap = LiftTemplatePicker.pick(templates: ownersTemplates(), weekday: 7, lastCompletedTemplateId: "lb")
        XCTAssertEqual(wrap?.template.id, "ua", "the rotation wraps")
        let fresh = LiftTemplatePicker.pick(templates: ownersTemplates(), weekday: 1, lastCompletedTemplateId: nil)
        XCTAssertEqual(fresh?.template.id, "ua")
        XCTAssertEqual(fresh?.reason, .first)
        XCTAssertNil(LiftTemplatePicker.pick(templates: [], weekday: 3, lastCompletedTemplateId: nil))
    }

    // MARK: - Increment

    func testIncrementIsTheWearersOwnSmallestStep() {
        XCTAssertEqual(LiftIncrement.infer(weightsKg: [30, 27.5, 32.5, 30]), 2.5)
        XCTAssertEqual(LiftIncrement.infer(weightsKg: [40, 48, 56]), 8, "an 8 kg stack is a real step")
        XCTAssertEqual(LiftIncrement.infer(weightsKg: [74.9997, 75, 77.5]), 2.5, "rounding noise is not a step")
        XCTAssertNil(LiftIncrement.infer(weightsKg: [60, 60, 60]), "one weight is evidence of nothing")
        XCTAssertNil(LiftIncrement.infer(weightsKg: [20, 40]), "a 20 kg jump is not an increment")
        let fallback = LiftIncrement.resolve(weightsKg: [])
        XCTAssertEqual(fallback, LiftIncrement.Resolved(kg: 2.5, observed: false), "default only without history, flagged")
        XCTAssertTrue(LiftIncrement.resolve(weightsKg: [40, 48]).observed)
    }

    func testStepperAnchorsOnTheCurrentWeight() {
        XCTAssertEqual(LiftIncrement.step(27.5, by: 1, incrementKg: 5), 32.5)
        XCTAssertEqual(LiftIncrement.step(5, by: -1, incrementKg: 5), nil, "never zero or below")
        XCTAssertEqual(LiftIncrement.step(nil, by: 1, incrementKg: 2.5), 2.5)
        XCTAssertNil(LiftIncrement.step(nil, by: -1, incrementKg: 2.5))
        let wheel = LiftIncrement.wheelValues(around: 10, incrementKg: 2.5, count: 5)
        XCTAssertEqual(wheel, [2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20, 22.5])
    }

    // MARK: - e1RM

    func testE1rmAbstainsOutsideTheWindow() {
        XCTAssertEqual(LiftE1RM.epley(weightKg: 60, reps: 10)!, 80, accuracy: 1e-9)
        XCTAssertEqual(LiftE1RM.epley(weightKg: 100, reps: 12)!, 140, accuracy: 1e-9)
        XCTAssertNil(LiftE1RM.epley(weightKg: 60, reps: 13))
        XCTAssertNil(LiftE1RM.epley(weightKg: 60, reps: 0))
        XCTAssertNil(LiftE1RM.epley(weightKg: nil, reps: 10))
        XCTAssertNil(LiftE1RM.epley(weightKg: 0, reps: 10))
        XCTAssertNil(LiftE1RM.epley(weightKg: 10, reps: 10, addedToBodyweight: true))
    }

    func testBodyweightExerciseRowsAbstainAndAreStoredWithTheImportersMarker() {
        let plan = exercise("Hyperextensions", working: 1, equipment: "Körpergewicht")
        XCTAssertTrue(plan.isBodyweight)
        var s = session(with: [plan])
        let ex = s.exercises[0]
        s.updateSet(exerciseId: ex.id, setId: ex.sets[0].id) { $0.weightKg = 10; $0.reps = 11 }
        XCTAssertNil(s.exercises[0].e1rm(s.exercises[0].sets[0]))
        s.check(exerciseId: ex.id, setId: ex.sets[0].id, at: date(2026, 9, 29, 18, 5), defaultRestSeconds: 150)
        let rows = LiftStoreBridge.setRows(s, deviceId: "lifting")
        XCTAssertEqual(rows.first?.note, LiftStoreBridge.bodyweightAddedNote)
    }

    // MARK: - Prefill

    private func history() -> [LiftHistorySession] {
        [
            LiftHistorySession(id: "lifting-1", start: date(2026, 9, 15), title: "Lower A (Di) · Tag 1 · Woche 30 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 100, reps: 10),
                                      LiftHistorySet(exercise: "Beinpresse", weightKg: 105, reps: 8)]),
            LiftHistorySession(id: "lifting-2", start: date(2026, 9, 19), title: "Lower B (Fr) · Tag 2 · Woche 30 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 90, reps: 12)]),
        ]
    }

    func testPrefillPrefersTheSameTemplateThenTheExercise() {
        let plan = exercise("Beinpresse", working: 3)
        let same = LiftPrefill.build(plan: plan, templateId: "la", templateName: "Lower A (Di)", history: history())
        XCTAssertEqual(same.source, .sameTemplate(date(2026, 9, 15)), "the imported title's template segment matches")
        XCTAssertEqual(same.sets.map(\.weightKg), [100, 105, 105], "extra rows copy last time's final set")
        XCTAssertEqual(same.sets.map(\.reps), [10, 8, 8])
        XCTAssertTrue(same.sets.allSatisfy(\.prefilled))
        XCTAssertEqual(same.lastTime.count, 2)

        let other = LiftPrefill.build(plan: plan, templateId: "x", templateName: "Legs (Sa)", history: history())
        XCTAssertEqual(other.source, .sameExercise(date(2026, 9, 19)), "falls back to the exercise's last session")
        XCTAssertEqual(other.sets.map(\.weightKg), [90, 90, 90])

        let none = LiftPrefill.build(plan: exercise("Adduktoren", working: 2, warmups: 1), templateId: "la",
                                     templateName: "Lower A (Di)", history: history())
        XCTAssertEqual(none.source, .none)
        XCTAssertEqual(none.sets.map(\.weightKg), [nil, nil, nil], "never logged: no weight is invented")
        XCTAssertEqual(none.sets.map(\.reps), [nil, 10, 10], "work sets show the plan's target, warm-ups nothing")
        XCTAssertFalse(none.sets.contains(where: \.prefilled))
    }

    // MARK: - Rest timer

    func testRestTimerIsATargetDateThatSurvivesTheBackground() {
        let t0 = date(2026, 9, 29, 18, 0)
        var timer = LiftRestTimer()
        XCTAssertEqual(timer.expiry(at: t0), .idle)
        timer.start(now: t0, seconds: LiftRestTimer.duration(exerciseRestSeconds: nil, globalDefaultSeconds: 150))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(4)), 146, accuracy: 1e-9)
        XCTAssertEqual(LiftRestTimer.clock(timer.remaining(at: t0.addingTimeInterval(4))), "2:26")
        // The phone sat in a pocket, suspended, for 100 s: nothing ticked, the answer is still right.
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(100)), 50, accuracy: 1e-9)
        timer.adjust(bySeconds: 15, now: t0.addingTimeInterval(100))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(100)), 65, accuracy: 1e-9)
        timer.adjust(bySeconds: -15, now: t0.addingTimeInterval(100))
        timer.adjust(bySeconds: -15, now: t0.addingTimeInterval(100))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(100)), 35, accuracy: 1e-9)
        XCTAssertEqual(timer.expiry(at: t0.addingTimeInterval(135)), .dueNow, "exactly at zero")
        XCTAssertEqual(timer.expiry(at: t0.addingTimeInterval(137)), .dueNow, "within the grace")
        XCTAssertEqual(timer.expiry(at: t0.addingTimeInterval(200)), .late(by: 65), "no late strap cue")
        // A cut past zero ends the rest now, never negative.
        var short = LiftRestTimer()
        short.start(now: t0, seconds: 10)
        short.adjust(bySeconds: -15, now: t0)
        XCTAssertEqual(short.remaining(at: t0), 0)
        XCTAssertEqual(LiftRestTimer.duration(exerciseRestSeconds: 90, globalDefaultSeconds: 150), 90)
        XCTAssertEqual(LiftRestTimer.clock(0.2), "0:01", "rounded up while running")
    }

    // MARK: - Session: check, early finish

    private func session(with plans: [LiftExercisePlan], start: Date? = nil,
                         templateId: String = "la", name: String = "Lower A (Di)") -> LiftLoggedSession {
        let exercises = plans.map { plan in
            LiftLoggedExercise(id: plan.id, name: plan.name, equipment: plan.equipment, targetReps: plan.targetReps,
                               restSeconds: plan.restSeconds, isBodyweight: plan.isBodyweight,
                               sets: plan.sets.map { LiftLoggedSet(id: $0.id, kind: $0.kind, reps: plan.targetReps) },
                               increment: LiftIncrement.resolve(weightsKg: []))
        }
        let s = start ?? date(2026, 9, 29, 18, 0)
        return LiftLoggedSession(id: LiftLoggedSession.sessionId(workoutStart: s), templateId: templateId,
                                 templateName: name, programName: "Lower", start: s, exercises: exercises)
    }

    func testCheckStartsTheRightRestAndRecordsRestTaken() {
        var s = session(with: [exercise("Beinpresse", working: 2, rest: 90), exercise("Beinstrecken", working: 1)])
        let a = s.exercises[0], b = s.exercises[1]
        let t = date(2026, 9, 29, 18, 5)
        XCTAssertEqual(s.check(exerciseId: a.id, setId: a.sets[0].id, at: t, defaultRestSeconds: 150), 90)
        XCTAssertEqual(s.check(exerciseId: a.id, setId: a.sets[1].id, at: t.addingTimeInterval(100),
                               defaultRestSeconds: 150), 90)
        XCTAssertEqual(s.exercises[0].sets[0].restTakenSec, 100)
        XCTAssertEqual(s.check(exerciseId: b.id, setId: b.sets[0].id, at: t.addingTimeInterval(300),
                               defaultRestSeconds: 150), 150, "no override: the global default")
        XCTAssertTrue(s.allPlannedDone)
        s.uncheck(exerciseId: b.id, setId: b.sets[0].id)
        XCTAssertFalse(s.allPlannedDone)
        XCTAssertEqual(s.exercises[1].sets[0].reps, 10, "un-checking keeps the values")
    }

    func testEarlyFinishRecordsUnfinishedSetsAsNotDoneNeverAsZero() {
        var s = session(with: [exercise("Beinpresse", working: 3), exercise("Adduktoren", working: 2)])
        let a = s.exercises[0]
        s.updateSet(exerciseId: a.id, setId: a.sets[0].id) { $0.weightKg = 100 }
        s.check(exerciseId: a.id, setId: a.sets[0].id, at: date(2026, 9, 29, 18, 5), defaultRestSeconds: 150)
        s.finish(at: date(2026, 9, 29, 18, 40))
        XCTAssertTrue(s.finishedEarly)
        XCTAssertEqual(s.doneCount, 1)
        XCTAssertEqual(s.notDoneCount, 4)
        XCTAssertEqual(s.pendingCount, 0)
        let rows = LiftStoreBridge.setRows(s, deviceId: "lifting")
        XCTAssertEqual(rows.count, 1, "a not-done set is not a set: no zero row reaches the store")
        XCTAssertEqual(rows[0].weightKg, 100)
        let sessionRow = LiftStoreBridge.sessionRow(s, deviceId: "lifting", sport: "Strength Training")
        XCTAssertEqual(sessionRow.note, "telos-lift notDone=4")
        XCTAssertEqual(sessionRow.programId, "la")
        XCTAssertEqual(sessionRow.endTs, Int(date(2026, 9, 29, 18, 40).timeIntervalSince1970))
        XCTAssertEqual(sessionRow.id, "telos-\(Int(s.start.timeIntervalSince1970))")
    }

    func testSetRowsCarryKindTokensAndPerformedOrder() {
        var s = session(with: [exercise("Beinpresse", working: 2, warmups: 1)])
        let ex = s.exercises[0]
        s.updateSet(exerciseId: ex.id, setId: ex.sets[2].id) { $0.kind = .drop; $0.weightKg = 80 }
        s.check(exerciseId: ex.id, setId: ex.sets[0].id, at: date(2026, 9, 29, 18, 1), defaultRestSeconds: 150)
        s.check(exerciseId: ex.id, setId: ex.sets[2].id, at: date(2026, 9, 29, 18, 3), defaultRestSeconds: 150)
        s.check(exerciseId: ex.id, setId: ex.sets[1].id, at: date(2026, 9, 29, 18, 5), defaultRestSeconds: 150)
        let rows = LiftStoreBridge.setRows(s, deviceId: "lifting")
        XCTAssertEqual(rows.map(\.ord), [0, 1, 2])
        XCTAssertEqual(rows.map(\.isWarmup), [true, false, false])
        XCTAssertEqual(rows[1].note, "telos:drop")
        XCTAssertEqual(rows.map(\.setIndex), [1, 2, 3])
        XCTAssertEqual(LiftSetKind.fromNoteToken(rows[1].note), .drop)
    }

    // MARK: - Summary: PRs, e1RM change, muscles, streak

    private let muscles: (String) -> [String] = { name in
        switch name.lowercased() {
        case "beinpresse": return ["quadriceps", "glutes"]
        case "beinstrecken": return ["quadriceps"]
        case "adduktoren": return ["hamstrings"]
        default: return []
        }
    }

    private func finished(_ values: [(String, Double?, Int?)], start: Date, templateId: String = "la",
                          name: String = "Lower A (Di)") -> LiftLoggedSession {
        var names: [String] = []
        for v in values where !names.contains(v.0) { names.append(v.0) }
        var s = session(with: names.map { n in exercise(n, working: values.filter { $0.0 == n }.count) },
                        start: start, templateId: templateId, name: name)
        var t = start
        for ex in s.exercises {
            let vals = values.filter { $0.0 == ex.name }
            for (i, set) in ex.sets.enumerated() {
                s.updateSet(exerciseId: ex.id, setId: set.id) { $0.weightKg = vals[i].1; $0.reps = vals[i].2 }
                t = t.addingTimeInterval(120)
                s.check(exerciseId: ex.id, setId: set.id, at: t, defaultRestSeconds: 150)
            }
        }
        s.finish(at: t.addingTimeInterval(60))
        return s
    }

    func testPRsNeedAPreviousBestAndE1rmChangeComparesTheLastSession() {
        let prior = [
            LiftHistorySession(id: "lifting-a", start: date(2026, 9, 8), title: "Lower A (Di) · Tag 1 · Woche 29 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 100, reps: 10)]),
            LiftHistorySession(id: "lifting-b", start: date(2026, 9, 15), title: "Lower A (Di) · Tag 1 · Woche 30 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 95, reps: 10)]),
        ]
        let s = finished([("Beinpresse", 105, 10), ("Adduktoren", 50, 10)], start: date(2026, 9, 22))
        let summary = LiftSummaryBuilder.build(session: s, history: prior, musclesFor: muscles, calendar: calendar)
        let press = summary.exercises.first { $0.name == "Beinpresse" }!
        XCTAssertEqual(press.records, [.e1rm(newKg: 105.0 * (1 + 10.0 / 30), previousBestKg: 100.0 * (1 + 10.0 / 30)),
                                       .heaviest(newKg: 105, previousBestKg: 100)])
        XCTAssertEqual(press.previousE1rmKg!, 95 * (1 + 10.0 / 30), accuracy: 1e-9, "the LAST session, not the best")
        XCTAssertEqual(press.e1rmDeltaKg!, 10 * (1 + 10.0 / 30), accuracy: 1e-9)
        let add = summary.exercises.first { $0.name == "Adduktoren" }!
        XCTAssertEqual(add.records, [], "a first log is not a record")
        XCTAssertNil(add.e1rmDeltaKg)
        XCTAssertEqual(summary.recordCount, 2)
        XCTAssertEqual(summary.improvedCount, 1)
        XCTAssertEqual(summary.templateSessionNumber, 3)
        XCTAssertEqual(summary.totalSessions, 3)
    }

    func testMuscleChangeAgainstThePreviousComparableSession() {
        let prior = [
            LiftHistorySession(id: "lifting-a", start: date(2026, 9, 15), title: "Lower A (Di) · Tag 1 · Woche 30 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 100, reps: 10),
                                      LiftHistorySet(exercise: "Adduktoren", weightKg: 40, reps: 10)]),
            // A different template in between must not be the comparison.
            LiftHistorySession(id: "lifting-b", start: date(2026, 9, 19), title: "Lower B (Fr) · Tag 2 · Woche 30 · Lower",
                               sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 10, reps: 10)]),
        ]
        let s = finished([("Beinpresse", 110, 10), ("Beinstrecken", 50, 10)], start: date(2026, 9, 22))
        let summary = LiftSummaryBuilder.build(session: s, history: prior, musclesFor: muscles, calendar: calendar)
        XCTAssertEqual(summary.comparableSessionStart, date(2026, 9, 15))
        let quads = summary.muscles.first { $0.group == "quadriceps" }!
        XCTAssertEqual(quads.sets, 2)
        XCTAssertEqual(quads.shareOfSets, 1, accuracy: 1e-9)
        XCTAssertEqual(quads.volumeKg, 1600, accuracy: 1e-9)
        XCTAssertEqual(quads.changePct!, 0.6, accuracy: 1e-9, "1600 vs 1000")
        let glutes = summary.muscles.first { $0.group == "glutes" }!
        XCTAssertEqual(glutes.changePct!, 0.1, accuracy: 1e-9)
        let hams = summary.muscles.first { $0.group == "hamstrings" }!
        XCTAssertEqual(hams.sets, 0)
        XCTAssertEqual(hams.changePct!, -1, accuracy: 1e-9, "trained last time, not today: −100 %")
    }

    func testNoComparableSessionMeansNoPercentage() {
        let s = finished([("Beinpresse", 110, 10)], start: date(2026, 9, 22))
        let other = [LiftHistorySession(id: "lifting-x", start: date(2026, 9, 19), title: "Lower B (Fr)",
                                        sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 100, reps: 10)])]
        let summary = LiftSummaryBuilder.build(session: s, history: other, musclesFor: muscles, calendar: calendar)
        XCTAssertNil(summary.comparableSessionStart)
        XCTAssertFalse(summary.muscles.isEmpty)
        XCTAssertTrue(summary.muscles.allSatisfy { $0.changePct == nil && $0.previousVolumeKg == nil })
        XCTAssertEqual(summary.templateSessionNumber, 1)
        XCTAssertEqual(summary.totalSessions, 2)
    }

    func testStreakCountsWeeksInARowIncludingThisOne() {
        let starts = [date(2026, 9, 1), date(2026, 9, 9), date(2026, 9, 16), date(2026, 9, 22)]
        XCTAssertEqual(LiftSummaryBuilder.streakWeeks(sessionStarts: starts, now: date(2026, 9, 22), calendar: calendar), 4)
        let gap = [date(2026, 9, 1), date(2026, 9, 16), date(2026, 9, 22)]
        XCTAssertEqual(LiftSummaryBuilder.streakWeeks(sessionStarts: gap, now: date(2026, 9, 22), calendar: calendar), 2)
        // Across the October DST change.
        let dst = [date(2026, 10, 20), date(2026, 10, 27)]
        XCTAssertEqual(LiftSummaryBuilder.streakWeeks(sessionStarts: dst, now: date(2026, 10, 27), calendar: calendar), 2)
    }

    func testAchievementsFollowTheirRules() {
        let s = finished([("Beinpresse", 100, 10)], start: date(2026, 9, 22, 22, 10))
        let summary = LiftSummaryBuilder.build(session: s, history: [], musclesFor: muscles, calendar: calendar)
        XCTAssertTrue(summary.achievements.contains(.nightOwl(startHour: 22)))
        XCTAssertTrue(summary.achievements.contains(.everySetDone(sets: 1)))
        XCTAssertFalse(summary.achievements.contains { if case .newRecords = $0 { return true } else { return false } })
        XCTAssertFalse(summary.achievements.contains { if case .longHaul = $0 { return true } else { return false } })
    }

    // MARK: - Store bridge + dedupe

    func testHistoryFromStoredRowsReadsTheMarkers() {
        var s = finished([("Beinpresse", 100, 10)], start: date(2026, 9, 22))
        s.exercises[0].isBodyweight = false
        let sessionRow = LiftStoreBridge.sessionRow(s, deviceId: "lifting", sport: "Strength Training")
        let setRows = LiftStoreBridge.setRows(s, deviceId: "lifting")
        let imported = LiftSessionRow(id: "lifting-99", deviceId: "lifting", startTs: 99, endTs: nil,
                                      sport: "Strength Training", programId: nil, programName: "Upper A (Mo) · Tag 1",
                                      note: nil)
        let importedSet = LiftSetRow(id: "lifting-99#0", deviceId: "lifting", sessionId: "lifting-99", ord: 0,
                                     exercise: "Hyperextensions", primaryMuscle: nil, setIndex: 1, weightKg: 10,
                                     reps: 11, rpe: nil, isWarmup: false, startTs: nil, endTs: nil, restSec: nil,
                                     note: LiftStoreBridge.bodyweightAddedNote)
        let history = LiftStoreBridge.history(
            sessions: [sessionRow, imported],
            sets: setRows.map { LiftSetWithSession(sessionStartTs: sessionRow.startTs, set: $0) }
                + [LiftSetWithSession(sessionStartTs: 99, set: importedSet)])
        XCTAssertEqual(history.map(\.id), ["lifting-99", s.id])
        XCTAssertNil(history[0].templateId, "an imported session has no Telos template id")
        XCTAssertTrue(history[0].sets[0].addedToBodyweight)
        XCTAssertNil(history[0].sets[0].e1rmKg)
        XCTAssertEqual(history[1].templateId, "la")
        XCTAssertTrue(history[1].ran(templateId: "la", templateName: nil))
    }

    func testDedupeMatchesTheSameVisitOnly() {
        let logged = LiftDedupe.Candidate(start: date(2026, 9, 22, 18, 0), title: "Lower A (Di)",
                                          exercises: ["Beinpresse", "Beinstrecken", "Adduktoren"])
        let sameVisit = LiftDedupe.Candidate(start: date(2026, 9, 22, 18, 20),
                                             title: "Lower A (Di) · Tag 1 · Woche 31 · Lower",
                                             exercises: ["Beinpresse"])
        let renamed = LiftDedupe.Candidate(start: date(2026, 9, 22, 17, 35), title: "Legs",
                                           exercises: ["beinpresse ", "Beinstrecken"])
        let tooFar = LiftDedupe.Candidate(start: date(2026, 9, 22, 18, 31), title: "Lower A (Di) · Tag 1",
                                          exercises: ["Beinpresse", "Beinstrecken", "Adduktoren"])
        let otherWorkout = LiftDedupe.Candidate(start: date(2026, 9, 22, 18, 10), title: "Upper A (Mo) · Tag 1",
                                                exercises: ["Brustpresse", "Curls"])
        XCTAssertTrue(LiftDedupe.isSameSession(sameVisit, logged), "± 30 min and the same template")
        XCTAssertTrue(LiftDedupe.isSameSession(renamed, logged), "a renamed template still overlaps on exercises")
        XCTAssertFalse(LiftDedupe.isSameSession(tooFar, logged), "31 minutes apart is outside the tolerance")
        XCTAssertFalse(LiftDedupe.isSameSession(otherWorkout, logged), "a different template with no overlap")
        XCTAssertEqual(LiftDedupe.duplicateIndices(imported: [otherWorkout, sameVisit, tooFar], logged: [logged]), [1])
        XCTAssertEqual(LiftDedupe.templateKey("Lower A (Di) · Tag 1 · Woche 5 · Lower"), "lower a (di)")
        XCTAssertNil(LiftDedupe.templateKey("  "))
    }

    // MARK: - Proposal

    func testProposalLayersHoldAndDeloadOnStrengthProgression() {
        let add = LiftProposal.Input(step: .addReps, weightKg: 100, reps: 9, incrementKg: 2.5,
                                     fromWeightKg: 100, fromReps: 8)
        XCTAssertEqual(LiftProposal.make(input: add, holdLoads: false, charge: 70, lowChargeThreshold: 34, stepKg: 2.5),
                       LiftProposal.Result(kind: .progress, weightKg: 100, reps: 9, reasons: [.addReps]))
        let hold = LiftProposal.make(input: add, holdLoads: true, charge: 20, lowChargeThreshold: 34, stepKg: 2.5)
        XCTAssertEqual(hold.kind, .hold)
        XCTAssertEqual(hold.weightKg, 100)
        XCTAssertEqual(hold.reps, 8)
        XCTAssertEqual(hold.reasons, [.easyWeek, .lowCharge(20)])

        let stalled = LiftProposal.Input(step: .addWeight, weightKg: 102.5, reps: 8, incrementKg: 2.5,
                                         fromWeightKg: 100, fromReps: 10, stalledSessions: 3, stalledDays: 21,
                                         stuckAtKg: 100)
        let deload = LiftProposal.make(input: stalled, holdLoads: false, charge: nil, lowChargeThreshold: 34, stepKg: 2.5)
        XCTAssertEqual(deload.kind, .deload)
        XCTAssertEqual(deload.weightKg, 90, "90 % of 100 on the 2.5 kg grid")
        let stack = LiftProposal.make(input: stalled, holdLoads: false, charge: nil, lowChargeThreshold: 34, stepKg: 8)
        XCTAssertEqual(stack.weightKg, 92, "the point of the machine's own 8 kg grid nearest 90 %, anchored at 100")

        let few = LiftProposal.Input(step: nil, weightKg: nil, reps: nil, incrementKg: nil, fromWeightKg: nil,
                                     fromReps: nil, tooFewHave: 1, tooFewNeed: 3)
        XCTAssertEqual(LiftProposal.make(input: few, holdLoads: false, charge: nil, lowChargeThreshold: 34, stepKg: nil).reasons,
                       [.tooFewSessions(have: 1, need: 3)])
        XCTAssertEqual(LiftProposal.make(input: nil, holdLoads: false, charge: nil, lowChargeThreshold: 34, stepKg: nil).kind,
                       .none)
        let exhausted = LiftProposal.Input(step: nil, weightKg: nil, reps: nil, incrementKg: nil, fromWeightKg: 40,
                                           fromReps: 12)
        XCTAssertEqual(LiftProposal.make(input: exhausted, holdLoads: false, charge: 80, lowChargeThreshold: 34,
                                         stepKg: nil).reasons, [.noIncrement])
    }
}
