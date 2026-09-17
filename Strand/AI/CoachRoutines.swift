import Foundation

// CoachRoutines.swift — the fixed points of the wearer's day, as constraints the coach plans around.
//
// Replaces the free-text Goals. A goal said what the training was FOR; it did not say when the wearer
// gets up, when they have to be at work, or that they cannot train before seven. Without those the
// coach planned an evening session for someone who is in bed at nine, and a morning run for someone
// whose alarm is at six-fifteen — advice that was reasonable and could not be followed.
//
// SO THE ROUTINES ARE CONSTRAINTS, handed to the coach on every session and every generated directive,
// and stated as such: plan inside them, never across them.
//
// A few fixed fields — the ones every plan collides with — and a free list for everything else, because
// a routine is as often "school run 07:45–08:15 on weekdays" as it is a time.

struct CoachRoutineEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var detail: String
}

struct CoachRoutineSet: Codable, Equatable {
    /// Minutes past midnight; nil when not set.
    var wake: Int?
    var bed: Int?
    var workStart: Int?
    var workEnd: Int?
    var caffeineCutoff: Int?
    var training: String = ""
    var meals: String = ""
    var entries: [CoachRoutineEntry] = []

    var isEmpty: Bool {
        wake == nil && bed == nil && workStart == nil && workEnd == nil && caffeineCutoff == nil
            && training.trimmingCharacters(in: .whitespaces).isEmpty
            && meals.trimmingCharacters(in: .whitespaces).isEmpty
            && entries.allSatisfy { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

enum CoachRoutines {

    static let key = "coach.routines.v1"

    static func read(_ d: UserDefaults = .standard) -> CoachRoutineSet {
        guard let data = d.data(forKey: key),
              let set = try? JSONDecoder().decode(CoachRoutineSet.self, from: data)
        else { return CoachRoutineSet() }
        return set
    }

    static func write(_ set: CoachRoutineSet, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(set) else { return }
        d.set(data, forKey: key)
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// The constraints block, or nil when nothing is set.
    ///
    /// Nil rather than "no routines": the absence of routines is not a thing to plan around.
    static func promptSection(_ d: UserDefaults = .standard) -> String? {
        let r = read(d)
        guard !r.isEmpty else { return nil }
        var lines: [String] = []
        if let w = r.wake { lines.append("- Wakes at \(clock(w))") }
        if let b = r.bed { lines.append("- In bed by \(clock(b))") }
        switch (r.workStart, r.workEnd) {
        case let (s?, e?): lines.append("- Works \(clock(s))–\(clock(e))")
        case let (s?, nil): lines.append("- Work starts \(clock(s))")
        case let (nil, e?): lines.append("- Work ends \(clock(e))")
        default: break
        }
        if let c = r.caffeineCutoff { lines.append("- No caffeine after \(clock(c))") }
        let training = r.training.trimmingCharacters(in: .whitespacesAndNewlines)
        if !training.isEmpty { lines.append("- Training: \(training)") }
        let meals = r.meals.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meals.isEmpty { lines.append("- Meals: \(meals)") }
        for e in r.entries {
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let detail = e.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- \(title)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        guard !lines.isEmpty else { return nil }
        return "THEIR ROUTINES — hard constraints. Every plan, time and directive you give must fit inside "
            + "these; never schedule anything that collides with them:\n" + lines.joined(separator: "\n")
    }
}
