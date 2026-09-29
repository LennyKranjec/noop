import Foundation
import StrandAnalytics

// QuestPenaltyStore.swift — the game layer's books, between launches.
//
// Holds one `QuestLedger` (StrandAnalytics): the XP balance, the daily streak, every judgement of the
// last 30 days, the quests waiting to be judged and the open make-ups. Every rule and every number lives
// in the ledger and `QuestPenaltyRules`; this file only persists it and publishes it.
//
// GAME LAYER ONLY. Nothing here reads or writes the measured Level (`LevelLedger` / `LevelEngine`). A
// missed quest costs XP, a streak and a make-up — never a point of the Level, which describes the body
// and is frozen against a fixed scale.
//
// LOCAL TO THIS DEVICE. The ledger is its own defaults key and is NOT on the `.noopbak` whitelist: there
// is no Android twin of the penalty system, and a key that crossed the backup boundary without one would
// break the byte-identical contract.
//
// Observable, because a judgement has to move the pinned board on Today the moment it is made.

@MainActor
final class QuestPenaltyStore: ObservableObject {

    static let shared = QuestPenaltyStore()

    static let key = "system.questLedger.v1"

    private let defaults: UserDefaults
    /// Where the day's gear is read from when a plan quest is queued for judgement.
    private let modes: QuestModeStore

    @Published private(set) var ledger: QuestLedger

    /// Internal rather than private so a test can run a store on its own suite; the app uses `shared`.
    init(defaults: UserDefaults = .standard, modes: QuestModeStore? = nil) {
        self.defaults = defaults
        self.modes = modes ?? QuestModeStore.shared
        ledger = Self.read(defaults)
    }

    // MARK: Paying

    /// Pay a completed quest — once. A make-up quest clears its debt instead of paying its own XP.
    @discardableResult
    func credit(_ quest: Quest) -> Int {
        var paid = 0
        mutate { paid = $0.credit(questId: quest.id, kind: quest.kind, xp: quest.xp) }
        return paid
    }

    /// Pay in the completions that pre-date the ledger, once. Without it a wearer with a month of
    /// finished quests would open this build at 0 XP and meet their first penalty "in the red".
    func seedIfNeeded(completed: [Quest]) {
        guard !ledger.seeded else { return }
        mutate { l in
            for quest in completed where quest.state == .completed {
                l.credit(questId: quest.id, kind: quest.kind, xp: quest.xp)
            }
            l.seeded = true
        }
    }

    // MARK: Judging

    /// Queue a closed quest to be judged on its data.
    ///
    /// Only a quest with something to measure: one whose goal is nil can never be judged short, so
    /// queueing it would only pin a "not measured" line nobody needs. A plan quest carries the gear its
    /// day ran in — the wearer's own bet — and nothing else does.
    func enqueue(_ quest: Quest, judgeAfterMs: Int64? = nil) {
        guard quest.effectiveGoal != nil else { return }
        let gear = QuestDayPlan.isPlanQuest(quest) ? modes.mode(for: quest.dayKey) : nil
        let subject = QuestJudgementSubject(quest: quest, gear: gear, judgeAfterMs: judgeAfterMs)
        // The ledger refuses anything already queued, judged or paid, so a re-sweep is a no-op.
        mutate { _ = $0.enqueue(subject) }
    }

    func judge(questId: String, evidence: QuestEvidence?, nowMs: Int64,
               context: QuestDebtContext) -> QuestLedger.JudgeResult {
        var result = QuestLedger.JudgeResult.notDue
        mutate { result = $0.judge(questId: questId, evidence: evidence, nowMs: nowMs, context: context) }
        return result
    }

    @discardableResult
    func void(questId: String) -> (refund: Int, withdrawnDebt: String?) {
        var out: (refund: Int, withdrawnDebt: String?) = (0, nil)
        mutate { out = $0.void(questId: questId) }
        return out
    }

    func lapseDebt(_ debtQuestId: String) {
        guard ledger.openDebts.contains(where: { $0.questId == debtQuestId }) else { return }
        mutate { $0.lapseDebt(debtQuestId: debtQuestId) }
    }

    func prune(today: String) { mutate { $0.prune(today: today) } }

    // MARK: Reading

    /// The judgement for `questId`, if it has been judged.
    func judgement(for questId: String) -> QuestJudgement? {
        ledger.judgements.first { $0.questId == questId }
    }

    /// Whether `questId` is waiting on its data.
    func isPending(_ questId: String) -> Bool { ledger.pending.contains { $0.questId == questId } }

    /// Whether any of `day`'s plan quests is still waiting to be judged — the day's card waits for it,
    /// so it can print the penalty on every line rather than a verdict without a price.
    func hasPendingPlanJudgement(day: String) -> Bool {
        ledger.pending.contains { $0.dayKey == day && $0.questId.hasPrefix(QuestDayPlan.idPrefix) }
    }

    /// The make-up waiting behind a make-up quest's id.
    func debt(for debtQuestId: String) -> QuestDebt? {
        ledger.judgements.compactMap(\.debt).first { $0.questId == debtQuestId }
    }

    /// Changes whenever something new may need judging — what the assessor's task is keyed on.
    var pendingSignature: String {
        ledger.pending.map(\.questId).joined(separator: ",") + "|" + String(ledger.openDebts.count)
    }

    // MARK: Storage

    private func mutate(_ body: (inout QuestLedger) -> Void) {
        var next = ledger
        body(&next)
        guard next != ledger else { return }
        write(next)
    }

    private func write(_ next: QuestLedger) {
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
        ledger = next
    }

    private static func read(_ defaults: UserDefaults) -> QuestLedger {
        guard let data = defaults.data(forKey: key),
              let ledger = try? JSONDecoder().decode(QuestLedger.self, from: data) else { return QuestLedger() }
        return ledger
    }
}
