import Foundation

// SleepAnchor.swift — one wake anchor, one bedtime, and every evening time derived from it.
//
// HEALTH_V2 S2. Before this, six things each kept their own idea of bedtime: detected sleep, the
// wind-down reminder (a user-set 07:00 wake, 8 h need, 30 min lead), the room-climate windows, WiZ
// (fixed 06:30 / 21:30), the ritual pushes and the caffeine bedtime setting — and the day's gear moved
// the bedtime directive by 20–40 minutes depending on the morning's choice, which made bedtimes LESS
// regular. This is the one plan they all read now (through `SleepScheduleProvider` on the app side).
//
// THE ANCHOR IS THE WAKE TIME. The wearer's own target wake when they set one; otherwise the circular
// median of their last 14 main-sleep wake times (needs 7), rounded to five minutes. Saturday and Sunday
// wake days move later by `weekendOffsetMin` (0–60, capped to keep social jet lag small). Without a
// target and without 7 nights there is NO plan — `calibrating(n, 7)` — and a wake-time spread over two
// hours abstains as `scheduleTooIrregular`: a bedtime off a median that describes nobody's actual night
// would be a fabricated schedule.
//
// BEDTIME = anchor − need − 15 min onset buffer − payback. Debt is paid back with an EARLIER bedtime and
// never with a later wake: getting up later would trade regularity for duration. Payback is
// `min(30, round5(debt / 3))` from 60 minutes of debt, and ZERO when efficiency was under 80 % on 4 of
// the last 7 nights — more time in bed is the opposite of what insomnia treatment prescribes.
//
// CLOCK MINUTES, NEVER SECONDS. Every figure here is a minute of the local clock (0..<1440) or a number
// of minutes, so a DST night cannot shift anything by an hour: nothing is ever computed as 86 400 s.
//
// Pure and deterministic (integer calendar math, no Foundation calendars), so a Kotlin twin can assert
// the same numbers. Swift-only in 2.0 — see HEALTH_V2 "Platform note".

/// One main sleep, keyed by the local day it ENDED on.
public struct SleepTimingNight: Equatable, Sendable, Codable {
    /// `yyyy-MM-dd`, the local day the night ended on.
    public let wakeDay: String
    /// Sleep onset, minutes past local midnight.
    public let onsetMin: Int
    /// Wake, minutes past local midnight.
    public let wakeMin: Int
    /// Minutes asleep, nil when not scored.
    public let asleepMin: Double?
    /// Sleep efficiency as the store carries it — a fraction, or a percentage on some imports.
    public let efficiency: Double?

    public init(wakeDay: String, onsetMin: Int, wakeMin: Int, asleepMin: Double? = nil,
                efficiency: Double? = nil) {
        self.wakeDay = wakeDay
        self.onsetMin = onsetMin
        self.wakeMin = wakeMin
        self.asleepMin = asleepMin
        self.efficiency = efficiency
    }

    /// Efficiency as a fraction 0–1. Imported rows sometimes carry a percentage (92 rather than 0.92);
    /// anything above 1.5 is read as one. Nil when absent or not a number.
    public var efficiencyFraction: Double? {
        guard let e = efficiency, e.isFinite, e >= 0 else { return nil }
        return e > 1.5 ? e / 100 : e
    }
}

/// Clock arithmetic on minutes past local midnight, and integer calendar math on `yyyy-MM-dd` keys.
public enum SleepClock {

    public static let minutesPerDay = 1440

    /// Into [0, 1440).
    public static func wrap(_ minute: Int) -> Int {
        ((minute % minutesPerDay) + minutesPerDay) % minutesPerDay
    }

    /// To the nearest five minutes (ties away from zero, like `Double.rounded()`).
    public static func round5(_ minutes: Double) -> Int { Int((minutes / 5).rounded()) * 5 }

