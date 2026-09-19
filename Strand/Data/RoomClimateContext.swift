import Foundation
import StrandAnalytics

// RoomClimateContext.swift — what the bedroom should be RIGHT NOW: a room to work in, or a room to
// sleep in.
//
// The same room is a desk by day and a bed by night, and the two want different air. Judging it against
// the sleep band all day told the wearer at two in the afternoon that 21 °C was "too warm" — the right
// temperature to think in. So the day is split into windows, each with its own targets:
//
//   · SLEEP  — from the planned bedtime minus a 90-minute wind-down (the room needs that long to cool),
//              until the wake time. Also whenever a sleep is detected, whatever the clock says.
//   · MORNING — a short neutral stretch from wake to wake + 30 min, judged against the focus targets
//              (the room is being handed over from night to day).
//   · FOCUS  — the rest of the waking day: from wake + 30 min until the sleep window opens.
//
// THE TARGETS, and where they come from (applied as a nudge, not a diagnosis):
//
//   · Sleep, 16–19.5 °C, best near 18 °C — the thermal-environment review of Okamoto-Mizuno & Mizuno,
//     J Physiol Anthropol 2012 (warm rooms raise wakefulness and cut slow-wave and REM sleep), and the
//     widely used sleep-hygiene guidance of about 18 °C. The band is `ClimateAdvice`'s, so the sleep
//     judgement here and everywhere else is one number.
//   · Focus, 20–22.5 °C, best near 21 °C — Seppänen, Fisk & Lei, "Effect of temperature on task
//     performance in office environment" (LBNL 2006): office-work performance peaks around 21–22 °C and
//     falls about 2 % per °C above 25; Lan, Wargocki & Lian, Indoor Air 2011, found a slightly cool room
//     (≈22 °C) beat a warm one (≈26 °C) on cognitive tasks, with less fatigue.
//   · Humidity, 40–60 % in both — Arundel et al., Environ Health Perspect 1986 (the 40–60 % band
//     minimises microbial and irritant exposure); Wolkoff, Int J Hyg Environ Health 2018 (below ~40 %
//     the eyes and airways dry out, which costs concentration at a screen). Best near 45–50 %.
//
// PURE: no store, no clock of its own. The schedule and the instant come in, so the windows can be
// tested across midnight without waiting for one. `RoomClimatePlan` below is the app-side half that
// finds the schedule.

/// Which window the room is in.
enum RoomClimateMode: String, Equatable, Sendable {
    case focus, morning, sleep

    /// The chip on the tile.
    var label: String {
        switch self {
        case .focus: return "FOCUS"
        case .morning: return "MORNING"
        case .sleep: return "SLEEP"
        }
    }

    /// The word in a hint: "too warm for focus".
    fileprivate var purpose: String {
        switch self {
        case .sleep: return "sleep"
        case .focus, .morning: return "focus"
        }
    }
}

/// The band each figure should sit in, and the point inside it that is best.
struct RoomClimateTargets: Equatable, Sendable {
    let temp: ClosedRange<Double>
    let tempOptimum: Double
    let humidity: ClosedRange<Double>
    let humidityOptimum: Double

    static let sleep = RoomClimateTargets(temp: ClimateAdvice.tempLowC...ClimateAdvice.tempHighC, tempOptimum: 18,
                                          humidity: ClimateAdvice.humidityLow...ClimateAdvice.humidityHigh,
                                          humidityOptimum: 50)
    static let focus = RoomClimateTargets(temp: 20...22.5, tempOptimum: 21,
                                          humidity: 40...60, humidityOptimum: 47.5)

    static func forMode(_ mode: RoomClimateMode) -> RoomClimateTargets {
        mode == .sleep ? sleep : focus
    }
}

