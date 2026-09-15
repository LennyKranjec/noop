import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Parity pin for quests: the countdown, the stored JSON, and — the part that matters most — the line
/// between what the DATA decides and what the MODEL decides.
///
/// The same inputs MUST produce the same results as the Android twin `com.noop.ai.QuestTest`. A
/// language model handed a day of metrics will happily invent both a reason to nag and a number to nag
/// about. The triggers exist so it never gets the chance: it names the quest, it does not raise one.
final class QuestTests: XCTestCase {

    private let now: Int64 = 1_757_900_000_000

    private func quest(xp: Int = 40, expiresIn: Int64 = 3_600_000) -> Quest {
        Quest(
            kind: .side,
            title: "Proof of Life",
            taunt: "The step counter checked twice.",
            target: "8000 steps",
            rewards: [.heart],
            xp: xp,
            dayKey: "2026-09-15",
            createdAtMs: now,
            expiresAtMs: now + expiresIn
        )
    }

    // MARK: - The clock

    func testTheCountdownIsZeroPaddedAndCountsDownTheClock() {
        XCTAssertEqual(Quest.formatRemaining(0), "00:00:00")
        XCTAssertEqual(Quest.formatRemaining(9_000), "00:00:09")
        XCTAssertEqual(Quest.formatRemaining(3_723_000), "01:02:03")
        XCTAssertEqual(Quest.formatRemaining(86_399_000), "23:59:59")
    }

    func testANegativeRemainderReadsAsZeroRatherThanAsNegativeTime() {
        // The window closed while the screen was off. "-00:04:12" is not a thing a countdown may show.
        let past = quest(expiresIn: -60_000)
        XCTAssertEqual(past.remainingMs(now: now), 0)
        XCTAssertTrue(past.isExpired(now: now))
        XCTAssertEqual(Quest.formatRemaining(past.remainingMs(now: now)), "00:00:00")
    }

    func testEveryQuestHasADeadlineEvenWhenNobodySetOne() {
        // A directive with no clock is a suggestion, so the default is a real window and not "never".
        let q = Quest(kind: .daily, title: "t", taunt: "x", target: "y", rewards: [], xp: 10,
                      dayKey: "2026-09-15", createdAtMs: now)
        XCTAssertEqual(q.expiresAtMs, now + Quest.defaultWindowMs)
        XCTAssertFalse(q.isExpired(now: now))
    }

    // MARK: - Storage

