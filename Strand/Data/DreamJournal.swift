import Foundation

// DreamJournal.swift — the night, in the wearer's own words, and a few answers about it.
//
// EVERY MORNING'S FIRST OPEN asks for the dream while it is still there, then a handful of four-option
// questions about the night — recall, tone, how rested, wakings, how the alarm went, the last screen and
// the last meal. One entry per wake day.
//
// THE ANSWERS ARE THE POINT OF ASKING. Each one is ALSO written into the journal as a numbered answer
// (1 to 4, the option's position), under a fixed question name — the same seam the behaviour engine in
// Insights already correlates against recovery, HRV and sleep. So "a late meal" or "a screen until
// sleep" shows up there as an effect on the night with no separate analysis written for it.
//
// THE ORDER OF OPTIONS IS MEANINGFUL: where a question has a better and a worse end, the first option is
// the worse one, so a higher number is always the better night and a correlation reads the right way up.

/// One four-option question.
struct DreamQuestion: Identifiable, Equatable {
    struct Option: Equatable {
        let title: String
        let subtitle: String
        let symbol: String
    }

    let id: String
    /// The small caps line above the question.
    let overline: String
    let title: String
    /// The journal question the answer is stored under, for the behaviour engine.
    let journalName: String
    let options: [Option]
}

enum DreamQuestions {
    static let all: [DreamQuestion] = [
        DreamQuestion(
            id: "recall", overline: "Dream recall", title: "How much of it do you remember?",
            journalName: "Dream recall",
            options: [
                .init(title: "Nothing", subtitle: "No memory of dreaming at all.", symbol: "moon.zzz"),
                .init(title: "Fragments", subtitle: "Flashes and images, no story.", symbol: "sparkle"),
                .init(title: "Clear", subtitle: "Scenes and a story I could retell.", symbol: "cloud.moon"),
                .init(title: "Vivid", subtitle: "Every detail, or I knew I was dreaming.", symbol: "sparkles"),
            ]),
        DreamQuestion(
            id: "tone", overline: "Dream tone", title: "How did the dream feel?",
            journalName: "Dream tone",
            options: [
                .init(title: "Nightmare", subtitle: "Fear or distress that stayed with me.", symbol: "cloud.bolt"),
                .init(title: "Unsettling", subtitle: "Tense, strange or sad.", symbol: "cloud.drizzle"),
                .init(title: "Neutral", subtitle: "Ordinary, nothing charged.", symbol: "cloud"),
                .init(title: "Pleasant", subtitle: "Calm, warm or exciting.", symbol: "sun.max"),
            ]),
        DreamQuestion(
            id: "rested", overline: "Waking state", title: "How rested do you feel right now?",
            journalName: "Felt rested",
            options: [
                .init(title: "Drained", subtitle: "I could sleep for hours more.", symbol: "battery.0"),
                .init(title: "Groggy", subtitle: "Slow to start, heavy head.", symbol: "battery.25"),
                .init(title: "Functional", subtitle: "Awake, but not sharp yet.", symbol: "battery.75"),
                .init(title: "Restored", subtitle: "Fully charged and clear-headed.", symbol: "battery.100.bolt"),
            ]),
        DreamQuestion(
            id: "wakings", overline: "The night", title: "How often did you wake up?",
            journalName: "Night wakings (felt)",
            options: [
                .init(title: "More than three", subtitle: "A broken night, hard to fall back.", symbol: "moon.haze"),
                .init(title: "Two or three", subtitle: "Awake a few times.", symbol: "moon"),
                .init(title: "Once", subtitle: "Up once, back asleep quickly.", symbol: "moon.stars"),
                .init(title: "Straight through", subtitle: "Didn't wake until morning.", symbol: "moon.stars.fill"),
            ]),
        DreamQuestion(
            id: "wake", overline: "Wake-up", title: "How did you wake up?",
            journalName: "Wake-up",
            options: [
                .init(title: "Jolted", subtitle: "A loud alarm pulled me out.", symbol: "alarm"),
                .init(title: "Woken", subtitle: "Something else woke me: noise, light, someone.", symbol: "ear"),
                .init(title: "Gentle alarm", subtitle: "A soft alarm or the strap's buzz.", symbol: "bell"),
                .init(title: "Naturally", subtitle: "On my own, before any alarm.", symbol: "sunrise"),
            ]),
        DreamQuestion(
            id: "screen", overline: "Last night", title: "When did you last look at a screen?",
            journalName: "Screen before bed",
            options: [
                .init(title: "Right up to sleep", subtitle: "Phone in hand until lights out.", symbol: "iphone"),
                .init(title: "Under 30 minutes", subtitle: "Put it down just before bed.", symbol: "iphone.gen2"),
                .init(title: "30 to 60 minutes", subtitle: "Screens off a while before sleep.", symbol: "clock"),
                .init(title: "Over an hour", subtitle: "A screen-free wind-down.", symbol: "book"),
            ]),
        DreamQuestion(
            id: "meal", overline: "Last night", title: "When was your last meal?",
            journalName: "Last meal before bed",
            options: [
                .init(title: "Within an hour", subtitle: "Ate right before bed.", symbol: "fork.knife"),
                .init(title: "One to two hours", subtitle: "A late dinner.", symbol: "fork.knife.circle"),
                .init(title: "Two to three hours", subtitle: "Dinner at a normal time.", symbol: "clock.arrow.circlepath"),
                .init(title: "More than three", subtitle: "Kitchen closed early.", symbol: "moon.circle"),
            ]),
    ]
}

/// One morning's entry.
struct DreamEntry: Codable, Identifiable, Equatable {
    /// The wake day, `yyyy-MM-dd`.
    let day: String
    var text: String
    /// Question id → option index (0–3).
    var answers: [String: Int]
    var updatedAt: Date

    var id: String { day }
}

@MainActor
final class DreamJournalStore: ObservableObject {
    static let shared = DreamJournalStore()

    @Published private(set) var entries: [DreamEntry] = []

    private static let key = "dreamJournal.entries.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([DreamEntry].self, from: data) {
            entries = stored.sorted { $0.day > $1.day }
        }
    }

    func entry(day: String) -> DreamEntry? { entries.first { $0.day == day } }

    /// Store an entry and mirror its answers into the journal, so Insights can correlate them.
    func save(_ entry: DreamEntry, repo: Repository) async {
        var all = entries.filter { $0.day != entry.day }
        all.append(entry)
        entries = all.sorted { $0.day > $1.day }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            await repo.saveJournalAnswer(day: entry.day, question: "Dream", answeredYes: true, notes: text)
        }
        for question in DreamQuestions.all {
            guard let index = entry.answers[question.id] else { continue }
            await repo.saveJournalNumeric(day: entry.day, question: question.journalName,
                                          value: Double(index + 1))
        }
    }

    /// The answers as one line per question, for the coach and the brief.
    static func summary(_ entry: DreamEntry) -> [String] {
        DreamQuestions.all.compactMap { q in
            guard let i = entry.answers[q.id], q.options.indices.contains(i) else { return nil }
            return "\(q.journalName): \(q.options[i].title)"
        }
    }
}
