import Foundation

// WeekPlanProgram.swift — the week plan's two wearer-specific lines (owner request, 2026-09-30).
//
// 1. STRENGTH FROM THE WEARER'S OWN PLAN. With a Telos Lift plan, the week's strength target is the number
//    of day templates the plan schedules in a week — the owner's plan is Upper A (Mo), Lower A (Di),
//    Upper B (Do), Lower B (Fr), so 4 — and the card names them: "Upper A ✓ · Lower A · Upper B · Lower B".
//    Each done session is matched to its template: a session logged in Telos by its template id, an imported
//    one by its title's template segment ("Lower A (Di) · Tag 1 · Woche 5" → "Lower A (Di)"), with or without
//    the weekday tag. A strength session that matches no open template (a repeat, a Hevy session with its
//    own title, a strap-detected strength workout with no lift log) still COUNTS, as "other" — the fallback
//    is counting strength sessions exactly as before, never dropping one.
//    The engine's safety rules stay: an easy week (HRV suppressed, illness, sleep debt, or an accepted
//    lighter week) asks for one session fewer, never below one ("Easy week — 3 of 4"), holds loads and
//    takes about two-thirds of the sets. Without a plan the old rule applies unchanged (2, stepping in at 1).
//    The wearer's plan replaces the "step in at 1" ramp: that ramp exists so the APP never asks a
//    non-lifter for two sessions at once, and a plan the wearer wrote is their own prescription.
//
// 2. ZONE 4–5 MINUTES. Minutes at or above the lower edge of zone 4 of the app's display zones, inside
//    recorded sessions (`SessionIntensity`), toward a short weekly dose (`zone45WeeklyTargetMin`). Only
//    worn / measured time counts: a day adds its minutes only when it was worn (≥ 50 % wear, the review's
//    observed-day line) or holds measured minutes; a day whose intensity abstained (no zone inputs) is
//    UNKNOWN, never 0; a week with no measured day is "—" plus its reason.
//
// Pure, deterministic, DB-free: `yyyy-MM-dd` strings, plain numbers and the Lift value types.

// MARK: - Types

/// One day template of the wearer's Lift plan, as the week plan carries it (frozen with the plan).
public struct PlannedLiftDay: Codable, Equatable, Sendable {
    public let templateId: String
    /// The template's name as the wearer wrote it ("Upper A (Mo)").
    public let name: String
    /// Calendar weekday from the name's tag (1 = Sunday … 7 = Saturday), nil when untagged.
    public let weekday: Int?

    public init(templateId: String, name: String, weekday: Int?) {
        self.templateId = templateId
        self.name = name
        self.weekday = weekday
    }

    /// The name without its weekday tag ("Upper A (Mo)" → "Upper A"), for the card's compact line.
    public var displayName: String { WeekPlanEngine.strippingWeekdayTag(name) }
}

/// One stored lift session, as the week plan matches it. Built in the app from `LiftHistorySession`
/// (sessions with no stored set are not sessions and are not passed).
public struct LiftSessionMark: Equatable, Sendable {
    /// Local day of the session start, `yyyy-MM-dd`.
    public let day: String
    /// The Telos template id it ran (sessions logged in Telos), nil for an imported one.
    public let templateId: String?
    /// The template name (Telos) or the export's session title.
    public let title: String?

    public init(day: String, templateId: String?, title: String?) {
        self.day = day
        self.templateId = templateId
        self.title = title
    }
}

/// One planned template and the day a session of it was done this week (nil = not yet).
public struct TemplateDone: Equatable, Sendable {
    public let template: PlannedLiftDay
    public let doneOn: String?

    public var done: Bool { doneOn != nil }
}

/// The week's strength sessions so far. `templates` is nil without a Lift plan in the week's plan.
public struct StrengthWeekStatus: Equatable, Sendable {
    /// Matched template sessions + other strength sessions.
    public let done: Int
    public let templates: [TemplateDone]?
    /// Strength sessions that matched no open template (repeats, other titles, no lift log). Counted.
    public let otherSessions: Int
}

/// Why the week's zone 4–5 minutes are unknown.
public enum Zone45Absence: String, Codable, Equatable, Sendable {
    /// Sessions exist but their intensity abstained: no measured resting HR / HRmax for the zones.
    case zoneInputsMissing
    /// No worn day with heart rate in the period yet.
    case notWorn

    /// The reason line ("—" + this).
    public var text: String {
        switch self {
        case .zoneInputsMissing: return "needs a measured resting heart rate for your zones"
        case .notWorn: return "no worn time with heart rate yet"
        }
    }
}

