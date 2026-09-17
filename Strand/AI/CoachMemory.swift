import Foundation

// CoachMemory.swift — what the coach writes down between sessions.
//
// A conversation ends and the coach forgets it: the plan agreed on Monday, the knee that hurts on
// stairs, the fact that evening sessions wreck this person's sleep. Every new session started from
// numbers alone, and the wearer repeated themselves.
//
// SO THE COACH HAS A FILE. It reads the whole file at the start of every session and can add to it or
// strike from it as it talks, by writing a command on a line of its own:
//
//   [[REMEMBER: Knee pain on stairs since 14 Sep — no jumping until it settles.]]
//   [[FORGET: k3f9]]
//
// A COMMAND, NOT A TOOL CALL, because every provider the coach runs on can write a line of text and
// not every one supports tools. The lines are applied when the reply is finished and removed from what
// the wearer sees; the reply reads as a reply.
//
// A FILE, NOT A PREFERENCE, as the wearer asked: plain JSON in Application Support, so it is part of the
// app's own data, survives relaunches, and can be read and pruned from the coach's settings sheet.
//
// BOUNDED. The whole file rides in every session's context, so it holds the most recent `maxItems`
// entries and each is capped. A memory that grows without limit is a context window that fills with
// last spring.

struct CoachMemoryItem: Codable, Identifiable, Equatable {
    /// Short, so the model can quote it back in a FORGET line without mangling it.
    let id: String
    let text: String
    let createdAt: Date
}

@MainActor
final class CoachMemory: ObservableObject {

    static let shared = CoachMemory()

    static let maxItems = 40
    static let maxChars = 280

    @Published private(set) var items: [CoachMemoryItem] = []

    private let url: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("coach_memory.json")
        items = (try? JSONDecoder().decode([CoachMemoryItem].self, from: Data(contentsOf: url))) ?? []
    }

    @discardableResult
    func add(_ text: String) -> CoachMemoryItem? {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxChars))
        guard !clean.isEmpty else { return nil }
        // The same fact twice is one fact.
        if let existing = items.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        let item = CoachMemoryItem(id: Self.newId(taken: Set(items.map(\.id))), text: clean, createdAt: Date())
        items.append(item)
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        save()
        return item
    }

    func remove(id: String) {
        let before = items.count
        items.removeAll { $0.id.caseInsensitiveCompare(id.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        if items.count != before { save() }
    }

    func clear() {
        items = []
        save()
    }

    /// The block that goes into every session's context: the file's contents and how to change it.
    func promptSection() -> String {
        var s = "YOUR MEMORY FILE — notes you wrote in earlier sessions. Read it before answering.\n"
        if items.isEmpty {
            s += "(empty)\n"
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            for item in items { s += "- [\(item.id)] (\(f.string(from: item.createdAt))) \(item.text)\n" }
        }
        s += "To save something worth keeping — an agreed plan, an injury, a preference, what worked or "
        s += "did not — write a line exactly like [[REMEMBER: the note]]. To delete an entry that is done "
        s += "or wrong, write [[FORGET: its id]]. One command per line, short notes, no duplicates. These "
        s += "lines are removed before the user sees your reply, so do not mention them."
        return s
    }

    /// Apply every command in a finished reply and return the reply without them.
    func apply(reply: String) -> String {
        var kept: [String] = []
        for line in reply.components(separatedBy: "\n") {
            if let (verb, body) = Self.command(line) {
                if verb == "REMEMBER" { add(body) } else { remove(id: body) }
            } else {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reply with its command lines hidden, for drawing a reply that is still streaming.
    nonisolated static func hidingCommands(_ text: String) -> String {
        guard text.contains("[[") else { return text }
        return text.components(separatedBy: "\n")
            .filter { command($0) == nil && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[[") }
            .joined(separator: "\n")
    }

    /// `[[REMEMBER: …]]` / `[[FORGET: …]]`, tolerant of bold, bullets and spacing.
    nonisolated static func command(_ line: String) -> (String, String)? {
        var t = line.trimmingCharacters(in: .whitespaces)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "*-• `"))
        guard t.hasPrefix("[["), t.hasSuffix("]]") else { return nil }
        let inner = t.dropFirst(2).dropLast(2)
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let verb = inner[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
        let body = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard verb == "REMEMBER" || verb == "FORGET", !body.isEmpty else { return nil }
        return (verb, body)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func newId(taken: Set<String>) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        while true {
            let id = String((0..<4).map { _ in alphabet.randomElement()! })
            if !taken.contains(id) { return id }
        }
    }
}