/// When the night is, as minutes past local midnight.
struct RoomClimateSchedule: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        /// The wearer's own plan (wind-down wake time and sleep need).
        case plan
        /// The typical bedtime and wake time of the last two weeks.
        case history
        /// Neither: 22:30 to 07:00.
        case fallback
    }

    let bedtimeMinute: Int
    let wakeMinute: Int
    /// How long before bedtime the room should already be a bedroom.
    let windDownLeadMinutes: Int
    /// The neutral stretch after waking before the focus window opens.
    let morningMinutes: Int
    let source: Source

    static let defaultWindDownLead = 90
    static let defaultMorning = 30

    init(bedtimeMinute: Int, wakeMinute: Int, windDownLeadMinutes: Int = RoomClimateSchedule.defaultWindDownLead,
         morningMinutes: Int = RoomClimateSchedule.defaultMorning, source: Source) {
        self.bedtimeMinute = Self.wrap(bedtimeMinute)
        self.wakeMinute = Self.wrap(wakeMinute)
        self.windDownLeadMinutes = max(0, windDownLeadMinutes)
        self.morningMinutes = max(0, morningMinutes)
        self.source = source
    }

    static let fallback = RoomClimateSchedule(bedtimeMinute: 22 * 60 + 30, wakeMinute: 7 * 60, source: .fallback)

    /// The minute the sleep window opens: bedtime minus the wind-down.
    var sleepStartMinute: Int { Self.wrap(bedtimeMinute - windDownLeadMinutes) }
    /// The minute the focus window opens: wake plus the morning stretch.
    var focusStartMinute: Int { Self.wrap(wakeMinute + morningMinutes) }

    /// The window a minute of the day falls in. A detected sleep is the sleep window, whatever the clock.
    func mode(atMinute minute: Int, asleepNow: Bool = false) -> RoomClimateMode {
        let m = Self.wrap(minute)
        if asleepNow || Self.within(m, from: sleepStartMinute, to: wakeMinute) { return .sleep }
        if Self.within(m, from: wakeMinute, to: focusStartMinute) { return .morning }
        return .focus
    }

    func mode(at date: Date, asleepNow: Bool = false, calendar: Calendar = .current) -> RoomClimateMode {
        mode(atMinute: Self.minuteOfDay(date, calendar), asleepNow: asleepNow)
    }

    /// The next window worth naming, and when it opens: the sleep window from the focus window, the
    /// focus window from the sleep window or the morning.
    func nextWindow(after date: Date, asleepNow: Bool = false,
                    calendar: Calendar = .current) -> (mode: RoomClimateMode, start: Date) {
        switch mode(at: date, asleepNow: asleepNow, calendar: calendar) {
        case .focus:
            return (.sleep, Self.nextOccurrence(of: sleepStartMinute, after: date, calendar))
        case .sleep, .morning:
            return (.focus, Self.nextOccurrence(of: focusStartMinute, after: date, calendar))
        }
    }

    // MARK: - Minute arithmetic

    static func wrap(_ minute: Int) -> Int {
        let day = 24 * 60
        return ((minute % day) + day) % day
    }

    /// Whether `m` lies in the half-open window [from, to) on a 24-hour clock — across midnight when
    /// `from` is later than `to`. An empty window (from == to) holds nothing.
    static func within(_ m: Int, from: Int, to: Int) -> Bool {
        if from == to { return false }
        if from < to { return m >= from && m < to }
        return m >= from || m < to
    }

    static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The first instant strictly after `date` whose clock reads `minute`.
    static func nextOccurrence(of minute: Int, after date: Date, _ calendar: Calendar) -> Date {
        let m = wrap(minute)
        let today = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(m * 60))
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// The typical clock time of a set of nights, the median taken the short way round the clock — so
    /// 23:50, 00:10 and 00:20 are "00:10", not the 08:00-ish a plain median of 1430, 10 and 20 minutes
    /// would give. The circle is cut opposite the circular mean, and the median read on that line.
    static func circularMedianMinute(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        let day = 1440.0
        var s = 0.0, c = 0.0
        for m in minutes {
            let a = Double(wrap(m)) / day * 2 * Double.pi
            s += sin(a)
            c += cos(a)
        }
        var mean = atan2(s, c) / (2 * Double.pi) * day
        if mean < 0 { mean += day }
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
}

/// How one figure sits against its band.
struct ClimateDimension: Equatable, Sendable {
    enum Status: Equatable, Sendable { case good, low, high }