/// Zone 4–5 minutes over a set of days.
public struct Zone45Week: Equatable, Sendable {
    /// nil ⇒ unknown ("—" + `absence`), never 0.
    public let minutes: Double?
    public let absence: Zone45Absence?
    /// Part of the minutes came from WHOOP-imported zones ("≈").
    public let approximate: Bool
    /// Days whose minutes were counted (worn, or holding measured minutes).
    public let measuredDays: Int
    /// Days with sessions whose intensity abstained (their minutes are unknown, not 0).
    public let unknownDays: Int
    /// Sessions without heart rate on the counted days (counted as sessions, no minutes).
    public let unmeasuredSessions: Int
}

// MARK: - Engine

extension WeekPlanEngine {

    /// The weekly zone 4–5 target, minutes. A short weekly high-intensity dose, set as a coaching choice
    /// (owner, 2026-09-30), not a threshold taken from a trial: high-intensity work adds a training stimulus
    /// the moderate minutes do not, and ten minutes a week fits inside sessions the wearer already does.
    /// Vigorous minutes already count double toward the aerobic target; this line only makes the top end
    /// visible. Asked for in build and hold weeks; an easy week asks for none (no hard work is advised then).
    public static let zone45WeeklyTargetMin: Double = 10

    /// An untagged plan is taken as one week only up to this many templates (one a day): past it, the
    /// library holds more than a week's plan and which templates are "this week" is not knowable.
    public static let maxUntaggedTemplatesPerWeek: Int = 7

    /// The zone 4–5 target for a week type.
    public static func zone45Target(type: WeekType) -> Double? {
        type == .easy ? nil : zone45WeeklyTargetMin
    }

    // MARK: Program → planned days

    /// The day templates a Lift library schedules in one week, in week order (Monday first).
    ///   * Tagged templates ("(Mo)", "(Di)" …) are the week — one session each. Untagged ones beside them are
    ///     spares and do not count.
    ///   * Two templates tagged the SAME weekday (an A/B alternation) ⇒ nil: which one is this week's is not
    ///     knowable from the plan, and the default target applies.
    ///   * No tags: every template, when there are at most `maxUntaggedTemplatesPerWeek`; else nil.
    public static func plannedDays(from templates: [LiftDayTemplate]) -> [PlannedLiftDay]? {
        let tagged = templates.filter { $0.weekday != nil }
        let chosen: [LiftDayTemplate]
        if !tagged.isEmpty {
            let weekdays = tagged.compactMap(\.weekday)
            guard Set(weekdays).count == weekdays.count else { return nil }
            chosen = tagged
        } else if !templates.isEmpty && templates.count <= maxUntaggedTemplatesPerWeek {
            chosen = templates
        } else {
            return nil
        }
        return LiftTemplatePicker.rotation(chosen).map {
            PlannedLiftDay(templateId: $0.id, name: $0.name, weekday: $0.weekday)
        }
    }

    /// "Upper A (Mo)" → "Upper A". Only a trailing parenthesised WEEKDAY tag is removed ("Push (heavy)" stays).
    public static func strippingWeekdayTag(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard LiftWeekday.weekday(inTemplateName: trimmed) != nil, trimmed.hasSuffix(")"),
              let open = trimmed.lastIndex(of: "(") else { return trimmed }
        let base = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? trimmed : base
    }

    /// Whether a stored session ran a planned template: the same Telos template id, or the same template
    /// name (the title's first "·" segment, case-folded), with or without the weekday tag.
    public static func matches(_ session: LiftSessionMark, _ template: PlannedLiftDay) -> Bool {
        if let id = session.templateId, id == template.templateId { return true }
        guard let a = LiftDedupe.templateKey(session.title), let b = LiftDedupe.templateKey(template.name) else {
            return false
        }
        if a == b { return true }
        return strippingWeekdayTag(a) == strippingWeekdayTag(b)
    }

    // MARK: Strength target and status

    /// Sessions asked for in an easy week with a plan of `n` templates: one fewer, never below one
    /// (4 → 3, 2 → 1 — the same 1-of-2 the default easy week asks for).
    public static func easyProgramSessions(_ n: Int) -> Int { max(1, n - 1) }

    /// The strength target from the wearer's plan for a week type.
    public static func programStrength(type: WeekType, program: [PlannedLiftDay]) -> StrengthTarget {
        let n = program.count
        switch type {
        case .build, .hold:
            return StrengthTarget(minSessions: n, maxSessions: n, holdLoads: false, setsFactor: 1, templates: program)
        case .easy:
            return StrengthTarget(minSessions: easyProgramSessions(n), maxSessions: n, holdLoads: true,
                                  setsFactor: easySetsFactor, templates: program)
        }
    }

