import Foundation

// Quest.swift — the system's directives, as a domain model.
//
// Pure + deterministic so it is unit-testable without an app target, and so the shape is
// byte-identical to the Android twin `com.noop.ai.Quest` / `QuestStore` (the cross-platform parity
// contract: the same stored JSON has to read the same on both platforms, because it crosses the
// `.noopbak` boundary).
//
// WHAT MAKES IT A QUEST AND NOT A NOTIFICATION: it is concrete, it is bounded, it has a price on it,
// and it has to be ACCEPTED. A push that says "consider stretching" is ignorable in a way that a card
// demanding an answer is not, and accepting is the user choosing, which is the only reason any of
// this works.
//
// THE TITLE AND THE TAUNT ARE GENERATED; THE TRIGGER AND THE TARGET ARE NOT. A model writes the name
// and the one-line insult because those are the parts that should never repeat. It does NOT decide
// that today deserves a mobility quest, and it does not invent the number: those come from the user's
// own metrics through `QuestTriggers`, because a language model asked to read a day's data and set a
// target will cheerfully invent both.

/// Where a quest came from. Decides its weight, its XP band and whether it interrupts.
public enum QuestKind: String, Equatable, Codable, CaseIterable, Sendable {
    /// The morning mission, promoted. One a day, always issued.
    case daily = "DAILY"
    /// Raised by a condition in the data. Zero or several a day.
    case side = "SIDE"
}

/// What finishing a quest is supposed to improve — shown as an icon on the card.
///
/// Deliberately coarse and honest: these are the systems a directive plausibly touches, not a claim
/// about a measured effect. "Meditation improves your stress" is a reasonable thing to say on a card;
/// "meditation will lower your RHR by 2 bpm" would be a fabricated number, which this app does not do.
public enum QuestReward: String, Equatable, Codable, CaseIterable, Sendable {
    case heart = "HEART"
    case lungs = "LUNGS"
    case brain = "BRAIN"
    case muscle = "MUSCLE"
    case sleep = "SLEEP"
    case stress = "STRESS"
}

/// Where a quest is in its life.
public enum QuestState: String, Equatable, Codable, CaseIterable, Sendable {
    /// Issued, shown as a pop-up, waiting for the user to accept it.
    case offered = "OFFERED"
    /// Accepted. Visible on Today until it is finished or the window closes.
    case active = "ACTIVE"
    /// The user says it is done. XP claimed once, through the XP ledger.
    case completed = "COMPLETED"
    /// Offered and turned down, or expired unfinished. Kept briefly so it is not re-issued at once.
    case declined = "DECLINED"
}

/// One quest.
///
/// `target` is the thing to actually do, in plain words with the number in it ("8,000 steps",
/// "10 minutes of mobility"). `taunt` is the sarcastic line the card types out. `title` is the name
/// the model gave it. All three are shown; only the first is a commitment.
public struct Quest: Equatable, Sendable {

    /// A day, which is what "before this is over" means for everything the triggers ask for.
    public static let defaultWindowMs: Int64 = 24 * 60 * 60 * 1000

    public let id: String
    public let kind: QuestKind
    public let title: String
    public let taunt: String
    public let target: String
    public let rewards: [QuestReward]
    public let xp: Int
    public let state: QuestState
    public let dayKey: String
    public let createdAtMs: Int64
    /// When it stops counting, as epoch milliseconds.
    ///
    /// EVERY QUEST HAS ONE. A directive with no deadline is a suggestion, and the countdown is most of
    /// what separates the two: "8,000 steps" is advice, "8,000 steps in 14:22:07" is a quest.
    public let expiresAtMs: Int64

    public init(
        id: String = UUID().uuidString,
        kind: QuestKind,
        title: String,
        taunt: String,
        target: String,
        rewards: [QuestReward],
        xp: Int,
        state: QuestState = .offered,
        dayKey: String,
        createdAtMs: Int64,
        expiresAtMs: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.taunt = taunt
        self.target = target
        self.rewards = rewards
        self.xp = xp
        self.state = state
        self.dayKey = dayKey
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs ?? (createdAtMs + Quest.defaultWindowMs)
    }

    /// The ledger key, so one quest pays out exactly once however many times the button is tapped.
    public var claimKey: String { "quest-\(id)" }

    /// Milliseconds left, floored at zero.
    public func remainingMs(now: Int64) -> Int64 { max(0, expiresAtMs - now) }

    /// Whether the window has closed. An expired quest cannot be completed for XP.
    public func isExpired(now: Int64) -> Bool { now >= expiresAtMs }

    /// `HH:MM:SS` of what is left.
    ///
    /// Zero-padded and locale-independent: this is a countdown, not a formatted duration, and it has
    /// to be the same width on every tick or the whole row jitters as the digits change. Byte-identical
    /// to the Android twin's `Quest.formatRemaining`.
    public static func formatRemaining(_ ms: Int64) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Storage

/// The JSON codec for the stored quest list.
///
/// Hand-rolled rather than `Codable` on purpose: the wire shape is a parity contract with the Kotlin
/// twin's `org.json` writer — same keys, same string cases, same tolerance for a record written by an
/// older build. `Codable`'s synthesised container would tie the format to Swift property names and
/// would throw on the first unknown or missing field instead of degrading.
public enum QuestCodec {

    /// The XP a quest may be worth, whatever a model suggests.
    public static let minXp = 10
    public static let maxXp = 150

    /// How many are kept. Enough for a week of history; the list is read on every Today render.
    public static let maxKept = 40

    public static func encode(_ quests: [Quest]) -> String {
        let array: [[String: Any]] = quests.map { q in
            [
                "id": q.id,
                "kind": q.kind.rawValue,
                "title": q.title,
                "taunt": q.taunt,
                "target": q.target,
                "rewards": q.rewards.map(\.rawValue),
                "xp": q.xp,
                "state": q.state.rawValue,
                "day": q.dayKey,
                "createdAt": q.createdAtMs,
                "expiresAt": q.expiresAtMs,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Read a stored list, dropping anything unusable rather than failing the whole read.
    ///
    /// A record with no `target` is dropped: the target is the commitment, and a quest without one
    /// would render as an empty card. Everything else degrades to a default, including the deadline —
    /// a record written before quests had one gets a window measured from its creation, so it reads as
    /// neither already-expired nor never-expiring.
    public static func decode(_ raw: String, fallbackDay: String, now: Int64) -> [Quest] {
        guard let data = raw.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return array.compactMap { o -> Quest? in
            guard let target = (o["target"] as? String), !target.isEmpty else { return nil }
            let created = (o["createdAt"] as? NSNumber)?.int64Value ?? now
            let expires = (o["expiresAt"] as? NSNumber)?.int64Value
            let rewards = (o["rewards"] as? [String] ?? []).compactMap(QuestReward.init(rawValue:))
            let title = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? target
            return Quest(
                id: (o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                kind: QuestKind(rawValue: o["kind"] as? String ?? "") ?? .side,
                title: title,
                taunt: o["taunt"] as? String ?? "",
                target: target,
                rewards: rewards,
                // Clamped, not trusted: part of this record came from a language model.
                xp: min(maxXp, max(minXp, (o["xp"] as? NSNumber)?.intValue ?? minXp)),
                state: QuestState(rawValue: o["state"] as? String ?? "") ?? .offered,
                dayKey: (o["day"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDay,
                createdAtMs: created,
                expiresAtMs: (expires.map { $0 > 0 ? $0 : nil } ?? nil) ?? (created + Quest.defaultWindowMs)
            )
        }
    }
}
