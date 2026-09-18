import Foundation
import StrandAnalytics

// QuestStore.swift — where the system's directives live between launches.
//
// Swift twin of the Android `com.noop.ai.QuestStore`. One defaults key holding the whole list as the
// JSON `QuestCodec` writes — the same bytes on both platforms, because the list crosses the `.noopbak`
// boundary and a quest exported on one has to read on the other.
//
// AN OBSERVABLE OBJECT, not a bag of statics. Today reads the strip while it renders, and accepting a
// quest has to move the strip immediately; a plain static would update the stored list and leave the
// screen showing the old one until something else happened to redraw.

@MainActor
final class QuestStore: ObservableObject {

    static let shared = QuestStore()

    private static let key = "system.quests"

    /// Everything kept, oldest first.
    @Published private(set) var quests: [Quest] = []

    private init() {
        quests = QuestStore.read()
    }

    /// The quest waiting to be answered, if any.
    ///
    /// ONE AT A TIME. Two pop-ups stacked on top of each other is a dialog fight, and a wearer who is
    /// shown three quests at once accepts none of them. The rest keep their turn.
    var offered: Quest? { quests.first { $0.state == .offered } }

    /// What the wearer has taken on and not yet finished, newest first.
    var active: [Quest] {
        quests.filter { $0.state == .active }.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    /// Today's quests in every state, for deciding whether a trigger has already fired.
    func forDay(_ dayKey: String) -> [Quest] { quests.filter { $0.dayKey == dayKey } }

    @discardableResult
    func upsert(_ quest: Quest) -> [Quest] {
        var next = quests
        if let i = next.firstIndex(where: { $0.id == quest.id }) {
            next[i] = quest
        } else {
            next.append(quest)
        }
        // Oldest fall off the end. A quest from three weeks ago is history nobody reads, and this list
        // is parsed on every Today render.
        next.sort { $0.createdAtMs < $1.createdAtMs }
        if next.count > QuestCodec.maxKept { next = Array(next.suffix(QuestCodec.maxKept)) }
        write(next)
        return next
    }

    @discardableResult
    func setState(id: String, state: QuestState) -> Quest? {
        guard let existing = quests.first(where: { $0.id == id }) else { return nil }
        // Through `with(state:)`, which carries EVERY field. Rebuilding the quest here field by field is
        // how the goal would have been silently dropped the first time a quest was accepted.
        let updated = existing.with(state: state)
        upsert(updated)
        return updated
    }

    /// A quest the data just closed, and what the data said. What the completion pop-up reads.
    struct Completion: Identifiable, Equatable {
        let quest: Quest
        let summary: String
        var id: String { quest.id }
    }

    /// Completions waiting to be shown, oldest first. A queue, because two quests can close in the same
    /// refresh and each deserves its own moment.
    @Published private(set) var completions: [Completion] = []

    /// Close `quest` because its goal was met, and queue the pop-up that says so.
    func complete(_ quest: Quest, summary: String) {
        guard quests.contains(where: { $0.id == quest.id && $0.state != .completed }) else { return }
        setState(id: quest.id, state: .completed)
        completions.append(Completion(quest: quest.with(state: .completed), summary: summary))
    }

    /// The front completion has been seen.
    func dismissCompletion() {
        if !completions.isEmpty { completions.removeFirst() }
    }

    /// Quests whose window closed with the goal unmet, waiting to be shown in red. A queue for the same
    /// reason completions are one.
    @Published private(set) var failures: [Completion] = []

    /// CANCEL EVERY QUEST WHOSE WINDOW HAS CLOSED. An accepted quest that runs out is cancelled and its
    /// failure queued for the red pop-up — a commitment that quietly vanished from the strip would be the
    /// system pretending it never asked. One only ever offered and never accepted is withdrawn silently:
    /// nothing was promised, so there is nothing to fail.
    ///
    /// Runs after the completion check, so a goal met in the last minute closes as done, not as failed.
    func sweepExpired(now: Date = Date()) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for quest in quests where quest.state == .active || quest.state == .offered {
            guard nowMs >= quest.checkableUntilMs() else { continue }
            setState(id: quest.id, state: .declined)
            // Only a window that closed in the last day is news. A quest that ran out weeks ago — from
            // before quests could fail — is cancelled quietly rather than joining a queue of red cards.
            if quest.state == .active, nowMs - quest.checkableUntilMs() < 24 * 3_600_000 {
                failures.append(Completion(
                    quest: quest.with(state: .declined),
                    summary: "The window closed before the data showed it done, so the quest has been cancelled."))
            }
        }
    }

    /// The front failure has been seen.
    func dismissFailure() {
        if !failures.isEmpty { failures.removeFirst() }
    }

    /// Re-read from storage. For a screen that has been away while a background pass wrote one.
    func reload() { quests = QuestStore.read() }

    private func write(_ list: [Quest]) {
        UserDefaults.standard.set(QuestCodec.encode(list), forKey: QuestStore.key)
        quests = list
    }

    private static func read() -> [Quest] {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return [] }
        return QuestCodec.decode(
            raw,
            fallbackDay: DailyMissionStore.dayKey(),
            now: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
