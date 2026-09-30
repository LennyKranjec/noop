import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The week plan's wearer-specific lines (`WeekPlanProgram.swift`). Pinned here:
///   * the strength target is the Lift plan's templates for a week (the owner's 2 Upper + 2 Lower → 4), in
///     week order, and an untaggable / ambiguous plan falls back to the default target;
///   * an easy week asks for one fewer (never below one), holds loads and keeps the templates;
///   * done sessions are matched to templates by Telos id, by imported title (with or without the weekday
///     tag), and everything else still counts as "other" — never dropped;
///   * zone 4–5 minutes: only worn / measured days count, an abstained day is unknown (never 0), a week with
///     nothing measured is nil + its reason; 10 min target in build/hold, none in an easy week;
///   * a frozen plan adopts the Lift plan and the zone 4–5 target once, idempotently;
///   * the review scores zone 4–5 and the template-matched strength count with the same rules as the card;
///   * `SessionIntensity` counts zone 4–5 minutes from the display zones' zone-4 edge.
final class WeekPlanProgramTests: XCTestCase {

    /// A Monday.
    private let today = "2026-09-28"
    private func add(_ d: String, _ n: Int) -> String { WeeklyDigestEngine.addDays(d, n) }

    // MARK: Fixtures

    /// The owner's plan as the importer builds it: program "Lower" first, then "Upper".
    private var ownerTemplates: [LiftDayTemplate] {
        [
            LiftDayTemplate(id: LiftProgram.templateId(program: "Lower", day: "Lower A (Di)"), name: "Lower A (Di)", exercises: []),
            LiftDayTemplate(id: LiftProgram.templateId(program: "Lower", day: "Lower B (Fr)"), name: "Lower B (Fr)", exercises: []),
            LiftDayTemplate(id: LiftProgram.templateId(program: "Upper", day: "Upper A (Mo)"), name: "Upper A (Mo)", exercises: []),
            LiftDayTemplate(id: LiftProgram.templateId(program: "Upper", day: "Upper B (Do)"), name: "Upper B (Do)", exercises: []),
        ]
    }

    private var ownerProgram: [PlannedLiftDay] { WeekPlanEngine.plannedDays(from: ownerTemplates)! }

    private func history(weekly: Double = 100, weeks: Int = 4, strengthPerWeek: Int = 0) -> [DayActivity] {
        var out: [DayActivity] = []
        for w in 1...weeks {
            let start = add(today, -7 * w)
            for i in 0..<7 {
                out.append(DayActivity(day: add(start, i), mvpaEq: weekly / 7, moderateMin: weekly / 7,
                                       vigorousMin: 0, hardSession: false, strengthSession: i < strengthPerWeek,
                                       trimp: 100, wearCoverage: 0.9, zone45Min: 0))
            }
        }
        return out
    }

    private func inputs(days: [DayActivity], debt: Double? = 0, program: [PlannedLiftDay]? = nil,
                        lifts: [LiftSessionMark] = []) -> WeekPlanInputs {
        WeekPlanInputs(today: today, days: days, hrvTier: .normal, hrvTierLast7: Array(repeating: .normal, count: 7),
                       hrvValidNights: 30, charge: 70, illnessRaisedDays: [], illnessRaisedNow: false,
                       sleepDebtMin: debt, age: 35, liftProgram: program, liftSessions: lifts)
    }

    private func plan(type: WeekType = .build, zone45: Double? = 10, strength: StrengthTarget? = nil,
                      start: String = "2026-09-21") -> WeekPlan {
        WeekPlan(version: 2, weekStart: start, decidedOn: start, type: type, reasons: [], baselineMvpa: 120,
                 validBaselineWeeks: 4, chronicLoad: nil, lastWeekLoad: nil, monotony: nil, aerobicTarget: nil,
                 hardSessionTarget: 0, hardSessionOptional: false,
                 strength: strength ?? StrengthTarget(minSessions: 2, maxSessions: 2, holdLoads: false, setsFactor: 1),
                 stepsTarget: nil, stepsMedian: nil, stepsPlateau: 8000, ageKnown: true,
                 stepGate: StepGate(passed: false, reliableDays: 0, windowDays: 28), easyOffer: nil,
                 zone45Target: zone45)
    }

