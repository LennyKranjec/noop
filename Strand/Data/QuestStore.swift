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
        let updated = Quest(
            id: existing.id,
            kind: existing.kind,
            title: existing.title,
            taunt: existing.taunt,
            target: existing.target,
            rewards: existing.rewards,
            xp: existing.xp,
            state: state,
            dayKey: existing.dayKey,
            createdAtMs: existing.createdAtMs,
            expiresAtMs: existing.expiresAtMs)
        upsert(updated)
        return updated
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