    /// "HH:mm", locale-free.
    public static func clock(_ minute: Int) -> String {
        let m = wrap(minute)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "8 h 15 m" / "8 h" — locale-free.
    public static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    private static func angle(_ minute: Int) -> Double {
        Double(wrap(minute)) / Double(minutesPerDay) * 2 * Double.pi
    }

    /// The circular mean of clock minutes, or nil for an empty set or a perfectly balanced one.
    public static func circularMean(_ minutes: [Int]) -> Double? {
        guard !minutes.isEmpty else { return nil }
        var s = 0.0, c = 0.0
        for m in minutes { s += sin(angle(m)); c += cos(angle(m)) }
        guard (s * s + c * c).squareRoot() > 1e-9 else { return nil }
        var mean = atan2(s, c) / (2 * Double.pi) * Double(minutesPerDay)
        if mean < 0 { mean += Double(minutesPerDay) }
        return mean
    }

    /// The median of clock minutes taken the short way round the clock — 23:50 and 00:10 give 00:00,
    /// not 12:00. The circle is cut opposite the circular mean and the median read on that line (the same
    /// rule `RoomClimateSchedule.circularMedianMinute` uses app-side).
    public static func circularMedian(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        let day = Double(minutesPerDay)
        let mean = circularMean(minutes) ?? Double(wrap(minutes[0]))
        let origin = mean - day / 2
        let shifted = minutes.map { v -> Double in
            var x = (Double(wrap(v)) - origin).truncatingRemainder(dividingBy: day)
            if x < 0 { x += day }
            return x
        }.sorted()
        let mid = shifted.count / 2
        let median = shifted.count % 2 == 1 ? shifted[mid] : (shifted[mid - 1] + shifted[mid]) / 2
        return wrap(Int((median + origin).rounded()))
    }

    /// Circular standard deviation in minutes: √(−2 ln R) on the 24-hour circle. Nil for an empty set.
    /// A set spread evenly round the clock (R ≈ 0) reads as a full day.
    public static func circularSD(_ minutes: [Int]) -> Double? {
        guard !minutes.isEmpty else { return nil }
        var s = 0.0, c = 0.0
        for m in minutes { s += sin(angle(m)); c += cos(angle(m)) }
        let r = (s * s + c * c).squareRoot() / Double(minutes.count)
        guard r > 1e-12 else { return Double(minutesPerDay) }
        let sd = (-2 * log(Swift.min(r, 1))).squareRoot() * Double(minutesPerDay) / (2 * Double.pi)
        return Swift.min(sd, Double(minutesPerDay))
    }

    /// The shortest distance between two clock minutes, 0...720.
    public static func distance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: Double(minutesPerDay))
        return Swift.min(raw, Double(minutesPerDay) - raw)
    }

    /// Days since 1970-01-01 for a `yyyy-MM-dd` key (proleptic Gregorian, integer math). Nil when the key
    /// does not parse.
    public static func dayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let y0 = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Calendar weekday of a day key, 1 = Sunday … 7 = Saturday (Foundation's numbering).
    public static func weekday(of key: String) -> Int? {
        guard let n = dayNumber(key) else { return nil }
        // 1970-01-01 was a Thursday (weekday 5).
        return ((n + 4) % 7 + 7) % 7 + 1
    }

    /// Saturday or Sunday.
    public static func isWeekend(weekday: Int) -> Bool { weekday == 1 || weekday == 7 }
}

/// Where the anchor came from.
public enum SleepAnchorSource: String, Equatable, Sendable, Codable {
    /// The wearer set the time they want to wake.
    case userTarget
    /// The circular median of their own recent wake times.
    case medianWake
}

/// Why there is no plan. Rendered as "—" plus `reason`.
public enum SleepAnchorAbstention: Equatable, Sendable {
    /// Fewer than `needed` main sleeps and no target wake.
    case calibrating(nights: Int, needed: Int)
    /// No target wake, and the wake time's circular SD over the window exceeds two hours.
    case scheduleTooIrregular(wakeSdMin: Double)

    public var reason: String {
        switch self {
        case .calibrating(let n, let needed):
            return "Calibrating (\(n) of \(needed) nights) — or set the time you want to wake."
        case .scheduleTooIrregular:
            return "Your wake time varies by more than two hours — set a target wake if you want an anchor."
        }
    }
}