    // MARK: Program → planned days

    func testOwnersPlanIsFourSessionsInWeekOrder() {
        let p = ownerProgram
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p.map(\.displayName), ["Upper A", "Lower A", "Upper B", "Lower B"])
        XCTAssertEqual(p.map(\.weekday), [2, 3, 5, 6])
        XCTAssertEqual(p.first?.name, "Upper A (Mo)", "the stored name stays verbatim")
    }

    func testUntaggedDuplicateAndSparePlans() {
        let untagged = ["Push", "Pull", "Legs"].map { LiftDayTemplate(id: $0, name: $0, exercises: []) }
        XCTAssertEqual(WeekPlanEngine.plannedDays(from: untagged)?.count, 3)
        let many = (1...8).map { LiftDayTemplate(id: "t\($0)", name: "Day \($0)", exercises: []) }
        XCTAssertNil(WeekPlanEngine.plannedDays(from: many), "more than a week of untagged templates: not knowable")
        let clash = [LiftDayTemplate(id: "a", name: "A (Mo)", exercises: []),
                     LiftDayTemplate(id: "b", name: "B (Mo)", exercises: [])]
        XCTAssertNil(WeekPlanEngine.plannedDays(from: clash), "an A/B alternation on one weekday is ambiguous")
        let spare = ownerTemplates + [LiftDayTemplate(id: "x", name: "Mobility", exercises: [])]
        XCTAssertEqual(WeekPlanEngine.plannedDays(from: spare)?.count, 4, "an untagged spare beside a tagged week")
        XCTAssertNil(WeekPlanEngine.plannedDays(from: []))
    }

    func testWeekdayTagIsStrippedOnlyWhenItIsAWeekday() {
        XCTAssertEqual(WeekPlanEngine.strippingWeekdayTag("Upper A (Mo)"), "Upper A")
        XCTAssertEqual(WeekPlanEngine.strippingWeekdayTag("Push (heavy)"), "Push (heavy)")
        XCTAssertEqual(WeekPlanEngine.strippingWeekdayTag("Legs"), "Legs")
    }

    // MARK: Strength target

    func testBuildWeekTargetIsThePlan() {
        let plan = WeekPlanEngine.decide(inputs(days: history(), program: ownerProgram))
        XCTAssertEqual(plan.strength.minSessions, 4)
        XCTAssertEqual(plan.strength.maxSessions, 4)
        XCTAssertFalse(plan.strength.holdLoads)
        XCTAssertEqual(plan.strength.templates, ownerProgram)
    }

    func testEasyWeekAsksForOneFewerAndHoldsLoads() {
        let plan = WeekPlanEngine.decide(inputs(days: history(), debt: 200, program: ownerProgram))
        XCTAssertEqual(plan.type, .easy)
        XCTAssertEqual(plan.strength.minSessions, 3, "Easy week — 3 of 4")
        XCTAssertEqual(plan.strength.maxSessions, 4)
        XCTAssertTrue(plan.strength.holdLoads)
        XCTAssertEqual(plan.strength.setsFactor, WeekPlanEngine.easySetsFactor, accuracy: 1e-12)
        XCTAssertEqual(WeekPlanEngine.easyProgramSessions(2), 1)
        XCTAssertEqual(WeekPlanEngine.easyProgramSessions(1), 1, "never below one")
    }

    func testWithoutAPlanTheDefaultRuleIsUnchanged() {
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history())).strength,
                       StrengthTarget(minSessions: 1, maxSessions: 1, holdLoads: false, setsFactor: 1))
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(strengthPerWeek: 2), program: [])).strength.minSessions, 2)
    }

    func testAcceptingAnEasyWeekKeepsTheTemplates() {
        let days = history(weekly: 105, strengthPerWeek: 1)
        let frozen = [1, 2, 3].map { w -> WeekPlan in
            plan(zone45: nil, strength: StrengthTarget(minSessions: 1, maxSessions: 1, holdLoads: false, setsFactor: 1),
                 start: add(today, -7 * w))
        }.map { p -> WeekPlan in var q = p; q.aerobicTarget = 100; return q }
        let offered = WeekPlanEngine.decide(inputs(days: days, program: ownerProgram), frozen: frozen)
        XCTAssertEqual(offered.easyOffer, .offered)
        let accepted = WeekPlanEngine.respond(to: offered, accept: true, days: days)
        XCTAssertEqual(accepted.strength.templates, ownerProgram)
        XCTAssertEqual(accepted.strength.minSessions, 3)
        XCTAssertNil(accepted.zone45Target, "an easy week asks for no high-intensity minutes")
    }

    // MARK: Matching

    private var weekKeys: [String] { (0..<7).map { add(today, $0) } }

    private var matchingLifts: [LiftSessionMark] {
        [
            LiftSessionMark(day: add(today, 0), templateId: LiftProgram.templateId(program: "Upper", day: "Upper A (Mo)"),
                            title: "Upper A (Mo)"),
            LiftSessionMark(day: add(today, 1), templateId: nil, title: "Lower A (Di) · Tag 1 · Woche 5 · Lower"),
            LiftSessionMark(day: add(today, 3), templateId: nil, title: "Upper B"),
            LiftSessionMark(day: add(today, 4), templateId: nil, title: "Push day"),
        ]
    }

    private var matchingDays: [DayActivity] {
        [0, 1, 3, 4, 5].map { DayActivity(day: add(today, $0), strengthSession: true, wearCoverage: 0.9) }
    }

    func testSessionsAreMatchedToTheirTemplates() {
        let s = WeekPlanEngine.strengthStatus(templates: ownerProgram, days: matchingDays, lifts: matchingLifts,
                                              dayKeys: weekKeys)
        XCTAssertEqual(s.templates?.map(\.doneOn), [add(today, 0), add(today, 1), add(today, 3), nil])
        XCTAssertEqual(s.otherSessions, 2, "the unmatched 'Push day' (Fri) and the strength day with no lift log (Sat)")
        XCTAssertEqual(s.done, 5, "matched sessions plus the others — nothing is dropped")
        XCTAssertEqual(WeekPlanEngine.templateLine(s), "Upper A ✓ · Lower A ✓ · Upper B ✓ · Lower B · +2 other")
    }

    func testARepeatCountsAsOther() {
        let id = LiftProgram.templateId(program: "Upper", day: "Upper A (Mo)")
        let lifts = [LiftSessionMark(day: add(today, 0), templateId: id, title: "Upper A (Mo)"),
                     LiftSessionMark(day: add(today, 2), templateId: id, title: "Upper A (Mo)")]
        let days = [0, 2].map { DayActivity(day: add(today, $0), strengthSession: true) }
        let s = WeekPlanEngine.strengthStatus(templates: ownerProgram, days: days, lifts: lifts, dayKeys: weekKeys)
        XCTAssertEqual(s.templates?.filter(\.done).count, 1)
        XCTAssertEqual(s.otherSessions, 1)
        XCTAssertEqual(s.done, 2)
    }

    func testWithoutAPlanTheCountIsStrengthDays() {
        let s = WeekPlanEngine.strengthStatus(templates: nil, days: matchingDays, lifts: matchingLifts, dayKeys: weekKeys)
        XCTAssertNil(s.templates)
        XCTAssertEqual(s.done, 5)
        XCTAssertNil(WeekPlanEngine.templateLine(s))
    }

    func testLiftsOutsideTheWindowDoNotTick() {
        let s = WeekPlanEngine.strengthStatus(templates: ownerProgram, days: [], lifts: matchingLifts,
                                              dayKeys: [add(today, 0)])
        XCTAssertEqual(s.templates?.filter(\.done).count, 1)
        XCTAssertEqual(s.done, 1)
    }

    func testProgressUsesTheMatchingAndZone45() {
        var days = history()
        days += (0..<5).map { i in
            DayActivity(day: add(today, i), mvpaEq: 10, strengthSession: [0, 1, 3, 4].contains(i),
                        wearCoverage: 0.9, zone45Min: i == 2 ? 4 : 0)
        }
        let plan = WeekPlanEngine.decide(inputs(days: history(), program: ownerProgram))
        let p = WeekPlanEngine.progress(plan: plan, days: days, today: add(today, 4), lifts: matchingLifts)
        XCTAssertEqual(p.strengthDone, 4, "three templates + the unmatched Friday session")
        XCTAssertEqual(p.strength.templates?.filter(\.done).count, 3)
        XCTAssertEqual(p.zone45.minutes ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(p.zone45.measuredDays, 5)
    }

    // MARK: Zone 4–5

    func testZone45CountsOnlyMeasuredTime() {
        let days = [
            DayActivity(day: add(today, 0), wearCoverage: 0.9, zone45Min: 3),
            DayActivity(day: add(today, 1), wearCoverage: 0.9, zone45Min: 0),                      // worn, no session
            DayActivity(day: add(today, 2), wearCoverage: 0.9, unmeasuredSessions: 1, zone45Min: nil), // abstained
            DayActivity(day: add(today, 3), wearCoverage: 0.1, approximate: true, zone45Min: 5),   // imported zones
            DayActivity(day: add(today, 4), wearCoverage: 0.1, zone45Min: 0),                      // not worn
        ]
        let z = WeekPlanEngine.zone45Week(days: days, dayKeys: weekKeys)
        XCTAssertEqual(z.minutes ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(z.measuredDays, 3)
        XCTAssertEqual(z.unknownDays, 1, "an abstained day is unknown, not 0")
        XCTAssertTrue(z.approximate)
        XCTAssertNil(z.absence)
    }

    func testZone45AbsentIsNilWithAReason() {
        let abstained = [DayActivity(day: add(today, 0), wearCoverage: 0.9, unmeasuredSessions: 2, zone45Min: nil)]
        let a = WeekPlanEngine.zone45Week(days: abstained, dayKeys: weekKeys)
        XCTAssertNil(a.minutes, "never 0 invented")
        XCTAssertEqual(a.absence, .zoneInputsMissing)

        let unworn = [DayActivity(day: add(today, 0), wearCoverage: 0.2, zone45Min: 0)]
        let u = WeekPlanEngine.zone45Week(days: unworn, dayKeys: weekKeys)
        XCTAssertNil(u.minutes)
        XCTAssertEqual(u.absence, .notWorn)
        XCTAssertEqual(WeekPlanEngine.zone45Week(days: [], dayKeys: weekKeys).absence, .notWorn)
    }

    func testZone45TargetByWeekType() {
        XCTAssertEqual(WeekPlanEngine.zone45WeeklyTargetMin, 10)
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history())).zone45Target, 10)
        XCTAssertNil(WeekPlanEngine.decide(inputs(days: history(), debt: 200)).zone45Target)
        XCTAssertEqual(WeekPlanEngine.zone45Target(type: .hold), 10)
    }

    // MARK: Adopting into a frozen week

    func testAFrozenPlanAdoptsOnceAndIdempotently() {
        let old = plan(zone45: nil)
        let adopted = WeekPlanEngine.adopt(old, program: ownerProgram)
        XCTAssertEqual(adopted.zone45Target, 10)
        XCTAssertEqual(adopted.strength.minSessions, 4)
        XCTAssertEqual(adopted.strength.templates, ownerProgram)
        XCTAssertEqual(WeekPlanEngine.adopt(adopted, program: ownerProgram), adopted, "idempotent")
        let edited = Array(ownerProgram.prefix(3))
        XCTAssertEqual(WeekPlanEngine.adopt(adopted, program: edited), adopted,
                       "a later edit of the Lift plan never moves this week's target")
        let noProgram = WeekPlanEngine.adopt(old, program: nil)
        XCTAssertEqual(noProgram.strength, old.strength)
        XCTAssertEqual(noProgram.zone45Target, 10)
        XCTAssertNil(WeekPlanEngine.adopt(plan(type: .easy, zone45: nil), program: nil).zone45Target)
    }

    func testAPlanFrozenBeforeTheNewFieldsStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan(zone45: 10))) as! [String: Any]
        json.removeValue(forKey: "zone45Target")
        var strength = json["strength"] as! [String: Any]
        strength.removeValue(forKey: "templates")
        json["strength"] = strength
        let decoded = try JSONDecoder().decode(WeekPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.zone45Target)
        XCTAssertNil(decoded.strength.templates)
    }

    // MARK: Review

    private func reviewWeek(zone45: [Double?], strengthOn: Set<Int> = [], unmeasured: Int = 0) -> [DayActivity] {
        (0..<7).map { i in
            DayActivity(day: add("2026-09-21", i), mvpaEq: 20, strengthSession: strengthOn.contains(i),
                        wearCoverage: 0.9, unmeasuredSessions: i == 0 ? unmeasured : 0, zone45Min: zone45[i])
        }
    }

    private func status(_ c: [ComponentResult], _ k: WeekComponent) -> ComponentResult? {
        c.first { $0.component == k }
    }

    func testReviewScoresZone45() {
        let met = WeekReview.planVsDone(plan: plan(), days: reviewWeek(zone45: [4, 0, 4, 0, 4, 0, 0]),
                                        guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(met, .zone45)?.status, .met)
        XCTAssertEqual(WeekReview.componentLine(status(met, .zone45)!), "Zone 4–5 12 / 10 min (met)")

        let missed = WeekReview.planVsDone(plan: plan(), days: reviewWeek(zone45: [2, 0, 0, 0, 0, 0, 0]),
                                           guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(missed, .zone45)?.status, .missed)

        let blind = WeekReview.planVsDone(plan: plan(), days: reviewWeek(zone45: [2, 0, 0, 0, 0, 0, 0], unmeasured: 1),
                                          guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(blind, .zone45)?.status, .notMeasured, "a session without heart rate cannot be a miss")

        let absent = WeekReview.planVsDone(plan: plan(), days: reviewWeek(zone45: Array(repeating: nil, count: 7),
                                                                          unmeasured: 1),
                                           guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(absent, .zone45)?.status, .notMeasured)
        XCTAssertNil(status(absent, .zone45)?.done, "unknown, never 0")

        let old = WeekReview.planVsDone(plan: plan(zone45: nil), days: reviewWeek(zone45: [2, 0, 0, 0, 0, 0, 0]),
                                        guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(old, .zone45)?.status, .notAsked)
        let easy = WeekReview.planVsDone(plan: plan(type: .easy, zone45: nil),
                                         days: reviewWeek(zone45: [0, 0, 0, 0, 0, 0, 0]),
                                         guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(easy, .zone45)?.note, "No high-intensity target in an easy week.")
    }

    func testReviewStrengthUsesTheSameMatching() {
        let target = WeekPlanEngine.programStrength(type: .build, program: ownerProgram)
        let start = "2026-09-21"
        let lifts = [
            LiftSessionMark(day: add(start, 0), templateId: ownerProgram[0].templateId, title: nil),
            LiftSessionMark(day: add(start, 1), templateId: ownerProgram[1].templateId, title: nil),
            LiftSessionMark(day: add(start, 3), templateId: ownerProgram[2].templateId, title: nil),
            LiftSessionMark(day: add(start, 4), templateId: ownerProgram[3].templateId, title: nil),
        ]
        let days = reviewWeek(zone45: Array(repeating: 3, count: 7), strengthOn: [0, 1, 3, 4])
        let r = WeekReview.planVsDone(plan: plan(strength: target), days: days, guidanceByDay: [:],
                                      liftDataFresh: true, liftSessions: lifts)
        XCTAssertEqual(status(r, .strength)?.done, 4)
        XCTAssertEqual(status(r, .strength)?.status, .met)

        let half = WeekReview.planVsDone(plan: plan(strength: target),
                                         days: reviewWeek(zone45: Array(repeating: 3, count: 7), strengthOn: [0, 1]),
                                         guidanceByDay: [:], liftDataFresh: true, liftSessions: Array(lifts.prefix(2)))
        XCTAssertEqual(status(half, .strength)?.status, .partly, "2 of the plan's 4")
    }

    // MARK: SessionIntensity zone 4–5

    // rhr 60, max 160 ⇒ the Karvonen zone-4 edge is 60 + 0.8 × 100 = 140 bpm, i.e. f = 0.80.
    private func samples(bpm: Int, seconds: Int = 600) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testZone45FromStrapHrUsesTheZoneFourEdge() {
        let karvonen = HRZones.zones(maxHR: 160, restingHR: 60).zones[3].lower
        XCTAssertEqual(karvonen, 140, accuracy: 1e-9)

        let byDefault = SessionIntensity.minutes(hr: samples(bpm: 145), start: 0, end: 600, restingHR: 60, hrMax: 160)
        XCTAssertEqual(byDefault.zone45Min, 10, accuracy: 1e-9)
        XCTAssertEqual(byDefault.zone45Min, byDefault.hardMin, accuracy: 1e-9, "same line on the default zones")

        let edge = SessionIntensity.minutes(hr: samples(bpm: 145), start: 0, end: 600, restingHR: 60, hrMax: 160,
                                            zone4LowerBpm: karvonen)
        XCTAssertEqual(edge.zone45Min, 10, accuracy: 1e-9)

        let customHigher = SessionIntensity.minutes(hr: samples(bpm: 145), start: 0, end: 600, restingHR: 60,
                                                    hrMax: 160, zone4LowerBpm: 150)
        XCTAssertEqual(customHigher.zone45Min, 0, accuracy: 1e-9)
        let customLower = SessionIntensity.minutes(hr: samples(bpm: 135), start: 0, end: 600, restingHR: 60,
                                                   hrMax: 160, zone4LowerBpm: 130)
        XCTAssertEqual(customLower.zone45Min, 10, accuracy: 1e-9)
        XCTAssertEqual(customLower.hardMin, 0, accuracy: 1e-9)

        let below = SessionIntensity.minutes(hr: samples(bpm: 139), start: 0, end: 600, restingHR: 60, hrMax: 160)
        XCTAssertEqual(below.zone45Min, 0, accuracy: 1e-9)
    }

    func testZone45FromImportedZonesAndAbstention() {
        let w = SessionIntensity.Window(start: 0, end: 3600, sport: "Running", zonePercents: [10, 20, 30, 20, 10])
        let day = SessionIntensity.day(sessions: [w], hr: [], restingHR: 60, hrMax: 160)
        XCTAssertEqual(day.zone45Min, 18, accuracy: 1e-9, "60 min × (20 % + 10 %)")
        XCTAssertTrue(day.approximate)

        let unmeasured = SessionIntensity.day(sessions: [SessionIntensity.Window(start: 0, end: 600, sport: "Run")],
                                              hr: [], restingHR: 60, hrMax: 160)
        XCTAssertEqual(unmeasured.zone45Min, 0)
        XCTAssertEqual(unmeasured.unmeasuredCount, 1, "no HR: a session with no minutes, named as such")

        let noZones = SessionIntensity.day(sessions: [w], hr: [], restingHR: nil, hrMax: 160)
        XCTAssertEqual(noZones.abstained, .zoneInputsMissing, "the reader must treat its zone 4–5 minutes as unknown")
    }
}
