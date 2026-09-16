import Foundation
import XCTest
@testable import StrandAnalytics

/// Quests close themselves when the data meets their goal. What matters here:
///
///   * AN UNMEASURED GOAL IS NEVER MET. No step count is not eight thousand steps.
///   * BEDTIMES ARE COMPARED ON THE EVENING CLOCK. 00:30 is after 23:00, not twenty-two hours before it.
///   * A GOAL READ OUT OF A SENTENCE PICKS THE SPECIFIC READING. "10 minutes of meditation" is
///     meditation, not a workout; "bed by 22:30" is a bedtime, not a strain of 22.
final class QuestGoalTests: XCTestCase {

    // MARK: - Meeting a goal

    func testAThresholdIsMetAtExactlyItsValue() {
        let goal = QuestGoal(metric: .steps, threshold: 8_000)
        XCTAssertTrue(goal.isMet(by: QuestEvidence(steps: 8_000)))
        XCTAssertTrue(goal.isMet(by: QuestEvidence(steps: 9_214)))
        XCTAssertFalse(goal.isMet(by: QuestEvidence(steps: 7_999)))
    }

    func testAGoalWithNoEvidenceIsNotMet() {
        XCTAssertFalse(QuestGoal(metric: .steps, threshold: 1).isMet(by: QuestEvidence()))
        XCTAssertFalse(QuestGoal(metric: .strain, threshold: 1).isMet(by: QuestEvidence()))
        XCTAssertFalse(QuestGoal(metric: .journal, threshold: 1).isMet(by: QuestEvidence()))
        XCTAssertFalse(QuestGoal(metric: .bedtimeBy, threshold: 1350).isMet(by: QuestEvidence()))
    }

    func testABedtimeAfterMidnightIsLateNotEarly() {
        let by2300 = QuestGoal(metric: .bedtimeBy, threshold: 23 * 60)
        XCTAssertTrue(by2300.isMet(by: QuestEvidence(nextSleepOnsetMinute: 22 * 60 + 50)))
        XCTAssertTrue(by2300.isMet(by: QuestEvidence(nextSleepOnsetMinute: 23 * 60)))
        XCTAssertFalse(by2300.isMet(by: QuestEvidence(nextSleepOnsetMinute: 30)))
    }

    func testEarlierThanLastNightIsMeasuredAcrossMidnight() {
        let goal = QuestGoal(metric: .bedtimeEarlier, threshold: 45)
        // Last night 00:15, tonight 23:25: fifty minutes earlier.
        XCTAssertTrue(goal.isMet(by: QuestEvidence(nextSleepOnsetMinute: 23 * 60 + 25,
                                                   previousSleepOnsetMinute: 15)))
        // Last night 23:00, tonight 22:30: only thirty.
        XCTAssertFalse(goal.isMet(by: QuestEvidence(nextSleepOnsetMinute: 22 * 60 + 30,
                                                    previousSleepOnsetMinute: 23 * 60)))
    }

    // MARK: - Reading a goal line

    func testTheGoalLineIsRead() {
        XCTAssertEqual(QuestGoal.parseLine("GOAL: STEPS 9000"), QuestGoal(metric: .steps, threshold: 9_000))
        XCTAssertEqual(QuestGoal.parseLine("**GOAL:** WATER_ML 2,500"),
                       QuestGoal(metric: .waterMl, threshold: 2_500))
        XCTAssertEqual(QuestGoal.parseLine("GOAL: BEDTIME_BY 22:30"),
                       QuestGoal(metric: .bedtimeBy, threshold: 22 * 60 + 30))
        XCTAssertEqual(QuestGoal.parseLine("GOAL: JOURNAL"), QuestGoal(metric: .journal, threshold: 1))
        XCTAssertNil(QuestGoal.parseLine("GOAL: VIBES 11"))
        XCTAssertNil(QuestGoal.parseLine("Walk the dog."))
    }

    // MARK: - Reading a goal out of a sentence

    func testTheTriggerDirectivesAllParseToWhatTheTriggersState() {
        // The fallback for quests stored before goals existed: the fixed trigger sentences must read
        // back as the same goals the triggers now attach explicitly.
        XCTAssertEqual(QuestGoal.parse("8000 steps before the day is out"),
                       QuestGoal(metric: .steps, threshold: 8_000))
        XCTAssertEqual(QuestGoal.parse("10 minutes of slow breathing or meditation before this evening"),
                       QuestGoal(metric: .meditationMinutes, threshold: 10))
        XCTAssertEqual(QuestGoal.parse("Lights out 45 minutes earlier than last night. No screen in bed"),
                       QuestGoal(metric: .bedtimeEarlier, threshold: 45))
        XCTAssertEqual(QuestGoal.parse("One 30-minute session today. Anything that raises your heart rate"),
                       QuestGoal(metric: .workoutMinutes, threshold: 30))
        XCTAssertEqual(
            QuestGoal.parse("20 minutes of Zone 2 or mobility only — nothing hard, and in bed early"),
            QuestGoal(metric: .workoutMinutes, threshold: 20))
    }

    func testTheSpecificReadingWinsOverTheGeneralOne() {
        XCTAssertEqual(QuestGoal.parse("Bed by 22:30. Yes, that early."),
                       QuestGoal(metric: .bedtimeBy, threshold: 22 * 60 + 30))
        XCTAssertEqual(QuestGoal.parse("Drink 2.5 L of water before 18:00."),
                       QuestGoal(metric: .waterMl, threshold: 2_500))
        XCTAssertEqual(QuestGoal.parse("Hit 9.000 Schritte heute."),
                       QuestGoal(metric: .steps, threshold: 9_000))
        XCTAssertEqual(QuestGoal.parse("Get 8.5k steps in."),
                       QuestGoal(metric: .steps, threshold: 8_500))
        XCTAssertEqual(QuestGoal.parse("Write one honest journal entry."),
                       QuestGoal(metric: .journal, threshold: 1))
        XCTAssertNil(QuestGoal.parse("Call a friend."))
    }

    // MARK: - Storage

    func testAGoalSurvivesTheStoredListAndAStateChange() {
        let q = Quest(kind: .side, title: "t", taunt: "x", target: "8000 steps", rewards: [.heart], xp: 40,
                      dayKey: "2026-09-15", createdAtMs: 1_000,
                      goal: QuestGoal(metric: .steps, threshold: 8_000))
        let back = QuestCodec.decode(QuestCodec.encode([q.with(state: .active)]),
                                     fallbackDay: "2026-09-15", now: 1_000)
        XCTAssertEqual(back.first?.state, .active)
        XCTAssertEqual(back.first?.goal, QuestGoal(metric: .steps, threshold: 8_000))
    }

    func testASleepQuestStaysCheckableUntilTheNextMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let created = Int64(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 13))!
            .timeIntervalSince1970 * 1000)
        let q = Quest(kind: .side, title: "t", taunt: "x", target: "bed by 22:30", rewards: [], xp: 40,
                      dayKey: "2026-09-15", createdAtMs: created, expiresAtMs: created + 3_600_000,
                      goal: QuestGoal(metric: .bedtimeBy, threshold: 22 * 60 + 30))
        let noonNext = Int64(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
            .timeIntervalSince1970 * 1000)
        XCTAssertEqual(q.checkableUntilMs(calendar: calendar), noonNext)
    }
}