/// The night's schedule for one wake day.
public struct SleepSchedulePlan: Equatable, Sendable, Codable {
    /// 1 = Sunday … 7 = Saturday, the weekday of the WAKE day this plan ends on.
    public let wakeWeekday: Int
    /// The wake time for that day, minutes past midnight, with any weekend offset applied.
    public let anchorMin: Int
    public let anchorSource: SleepAnchorSource
    /// The weekend offset applied to this day's anchor (0 on a weekday).
    public let weekendOffsetMin: Int
    /// The sleep need planned for, in minutes.
    public let needMin: Int
    /// True when `needMin` is the adult recommendation rather than the wearer's own figure (fewer than
    /// seven scored nights, or no analysis pass yet). A labelled planning target, not a measurement.
    public let needIsPopulationDefault: Bool
    /// The debt the payback was sized from, nil when unknown.
    public let debtMin: Double?
    /// How much earlier than need + buffer the bedtime is, to pay back debt. 0–30.
    public let paybackMin: Int
    /// Efficiency under 80 % on 4 of the last 7 nights: payback is withheld and the card says why.
    public let insomniaGuard: Bool
    /// Main sleeps the median / confidence was read from.
    public let nightsUsed: Int
    /// `building` at 7–13 nights (or a target with fewer), `solid` at 14 or more.
    public let confidence: ScoreConfidence
    /// Minutes BEFORE the anchor the bedtime falls: need + onset buffer + payback.
    public let bedtimeLeadMin: Int

    public init(wakeWeekday: Int, anchorMin: Int, anchorSource: SleepAnchorSource, weekendOffsetMin: Int,
                needMin: Int, needIsPopulationDefault: Bool, debtMin: Double?, paybackMin: Int,
                insomniaGuard: Bool, nightsUsed: Int, confidence: ScoreConfidence, bedtimeLeadMin: Int) {
        self.wakeWeekday = wakeWeekday
        self.anchorMin = SleepClock.wrap(anchorMin)
        self.anchorSource = anchorSource
        self.weekendOffsetMin = weekendOffsetMin
        self.needMin = needMin
        self.needIsPopulationDefault = needIsPopulationDefault
        self.debtMin = debtMin
        self.paybackMin = paybackMin
        self.insomniaGuard = insomniaGuard
        self.nightsUsed = nightsUsed
        self.confidence = confidence
        self.bedtimeLeadMin = bedtimeLeadMin
    }

    /// Lights out, minutes past midnight.
    public var bedtimeMin: Int { SleepClock.wrap(anchorMin - bedtimeLeadMin) }
    /// Asleep by: bedtime plus the onset buffer. The threshold a bedtime QUEST checks sleep onset
    /// against (`QuestBaseline.bedtimeTargetMin`) — the plan's own figure, the same for every gear.
    public var asleepByMin: Int { SleepClock.wrap(bedtimeMin + SleepAnchor.onsetBufferMin) }
    public var windDownStartMin: Int { SleepClock.wrap(bedtimeMin - SleepAnchor.windDownLeadMin) }
    /// Roughly when melatonin starts to rise before habitual sleep.
    public var lightsDimMin: Int { SleepClock.wrap(bedtimeMin - SleepAnchor.lightsDimLeadMin) }
    public var morningLightMin: Int { anchorMin }
    /// The room's sleep window: wind-down start … anchor.
    public var roomSleepWindowStartMin: Int { windDownStartMin }
    public var roomSleepWindowEndMin: Int { anchorMin }

    /// Which local day an evening time `leadMin` before the anchor falls on, relative to the WAKE day:
    /// 0 the same day, −1 the evening before. Floor division on clock minutes.
    public func dayShift(leadBeforeAnchorMin leadMin: Int) -> Int {
        let raw = anchorMin - leadMin
        return raw >= 0 ? raw / SleepClock.minutesPerDay : -((-raw - 1) / SleepClock.minutesPerDay + 1)
    }