    let value: Double
    let range: ClosedRange<Double>
    let optimum: Double
    let status: Status
    /// 0–100: 100 at the optimum, 85 at the edge of the band, falling off beyond it.
    let score: Int
    /// How far outside the band, in the figure's own unit. Zero inside it.
    let deviation: Double

    /// `penaltyPerUnit` is the score lost per unit beyond the band's edge.
    init(value: Double, range: ClosedRange<Double>, optimum: Double, penaltyPerUnit: Double) {
        self.value = value
        self.range = range
        self.optimum = optimum
        let s: Status
        let d: Double
        if value < range.lowerBound {
            s = .low
            d = range.lowerBound - value
        } else if value > range.upperBound {
            s = .high
            d = value - range.upperBound
        } else {
            s = .good
            d = 0
        }
        self.status = s
        self.deviation = d
        if s == .good {
            let half = value >= optimum ? range.upperBound - optimum : optimum - range.lowerBound
            let frac = half > 0 ? min(1, abs(value - optimum) / half) : 0
            self.score = Int((100 - 15 * frac).rounded())
        } else {
            self.score = max(0, Int((85 - penaltyPerUnit * d).rounded()))
        }
    }
}

/// The room judged against the window it is in.
struct RoomClimateContext: Equatable, Sendable {
    let mode: RoomClimateMode
    let targets: RoomClimateTargets
    let temperature: ClimateDimension
    let humidity: ClimateDimension
    /// 0–100, the worse of the two figures: a perfect temperature does not make up for desert air.
    let score: Int
    /// One line per problem, worst first. Empty when the room fits the window.
    let issues: [String]
    /// The one line the tile shows.
    let hint: String
    /// The next window worth naming, and when it opens.
    let nextMode: RoomClimateMode
    let nextStart: Date

    var isGood: Bool { issues.isEmpty }

    /// Score lost per °C and per % RH beyond a band's edge: two degrees out is a poor room (45), ten
    /// points of humidity out is a middling one (55).
    static let tempPenaltyPerC = 20.0
    static let humidityPenaltyPerPct = 3.0

    static func evaluate(temperatureC: Double, humidityPct: Double, schedule: RoomClimateSchedule,
                         now: Date, asleepNow: Bool = false, calendar: Calendar = .current) -> RoomClimateContext {
        let mode = schedule.mode(at: now, asleepNow: asleepNow, calendar: calendar)
        let targets = RoomClimateTargets.forMode(mode)
        let t = ClimateDimension(value: temperatureC, range: targets.temp, optimum: targets.tempOptimum,
                                 penaltyPerUnit: tempPenaltyPerC)
        let h = ClimateDimension(value: humidityPct, range: targets.humidity, optimum: targets.humidityOptimum,
                                 penaltyPerUnit: humidityPenaltyPerPct)

        var ranked: [(score: Int, line: String)] = []
        if let line = tempLine(t, mode) { ranked.append((t.score, line)) }
        if let line = humidityLine(h, mode) { ranked.append((h.score, line)) }
        let issues = ranked.sorted { $0.score < $1.score }.map { $0.line }

        let next = schedule.nextWindow(after: now, asleepNow: asleepNow, calendar: calendar)
        return RoomClimateContext(mode: mode, targets: targets, temperature: t, humidity: h,
                                  score: min(t.score, h.score), issues: issues,
                                  hint: issues.first ?? goodLine(mode),
                                  nextMode: next.mode, nextStart: next.start)
    }

    static func evaluate(_ r: ClimateReading, schedule: RoomClimateSchedule, now: Date,
                         asleepNow: Bool = false, calendar: Calendar = .current) -> RoomClimateContext {
        evaluate(temperatureC: r.temperatureC, humidityPct: r.humidityPct, schedule: schedule,
                 now: now, asleepNow: asleepNow, calendar: calendar)
    }

    // MARK: - Lines

