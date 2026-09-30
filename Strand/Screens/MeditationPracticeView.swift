import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MeditationPracticeView.swift — the Focus tab's meditation practice view (DESIGN_V2 coordinator decision 12;
// BODY package). It sits under the meditation card (PROGRESS owns `MeditationCardView`) and turns the log into
// a real practice view:
//
//   • a heat-map calendar of the MEDITATION ERA — from the first logged day, week columns Mon→Sun — each
//     cell encoding that day's minutes against THAT day's minimum (5 min before 2026-09-29, 10 from it:
//     `LevelEngine.meditationMinMinutes(on:)`, date-effective, so a past day keeps the rule it was set
//     under);
//   • the current and best streak (days that met their minimum, back to back);
//   • weekly minutes as a compact bar series;
//   • the recent days with the plain miss marking and what each miss costs the Level (decision 10: the
//     meditation deduction is the Level's one penalty input — `LevelEngine.meditationMissPenaltyPoints` per
//     missed day, for every day of the level's 7-day window it sits in);
//   • the session list: time, duration and — for a breathing session recorded with the honest S4 flow — the
//     before/after quiet reading, or "—" with its reason.
//
// HONESTY: a day before the era is "not tracked yet", never missed. A day the app holds no data row for is
// "not measured", never missed (the same rule `LevelWiring.meditationMissedDays` applies). Today is "open"
// until it is over or met. No storage of its own: it reads the existing meditation log
// (`Repository.meditationMinutesByDay` / `meditationSessions`), the day rows and `BreathSessionLog`.
//
// COST: one read per data refresh (`refreshSeq`); the calendar is ONE static Canvas (no clock, no per-cell
// views), the bars are plain shapes. Nothing animates.

/// How one calendar day reads.
enum MeditationDayState: Equatable {
    /// Before the first logged meditation — not part of the practice yet.
    case notTracked
    /// In the era, but the app holds no data for the day — never counted as a miss.
    case notMeasured
    /// Met the day's minimum. `ratio` = minutes / minimum (≥ 1).
    case done(ratio: Double)
    /// Some minutes, under the minimum. `ratio` in (0, 1).
    case partial(ratio: Double)
    /// In the era, measured, nothing (or too little) logged: a miss the Level deducts for.
    case missed
    /// Today, not met yet — not a miss while the day is still open.
    case open
    /// After today.
    case future

    var countsAsDone: Bool {
        if case .done = self { return true }
        return false
    }
}

/// One calendar day and how it reads.
struct MeditationDayEntry: Identifiable, Equatable {
    let day: String
    let state: MeditationDayState
    var id: String { day }
}

/// One week's summed minutes (the bar series).
struct MeditationWeekMinutes: Identifiable, Equatable {
    let start: String
    let minutes: Double
    var id: String { start }
}

/// The pure part: classification, streaks, weekly sums. Tested without a store.
enum MeditationPractice {

    /// The first day with any logged minutes, or nil (no era yet).
    static func eraStart(_ byDay: [String: Double]) -> String? {
        byDay.filter { $0.value > 0 }.keys.min()
    }

    /// One day's state. `measured` = the app holds a day row for it.
    static func state(day: String, minutes: Double, eraStart: String?, today: String,
                      measured: Bool) -> MeditationDayState {
        if day > today { return .future }
        guard let eraStart, day >= eraStart else { return .notTracked }
        let minimum = LevelEngine.meditationMinMinutes(on: day)
        if LevelEngine.isMeditationDay(minutes: minutes, on: day) {
            return .done(ratio: minimum > 0 ? minutes / minimum : 1)
        }
        if day == today { return .open }
        // The Level counts a day as missed only when the wearer's data covers it — so does this view.
        guard measured else { return .notMeasured }
        if minutes > 0, minimum > 0 { return .partial(ratio: minutes / minimum) }
        return .missed
    }

    /// Days back to back that met their minimum, ending today (or yesterday while today is still open).
    static func currentStreak(states: [MeditationDayEntry]) -> Int {
        var n = 0
        for (i, entry) in states.reversed().enumerated() {
            if entry.state.countsAsDone { n += 1; continue }
            // An open today does not break the streak that ended yesterday.
            if i == 0, entry.state == .open { continue }
            break
        }
        return n
    }

    /// The longest run of met days in the era.
    static func bestStreak(states: [MeditationDayEntry]) -> Int {
        var best = 0
        var run = 0
        for entry in states {
            if entry.state.countsAsDone {
                run += 1
                best = max(best, run)
            } else if entry.state != .open && entry.state != .future {
                run = 0
            }
        }
        return best
    }
}