    public var bedtimeDayShift: Int { dayShift(leadBeforeAnchorMin: bedtimeLeadMin) }
    public var windDownDayShift: Int {
        dayShift(leadBeforeAnchorMin: bedtimeLeadMin + SleepAnchor.windDownLeadMin)
    }
    public var lightsDimDayShift: Int {
        dayShift(leadBeforeAnchorMin: bedtimeLeadMin + SleepAnchor.lightsDimLeadMin)
    }

    // MARK: - The card's lines (the design packages place them; the words are decided here)

    /// "to wake at 07:00 with your ~8 h 15 m need" or the labelled population target.
    public var needLine: String {
        let wake = SleepClock.clock(anchorMin)
        if needIsPopulationDefault {
            return "to wake at \(wake) with \(SleepClock.duration(needMin)) — adult recommendation; "
                + "yours after \(SleepAnchor.minNights) nights"
        }
        return "to wake at \(wake) with your ~\(SleepClock.duration(needMin)) need"
    }

    /// "15 min earlier this week to pay back 45 min of sleep debt", or nil with no payback.
    public var paybackLine: String? {
        guard paybackMin > 0, let debt = debtMin else { return nil }
        return "\(paybackMin) min earlier this week to pay back \(Int(debt.rounded())) min of sleep debt"
    }

    /// The insomnia note, or nil.
    public var insomniaLine: String? {
        insomniaGuard ? SleepAnchor.insomniaNote : nil
    }
}

/// A plan, or the reason there is none.
public enum SleepAnchorResult: Equatable, Sendable {
    case plan(SleepSchedulePlan)
    case abstain(SleepAnchorAbstention)

    public var plan: SleepSchedulePlan? {
        if case .plan(let p) = self { return p }
        return nil
    }

    public var abstention: SleepAnchorAbstention? {
        if case .abstain(let a) = self { return a }
        return nil
    }
}

public enum SleepAnchor {

    /// Main sleeps the median reads, and how many it needs.
    public static let windowNights = 14
    public static let minNights = 7
    /// No target and a wake SD above this: `scheduleTooIrregular`.
    public static let irregularWakeSdMin: Double = 120
    /// Between lights out and sleep.
    public static let onsetBufferMin = 15
    public static let windDownLeadMin = 60
    public static let lightsDimLeadMin = 120
    /// Payback: from this much debt, a third of it, to the nearest five, at most `maxPaybackMin`.
    public static let paybackFromDebtMin: Double = 60
    public static let maxPaybackMin = 30
    /// Weekend wake offset bounds (Wittmann 2006: keep social jet lag small).
    public static let maxWeekendOffsetMin = 60
    /// Insomnia guard: efficiency under this on `insomniaNights` of the last `insomniaWindow` nights.
    public static let insomniaEfficiency = 0.80
    public static let insomniaNights = 4
    public static let insomniaWindow = 7

    public static let insomniaNote = "If you often lie awake, more time in bed can make it worse. CBT-I is "
        + "the recommended approach — consider talking to a professional."

    /// What the plan is computed from.
    public struct Inputs: Equatable, Sendable {
        /// Main sleeps, any order; one per wake day.
        public var nights: [SleepTimingNight]
        /// The need the engine scored Rest with (`AnalyticsEngine.Rest.engineNeedHours`), nil before a pass.
        public var needHours: Double?
        /// The sleep-debt balance in minutes (a magnitude), nil when unknown.
        public var debtMin: Double?
        /// The wearer's target wake, minutes past midnight, nil when not set.
        public var targetWakeMin: Int?
        /// 0–60; clamped.
        public var weekendOffsetMin: Int

        public init(nights: [SleepTimingNight], needHours: Double? = nil, debtMin: Double? = nil,
                    targetWakeMin: Int? = nil, weekendOffsetMin: Int = 0) {
            self.nights = nights
            self.needHours = needHours
            self.debtMin = debtMin
            self.targetWakeMin = targetWakeMin
            self.weekendOffsetMin = weekendOffsetMin
        }
    }

