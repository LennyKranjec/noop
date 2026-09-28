import Foundation

// AlphaprogImporter.swift — the Alphaprog CSV.
//
// Swift twin of the Android `com.noop.ingest.AlphaprogImporter`. Alphaprog exports a training log as a
// semicolon-separated file that is not really a table: it is a printed workout, with a header line per
// session, a title line per exercise, and a tiny three-column grid of sets between them. A generic CSV
// reader makes nonsense of it, so this is a small state machine that reads it the way a person would.
//
// THE SHAPE, in the order it appears:
//
//   "Upper B (Do) · Tag 2 · Woche 32 · Upper";"2026-09-14 13:44 Uhr";"53 Min."
//   "1. Rudern mit Brustauflage eng · Maschine · 10 Wdh"
//   #;KG;WDH
//   1;30;10
//   2;27,5;7
//   3;-;-
//
// GERMAN NUMBERS AND A GERMAN CLOCK. Weights use a comma decimal separator, and a dash marks a set that
// was planned and not done. Both are parsed here rather than pushed onto the shared lifting parser,
// because they are this exporter's conventions and not lifting's.
//
// A SESSION HEADER HAS THREE DURATION FORMS AND A ONE- OR TWO-DIGIT CLOCK. "53 Min.", "1:19 Std." and
// "45 s" all appear, and a session that started at "5:18 Uhr" writes one digit. The first cut of the
// Android parser accepted only `HH:MM` and `N Min.` — so it matched 26 of the file's 96 sessions, and
// the other 70 sessions' exercises were appended to whichever session HAD matched. The result was a
// single fabricated 190-exercise day holding most of a year's training, which is exactly the kind of
// failure that looks like data rather than like a bug: the totals were plausible, the days were not.
// Every form the export actually writes is matched here.
//
// THE SET GRID COMES IN THREE FLAVOURS, and only one of them is volume load:
//
//   #;KG;WDH   weight × repetitions  → volume load, the figure the muscle view reads
//   #;KG;SEK   weight × seconds      → a loaded hold; the second column is TIME, not reps
//   #;MIN.     minutes               → a timed effort with no external load at all
//
// Only the first contributes kilograms. Multiplying 30 kg by 45 SECONDS would produce "1,350 kg" of
// volume from a 45-second hold, which is not a smaller or larger number than the truth — it is a
// different quantity wearing the same unit. The other two are counted as sets that happened and
// contribute no volume, which is the honest reading of what the file says.
//
// AN UNPERFORMED SET IS NOT A ZERO. "3;-;-" is a row the app printed and the wearer left empty; it
// contributes no volume and is not counted as a set. Treating it as 0 kg × 0 reps would be the same
// arithmetic and a different claim — it would say they did a set of nothing.
//
// TWO KNOWN UNDER-READINGS, documented rather than silently "improved", because changing either moves
// already-imported figures and neither is what this change is about:
//
//   * "1;+10;11" is a bodyweight exercise with ten kilograms ADDED (dips, pull-ups, hyperextensions).
//     `Double("+10")` is 10, so it is read as a flat 10 kg and the volume is the added weight only, not
//     bodyweight + 10. That UNDER-states the load; it never invents one. Reading it as bodyweight + 10
//     would need a bodyweight the file does not carry, which is the imputation this file refuses.
//   * "1 Std." — an hour with no minutes — falls through the `H:MM` branch (no colon), and its unit
//     "std." starts with "s", so the seconds branch reads it as 1 ÷ 60 = 0 minutes. That session's END
//     is its start; its exercises and volume are unaffected. One session in the wearer's file.

public enum AlphaprogImporter {

    /// Shown to the wearer, and the label on the import result.
    public static let sourceLabel = "Alphaprog"

    /// Stored under the SAME source as every other lifting import.
    ///
    /// Alphaprog is a different exporter, not a different kind of training: keeping it here means the
    /// muscle view, the workouts list and the level's muscle term all read one series rather than
    /// needing to know which app the wearer happened to log in.
    public static let sourceId = LiftingImporter.sourceId

