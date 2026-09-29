import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-B.1 / B.7 / A.4 — the closed catalogue, eligibility, proposals, and the trial-quest
/// penalty exemption.
final class HabitTrialCatalogTests: XCTestCase {

    func testClosedCatalogue() {
        XCTAssertEqual(HabitTrialCatalog.entries.map { $0.id },
                       ["caffeineCutoff14", "screensOff60", "bedroom18", "walkAfterDinner10", "morningDaylight",
                        "dinner3h", "breathing10", "alcoholFree"])
        XCTAssertEqual(Set(HabitTrialCatalog.entries.map { $0.id }).count, HabitTrialCatalog.entries.count)
        for e in HabitTrialCatalog.entries {
            XCTAssertTrue(e.primaryOutcome.canBePrimary, "\(e.id): primary must be a primary-capable outcome")
            XCTAssertLessThanOrEqual(e.secondaryOutcomes.count, 2)
            XCTAssertTrue((1...3).contains(e.effortRank))
            XCTAssertFalse(e.allowedLengths.isEmpty)
        }
    }

    func testNothingUnsafeIsInTheCatalogue() {
        let banned = ["melatonin", "magnesium", "creatine", "supplement", "medication", "fast", "calorie",
                      "restrict", "ice", "sauna", "cold", "breath-hold", "hyperventil", "more caffeine", "drink more"]
        for e in HabitTrialCatalog.entries {
            let text = (e.title + " " + e.onInstruction + " " + e.offInstruction).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(e.id) mentions '\(word)'")
            }
        }
        // alcoholFree's OFF arm never tells anyone to drink.
        XCTAssertTrue(HabitTrialCatalog.entry("alcoholFree")!.offInstruction.contains("no instruction to drink"))
        let categories = HabitTrialCatalog.exclusions.map { $0.category.lowercased() }.joined(separator: " | ")
        for word in ["supplement", "medication", "fasting", "sleep restriction", "cold or heat", "breath-holds",
                     "harder training", "free text", "more caffeine"] {
            XCTAssertTrue(categories.contains(word), "exclusion list lacks \(word)")
        }
    }

    func testDesignFollowsCarryOver() {
        XCTAssertEqual(HabitTrialCatalog.entry("morningDaylight")!.design, .phaseBlocks)
        XCTAssertEqual(HabitTrialCatalog.entry("alcoholFree")!.carryOver, .short)
        XCTAssertEqual(HabitTrialCatalog.entry("screensOff60")!.design, .weekdayBalanced)
        XCTAssertTrue(HabitTrialCatalog.entry("walkAfterDinner10")!.affectsEffort)
    }

    func testConflictingMetrics() {
        XCTAssertEqual(HabitTrialCatalog.entry("screensOff60")!.conflictingMetrics, [.bedtimeBy, .bedtimeEarlier])
        XCTAssertEqual(HabitTrialCatalog.entry("breathing10")!.conflictingMetrics, [.meditationMinutes])
    }

    func testContrastRule() {
        let caffeine = HabitTrialCatalog.entry("caffeineCutoff14")!
        XCTAssertFalse(HabitTrialCatalog.hasContrast(caffeine, usualPerWeek: 2), "already mostly avoids it")
        XCTAssertTrue(HabitTrialCatalog.hasContrast(caffeine, usualPerWeek: 3))
        let walk = HabitTrialCatalog.entry("walkAfterDinner10")!
        XCTAssertTrue(HabitTrialCatalog.hasContrast(walk, usualPerWeek: 4))
        XCTAssertFalse(HabitTrialCatalog.hasContrast(walk, usualPerWeek: 5), "already walks most evenings")
        let alcohol = HabitTrialCatalog.entry("alcoholFree")!
        XCTAssertTrue(HabitTrialCatalog.hasContrast(alcohol, usualPerWeek: 2), "relaxed to 2 a week")
        XCTAssertFalse(HabitTrialCatalog.hasContrast(alcohol, usualPerWeek: 1))
    }

    func testEligibility() {
        let today = "2026-09-29"
        let bedroom = HabitTrialCatalog.entry("bedroom18")!
        XCTAssertEqual(HabitTrialCatalog.ineligibility(bedroom, context: .init(today: today)), .needsClimateSensor)
        XCTAssertEqual(HabitTrialCatalog.ineligibility(bedroom, context: .init(climateSensorPaired: true, today: today)),
                       .needsCoolRoomConfirmation)
        XCTAssertNil(HabitTrialCatalog.ineligibility(bedroom, context: .init(climateSensorPaired: true,
                                                                             coolRoomConfirmed: true, today: today)))
        let alcohol = HabitTrialCatalog.entry("alcoholFree")!
        XCTAssertEqual(HabitTrialCatalog.ineligibility(alcohol, context: .init(today: today)), .drinkingUnknown)
        XCTAssertEqual(HabitTrialCatalog.ineligibility(alcohol, context: .init(drinkingEveningsLast28: 7, today: today)),
                       .tooFewDrinkingEvenings(have: 7, need: 8))
        XCTAssertNil(HabitTrialCatalog.ineligibility(alcohol, context: .init(drinkingEveningsLast28: 8, today: today)))
        let screens = HabitTrialCatalog.entry("screensOff60")!
        XCTAssertEqual(HabitTrialCatalog.ineligibility(screens, context: .init(lastTrialledDay: ["screensOff60": "2026-08-01"],
                                                                               today: today)),
                       .trialledRecently(lastDay: "2026-08-01"))
        XCTAssertNil(HabitTrialCatalog.ineligibility(screens, context: .init(lastTrialledDay: ["screensOff60": "2026-06-01"],
                                                                             today: today)))
    }

    func testProposalsPreferOwnDataThenEffortThenEvidence() {
        let ctx = HabitTrialEligibilityContext(today: "2026-09-29")
        // No data: the strong-evidence untested entries, lowest effort first. alcoholFree is ineligible here
        // (drinking unknown), so caffeine (effort 1) then screens (effort 2).
        let untested = HabitTrialCatalog.proposals(report: nil, context: ctx)
        XCTAssertEqual(untested.map { $0.entryId }, ["caffeineCutoff14", "screensOff60"])
        XCTAssertTrue(untested.allSatisfy { !$0.fromOwnData })

        // A possible link on late meals (RHR up when present) puts dinner3h first despite its effort rank.
        let row = HabitAssociationRow(
            habit: HabitCatalog.lateMeal, habitLabel: "Eating close to bedtime", outcome: .nightRhr,
            label: .possibleLink, yesCount: 20, noCount: 40, estimate: 2.5, lower: 1.2, upper: 3.8, mcid: 1,
            pValue: 0.001, bhSignificant: true, absence: nil, cooccursWith: [], cooccurLabels: [], secondaries: [])
        let report = HabitAssociationReport(asOf: "2026-09-29", windowStart: "2026-07-02", windowEnd: "2026-09-29",
                                            rows: [row], alsoLogged: [], sourceCounts: [:])
        let withData = HabitTrialCatalog.proposals(report: report, context: ctx)
        XCTAssertEqual(withData.first?.entryId, "dinner3h")
        XCTAssertTrue(withData.first!.fromOwnData)
        XCTAssertEqual(withData.count, 2)

        // The same link pointing the HELPFUL way does not support a trial that removes the habit.
        let benign = HabitAssociationRow(
            habit: HabitCatalog.lateMeal, habitLabel: "Eating close to bedtime", outcome: .nightRhr,
            label: .possibleLink, yesCount: 20, noCount: 40, estimate: -2.5, lower: -3.8, upper: -1.2, mcid: 1,
            pValue: 0.001, bhSignificant: true, absence: nil, cooccursWith: [], cooccurLabels: [], secondaries: [])
        let benignReport = HabitAssociationReport(asOf: "2026-09-29", windowStart: "2026-07-02",
                                                  windowEnd: "2026-09-29", rows: [benign], alsoLogged: [],
                                                  sourceCounts: [:])
        XCTAssertFalse(HabitTrialCatalog.proposals(report: benignReport, context: ctx).contains { $0.entryId == "dinner3h" })
    }

    // MARK: Trial quests are never penalised (HEALTH_V2 §S0 rule 3, §B.7; DESIGN_V2 coordinator decision 2)

    func testTrialQuestIdsUseThePenaltyExemptionPrefix() {
        let id = HabitTrialQuestId.make(trialId: "screensOff60.2026-09-30", day: "2026-10-04")
        XCTAssertEqual(id, "trial-screensOff60.2026-09-30-2026-10-04")
        XCTAssertTrue(id.hasPrefix(QuestPenaltyRules.trialIdPrefix))
        XCTAssertTrue(HabitTrialQuestId.isTrialQuest(id))
        XCTAssertEqual(HabitTrialQuestId.day(of: id), "2026-10-04")
        XCTAssertFalse(HabitTrialQuestId.isTrialQuest("plan-2026-10-04-STEPS"))
    }

    func testTrialQuestIsNeverPenalisableInAnyKind() {
        let id = HabitTrialQuestId.make(trialId: "alcoholFree.2026-09-30", day: "2026-10-01")
        for kind in QuestKind.allCases {
            XCTAssertFalse(QuestPenaltyRules.isPenalisable(kind: kind, questId: id), "kind \(kind)")
        }
    }

    func testTrialQuestIsNeverJudgedByTheLedger() {
        let id = HabitTrialQuestId.make(trialId: "screensOff60.2026-09-30", day: "2026-10-01")
        var ledger = QuestLedger()
        let subject = QuestJudgementSubject(
            questId: id, kind: .custom, dayKey: "2026-10-01", title: "Trial day", target: "Screens off by 21:45",
            goal: nil, xp: HabitTrialQuestId.loggingXp, gear: nil, judgeAfterMs: 0)
        // Even a trial quest that somehow carried a goal is exempt.
        let withGoal = QuestJudgementSubject(
            questId: id, kind: .side, dayKey: "2026-10-01", title: "Trial day", target: "10,000 steps",
            goal: QuestGoal(metric: .steps, threshold: 10_000), xp: 50, gear: .relentless, judgeAfterMs: 0)
        XCTAssertFalse(ledger.enqueue(withGoal))
        XCTAssertFalse(ledger.enqueue(subject), "a trial quest never enters the judgement queue")
        let judged = ledger.judge(questId: id, evidence: nil, nowMs: 10_000_000_000_000,
                                  context: QuestDebtContext(today: "2026-10-03"))
        XCTAssertEqual(judged, .notDue)
        XCTAssertEqual(ledger.balance, 0)
        XCTAssertTrue(ledger.judgements.isEmpty)
        XCTAssertTrue(ledger.pinned(today: "2026-10-02").isEmpty)
    }

    func testLoggingXpIsIdenticalForEveryAnswerAndNeverTouchesTheStreak() {
        // Whatever the answer, the trial quest is credited the same fixed XP, and a custom-kind credit never
        // moves the daily streak.
        var ledger = QuestLedger()
        let did = ledger.credit(questId: HabitTrialQuestId.make(trialId: "t", day: "2026-10-01"), kind: .custom,
                                xp: HabitTrialQuestId.loggingXp)
        let didNot = ledger.credit(questId: HabitTrialQuestId.make(trialId: "t", day: "2026-10-02"), kind: .custom,
                                   xp: HabitTrialQuestId.loggingXp)
        XCTAssertEqual(did, didNot)
        XCTAssertEqual(ledger.streak, 0)
        XCTAssertTrue((QuestCodec.minXp...QuestCodec.maxXp).contains(HabitTrialQuestId.loggingXp))
    }
}