    /// The last `windowNights` main sleeps, oldest first, one per wake day.
    public static func recentNights(_ nights: [SleepTimingNight],
                                    window: Int = windowNights) -> [SleepTimingNight] {
        var byDay: [String: SleepTimingNight] = [:]
        for n in nights where SleepClock.dayNumber(n.wakeDay) != nil { byDay[n.wakeDay] = n }
        return Array(byDay.values.sorted { $0.wakeDay < $1.wakeDay }.suffix(Swift.max(window, 1)))
    }

    /// Payback in minutes for a debt, before the insomnia guard.
    public static func payback(debtMin: Double?) -> Int {
        guard let debt = debtMin, debt.isFinite, debt >= paybackFromDebtMin else { return 0 }
        return Swift.min(maxPaybackMin, Swift.max(0, SleepClock.round5(debt / 3)))
    }

    /// Whether efficiency was under 80 % on at least 4 of the last 7 nights that carry one.
    public static func insomniaGuard(_ nights: [SleepTimingNight]) -> Bool {
        let last = recentNights(nights, window: insomniaWindow)
        let low = last.compactMap(\.efficiencyFraction).filter { $0 < insomniaEfficiency }.count
        return low >= insomniaNights
    }

    /// The plan for a wake day falling on `wakeWeekday` (1 = Sunday … 7 = Saturday), or why there is none.
    public static func plan(_ inputs: Inputs, wakeWeekday: Int) -> SleepAnchorResult {
        let recent = recentNights(inputs.nights)
        let wakes = recent.map(\.wakeMin)

        let base: Int
        let source: SleepAnchorSource
        if let target = inputs.targetWakeMin {
            base = SleepClock.wrap(target)
            source = .userTarget
        } else {
            guard recent.count >= minNights else {
                return .abstain(.calibrating(nights: recent.count, needed: minNights))
            }
            if let sd = SleepClock.circularSD(wakes), sd > irregularWakeSdMin {
                return .abstain(.scheduleTooIrregular(wakeSdMin: sd))
            }
            guard let median = SleepClock.circularMedian(wakes) else {
                return .abstain(.calibrating(nights: recent.count, needed: minNights))
            }
            base = SleepClock.wrap(SleepClock.round5(Double(median)))
            source = .medianWake
        }

        let offset = SleepClock.isWeekend(weekday: wakeWeekday)
            ? Swift.min(Swift.max(inputs.weekendOffsetMin, 0), maxWeekendOffsetMin) : 0
        let anchor = SleepClock.wrap(base + offset)

        // NEED: the engine's own figure once there are seven scored nights behind it; before that the
        // adult recommendation, LABELLED as such on the card.
        let scoredNights = recent.filter { ($0.asleepMin ?? 0) > 0 }.count
        let ownNeed = inputs.needHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let populationDefault = ownNeed == nil || scoredNights < minNights
        let needHours = populationDefault ? AnalyticsEngine.Rest.defaultNeedHours : (ownNeed ?? 8)
        let needMin = Int((needHours * 60).rounded())

        let guardOn = insomniaGuard(inputs.nights)
        let paybackMin = guardOn ? 0 : payback(debtMin: inputs.debtMin)

        let confidence: ScoreConfidence = recent.count >= windowNights ? .solid : .building
        return .plan(SleepSchedulePlan(
            wakeWeekday: wakeWeekday, anchorMin: anchor, anchorSource: source, weekendOffsetMin: offset,
            needMin: needMin, needIsPopulationDefault: populationDefault, debtMin: inputs.debtMin,
            paybackMin: paybackMin, insomniaGuard: guardOn, nightsUsed: recent.count,
            confidence: confidence, bedtimeLeadMin: needMin + onsetBufferMin + paybackMin))
    }

    /// The plan for every weekday, keyed 1…7. Empty when the inputs abstain (the abstention is the same
    /// for every day, so the caller reads it from `plan(_:wakeWeekday:)`).
    public static func weekPlans(_ inputs: Inputs) -> [Int: SleepSchedulePlan] {
        var out: [Int: SleepSchedulePlan] = [:]
        for wd in 1...7 {
            if let p = plan(inputs, wakeWeekday: wd).plan { out[wd] = p }
        }
        return out
    }
}