    private static func tempLine(_ t: ClimateDimension, _ mode: RoomClimateMode) -> String? {
        switch t.status {
        case .good:
            return nil
        case .high:
            let fix = mode == .sleep ? "air it out or turn the heating down before bed"
                                     : "ventilate or lower the heating"
            return String(format: "%.1f °C too warm for %@ — %@.", t.deviation, mode.purpose, fix)
        case .low:
            let fix = mode == .sleep ? "a little heat or a warmer duvet helps"
                                     : "a little heat keeps the mind sharper"
            return String(format: "%.1f °C too cool for %@ — %@.", t.deviation, mode.purpose, fix)
        }
    }

    private static func humidityLine(_ h: ClimateDimension, _ mode: RoomClimateMode) -> String? {
        switch h.status {
        case .good:
            return nil
        case .low:
            return String(format: "Dry air at %.0f %% — a humidifier or a bowl of water helps %@.",
                          h.value, mode == .sleep ? "overnight" : "eyes and focus")
        case .high:
            return String(format: "Humid air at %.0f %% — %@.",
                          h.value, mode == .sleep ? "air the room briefly before bed" : "air the room for a few minutes")
        }
    }

    private static func goodLine(_ mode: RoomClimateMode) -> String {
        switch mode {
        case .sleep: return "A good room to sleep in."
        case .morning: return "A good room to start the day in."
        case .focus: return "A good room for focused work."
        }
    }
}

// MARK: - The app's schedule

/// Where the night is, for this wearer: their own plan when they have one, else how they have actually
/// slept, else 22:30–07:00.
///
/// THE PLAN is the wind-down reminder's wake time and sleep need — the one place the app holds a
/// bedtime the wearer chose. THE HISTORY is the typical onset and wake of the last two weeks, cached in
/// defaults so the notification path (which has no repository) reads the same schedule as the tile.
@MainActor
enum RoomClimatePlan {

    private static let typicalOnsetKey = "climate.typical.onsetMinute"
    private static let typicalWakeKey = "climate.typical.wakeMinute"
    private static let typicalAtKey = "climate.typical.at"
    /// Fewer nights than this is not a habit.
    static let minNights = 3

    static func schedule(now: Date = Date(), calendar: Calendar = .current,
                         defaults: UserDefaults = .standard) -> RoomClimateSchedule {
        if WindDownNudge.isEnabled {
            // The wake that ends the coming night: tomorrow's after noon, this morning's before.
            let nextDay = RoomClimateSchedule.minuteOfDay(now, calendar) >= 12 * 60
            let day = nextDay ? (calendar.date(byAdding: .day, value: 1, to: now) ?? now) : now
            let wake = WindDownNudge.wakeMinutes(forWeekday: calendar.component(.weekday, from: day))
            return RoomClimateSchedule(bedtimeMinute: wake - WindDownNudge.sleepNeedMinutes,
                                       wakeMinute: wake, source: .plan)
        }
        if let onset = defaults.object(forKey: typicalOnsetKey) as? Int,
           let wake = defaults.object(forKey: typicalWakeKey) as? Int {
            return RoomClimateSchedule(bedtimeMinute: onset, wakeMinute: wake, source: .history)
        }
        return .fallback
    }

    /// Re-read the typical night from the last two weeks, at most every six hours.
    static func refreshTypical(repo: Repository, now: Date = Date(), defaults: UserDefaults = .standard) async {
        if let at = defaults.object(forKey: typicalAtKey) as? Date, now.timeIntervalSince(at) < 6 * 3600 { return }
        let nights = Array((await repo.sleepTimingsByDay(days: 14)).values)
        defaults.set(now, forKey: typicalAtKey)
        guard nights.count >= minNights,
              let onset = RoomClimateSchedule.circularMedianMinute(nights.map(\.onsetMinute)),
              let wake = RoomClimateSchedule.circularMedianMinute(nights.map(\.wakeMinute))
        else { return }
        defaults.set(onset, forKey: typicalOnsetKey)
        defaults.set(wake, forKey: typicalWakeKey)
    }

    /// The reading judged against the window the room is in now.
    static func context(for r: ClimateReading, now: Date = Date()) -> RoomClimateContext {
        RoomClimateContext.evaluate(r, schedule: schedule(now: now), now: now)
    }
}
