import Foundation
import StrandAnalytics

// QuestModeStore.swift — which gear the wearer picked, by day.
//
// One choice per day, made at the end of the morning flow and held for that day. Kept as a day-keyed
// dictionary rather than a single "today's mode" value for two reasons: Today has to be able to say
// which mode THIS day is running in after a relaunch, and a choice made for yesterday must never be
// read as a choice for this morning.
//
// A DAY WITH NO CHOICE HAS NO MODE. `mode(for:)` returns nil, and nil is not `.steady`: a wearer who
// skipped the flow was never asked, and showing them a mode they did not pick would be the system
// putting words in their mouth. Nothing downstream substitutes a default.
//
// Observable, because picking a mode has to move the Today strip at once — the same reason `QuestStore`
// is an object and not a bag of statics.

@MainActor
final class QuestModeStore: ObservableObject {

    static let shared = QuestModeStore()

    /// One key, a `[day: rawValue]` dictionary. Raw strings rather than ordinals, so the stored choice
    /// survives a reordering of `QuestDifficulty`'s cases and is readable by any platform that adopts it.
    static let key = "system.questMode.v1"

    /// How many days of choices are kept. Only the current day is ever read; the rest is there so a
    /// screen looking a few days back has an answer, and so the dictionary cannot grow without bound.
    static let kept = 14

    private let defaults: UserDefaults

    /// Every day's choice. Published so the strip redraws the moment one is made.
    @Published private(set) var byDay: [String: QuestDifficulty] = [:]

    /// Internal rather than private so a test can run a store on its own suite; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        byDay = Self.read(defaults)
    }

    /// The gear picked for `day`, or nil when none was.
    func mode(for day: String) -> QuestDifficulty? { byDay[day] }

    /// Record the choice for `day`, replacing whatever was there — re-picking later in the day is
    /// allowed, and the quests are re-issued with it (`QuestIssuer.issuePlan`).
    func set(_ difficulty: QuestDifficulty, for day: String) {
        var next = byDay
        next[day] = difficulty
        // Oldest fall off the end, by day key — which sorts chronologically because it is `yyyy-MM-dd`.
        if next.count > Self.kept {
            for old in next.keys.sorted().prefix(next.count - Self.kept) { next[old] = nil }
        }
        defaults.set(next.mapValues(\.rawValue), forKey: Self.key)
        byDay = next
    }

    /// Re-read from storage. For a screen that has been away while another surface wrote one.
    func reload() { byDay = Self.read(defaults) }

    private static func read(_ defaults: UserDefaults) -> [String: QuestDifficulty] {
        // Tolerant: an unknown raw value from a newer build is dropped rather than failing the read, the
        // same way `QuestCodec` drops an unknown metric.
        let raw = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(QuestDifficulty.init(rawValue:))
    }
}