    /// The week's strength sessions over `dayKeys`.
    ///
    /// Without a plan (`templates` nil or empty): the days with a strength session, exactly as before.
    /// With one: each lift session (in day order) takes the first open template it matches; every day with a
    /// strength session or a lift session that matched nothing adds one "other" session. So the count never
    /// falls below the plain strength-day count.
    public static func strengthStatus(templates: [PlannedLiftDay]?, days: [DayActivity],
                                      lifts: [LiftSessionMark], dayKeys: [String]) -> StrengthWeekStatus {
        let byDay = index(days)
        let strengthDays = dayKeys.filter { byDay[$0]?.strengthSession == true }
        guard let templates, !templates.isEmpty else {
            return StrengthWeekStatus(done: strengthDays.count, templates: nil, otherSessions: 0)
        }
        let keys = Set(dayKeys)
        let weekLifts = lifts.enumerated()
            .filter { keys.contains($0.element.day) }
            .sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }
            .map(\.element)
        var doneOn = [String?](repeating: nil, count: templates.count)
        var matchedDays = Set<String>()
        for s in weekLifts {
            guard let i = templates.indices.first(where: { doneOn[$0] == nil && matches(s, templates[$0]) }) else {
                continue
            }
            doneOn[i] = s.day
            matchedDays.insert(s.day)
        }
        let otherDays = Set(strengthDays).union(weekLifts.map(\.day)).subtracting(matchedDays)
        let matched = doneOn.compactMap { $0 }.count
        return StrengthWeekStatus(
            done: matched + otherDays.count,
            templates: zip(templates, doneOn).map { TemplateDone(template: $0.0, doneOn: $0.1) },
            otherSessions: otherDays.count)
    }

    /// "Upper A ✓ · Lower A · Upper B · Lower B" (+ "+1 other"), nil without a plan.
    public static func templateLine(_ status: StrengthWeekStatus) -> String? {
        guard let t = status.templates, !t.isEmpty else { return nil }
        var parts = t.map { $0.done ? $0.template.displayName + " ✓" : $0.template.displayName }
        if status.otherSessions > 0 { parts.append("+\(status.otherSessions) other") }
        return parts.joined(separator: " · ")
    }

    // MARK: Zone 4–5

    /// Zone 4–5 minutes over `dayKeys` (see the file header for what counts).
    public static func zone45Week(days: [DayActivity], dayKeys: [String]) -> Zone45Week {
        let byDay = index(days)
        var sum = 0.0
        var measured = 0, unknown = 0, unmeasured = 0
        var approximate = false
        for key in dayKeys {
            guard let a = byDay[key] else { continue }
            guard let z = a.zone45Min else {
                if a.unmeasuredSessions > 0 { unknown += 1 }
                continue
            }
            guard (a.wearCoverage ?? 0) >= WeekReview.observedWear || z > 0 else { continue }
            measured += 1
            sum += z
            unmeasured += a.unmeasuredSessions
            if a.approximate { approximate = true }
        }
        guard measured > 0 else {
            return Zone45Week(minutes: nil, absence: unknown > 0 ? .zoneInputsMissing : .notWorn,
                              approximate: false, measuredDays: 0, unknownDays: unknown, unmeasuredSessions: 0)
        }
        return Zone45Week(minutes: sum, absence: nil, approximate: approximate, measuredDays: measured,
                          unknownDays: unknown, unmeasuredSessions: unmeasured)
    }

    // MARK: Adopting the plan into a frozen week

    /// Fill what a plan frozen before these lines existed (or before the wearer had a Lift plan) is missing:
    ///   * the zone 4–5 target, from the plan's type;
    ///   * the strength target from `program`, ONCE — a plan that already carries templates is returned
    ///     unchanged, so a later edit of the Lift plan never moves this week's target (it applies next week).
    /// Idempotent: adopting twice equals adopting once. Nothing else of the frozen plan changes.
    public static func adopt(_ plan: WeekPlan, program: [PlannedLiftDay]?) -> WeekPlan {
        var p = plan
        if p.zone45Target == nil { p.zone45Target = zone45Target(type: p.type) }
        if p.strength.templates == nil, let program, !program.isEmpty {
            p.strength = programStrength(type: p.type, program: program)
        }
        return p
    }
}