    /// One performed set.
    ///
    /// `reps` is repetitions and nothing else. A loaded hold's seconds and a timed effort's minutes are
    /// real work and are recorded as `holdSeconds` / `minutes`, but they never become reps: the whole
    /// point of the distinction is that `weight × seconds` is not a mass, and calling it one would put a
    /// fabricated figure into the muscle view under the same unit as a real one.
    public struct Set: Equatable, Sendable {
        public let weightKg: Double
        public let reps: Int
        public let holdSeconds: Int
        public let minutes: Double
        /// The file wrote this load as an ADDITION to bodyweight (`+10`), not as the whole load.
        ///
        /// `weightKg` is then the added weight ALONE — ten kilograms, not bodyweight plus ten — which is
        /// the under-reading the file header already documents and deliberately does not change, because
        /// changing it would move volume figures already imported and the bodyweight it would need is not
        /// in the file.
        ///
        /// The flag exists because a reader that needs the ABSOLUTE load cannot use that figure at all.
        /// An estimated 1RM from "10 kg × 11" on a hyperextension is not a smaller number than the truth,
        /// it is a different lift, and it would sit in a progression list next to real machine loads
        /// looking like one. `StrengthProgression` excludes these sets and says how many it excluded.
        /// Volume load is unaffected: `volumeKg` does not read this.
        public let addedToBodyweight: Bool

        public init(weightKg: Double, reps: Int, holdSeconds: Int = 0, minutes: Double = 0,
                    addedToBodyweight: Bool = false) {
            self.weightKg = weightKg
            self.reps = reps
            self.holdSeconds = holdSeconds
            self.minutes = minutes
            self.addedToBodyweight = addedToBodyweight
        }

        /// Kilograms of volume load. Zero for anything that was not weight × repetitions.
        public var volumeKg: Double { reps > 0 ? weightKg * Double(reps) : 0 }
    }

    /// One exercise inside a session, with only the sets that were actually done.
    public struct Exercise: Equatable, Sendable {
        public let name: String
        public let sets: [Set]

        public init(name: String, sets: [Set]) {
            self.name = name
            self.sets = sets
        }
    }

    /// One parsed session, before it is turned into the shared `LiftingSession`.
    public struct Workout: Equatable, Sendable {
        public let title: String
        public let start: Date
        public let end: Date
        public let exercises: [Exercise]

        public init(title: String, start: Date, end: Date, exercises: [Exercise]) {
            self.title = title
            self.start = start
            self.end = end
            self.exercises = exercises
        }