struct MeditationPracticeView: View {
    @EnvironmentObject var repo: Repository
    @ObservedObject private var breathLog = BreathSessionLog.shared

    /// nil until the first read finishes.
    @State private var byDay: [String: Double]?
    @State private var sessions: [WorkoutRow] = []

    private static let cell: CGFloat = 14
    private static let gap: CGFloat = 3
    /// Weeks of minutes in the bar series.
    private static let barWeeks = 12
    /// Recent days listed with their miss marking.
    private static let recentDays = 7

    var body: some View {
        StrandCard(tint: TelosColor.focus) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                Text("Practice")
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                content
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let byDay {
            let today = Repository.localDayKey(Date())
            if let era = MeditationPractice.eraStart(byDay) {
                let measured = Set(repo.days.map(\.day))
                let states = Self.states(from: era, to: today, byDay: byDay, measured: measured)
                streaks(states)
                calendar(states: states, era: era)
                legend
                weeklyBars(byDay: byDay, today: today)
                recent(states: states, byDay: byDay)
                sessionList
            } else {
                // No era yet: nothing is missed, nothing is tracked. Sessions (e.g. breathing) still list.
                AbsentValue(reason: "Not tracked yet")
                sessionList
            }
        } else {
            AbsentValue(reason: nil, arrangement: .inline)
        }
    }

    // MARK: - Streaks

    private func streaks(_ states: [MeditationDayEntry]) -> some View {
        TelosTileGrid(maxColumns: 2) {
            TelosMetricTile("Current streak", value: Double(MeditationPractice.currentStreak(states: states)),
                            unit: "d", ink: TelosColor.focusInk, icon: "flame", iconTint: TelosColor.focus)
            TelosMetricTile("Best streak", value: Double(MeditationPractice.bestStreak(states: states)),
                            unit: "d", ink: TelosColor.textPrimary, icon: "trophy", iconTint: TelosColor.bestGold)
        }
    }

    // MARK: - Calendar heat map

