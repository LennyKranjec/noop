import Foundation

// AlphaprogPlanImporter.swift — the Alphaprog PLAN export (programs → day templates → exercises), for Telos
// Lift (DESIGN_V2 decision 16). The workout HISTORY export is `AlphaprogImporter`; this is its sibling for the
// file Alphaprog writes from the plan editor.
//
// THE SHAPE, exactly as the owner's `alphaprog_plans.csv` fixture has it (UTF-8 with a BOM, CRLF, `;`):
//
//   Lower;2026-01-05                                   ← program header: name ; date   (UNQUOTED)
//   "Tag 1 · Lower A (Di)"                             ← day header: one quoted field, "Tag N · <name>"
//   "1. Beinpresse · Maschine";"4 Sätze";"10 Wdh"      ← exercise: "<n>. <name> · <equipment>" ; sets ; reps
//   …
//   (blank line)                                       ← between programs
//
// READ THE BYTES THROUGH `ImportText.decode`, AND SPLIT LINES AT THE SCALAR LEVEL. CRLF broke the history
// importer once already: `split(separator: "\n")` sees a CRLF document as ONE line because Swift joins CR+LF
// into one Character (see `AlphaprogImporter.lines(of:)`). `decode` normalises CRLF → LF and strips the BOM,
// and the line split here reuses `AlphaprogImporter.lines(of:)` so both readers of Alphaprog files share the
// one spelling that works, even if a caller hands in undecoded text.
//
// TOLERANT, like every importer here: a line that matches nothing is skipped and COUNTED (`Diagnostics`), never
// fatal, so "no programs found" can say what the scanner saw. A rep target is a number or a range ("8-12 Wdh");
// a set count is "4 Sätze" / "1 Satz" (or English "sets"). A field that does not parse is nil, not a default.

public enum AlphaprogPlanImporter {

    public struct Exercise: Equatable, Sendable {
        /// The number the export printed before the name (1-based), nil when absent.
        public let position: Int?
        public let name: String
        /// "Maschine", "Kabelzug", "Körpergewicht" — the segment after the first "·", nil when absent.
        public let equipment: String?
        public let targetSets: Int?
        public let targetRepsLow: Int?
        public let targetRepsHigh: Int?

        public init(position: Int?, name: String, equipment: String?, targetSets: Int?,
                    targetRepsLow: Int?, targetRepsHigh: Int?) {
            self.position = position
            self.name = name
            self.equipment = equipment
            self.targetSets = targetSets
            self.targetRepsLow = targetRepsLow
            self.targetRepsHigh = targetRepsHigh
        }
    }

    public struct Day: Equatable, Sendable {
        /// "Tag 1" → 1; nil when the header carried no day number.
        public let dayNumber: Int?
        /// "Lower A (Di)"
        public let name: String
        public let exercises: [Exercise]

        public init(dayNumber: Int?, name: String, exercises: [Exercise]) {
            self.dayNumber = dayNumber
            self.name = name
            self.exercises = exercises
        }
    }

    public struct Program: Equatable, Sendable {
        public let name: String
        /// The date printed after the name, verbatim ("2026-01-05"); nil when absent.
        public let date: String?
        public let days: [Day]

        public init(name: String, date: String?, days: [Day]) {
            self.name = name
            self.date = date
            self.days = days
        }
    }

    public struct Diagnostics: Equatable, Sendable {
        public let programHeaders: Int
        public let dayHeaders: Int
        public let exerciseRows: Int
        /// Non-empty lines that matched none of the three shapes.
        public let skippedLines: Int
        public let firstLine: String

        public init(programHeaders: Int = 0, dayHeaders: Int = 0, exerciseRows: Int = 0, skippedLines: Int = 0,
                    firstLine: String = "") {
            self.programHeaders = programHeaders
            self.dayHeaders = dayHeaders
            self.exerciseRows = exerciseRows
            self.skippedLines = skippedLines
            self.firstLine = firstLine
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let programs: [Program]
        public let diagnostics: Diagnostics

        public init(programs: [Program], diagnostics: Diagnostics) {
            self.programs = programs
            self.diagnostics = diagnostics
        }

        public var dayCount: Int { programs.reduce(0) { $0 + $1.days.count } }
    }

    /// Decode the picked file's bytes (BOM, UTF-16, cp1252 — `ImportText.decode`) and parse. Nil only when the
    /// bytes are not text at all.
    public static func parse(data: Data) -> Parsed? {
        guard let decoded = ImportText.decode(data) else { return nil }
        return parse(decoded.text)
    }