        public var volumeLoadKg: Double {
            exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.volumeKg } }
        }
        public var setCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
        public var totalReps: Int {
            exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.reps } }
        }
        public var topSetKg: Double? {
            exercises.flatMap(\.sets).map(\.weightKg).max()
        }

        /// Every performed set, flattened in the order the file printed them, for the shared set list.
        ///
        /// A LOADED HOLD AND A TIMED EFFORT CARRY NO REPS, so they land with `reps: nil` rather than with
        /// the seconds or the minutes in the rep field — the same distinction this parser exists to keep.
        /// A timed effort has no external load either, so its weight is absent too rather than zero.
        var setRecords: [LiftingSetRecord] {
            exercises.flatMap { exercise in
                exercise.sets.map { set in
                    LiftingSetRecord(
                        exercise: exercise.name,
                        weightKg: set.weightKg > 0 ? set.weightKg : nil,
                        reps: set.reps > 0 ? set.reps : nil,
                        // Alphaprog prints no warm-up marker: every row in the grid is a set the wearer
                        // logged. Guessing which were warm-ups from the weights would invent a
                        // distinction the file does not make.
                        isWarmup: false,
                        addedToBodyweight: set.addedToBodyweight)
                }
            }
        }

        /// Volume per exercise name, which is what the shared muscle split is taken from.
        var volumeByExercise: [String: Double] {
            var out: [String: Double] = [:]
            for exercise in exercises {
                let volume = exercise.sets.reduce(0) { $0 + $1.volumeKg }
                if volume > 0 { out[exercise.name, default: 0] += volume }
            }
            return out
        }
    }

    /// What the parse SAW, whether or not it produced anything.
    ///
    /// Exists because "no sessions found" is the same sentence for a file that is not an Alphaprog
    /// export, a file that decoded as mojibake, and a file whose bytes never arrived — and the wearer
    /// reading that sentence on a phone has no other way to tell them apart. Counting what each scanner
    /// recognised turns the message into a diagnosis: 100 headers and 0 set rows is a delimiter
    /// problem, 0 headers with a readable first line is the wrong file, 0 headers and a first line of
    /// `ÿþ"` is an encoding problem.
    ///
    /// `setRows` counts rows that had the SHAPE of a grid row (an index and its columns), including the
    /// `-;-` ones that contribute no set: the question it answers is "did the scanner see the grid",
    /// not "how much was lifted".
    public struct Diagnostics: Equatable, Sendable {
        public let sessionHeaders: Int
        public let exerciseTitles: Int
        public let setRows: Int
        /// The first non-empty line, BOM-stripped and capped, so a wrong-file report can quote it.
        public let firstLine: String
        /// The delimiter this file was read with (`;` or `,`).
        public let delimiter: String

        public init(sessionHeaders: Int = 0,
                    exerciseTitles: Int = 0,
                    setRows: Int = 0,
                    firstLine: String = "",
                    delimiter: String = ";") {
            self.sessionHeaders = sessionHeaders
            self.exerciseTitles = exerciseTitles
            self.setRows = setRows
            self.firstLine = firstLine
            self.delimiter = delimiter
        }
    }

    /// What a parse produced, including what it could not place.
    public struct Parsed: Equatable, Sendable {
        public let workouts: [Workout]
        /// Exercise names the attribution table has no muscles for, so the wearer can see the gap.
        public let unattributed: [String]
        /// What the scanners recognised. Defaulted so the Kotlin-parity shape and every existing call
        /// site that builds an empty `Parsed` are undisturbed.
        public let diagnostics: Diagnostics

        public init(workouts: [Workout], unattributed: [String], diagnostics: Diagnostics = Diagnostics()) {
            self.workouts = workouts
            self.unattributed = unattributed
            self.diagnostics = diagnostics
        }
    }

    /// Which grid the rows below a header belong to.
    ///
    /// Carried as state through the parse because a row `1;30;45` is identical in every grid; only the
    /// header two lines above says whether the 45 is repetitions or seconds.
    private enum Grid {
        case reps, seconds, minutes, unknown
    }

    /// Which separator and decimal mark this FILE uses.
    ///
    /// The two travel together: an exporter writing `;` writes German decimal commas, and one writing
    /// `,` cannot (the comma is taken) so it writes dots. Carried as one value so no code path can pair
    /// a comma delimiter with a comma decimal and read `27,5` as two fields.
    struct Dialect: Equatable {
        let delimiter: Character
        let decimalComma: Bool

        /// What the export in hand actually is, and the default everywhere.
        static let german = Dialect(delimiter: ";", decimalComma: true)
        static let dotted = Dialect(delimiter: ",", decimalComma: false)
    }

    /// The file's lines, however it terminates them.
    ///
    /// NOT `split(separator: "\n")`. A Swift `Character` is an extended grapheme cluster and Unicode
    /// joins CR+LF into ONE cluster, so in a CRLF document no Character ever equals `"\n"` and
    /// `split(separator: "\n")` returns the WHOLE FILE as a single element. Alphaprog writes CRLF, so
    /// this parser read the wearer's real 4 859-line export as one line: `quotedFields` then swept up
    /// every quoted field in the file, the first three of them happened to look like a valid session
    /// header, and the result was one header, zero exercises and — because a session with no exercises
    /// is dropped — zero workouts. "No sessions found", about a file with a hundred sessions in it.
    ///
    /// The repo's own test fixture was LF-only, which is why nothing caught it.
    ///
    /// `components(separatedBy: .newlines)` is `CharacterSet`-based and therefore SCALAR-level, so it
    /// splits LF, CRLF (into two pieces, the empty one between them being skipped as a blank line like
    /// any other) and a lone CR alike. On an LF-only file it returns exactly what `split` returned.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    /// Sniff the dialect from the file.
    ///
    /// DELIBERATELY BIASED TOWARDS SEMICOLON. The grid header names the delimiter outright (`#;KG;WDH`
    /// vs `#,KG,WDH`) and appears within the first few lines of any real export, so that check decides
    /// almost every file on its own. The count fallback only runs for a file with no grid at all, and
    /// ties go to semicolon — so a file today's parser reads, tomorrow's reads identically.
    static func sniffDialect(_ text: String) -> Dialect {
        sniffDialect(lines: lines(of: text))
    }

    static func sniffDialect(lines: [String]) -> Dialect {
        var semis = 0, commas = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.hasPrefix("#;") { return .german }
            if t.hasPrefix("#,") { return .dotted }
            var inQuotes = false
            for ch in t {
                if ch == "\"" { inQuotes.toggle(); continue }
                if inQuotes { continue }
                if ch == ";" { semis += 1 } else if ch == "," { commas += 1 }
            }
        }
        return semis >= commas ? .german : .dotted
    }

    /// The set grid's own header, which carries no data but names the grid.
    /// Checked by first character before anything is built, because this runs on every line of the file.
    private static func grid(of line: String, _ dialect: Dialect) -> Grid? {
        let d = dialect.delimiter
        guard line.first == "#", line.dropFirst().first == d else { return nil }
        switch String(line.dropFirst(2)) {
        case "KG\(d)WDH": return .reps
        case "KG\(d)SEK": return .seconds
        case "MIN.": return .minutes
        default: return .unknown
        }
    }

    /// Parse the whole export.
    ///
    /// Never throws on a malformed line: a log the wearer spent months filling in should import the
    /// sessions it can read rather than fail on one of them. Lines that match nothing are skipped in
    /// silence — the format has blank lines, a BOM and section spacing that carry no data.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Parsed {
        var workouts: [Workout] = []
        var unattributed: [String] = []
        var seenUnattributed = Swift.Set<String>()

        var title: String?
        var start = Date(timeIntervalSince1970: 0)
        var end = Date(timeIntervalSince1970: 0)
        var haveStart = false
        var exercises: [Exercise] = []
        var exerciseName: String?
        var sets: [Set] = []
        // Defaults to reps: every grid in the file but two is weight × repetitions, and a row arriving
        // before any header at all is far likelier to be a stray than an isometric.
        var grid = Grid.reps
        // Split ONCE, and not on "\n" — see `lines(of:)` for why that spelling read a CRLF export as a
        // single line and reported a hundred sessions as none.
        let sourceLines = lines(of: text)
        let dialect = sniffDialect(lines: sourceLines)
        var headerCount = 0, titleCount = 0, rowCount = 0
        var firstLine = ""

        func closeExercise() {
            guard let name = exerciseName else { return }
            exercises.append(Exercise(name: name, sets: sets))
            if MuscleAttribution.muscles(for: name).isEmpty, seenUnattributed.insert(name).inserted {
                unattributed.append(name)
            }
            exerciseName = nil
            sets = []
        }

        func closeWorkout() {
            closeExercise()
            guard let t = title else { return }
            if !exercises.isEmpty {
                workouts.append(Workout(title: t, start: start, end: end, exercises: exercises))
            }
            title = nil
            exercises = []
            haveStart = false
        }

        for raw in sourceLines {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty { continue }
            if firstLine.isEmpty { firstLine = String(line.prefix(200)) }

            if let header = parseSessionHeader(line, timeZone: timeZone) {
                closeWorkout()
                title = header.title
                start = header.start
                end = header.start.addingTimeInterval(Double(header.durationMinutes) * 60)
                haveStart = header.valid
                grid = .reps
                headerCount += 1
                continue
            }
            if let name = parseExerciseTitle(line) {
                closeExercise()
                exerciseName = name
                titleCount += 1
                continue
            }
            if let g = self.grid(of: line, dialect) {
                grid = g
                continue
            }

            switch grid {
            case .reps:
                guard let row = parseSetRow(line, delimiter: dialect.delimiter) else { break }
                rowCount += 1
                if let weight = number(row.1, decimalComma: dialect.decimalComma),
                   let reps = Int(row.2.trimmingCharacters(in: .whitespaces)),
                   reps > 0 {
                    // A dash in either column is a set that was printed and not done.
                    //
                    // A LEADING PLUS is recorded, not read away. `Double("+10")` is 10 and the volume load
                    // keeps reading it that way (see `Set.addedToBodyweight`); the flag is what lets a
                    // reader that needs the absolute load abstain instead of treating ten added kilograms
                    // as a ten-kilogram lift.
                    sets.append(Set(weightKg: weight,
                                    reps: reps,
                                    addedToBodyweight: isBodyweightAdded(row.1)))
                }
            case .seconds:
                // A loaded hold. The weight is real and the seconds are real; their PRODUCT is not a
                // mass, so it is kept out of volume rather than converted into one.
                guard let row = parseSetRow(line, delimiter: dialect.delimiter) else { break }
                rowCount += 1
                if let weight = number(row.1, decimalComma: dialect.decimalComma),
                   let seconds = Int(row.2.trimmingCharacters(in: .whitespaces)), seconds > 0 {
                    sets.append(Set(weightKg: weight, reps: 0, holdSeconds: seconds))
                }
            case .minutes:
                guard let row = parseTwoColumnRow(line, delimiter: dialect.delimiter) else { break }
                rowCount += 1
                if let minutes = number(row.1, decimalComma: dialect.decimalComma), minutes > 0 {
                    sets.append(Set(weightKg: 0, reps: 0, minutes: minutes))
                }
            case .unknown:
                // A grid this parser has never seen. Its rows are skipped rather than guessed at, and
                // the exercise is still recorded — "they did this, with no figure I can read" is true,
                // where reading its second column as reps would be a number invented here.
                break
            }
            _ = haveStart
        }
        closeWorkout()

        return Parsed(
            workouts: workouts.sorted { $0.start < $1.start },
            unattributed: unattributed,
            diagnostics: Diagnostics(
                sessionHeaders: headerCount,
                exerciseTitles: titleCount,
                setRows: rowCount,
                firstLine: firstLine,
                delimiter: String(dialect.delimiter)))
    }

    /// Turn parsed workouts into the shared session shape the rest of the app already stores.
    public static func toSessions(_ parsed: Parsed) -> [LiftingSession] {
        parsed.workouts
            .filter { $0.start.timeIntervalSince1970 > 0 }
            .map { w in
                LiftingSession(
                    start: w.start,
                    end: w.end >= w.start ? w.end : w.start,
                    volumeLoadKg: w.volumeLoadKg,
                    setCount: w.setCount,
                    exerciseCount: w.exercises.count,
                    totalReps: w.totalReps,
                    topSetKg: w.topSetKg,
                    title: w.title,
                    muscleVolumeKg: LiftingImporter.muscleVolume(byExercise: w.volumeByExercise),
                    sets: w.setRecords)
            }
    }

    // MARK: - Lines
    //
    // Hand-written scanners rather than regular expressions. The Kotlin twin uses regex; here the same
    // shapes are matched by splitting on the quotes and semicolons the format actually uses, which is
    // easier to check against a real line and does not depend on `NSRegularExpression`'s behaviour with
    // the non-ASCII separators (·) this file is full of.

    struct SessionHeader {
        let title: String
        let start: Date
        let durationMinutes: Int
        let valid: Bool
    }

    /// `"Title";"2026-09-14 13:44 Uhr";"53 Min."`
    static func parseSessionHeader(_ line: String, timeZone: TimeZone = .current) -> SessionHeader? {
        guard line.hasPrefix("\"") else { return nil }
        let fields = quotedFields(line)
        guard fields.count >= 3 else { return nil }
        let stamp = fields[1].trimmingCharacters(in: .whitespaces)
        // `yyyy-MM-dd H:mm` with anything after it ("Uhr"), and the hour may be one digit.
        let parts = stamp.split(separator: " ")
        guard parts.count >= 2, let date = parseStart(String(parts[0]), String(parts[1]), timeZone: timeZone)
        else { return nil }
        return SessionHeader(
            title: fields[0].trimmingCharacters(in: .whitespaces),
            start: date,
            durationMinutes: durationMinutes(fields[2]),
            valid: true)
    }

    /// An exercise title line: `"3. Brustpresse · Maschine · 10 Wdh"`.
    ///
    /// The title carries equipment and a rep target after separators; only the name matters for
    /// attribution, and keeping the rest would make every variant its own exercise.
    static func parseExerciseTitle(_ line: String) -> String? {
        guard line.hasPrefix("\""), line.hasSuffix("\""), line.count > 2 else { return nil }
        let inner = String(line.dropFirst().dropLast())
        // A session header has two more quoted fields; an exercise line has exactly one.
        guard !inner.contains("\"") else { return nil }
        guard let dot = inner.firstIndex(of: "."), Int(inner[inner.startIndex..<dot]) != nil else { return nil }
        let after = inner[inner.index(after: dot)...]
        let name = after.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `1;30;10` — index, weight, reps.
    static func parseSetRow(_ line: String, delimiter: Character = ";") -> (Int, String, String)? {
        let parts = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (index, parts[1], parts[2])
    }

    /// `1;12,5` — index, minutes. Used by the minutes grid.
    static func parseTwoColumnRow(_ line: String, delimiter: Character = ";") -> (Int, String)? {
        let parts = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (index, parts[1])
    }

    /// The `"a";"b";"c"` fields of a line, unquoted.
    private static func quotedFields(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                if inQuotes { out.append(current); current = "" }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(ch)
            }
        }
        return out
    }

    /// `1.234,5` or `27,5` or `30` — comma decimal, optional thousands dot. A dash is not a number.
    public static func germanNumber(_ raw: String) -> Double? {
        number(raw, decimalComma: true)
    }

    /// Whether a weight column was written as an ADDITION to bodyweight: `+10`.
    ///
    /// Read off the RAW column rather than inferred after parsing, because the plus is gone by then —
    /// `Double("+10")` and `Double("10")` are the same value, and that is exactly the distinction a
    /// reader of absolute loads needs back. Both dialects write the plus the same way.
    static func isBodyweightAdded(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
    }

    /// A weight, a rep target or a duration column, in the file's own number convention.
    ///
    /// `decimalComma: false` is the comma-delimited dialect, where the decimal mark is a dot and a
    /// thousands separator cannot appear unquoted at all (it would be the delimiter) — so the string is
    /// taken as written rather than having its dots stripped, which is what would turn `27.5` into 275.
    ///
    /// A DASH IS NOT A ZERO in either dialect: `-` is a row the app printed and the wearer left empty.
    /// `+10` IS accepted and read as 10, which is what `Double` does with a leading plus. See the note
    /// on bodyweight-added loads in the file header.
    public static func number(_ raw: String, decimalComma: Bool) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "-" || t == "–" { return nil }
        guard decimalComma else { return Double(t) }
        return Double(t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
    }

    /// `53 Min.`, `1:19 Std.` or `45 s`, in whole minutes.
    ///
    /// Zero for a form this does not recognise, which makes the session a zero-length one rather than
    /// dropping it: the exercises are the data, and a session with an unreadable duration still happened.
    public static func durationMinutes(_ raw: String) -> Int {
        let t = raw.trimmingCharacters(in: .whitespaces)
        // `1:19 Std.`
        if let colon = t.firstIndex(of: ":") {
            let hours = Int(t[t.startIndex..<colon])
            let rest = t[t.index(after: colon)...].prefix(2)
            if let hours, let minutes = Int(rest) { return hours * 60 + minutes }
        }
        let digits = String(t.prefix { $0.isNumber })
        guard let value = Int(digits), !digits.isEmpty else { return 0 }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        if unit.hasPrefix("min") { return value }
        // Rounded DOWN to the minute, so a 45-second session is a zero-length one rather than being
        // rounded up into a minute it did not last.
        if unit.hasPrefix("s") { return value / 60 }
        return 0
    }

    /// `HH:mm` or `H:mm` — the exporter writes a single-digit hour before ten.
    static func parseStart(_ date: String, _ time: String, timeZone: TimeZone) -> Date? {
        let dateParts = date.split(separator: "-").compactMap { Int($0) }
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var c = DateComponents()
        c.year = dateParts[0]
        c.month = dateParts[1]
        c.day = dateParts[2]
        c.hour = timeParts[0]
        c.minute = timeParts[1]
        return calendar.date(from: c)
    }
}