    /// Week columns (Monday on top), from the era's first week to this one. One Canvas; scrolled to the
    /// present on appear.
    private func calendar(states: [MeditationDayEntry], era: String) -> some View {
        let firstMonday = WeeklyDigestEngine.mondayOfWeek(containing: era) ?? era
        let lead = Self.daysBetween(firstMonday, era)
        let cells: [MeditationDayState] = Array(repeating: MeditationDayState.notTracked, count: max(0, lead))
            + states.map { $0.state }
        let weeks = max(1, Int((Double(cells.count) / 7).rounded(.up)))
        let width = CGFloat(weeks) * (Self.cell + Self.gap)
        let height = 7 * (Self.cell + Self.gap)
        let doneCount = states.filter { $0.state.countsAsDone }.count
        let missedCount = states.filter { $0.state == .missed }.count
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Canvas { ctx, _ in
                        for (i, state) in cells.enumerated() {
                            let col = CGFloat(i / 7)
                            let row = CGFloat(i % 7)
                            let rect = CGRect(x: col * (Self.cell + Self.gap), y: row * (Self.cell + Self.gap),
                                              width: Self.cell, height: Self.cell)
                            Self.draw(state, in: rect, ctx: &ctx)
                        }
                    }
                    .frame(width: width, height: height)
                    Color.clear.frame(width: 1, height: 1).id("now")
                }
            }
            .onAppear { proxy.scrollTo("now", anchor: .trailing) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Meditation calendar"))
        .accessibilityValue(Text("\(doneCount) days met the minimum, \(missedCount) missed"))
    }

    private static func draw(_ state: MeditationDayState, in rect: CGRect, ctx: inout GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
        switch state {
        case .future, .notTracked:
            break
        case .notMeasured:
            ctx.stroke(shape, with: .color(TelosColor.lineSoft), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        case .done(let ratio):
            // Minutes against the day's minimum: at the minimum 55 %, at twice it (or more) full ink.
            let over: Double = min(max(ratio - 1, 0), 1)
            ctx.fill(shape, with: .color(TelosColor.focus.opacity(0.55 + 0.45 * over)))
        case .partial(let ratio):
            ctx.fill(shape, with: .color(TelosColor.focus.opacity(0.10 + 0.25 * min(max(ratio, 0), 1))))
            ctx.stroke(shape, with: .color(TelosColor.focus.opacity(0.6)), lineWidth: 1)
        case .missed:
            ctx.fill(shape, with: .color(TelosColor.critical.opacity(0.14)))
            ctx.stroke(shape, with: .color(TelosColor.critical), lineWidth: 1)
        case .open:
            ctx.stroke(shape, with: .color(TelosColor.textSecondary), lineWidth: 1)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(spacing: TelosSpace.m) {
                legendItem(fill: TelosColor.focus, stroke: nil, "Met")
                legendItem(fill: TelosColor.focus.opacity(0.2), stroke: TelosColor.focus, "Under the minimum")
                legendItem(fill: TelosColor.critical.opacity(0.14), stroke: TelosColor.critical, "Missed")
            }
            Text("A day counts from \(Int(LevelEngine.meditationMinMinutesBeforeChangeover)) minutes before 29 Sep 2026 and from \(Int(LevelEngine.meditationMinMinutes)) minutes since. Days before your first session are not tracked yet; days without data are not counted.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legendItem(fill: Color, stroke: Color?, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: TelosSpace.xs) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(stroke ?? Color.clear, lineWidth: 1)
                )
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(label)
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textSecondary)
        }
    }

    // MARK: - Weekly minutes

    private func weeklyBars(byDay: [String: Double], today: String) -> some View {
        let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: today) ?? today
        let weeks: [MeditationWeekMinutes] = Self.weekly(byDay: byDay, thisMonday: thisMonday,
                                                         weeks: Self.barWeeks)
        let top: Double = max(weeks.map { $0.minutes }.max() ?? 1, 1)
        let latest = weeks.last?.minutes ?? 0
        return VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly minutes")
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                Spacer()
                Text(verbatim: TelosFormat.integer(latest) + " min")
                    .font(TelosType.numeralXS)
                    .foregroundStyle(TelosColor.textPrimary)
            }
            HStack(alignment: .bottom, spacing: TelosSpace.xs) {
                ForEach(weeks) { w in
                    // Bars start at 0 (§2.3); an empty week is a bare 1 pt baseline, not a bar.
                    let h: CGFloat = w.minutes > 0 ? max(2, CGFloat(w.minutes / top) * 40) : 1
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(w.minutes > 0 ? TelosColor.focus : TelosColor.line)
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                }
            }
            .frame(height: 40, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Weekly minutes"))
            .accessibilityValue(Text(verbatim: weeks.map { TelosFormat.integer($0.minutes) }.joined(separator: ", ")))
        }
    }

    // MARK: - Recent days (the plain miss marking)

    private func recent(states: [MeditationDayEntry], byDay: [String: Double]) -> some View {
        let last = Array(states.suffix(Self.recentDays).reversed())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(last) { entry in
                recentRow(entry.day, entry.state, minutes: byDay[entry.day, default: 0])
                if entry.day != last.last?.day { TelosListDivider(leadingInset: 0) }
            }
            Text("A missed day takes \(Int(LevelEngine.meditationMissPenaltyPoints)) point off the level for each of the \(LevelEngine.meditationPenaltyWindowDays) days it sits in the level's window.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, TelosSpace.xs)
        }
    }

    private func recentRow(_ day: String, _ state: MeditationDayState, minutes: Double) -> some View {
        let minimum = LevelEngine.meditationMinMinutes(on: day)
        return HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            Text(verbatim: Self.dayLabel(day))
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textSecondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(verbatim: TelosFormat.integer(minutes) + " / " + TelosFormat.integer(minimum) + " min")
                .font(TelosType.numeralXS)
                .foregroundStyle(TelosColor.textPrimary)
            Spacer(minLength: TelosSpace.s)
            stateWord(state)
        }
        .padding(.vertical, TelosSpace.xs)
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stateWord(_ state: MeditationDayState) -> some View {
        switch state {
        case .done:
            Text("Met").font(TelosType.footnote).foregroundStyle(TelosColor.focusInk)
        case .partial, .missed:
            HStack(spacing: TelosSpace.xs) {
                Text("Missed").font(TelosType.footnote).foregroundStyle(TelosColor.critical)
                TelosTag(verbatim: TelosType.minus + TelosFormat.integer(LevelEngine.meditationMissPenaltyPoints),
                         ink: TelosColor.critical)
            }
        case .open:
            Text("Open").font(TelosType.footnote).foregroundStyle(TelosColor.textSecondary)
        case .notMeasured:
            Text("Not measured").font(TelosType.footnote).foregroundStyle(TelosColor.textTertiary)
        case .notTracked, .future:
            Text("Not tracked yet").font(TelosType.footnote).foregroundStyle(TelosColor.textTertiary)
        }
    }

    // MARK: - Sessions

    private enum SessionItem: Identifiable {
        case meditation(WorkoutRow)
        case breathing(BreathSessionRecord)

        var id: String {
            switch self {
            case .meditation(let w): return "m\(w.startTs)"
            case .breathing(let b): return "b" + b.id
            }
        }

        var startTs: Int {
            switch self {
            case .meditation(let w): return w.startTs
            case .breathing(let b): return b.startTs
            }
        }
    }

    private var sessionItems: [SessionItem] {
        let med = sessions.prefix(10).map { SessionItem.meditation($0) }
        let breath = breathLog.sessions.suffix(10).map { SessionItem.breathing($0) }
        return Array((med + breath).sorted { $0.startTs > $1.startTs }.prefix(10))
    }

    @ViewBuilder private var sessionList: some View {
        let items = sessionItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sessions")
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                    .padding(.bottom, TelosSpace.xs)
                ForEach(items) { item in
                    sessionRow(item)
                    if item.id != items.last?.id { TelosListDivider(leadingInset: 0) }
                }
            }
        }
    }

    private func sessionRow(_ item: SessionItem) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(item.startTs))
        return VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                Image(systemName: Self.isBreathing(item) ? "wind" : "figure.mind.and.body")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.focus)
                    .accessibilityHidden(true)
                Text(verbatim: start.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
                Spacer(minLength: TelosSpace.s)
                Text(verbatim: TelosFormat.integer(Self.minutes(item)) + " min")
                    .font(TelosType.numeralXS)
                    .foregroundStyle(TelosColor.textPrimary)
            }
            readingLine(item)
        }
        .padding(.vertical, TelosSpace.s)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func readingLine(_ item: SessionItem) -> some View {
        switch item {
        case .breathing(let b):
            // The S4 before/after — each a gated reading or "—" with its reason.
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: String(localized: "Before") + "  " + BreathSessionOutcome.line(b.outcome.pre))
                Text(verbatim: String(localized: "After") + "  " + BreathSessionOutcome.line(b.outcome.post)
                     + (BreathSessionOutcome.changeLine(b.outcome.change).map { "  " + $0 } ?? ""))
            }
            .font(TelosType.caption)
            .foregroundStyle(TelosColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        case .meditation:
            AbsentValue(reason: "No before/after reading for this session", dashFont: TelosType.caption,
                        arrangement: .inline)
        }
    }

    private static func isBreathing(_ item: SessionItem) -> Bool {
        if case .breathing = item { return true }
        return false
    }

    private static func minutes(_ item: SessionItem) -> Double {
        switch item {
        case .meditation(let w): return (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60
        case .breathing(let b): return b.pacedMinutes
        }
    }

    // MARK: - Data

    private func load() async {
        let map = await repo.meditationMinutesByDay()
        let rows = await repo.meditationSessions(days: 400)
        byDay = map
        sessions = rows
    }

    static func states(from era: String, to today: String, byDay: [String: Double],
                       measured: Set<String>) -> [MeditationDayEntry] {
        var out: [MeditationDayEntry] = []
        var day = era
        // Bounded: ten years of days at most, so a malformed key can never spin.
        var guardCount = 0
        while day <= today && guardCount < 3700 {
            let m = byDay[day] ?? 0
            let st = MeditationPractice.state(day: day, minutes: m, eraStart: era, today: today,
                                              measured: measured.contains(day))
            out.append(MeditationDayEntry(day: day, state: st))
            day = WeeklyDigestEngine.addDays(day, 1)
            guardCount += 1
        }
        return out
    }

    /// Minutes per Monday-started week, oldest first, the last one being this week.
    static func weekly(byDay: [String: Double], thisMonday: String, weeks: Int) -> [MeditationWeekMinutes] {
        (0..<max(0, weeks)).reversed().map { back -> MeditationWeekMinutes in
            let start = WeeklyDigestEngine.addDays(thisMonday, -7 * back)
            var sum = 0.0
            for d in 0..<7 { sum += byDay[WeeklyDigestEngine.addDays(start, d)] ?? 0 }
            return MeditationWeekMinutes(start: start, minutes: sum)
        }
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        var n = 0
        var d = a
        while d < b && n < 7 {
            d = WeeklyDigestEngine.addDays(d, 1)
            n += 1
        }
        return n
    }

    static func dayLabel(_ day: String) -> String {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day),
              let date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
        else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