    public static func parse(_ text: String) -> Parsed {
        var programs: [Program] = []
        var programName: String?
        var programDate: String?
        var days: [Day] = []
        var dayName: String?
        var dayNumber: Int?
        var exercises: [Exercise] = []
        var headers = 0, dayHeaders = 0, rows = 0, skipped = 0
        var firstLine = ""

        func closeDay() {
            guard let name = dayName else { return }
            days.append(Day(dayNumber: dayNumber, name: name, exercises: exercises))
            dayName = nil
            dayNumber = nil
            exercises = []
        }
        func closeProgram() {
            closeDay()
            if let name = programName, !days.isEmpty {
                programs.append(Program(name: name, date: programDate, days: days))
            }
            programName = nil
            programDate = nil
            days = []
        }

        for raw in AlphaprogImporter.lines(of: text) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty { continue }
            if firstLine.isEmpty { firstLine = String(line.prefix(200)) }

            if !line.hasPrefix("\"") {
                // Program header: `Name;2026-01-05` (the date is optional).
                let parts = line.split(separator: ";", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // A NAME (it has a letter — a history grid row `1;30;10` or `#;KG;WDH` has none) and, when
                // there is a second field, a date: anything else is not this file's program header.
                if let name = parts.first, name.contains(where: { $0.isLetter }),
                   parts.count == 1 || parts[1].isEmpty || looksLikeDate(parts[1]) {
                    closeProgram()
                    programName = name
                    programDate = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                    headers += 1
                } else {
                    skipped += 1
                }
                continue
            }

            let fields = quotedFields(line)
            if fields.count == 1, let day = parseDayHeader(fields[0]) {
                closeDay()
                dayName = day.name
                dayNumber = day.number
                dayHeaders += 1
                // A day before any program header still belongs somewhere: an unnamed program is not
                // invented; the day is kept under an empty name and dropped with it (counted as skipped).
                if programName == nil { skipped += 1 }
                continue
            }
            if fields.count >= 1, dayName != nil, let ex = parseExercise(fields) {
                exercises.append(ex)
                rows += 1
                continue
            }
            skipped += 1
        }
        closeProgram()

        return Parsed(programs: programs,
                      diagnostics: Diagnostics(programHeaders: headers, dayHeaders: dayHeaders, exerciseRows: rows,
                                               skippedLines: skipped, firstLine: firstLine))
    }

    // MARK: - Lines

    /// `Tag 1 · Lower A (Di)` → (1, "Lower A (Di)"). A header without the "Tag N ·" prefix is still a day when
    /// it does not start with an exercise number ("Lower A (Di)" alone).
    static func parseDayHeader(_ field: String) -> (number: Int?, name: String)? {
        let segments = field.split(separator: "·", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = segments.first, !first.isEmpty else { return nil }
        if segments.count >= 2 {
            let words = first.split(separator: " ")
            if words.count == 2, ["tag", "day"].contains(words[0].lowercased()), let n = Int(words[1]) {
                let name = segments.dropFirst().joined(separator: " · ")
                if name.isEmpty { return nil }
                return (number: n, name: name)
            }
        }
        // Not "Tag N · …": a day only if it is not an exercise title ("1. Beinpresse · Maschine").
        if leadingNumber(first) != nil { return nil }
        return (number: nil, name: field.trimmingCharacters(in: .whitespaces))
    }

    /// `"1. Beinpresse · Maschine";"4 Sätze";"10 Wdh"`.
    static func parseExercise(_ fields: [String]) -> Exercise? {
        let title = fields[0].trimmingCharacters(in: .whitespaces)
        var position: Int?
        var rest = Substring(title)
        if let lead = leadingNumber(title) {
            position = lead.0
            rest = lead.1
        }
        let segments = rest.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = segments.first, !name.isEmpty else { return nil }
        // An exercise line must carry its number or at least one plan column; a bare quoted word is not one.
        guard position != nil || fields.count >= 2 else { return nil }
        let equipment = segments.count > 1 && !segments[1].isEmpty ? segments[1] : nil
        let sets = fields.count > 1 ? leadingInt(fields[1]) : nil
        let reps = fields.count > 2 ? repRange(fields[2]) : nil
        return Exercise(position: position, name: name, equipment: equipment, targetSets: sets,
                        targetRepsLow: reps?.low, targetRepsHigh: reps?.high)
    }

    /// "12. Curls" → (12, "Curls"). Requires digits followed by a dot.
    static func leadingNumber(_ s: String) -> (Int, Substring)? {
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let after = s.dropFirst(digits.count)
        guard after.first == "." else { return nil }
        return (n, after.dropFirst())
    }

    /// `2026-01-05` — digits and dashes, a four-digit year first.
    static func looksLikeDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        return parts.count == 3 && parts[0].count == 4 && parts.allSatisfy { p in p.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// "4 Sätze" → 4. Nil without a leading number.
    static func leadingInt(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    /// "10 Wdh" → (10, 10); "8-12 Wdh" / "8–12 Wdh" → (8, 12). Nil without a number.
    static func repRange(_ s: String) -> (low: Int, high: Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let head = t.prefix { ($0.isASCII && $0.isNumber) || $0 == "-" || $0 == "–" || $0 == " " }
        let parts = head.split(whereSeparator: { $0 == "-" || $0 == "–" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { Int($0) }
        guard let low = parts.first else { return nil }
        let high = parts.count > 1 ? parts[1] : low
        return (min(low, high), max(low, high))
    }

    /// The `"a";"b";"c"` fields of a line, unquoted (a doubled quote inside a field is an escaped quote).
    static func quotedFields(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                if inQuotes { out.append(current); current = "" }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(ch)
            }
            i += 1
        }
        return out
    }
}