    func testStorageIsARoundTripIncludingTheDeadline() {
        let q = quest()
        let back = QuestCodec.decode(QuestCodec.encode([q]), fallbackDay: "2026-09-15", now: now)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, q.id)
        XCTAssertEqual(back[0].target, q.target)
        XCTAssertEqual(back[0].rewards, q.rewards)
        XCTAssertEqual(back[0].xp, q.xp)
        XCTAssertEqual(back[0].expiresAtMs, q.expiresAtMs)
        XCTAssertEqual(back[0].state, q.state)
        XCTAssertEqual(back[0].kind, q.kind)
    }

    func testARecordFromBeforeDeadlinesExistedGetsOneRatherThanExpiringAtOnce() {
        let raw = """
        [{"id":"a","kind":"SIDE","title":"t","taunt":"x","target":"y","xp":20,
          "state":"ACTIVE","day":"2026-09-15","createdAt":\(now)}]
        """
        let back = QuestCodec.decode(raw, fallbackDay: "2026-09-15", now: now)
        XCTAssertEqual(back.count, 1)
        XCTAssertFalse(back[0].isExpired(now: now))
        XCTAssertEqual(back[0].expiresAtMs, now + Quest.defaultWindowMs)
    }

    func testAnXpFigureFromAModelIsClampedOnTheWayIn() {
        let raw = #"[{"id":"a","kind":"SIDE","title":"t","taunt":"x","target":"y","xp":99999}]"#
        XCTAssertEqual(QuestCodec.decode(raw, fallbackDay: "2026-09-15", now: now)[0].xp, QuestCodec.maxXp)
    }

    func testARecordWithNoTargetIsDroppedRatherThanShownEmpty() {
        let raw = #"[{"id":"a","kind":"SIDE","title":"t","taunt":"x","xp":20}]"#
        XCTAssertTrue(QuestCodec.decode(raw, fallbackDay: "2026-09-15", now: now).isEmpty)
    }

    func testUnknownEnumCasesDegradeRatherThanFailingTheWholeRead() {
        // A record written by a future build must not take the rest of the list down with it.
        let raw = #"[{"id":"a","kind":"WEEKLY","title":"t","taunt":"x","target":"y","state":"PAUSED","rewards":["SPLEEN","HEART"]}]"#
        let back = QuestCodec.decode(raw, fallbackDay: "2026-09-15", now: now)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].kind, .side)
        XCTAssertEqual(back[0].state, .offered)
        XCTAssertEqual(back[0].rewards, [.heart])
    }

    // MARK: - Triggers: what the DATA is allowed to decide

    private func day(
        steps: Int? = nil, strain: Double? = nil, recovery: Double? = nil,
        sleepMin: Double? = nil, hrv: Double? = nil, key: String = "2026-09-15"
    ) -> DailyMetric {
        DailyMetric(
            day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: recovery,
            strain: strain, exerciseCount: nil, steps: steps
        )
    }

    func testNothingIsRaisedWithoutData() {
        // A phone with nothing synced has no grounds to nag, and inventing one would be the whole
        // failure mode this design exists to prevent.
        XCTAssertTrue(QuestTriggers.evaluate(today: nil, recent: []).isEmpty)
        XCTAssertTrue(QuestTriggers.evaluate(today: day(), recent: []).isEmpty)
    }

    func testASedentaryDayRaisesAStepQuestWithTheTargetInIt() {
        let fired = QuestTriggers.evaluate(today: day(steps: 900), recent: [])
        let sedentary = fired.first { $0.id == "sedentary" }
        XCTAssertNotNil(sedentary)
        XCTAssertTrue(sedentary!.target.contains("\(QuestTriggers.stepsTarget)"))
        XCTAssertTrue(sedentary!.rewards.contains(.heart))
    }

    func testAMissingStepCountIsNotAStillDay() {
        // Nil is a sensor that is not reporting. Treating it as zero would nag people whose phone
        // simply does not count steps, every single day.
        XCTAssertFalse(QuestTriggers.evaluate(today: day(steps: nil), recent: []).contains { $0.id == "sedentary" })
    }

    func testHardTrainingOnNoRecoveryIsTheMostUrgentThing() {
        let fired = QuestTriggers.evaluate(today: day(steps: 500, strain: 16, recovery: 20), recent: [])
        XCTAssertEqual(fired.first?.id, "overreach")
    }

    func testLowHrvIsJudgedAgainstTheirOwnBaselineNotAnAbsoluteNumber() {
        // 40ms is unremarkable for one person and alarming for another; only the deviation means
        // anything, so an absolute threshold would be a fabricated standard.
        let steady = (1...8).map { day(hrv: 100, key: String(format: "2026-09-%02d", $0)) }
        XCTAssertTrue(QuestTriggers.evaluate(today: day(hrv: 40), recent: steady).contains { $0.id == "hrv-dip" })
        XCTAssertFalse(QuestTriggers.evaluate(today: day(hrv: 95), recent: steady).contains { $0.id == "hrv-dip" })
    }

    func testABaselineTooShortToMeanAnythingRaisesNothing() {
        let thin = (1...3).map { day(hrv: 100, key: String(format: "2026-09-%02d", $0)) }
        XCTAssertFalse(QuestTriggers.evaluate(today: day(hrv: 40), recent: thin).contains { $0.id == "hrv-dip" })
    }

    func testTheSameConditionCannotRaiseTwoQuestsInADay() {
        let trigger = QuestTriggers.evaluate(today: day(steps: 100), recent: []).first { $0.id == "sedentary" }!
        let already = [Quest(kind: .side, title: "t", taunt: "x", target: trigger.target,
                             rewards: [], xp: 40, dayKey: "2026-09-15", createdAtMs: now)]
        XCTAssertFalse(QuestTriggers.mayRaise(existingToday: already, trigger: trigger))
    }

    func testTheDailySideQuestBudgetIsAHardStop() {
        let trigger = QuestTriggers.evaluate(today: day(steps: 100), recent: []).first { $0.id == "sedentary" }!
        let full = (0..<QuestTriggers.maxSidePerDay).map { i in
            Quest(kind: .side, title: "t", taunt: "x", target: "other \(i)",
                  rewards: [], xp: 40, dayKey: "2026-09-15", createdAtMs: now)
        }
        XCTAssertFalse(QuestTriggers.mayRaise(existingToday: full, trigger: trigger))
    }

    func testTheObservationSentenceIsLocaleFixed() {
        // It is handed to a model as prose. A German phone must not put a comma in the decimal and
        // send the model a different sentence than an American one does.
        let fired = QuestTriggers.evaluate(today: day(strain: 16.5, recovery: 20), recent: [])
        XCTAssertTrue(fired[0].observation.contains("16.5"))
        XCTAssertFalse(fired[0].observation.contains("16,5"))
    }
}
