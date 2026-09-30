import XCTest
import StrandAnalytics
@testable import Strand

/// HEALTH_V2 §S1-B acceptance, app side:
///   * a running trial has NO read path to an analysis (sealed); only counts and today's arm;
///   * stopping early gives Inconclusive(stopped early) with no numbers;
///   * the adherence record only moves toward honesty; OFF-day contamination is the wearer's own answer;
///   * a trial quest pays the same XP for any answer and never becomes a red card or a penalty.
@MainActor
final class HabitTrialStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("habit-trials-\(UUID().uuidString).json")
    }

    private let today = DailyMissionStore.dayKey(Date())

    private func baseline() -> [String: Double] {
        var b: [String: Double] = [:]
        for back in 0..<28 { b[HabitDay.adding(-back, to: today)!] = 1380 + Double((back * 37) % 41) }
        return b
    }

    private func startedStore(url: URL? = nil) -> (HabitTrialStore, HabitTrialRecord) {
        let defaults = UserDefaults(suiteName: "habittrial.test.\(UUID().uuidString)")!
        let store = HabitTrialStore(fileURL: url ?? tempURL(), defaults: defaults)
        let entry = HabitTrialCatalog.entry("screensOff60")!
        guard case .success(let rec) = store.start(entry: entry, lengthDays: 28, usualPerWeek: 5,
                                                   baseline: baseline(), today: today, seed: 42) else {
            XCTFail("start failed")
            return (store, store.trials[0])
        }
        return (store, rec)
    }

    func testRunningTrialIsSealed() {
        let (store, rec) = startedStore()
        XCTAssertEqual(rec.state, .running)
        XCTAssertNil(rec.result)
        XCTAssertNil(store.result(trialId: rec.id), "no result path while running")
        XCTAssertTrue(store.finishedForCoach().isEmpty)
        // Starts TOMORROW: today has no assignment yet.
        XCTAssertNil(store.todayAssignment(today: today))
        let tomorrow = HabitDay.adding(1, to: today)!
        XCTAssertEqual(store.todayAssignment(today: tomorrow)?.on, rec.registration.schedule[0])
        let p = store.runningProgress(today: tomorrow)!
        XCTAssertEqual(p.dayNumber, 1)
        let labels = Mirror(reflecting: p).children.compactMap { $0.label }
        XCTAssertFalse(labels.contains { ["estimate", "lower", "upper", "meanOn", "verdict"].contains($0) })
        // One trial at a time.
        let again = store.start(entry: HabitTrialCatalog.entry("dinner3h")!, lengthDays: 28, usualPerWeek: 5,
                                baseline: baseline(), today: today, seed: 1)
        XCTAssertEqual(again.failureValue, .alreadyRunning)
    }

    func testPersistsAndReloadsWithIntactHash() {
        let url = tempURL()
        let (_, rec) = startedStore(url: url)
        let reloaded = HabitTrialStore(fileURL: url, defaults: .standard)
        XCTAssertEqual(reloaded.running?.registration, rec.registration)
        XCTAssertTrue(reloaded.running!.registration.verify(storedHash: reloaded.running!.hash))
    }

    func testStoppedEarlyHasNoNumbers() {
        let (store, rec) = startedStore()
        store.stop(trialId: rec.id, today: today)
        let r = store.result(trialId: rec.id)!
        XCTAssertEqual(r.verdict, .inconclusive(.stoppedEarly))
        XCTAssertNil(r.estimate)
        XCTAssertNil(r.lower)
        XCTAssertNil(store.running)
    }

    func testAnswersOnlyMoveTowardHonesty() {
        let (store, rec) = startedStore()
        let onIndex = rec.registration.schedule.firstIndex(of: true)!
        let offIndex = rec.registration.schedule.firstIndex(of: false)!
        let onDay = HabitDay.adding(onIndex, to: rec.registration.startDay)!
        let offDay = HabitDay.adding(offIndex, to: rec.registration.startDay)!

        // ON: the app saw it not happen → a "did it" tap cannot overrule.
        store.recordAuto(trialId: rec.id, day: onDay, evidence: .didNot)
        store.recordAnswer(trialId: rec.id, day: onDay, did: true)
        XCTAssertEqual(store.dayRecord(onDay)?.effective, .didNot)
        // OFF: natural evidence is not contamination; only the wearer's own "did it anyway" is.
        store.recordAuto(trialId: rec.id, day: offDay, evidence: .did)
        XCTAssertEqual(store.dayRecord(offDay)?.effective, .unknown)
        store.recordAnswer(trialId: rec.id, day: offDay, did: true)
        XCTAssertEqual(store.dayRecord(offDay)?.effective, .did)

        var d = HabitTrialDayRecord(day: onDay, assigned: true, answer: .didNot, auto: .did, answeredAt: nil,
                                    illness: false)
        XCTAssertEqual(d.effective, .didNot, "\"I didn't\" always wins")
        d.answer = .unknown
        XCTAssertEqual(d.effective, .did)
    }

    // MARK: Quests

    func testTrialQuestPaysTheSameForAnyAnswerAndIsNeverAFailure() {
        let defaults = UserDefaults(suiteName: "habittrial.quests.\(UUID().uuidString)")!
        let penalties = QuestPenaltyStore(defaults: defaults, modes: QuestModeStore(defaults: defaults))
        let quests = QuestStore(defaults: defaults, penalties: penalties)
        let (trials, rec) = startedStore()
        let bridge = HabitTrialQuestBridge()
        let day1 = Date().addingTimeInterval(86_400)
        bridge.sync(now: day1, trials: trials, quests: quests)
        let dayKey = Repository.localDayKey(day1)
        let id = HabitTrialQuestId.make(trialId: rec.id, day: dayKey)
        let q = quests.quests.first { $0.id == id }
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.kind, .custom)
        XCTAssertNil(q?.goal)
        XCTAssertEqual(q?.xp, HabitTrialQuestId.loggingXp)
        XCTAssertFalse(QuestStore.showsAsFailure(q!), "a trial arm is never a red card")
        XCTAssertFalse(QuestPenaltyRules.isPenalisable(kind: q!.kind, questId: id))

        let before = penalties.ledger.balance
        bridge.answer(questId: id, did: false, trials: trials, quests: quests)
        XCTAssertEqual(penalties.ledger.balance - before, HabitTrialQuestId.loggingXp,
                       "\"Didn't\" pays exactly what \"Did it\" pays")
        XCTAssertEqual(trials.dayRecord(dayKey)?.answer, .didNot)
        XCTAssertEqual(penalties.ledger.streak, 0, "a trial quest never touches the streak")

        // Expiry of an unanswered trial quest: no failure card, no judgement.
        let day2 = Date().addingTimeInterval(2 * 86_400)
        bridge.sync(now: day2, trials: trials, quests: quests)
        quests.sweepExpired(now: Date().addingTimeInterval(10 * 86_400))
        XCTAssertTrue(quests.failures.isEmpty)
        XCTAssertTrue(penalties.ledger.judgements.isEmpty)
    }

    func testConflictingMetricsFollowTheRunningTrial() {
        let (store, _) = startedStore()
        XCTAssertEqual(HabitTrialQuestBridge.conflictingMetrics(store: store), [.bedtimeBy, .bedtimeEarlier])
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
