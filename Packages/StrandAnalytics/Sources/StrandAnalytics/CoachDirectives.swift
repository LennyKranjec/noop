import Foundation

// CoachDirectives.swift — letting the system act, not just talk.
//
// Pure + deterministic so it is unit-testable without a model or an app target, and so it behaves
// identically to the Android twin `com.noop.ai.CoachDirectives` (the cross-platform parity contract).
//
// The coach can create and delete reminders. It does that by writing a directive into its reply, which
// this strips out before the wearer sees it:
//
//     [[reminder add 22:00 daily Bedtime — you said you wanted eight hours]]
//     [[reminder del bedtime]]
//
// WHY A TEXT DIRECTIVE AND NOT TOOL-CALLING. Proper function calling needs the model to emit
// well-formed JSON inside a tool block, and needs the runtime to feed the result back as a tool
// message. The on-device engine has no tool channel at all, and a 0.8B model asked for JSON produces
// something JSON-shaped about as often as not. A single bracketed line is the largest instruction this
// model follows reliably, and a malformed one degrades to "nothing happened" rather than to a crash.
//
// WHAT THIS DELIBERATELY DOES NOT DO: act on anything it is not certain about. A directive that does
// not parse is dropped and REPORTED as dropped, so the wearer is never told a reminder exists because
// the model said the words. The store is what decides whether something was created; this only asks.

/// How often a reminder fires. The rule is evaluated per day, so no schedule is ever "every 36h".
public enum ReminderRepeat: String, Equatable, Codable, CaseIterable, Sendable {
    case daily = "DAILY"
    case weekdays = "WEEKDAYS"
    case weekends = "WEEKENDS"
    case weekly = "WEEKLY"

    /// Parse a coach-written or stored keyword. Unknown values fall back to `.daily`, never throw.
    public static func parse(_ raw: String?) -> ReminderRepeat {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.rawValue.lowercased() == trimmed } ?? .daily
    }
}

public enum CoachDirectives {

    /// The reason is what the notification gets written from, not an essay. Bounded so the prompt that
    /// carries it stays small.
    public static let maxContextChars = 160

    /// One request the model made. `add` and `delete` are applied; `unparsed` is reported, not applied.
    public enum Request: Equatable, Sendable {
        case add(minuteOfDay: Int, repeats: ReminderRepeat, context: String)
        case delete(reference: String)
        case unparsed(raw: String)
    }

    /// The reply with every directive removed, plus what those directives asked for.
    public struct Parsed: Equatable, Sendable {
        public let text: String
        public let requests: [Request]
    }

    /// Pull the directives out of `reply`.
    ///
    /// The returned text is what the wearer reads: directives gone, and the whitespace they leave
    /// behind collapsed so a reminder created mid-sentence does not leave a gap or a stranded blank
    /// line. Everything else is untouched — this must never rewrite the coach's actual words.
    ///
    /// Scanned by hand rather than with NSRegularExpression: the Linux ICU engine differs from
    /// Apple's, and a parity contract should not rest on which platform's regex is in the build.
    public static func parse(_ reply: String) -> Parsed {
        var requests: [Request] = []
        var out = ""
        var rest = Substring(reply)

        while let open = rest.range(of: "[[") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "]]") else { break }
            out += rest[..<open.lowerBound]
            let body = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            requests.append(request(body))
            rest = afterOpen[close.upperBound...]
        }
        out += rest

        return Parsed(text: tidy(out), requests: requests)
    }

    /// One directive's body — what was between the brackets, without them.
    ///
    /// Public because the streaming path never has the whole reply in one string: the chat hides
    /// directives with a streaming filter as the tokens arrive and hands the captured bodies here.
    public static func request(_ body: String) -> Request {
        let words = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3, words[0].lowercased() == "reminder" else {
            return .unparsed(raw: body)
        }
        switch words[1].lowercased() {
        case "add", "new", "create":
            return parseAdd(Array(words.dropFirst(2)), raw: body)
        case "del", "delete", "remove":
            return .delete(reference: words.dropFirst(2).joined(separator: " "))
        default:
            return .unparsed(raw: body)
        }
    }

    private static func parseAdd(_ rest: [String], raw: String) -> Request {
        guard let first = rest.first, let minute = minuteOfDay(first) else {
            return .unparsed(raw: raw)
        }
        let repeatWord = rest.count > 1 ? rest[1] : nil
        let known = ReminderRepeat.allCases.first {
            $0.rawValue.lowercased() == (repeatWord ?? "").lowercased()
        }
        // The repeat keyword is optional; without one the rest is all context and the rule is daily.
        let contextWords = known == nil ? Array(rest.dropFirst(1)) : Array(rest.dropFirst(2))
        let context = contextWords
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\u{2014}-:"))
        guard !context.isEmpty else { return .unparsed(raw: raw) }

        return .add(
            minuteOfDay: minute,
            repeats: known ?? .daily,
            context: String(context.prefix(maxContextChars))
        )
    }

    /// `HH:mm` or `H:mm`, 24-hour, as minutes since midnight — or nil.
    ///
    /// A time outside the clock is a MODEL ERROR, not a preference: clamping 25:00 to 23:59 would
    /// schedule a reminder the wearer never asked for at a time the coach never meant. "10pm" is
    /// refused for the same reason — it would otherwise parse as 10:00.
    private static func minuteOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count >= 1, parts[0].count <= 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              hour <= 23, minute <= 59
        else { return nil }
        return hour * 60 + minute
    }

    /// Close the hole a removed directive leaves: trailing spaces on a line, and runs of blank lines
    /// collapsed to one. Leading and trailing whitespace of the whole reply goes too.
    private static func tidy(_ text: String) -> String {
        var lines = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                var l = line
                while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                return l
            }
        // Collapse three-or-more blank runs down to one blank line.
        var collapsed: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks <= 1 { collapsed.append(line) }
            } else {
                blanks = 0
                collapsed.append(line)
            }
        }
        lines = collapsed
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
