import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MeditationCardView.swift — the meditation practice, at the top of Focus (and in the Habits hub).
//
// THE DAILY MEDITATION IS AN ACTIVITY, not a timer on this card. The wearer logs a "Meditation" session
// the way they log any other — Start workout, the WHOOP app, Apple Health — and this card reads those
// sessions back (`Repository.meditationMinutesByDay` / `meditationSessions`). No new storage.
//
// THE PLAY BUTTON STARTS THAT ACTIVITY. It opens the in-exercise screen with the sport already set to
// Meditation, so sitting from here is the same recording as Start workout → Meditation — heart rate,
// duration, saved as a workout when it ends.
//
// TELOS 2.0 — THE PRACTICE VIEW (coordinator decision 12, owner: "much too simplistic … design glow up").
// In the Mind & Focus register (violet / magenta light on the dark ground):
//   1. the 28-day ring (days that met their minimum) beside everything ever sat, today's minutes against
//      today's minimum, and the play button;
//   2. a luminous 28-day calendar: each day a glowing dot sized by its minutes against THAT day's minimum
//      (5 min before 2026-09-29, 10 min from it — `MeditationLog.isDayDone(minutes:day:)` per day), missed
//      days marked plainly with their level cost, days without data "not measured", days before the first
//      session "not tracked yet" (never missed);
//   3. the minutes-per-day bar field (or weekly totals) with the date-effective minimum drawn as a step;
//   4. streak, best streak, average and longest session as compact tiles;
//   5. the Level line — meditation is a PENALTY-ONLY Level input (decision 10): the deduction on today's
//      level, exactly as the level engine computed it, and the rule behind it;
//   6. the recent sessions; "Whole practice" opens the time-of-day pattern and the era's month grids.
//
// COST: all static. One read per data refresh; one Canvas for the bar field; the particle texture is a
// single still frame (`animated: false`). No clock anywhere.

/// The start button's drawn diameter AND its reach — 44, the HIG minimum.
private let playButtonSize: CGFloat = 44
private let meditationSport = "Meditation"

struct MeditationCardView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var model: AppModel

    @State private var showLiveWorkout = false
    @State private var practice: MeditationPractice?
    @State private var recent: [WorkoutRow] = []
    /// Level points today's level lost to missed meditation days (nil = no settled level to read).
    @State private var levelDeduction: Double?
    @State private var weekly = false
    @State private var showsWhole = false

    /// The shared rule, not a local copy of the threshold — the Focus tab's reminder badge clears on
    /// exactly this, so the two must be one expression.
    private var doneToday: Bool {
        guard let p = practice else { return false }
        return MeditationLog.isDayDone(minutes: p.todayMinutes, day: p.today)
    }

    var body: some View {
        StrandCard(tint: TelosColor.violet) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                header
                if let p = practice {
                    todayBar(p)
                    MeditationCalendarGrid(days: p.window)
                    legend
                    barField(p)
                    stats(p)
                    levelLine(p)
                    if !recent.isEmpty { sessions(Array(recent.prefix(showsWhole ? 10 : 3))) }
                    if showsWhole { whole(p) }
                    if p.hasSessions { wholeToggle }
                }
                footer
            }
        }
        .task(id: repo.refreshSeq) { await reload() }
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: {
                showLiveWorkout = false
                Task { await reload() }
            })
            .environmentObject(model)
            .environmentObject(model.live)
        }
    }

    // MARK: - 1 · Header: the 28-day ring, the total, the play button

    private var header: some View {
        HStack(alignment: .center, spacing: TelosSpace.m) {
            ZStack {
                // Cost: one still Canvas frame (animated: false) — texture, not motion.
                TelosParticleField(color: TelosColor.magenta, count: 36, seed: 0x3ED17A7E,
                                   sizes: 0.6...1.6, drift: 0, animated: false)
                    .frame(width: 92, height: 92)
                    .clipShape(Circle())
                    .opacity(0.7)
                TelosRing(value: practice.map { Double($0.daysInWindow) },
                          scale: Double(MeditationPractice.windowDays),
                          color: TelosColor.violet,
                          diameter: 84,
                          caption: Text("OF \(MeditationPractice.windowDays)"),
                          captionColor: TelosColor.violetInk,
                          accessibilityLabel: Text("Days meditated, last \(MeditationPractice.windowDays)"))
            }
            .background(TelosRadialGlow(color: TelosColor.violet, intensity: 0.28, radius: 60))

            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                PGOverline("Meditation", ink: TelosColor.violetInk)
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                    Text(verbatim: TelosFormat.integer(practice?.totalMinutes ?? 0))
                        .telosNumeral(.numeralL)
                        .foregroundStyle(TelosColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("min")
                        .font(TelosType.unitFont(forNumeralSize: 34))
                        .foregroundStyle(TelosColor.textSecondary)
                }
                Text(totalCaption)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            playButton
        }
    }

    private var totalCaption: String {
        guard let p = practice, let start = p.eraStart, let date = GoalsCalendar.date(start) else {
            return String(localized: "TOTAL MEDITATED")
        }
        return String(localized: "TOTAL · SINCE \(TelosFormat.dayLabel(date).uppercased()) · \(p.sessionCount) SESSIONS")
    }

    /// Starts a Meditation activity and opens the in-exercise screen — or, when a session is already
    /// running, just reopens it rather than starting a second one.
    private var playButton: some View {
        let running = model.activeWorkout != nil
        return Button {
            TelosHaptics.play(.commit)
            if !running { model.startWorkout(sport: meditationSport) }
            showLiveWorkout = true
        } label: {
            Image(systemName: running ? "waveform.path.ecg" : "play.fill")
                .font(TelosType.glyphControl)
                .foregroundStyle(TelosColor.violetInk)
                .frame(width: playButtonSize, height: playButtonSize)
                .background(Circle().fill(TelosColor.violet.opacity(TelosOpacity.fill)))
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [TelosColor.violetInk.opacity(0.9), TelosColor.violet.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: TelosStroke.line))
                .contentShape(Circle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text(running ? "Open the running session" : "Start a meditation"))
    }

    // MARK: - Today against today's minimum

    private func todayBar(_ p: MeditationPractice) -> some View {
        let done = doneToday
        let mins = TelosFormat.integer(p.todayMinutes)
        let floor = TelosFormat.integer(p.todayMinimum)
        return HStack(alignment: .center, spacing: TelosSpace.s) {
            PGOverline("Today")
            TelosSegmentedBar(value: p.todayMinutes, scale: p.todayMinimum, segments: 10,
                              color: done ? TelosColor.violet : TelosColor.violetInk.opacity(0.7), height: 6)
            Text(verbatim: "\(mins) / \(floor) MIN")
                .font(TelosType.scaleNumber)
                .foregroundStyle(done ? TelosColor.violetInk : TelosColor.textSecondary)
                .fixedSize()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.violetInk)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today"))
        .accessibilityValue(done ? Text("\(mins) of \(floor) minutes, done")
                                 : Text("\(mins) of \(floor) minutes, still open"))
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: TelosSpace.m) {
            legendItem(.done, "met")
            legendItem(.missed, "missed")
            legendItem(.notMeasured, "not measured")
            legendItem(.beforeEra, "not tracked yet")
        }
        .font(TelosType.scaleNumber)
        .foregroundStyle(TelosColor.textTertiary)
        .accessibilityHidden(true)
    }

    private func legendItem(_ state: MeditationDayState, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: TelosSpace.xs) {
            MeditationGlowDot(state: state, minutes: state == .done ? 10 : 0, minimum: 10, cell: 14)
            Text(label).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: - 3 · Minutes per day / per week

    private func barField(_ p: MeditationPractice) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack(spacing: TelosSpace.xs) {
                PGOverline(weekly ? "Minutes per week" : "Minutes per day")
                Spacer(minLength: TelosSpace.s)
                TelosChip("28 d", isOn: !weekly) { weekly = false }
                TelosChip("12 wk", isOn: weekly) { weekly = true }
            }
            if weekly {
                MeditationWeekField(weeks: p.weeks)
                    .frame(height: 92)
            } else {
                MeditationBarField(days: p.window)
                    .frame(height: 92)
            }
            Text(weekly
                 ? "Dashed: the week's minimums added up (5 min a day before 29 Sep 2026, 10 min from it)."
                 : "Dashed: that day's minimum (5 min before 29 Sep 2026, 10 min from it).")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 4 · Streak, best, average, longest

    private func stats(_ p: MeditationPractice) -> some View {
        let none = Text("No session yet")
        let hasEra = p.eraStart != nil
        return TelosTileGrid(minTileWidth: 72, maxColumns: 4) {
            TelosMetricTile("Streak", value: hasEra ? Double(p.currentStreak) : nil, unit: "d",
                            absentReason: none, icon: "flame", iconTint: TelosColor.magenta)
            TelosMetricTile("Best", value: hasEra ? Double(p.bestStreak) : nil, unit: "d",
                            absentReason: none, icon: "crown", iconTint: TelosColor.violetInk)
            TelosMetricTile("Avg session", value: p.averageSessionMinutes, unit: "min",
                            absentReason: none, icon: "timer", iconTint: TelosColor.violetInk)
            TelosMetricTile("Longest", value: p.longestSessionMinutes, unit: "min",
                            absentReason: none, icon: "arrow.up.to.line", iconTint: TelosColor.violetInk)
        }
    }

    // MARK: - 5 · The Level line (penalty-only input)

    private func levelLine(_ p: MeditationPractice) -> some View {
        let perDay = TelosFormat.integer(LevelEngine.meditationMissPenaltyPoints)
        let window = LevelEngine.meditationPenaltyWindowDays
        let costing = (levelDeduction ?? 0) > 0
        return VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                Image(systemName: "arrow.down.right.circle")
                    .font(TelosType.glyphRow)
                    .foregroundStyle(deductionInk(p))
                    .accessibilityHidden(true)
                PGOverline("Level")
                Spacer(minLength: TelosSpace.s)
                deductionValue(p)
            }
            Text(deductionDetail(p))
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Meditation never adds to your Level. In its era, each measured day under its minimum costs \(perDay) point on every level whose \(window)-day window holds it.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TelosSpace.m)
        .pgInsetBand(tint: costing ? TelosColor.critical : nil)
        .accessibilityElement(children: .combine)
    }

    private func deductionInk(_ p: MeditationPractice) -> Color {
        guard p.eraStart != nil, let d = levelDeduction else { return TelosColor.textTertiary }
        return d > 0 ? TelosColor.critical : TelosColor.positive
    }

    @ViewBuilder
    private func deductionValue(_ p: MeditationPractice) -> some View {
        if p.eraStart != nil, let d = levelDeduction {
            Text(verbatim: d > 0 ? "\(TelosType.minus)\(TelosFormat.decimal(d.rounded() == d ? 0 : 1)(d)) PTS" : "\u{00B1}0 PTS")
                .font(TelosType.numeralXS)
                .foregroundStyle(d > 0 ? TelosColor.critical : TelosColor.positive)
        } else {
            Text(verbatim: TelosType.absent)
                .font(TelosType.numeralS)
                .foregroundStyle(TelosColor.textTertiary)
        }
    }

    private func deductionDetail(_ p: MeditationPractice) -> String {
        guard p.eraStart != nil else {
            return String(localized: "No meditation term in your Level yet. It starts with your first logged session.")
        }
        guard let d = levelDeduction else {
            return String(localized: "Today's Level is not settled yet, so there is no deduction to show.")
        }
        let window = LevelEngine.meditationPenaltyWindowDays
        if d > 0 {
            let missed = p.missedInLevelWindow ?? 0
            return String(localized: "Deducted from today's Level. Missed days in the last \(window): \(missed).")
        }
        return String(localized: "No deduction on today's Level: every measured day in the last \(window) met its minimum.")
    }

    // MARK: - 6 · Sessions

    private func sessions(_ rows: [WorkoutRow]) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            PGOverline("Recent sessions")
            ForEach(Array(rows.enumerated()), id: \.offset) { i, w in
                if i > 0 { TelosListDivider(leadingInset: 0) }
                sessionRow(w)
            }
        }
    }

    private func sessionRow(_ w: WorkoutRow) -> some View {
        let minutes: Double = (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60
        return HStack(spacing: TelosSpace.s) {
            Circle()
                .fill(TelosColor.violet)
                .frame(width: 6, height: 6)
                .background(Circle().fill(TelosColor.violet.opacity(0.3)).frame(width: 12, height: 12))
                .accessibilityHidden(true)
            Text(Self.when(w))
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textSecondary)
            Spacer(minLength: 0)
            if let hr = w.avgHr {
                Text(verbatim: "\(hr) BPM AVG")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            Text(verbatim: "\(TelosFormat.integer(minutes)) min")
                .font(TelosType.numeralXS)
                .foregroundStyle(TelosColor.textPrimary)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Whole practice (time of day + the era's months)

    private var wholeToggle: some View {
        Button {
            TelosHaptics.play(.select)
            withAnimation(TelosMotion.fade) { showsWhole.toggle() }
        } label: {
            HStack(spacing: TelosSpace.xs) {
                Text(showsWhole ? "Less" : "Whole practice")
                Image(systemName: showsWhole ? "chevron.up" : "chevron.down")
                    .font(TelosType.glyphChevron)
            }
            .font(TelosType.subhead.weight(.semibold))
            .foregroundStyle(TelosColor.violetInk)
            .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
    }

    private func whole(_ p: MeditationPractice) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            timeOfDay(p)
            ForEach(p.months()) { month in
                MeditationMonthGrid(month: month)
            }
        }
        .transition(.opacity)
    }

    private func timeOfDay(_ p: MeditationPractice) -> some View {
        let labels: [LocalizedStringKey] = ["Morning", "Midday", "Evening", "Night"]
        let top: Int = max(p.timeOfDay.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: TelosSpace.xs) {
            PGOverline("When you sit")
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: TelosSpace.s) {
                    Text(labels[i])
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .frame(width: 72, alignment: .leading)
                    TimeOfDayBar(fraction: CGFloat(p.timeOfDay[i]) / CGFloat(top), lit: p.timeOfDay[i] > 0)
                        .frame(height: 6)
                    Text(verbatim: "\(p.timeOfDay[i])")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                        .frame(minWidth: 22, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(labels[i]))
                .accessibilityValue(Text("\(p.timeOfDay[i]) sessions"))
            }
            Text("Morning 05–11 · midday 11–17 · evening 17–22 · night 22–05, by session start.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text(doneToday
             ? "Meditated today. A day counts from \(Int(LevelEngine.meditationMinMinutes)) minutes."
             : "Press play to start a Meditation activity, or log one in the WHOOP app or Apple Health. A day counts from \(Int(LevelEngine.meditationMinMinutes)) minutes.")
            .font(TelosType.caption)
            .foregroundStyle(TelosColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Behaviour

    private func reload() async {
        let byDay = await repo.meditationMinutesByDay()
        let all = await repo.meditationSessions()
        let measured = Set(repo.days.map(\.day))
        let sessions: [(start: Date, minutes: Double)] = all.map { w in
            (start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
             minutes: (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60)
        }
        practice = MeditationPractice.build(byDay: byDay, sessions: sessions, measuredDays: measured)
        recent = Array(all.prefix(10))
        // The deduction exactly as the level engine made it (`LevelBreakdown.meditationPenalty`), never a
        // second computation of it.
        levelDeduction = LevelBarModel.shared.trend?.now?.meditationPenalty
    }

    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f
    }()

    private static func when(_ w: WorkoutRow) -> String {
        whenFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(w.startTs)))
    }
}

/// One time-of-day share bar (static).
private struct TimeOfDayBar: View {
    let fraction: CGFloat
    let lit: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(TelosColor.violet.opacity(TelosOpacity.whisper))
                if lit {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [TelosColor.violet, TelosColor.magenta],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
    }
}

// MARK: - The glowing day dot

/// One day. Done: a violet→magenta core sized by minutes against that day's minimum, inside a soft
/// pre-composited glow (no blur); twice the minimum or more adds a thin outer ring. Missed: a hollow
/// critical ring carrying its level cost. Not measured: a dashed ring. Before the era: a faint speck.
/// Today open: a ring filled to today's share of the minimum.
struct MeditationGlowDot: View {
    let state: MeditationDayState
    let minutes: Double
    let minimum: Double
    var cell: CGFloat = 34
    var showsCost = false

    private var ratio: Double { minimum > 0 ? max(0, minutes) / minimum : 0 }

    var body: some View {
        ZStack {
            switch state {
            case .done: doneDot
            case .missed: missedDot
            case .notMeasured:
                Circle()
                    .strokeBorder(TelosColor.textTertiary.opacity(0.6),
                                  style: StrokeStyle(lineWidth: TelosStroke.hair, dash: [2, 2]))
                    .frame(width: cell * 0.55, height: cell * 0.55)
            case .beforeEra:
                Circle()
                    .fill(TelosColor.textTertiary.opacity(0.25))
                    .frame(width: max(2, cell * 0.10), height: max(2, cell * 0.10))
            case .open: openDot
            }
        }
        .frame(width: cell, height: cell)
    }

    private var doneDot: some View {
        let core: CGFloat = cell * CGFloat(min(0.62, 0.30 + 0.16 * sqrt(ratio)))
        return ZStack {
            RadialGradient(colors: [TelosColor.violet.opacity(0.45), TelosColor.magenta.opacity(0.10), .clear],
                           center: .center, startRadius: 0, endRadius: cell * 0.55)
            Circle()
                .fill(RadialGradient(colors: [TelosColor.magentaInk, TelosColor.violet],
                                     center: .topLeading, startRadius: 0, endRadius: core))
                .frame(width: core, height: core)
            if ratio >= 2 {
                Circle()
                    .strokeBorder(TelosColor.magenta.opacity(0.6), lineWidth: TelosStroke.hair)
                    .frame(width: cell * 0.82, height: cell * 0.82)
            }
        }
    }

    private var missedDot: some View {
        ZStack {
            Circle()
                .strokeBorder(TelosColor.critical.opacity(0.7), lineWidth: TelosStroke.line)
                .frame(width: cell * 0.62, height: cell * 0.62)
            if showsCost {
                Text(verbatim: "\(TelosType.minus)\(TelosFormat.integer(LevelEngine.meditationMissPenaltyPoints))")
                    .font(TelosType.numeralFont(size: max(8, cell * 0.28), weight: .medium))
                    .foregroundStyle(TelosColor.critical)
            } else if minutes > 0 {
                Circle().fill(TelosColor.violet.opacity(0.5)).frame(width: cell * 0.16, height: cell * 0.16)
            }
        }
    }

    private var openDot: some View {
        ZStack {
            Circle()
                .stroke(TelosColor.violet.opacity(TelosOpacity.fill), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, ratio)))
                .stroke(TelosColor.violetInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: cell * 0.62, height: cell * 0.62)
    }
}

// MARK: - The 28-day calendar

/// Four rows of seven consecutive days, oldest top-left; the column letters come from the first row.
struct MeditationCalendarGrid: View {
    let days: [MeditationDay]

    private static let letter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()
    private static let spoken: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    private var rows: [[MeditationDay]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    var body: some View {
        VStack(spacing: TelosSpace.xxs) {
            if let first = rows.first {
                HStack(spacing: 0) {
                    ForEach(first) { d in
                        Text(verbatim: Self.letter.string(from: d.date))
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { d in
                        MeditationGlowDot(state: d.state, minutes: d.minutes, minimum: d.minimum, showsCost: true)
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: Self.spoken.string(from: d.date)))
                            .accessibilityValue(Self.spokenValue(d))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Meditation, last 28 days"))
    }

    static func spokenValue(_ d: MeditationDay) -> Text {
        let mins = TelosFormat.integer(d.minutes)
        let floor = TelosFormat.integer(d.minimum)
        switch d.state {
        case .done: return Text("\(mins) minutes, minimum \(floor), met")
        case .missed: return Text("\(mins) minutes, minimum \(floor), missed, costs 1 level point for 7 days")
        case .notMeasured: return Text("\(mins) minutes, not measured")
        case .beforeEra: return Text("Not tracked yet")
        case .open: return Text("\(mins) of \(floor) minutes, still open")
        }
    }
}

// MARK: - One month of the era

struct MeditationMonthGrid: View {
    let month: MeditationMonth

    private static let title: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    private var rows: [[MeditationDay?]] {
        stride(from: 0, to: month.cells.count, by: 7).map {
            Array(month.cells[$0..<min($0 + 7, month.cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            PGOverline(verbatim: Self.title.string(from: month.first))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        cell(i < row.count ? row[i] : nil)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cell(_ day: MeditationDay?) -> some View {
        if let d = day {
            MeditationGlowDot(state: d.state, minutes: d.minutes, minimum: d.minimum, cell: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: d.day))
                .accessibilityValue(MeditationCalendarGrid.spokenValue(d))
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }
}

// MARK: - The bar fields

/// Minutes per day, bars from zero; the date-effective minimum as a dashed step across the bar slots.
/// Days before the era draw no bar (a speck on the baseline), so "not tracked" never reads as zero.
struct MeditationBarField: View {
    let days: [MeditationDay]

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Minutes per day, last 28 days"))
        .accessibilityValue(Text("\(days.filter { $0.state == .done }.count) of \(days.count) days met their minimum"))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard !days.isEmpty, size.width > 0 else { return }
        let peak: Double = days.map(\.minutes).max() ?? 0
        let floorPeak: Double = days.map(\.minimum).max() ?? 10
        let top: Double = max(peak, floorPeak) * 1.15
        let slot: CGFloat = size.width / CGFloat(days.count)
        let barW: CGFloat = max(2, slot * 0.56)
        let h: CGFloat = size.height - 12
        func y(_ v: Double) -> CGFloat { h - CGFloat(v / top) * h }

        var base = Path()
        base.move(to: CGPoint(x: 0, y: h))
        base.addLine(to: CGPoint(x: size.width, y: h))
        ctx.stroke(base, with: .color(TelosColor.lineSoft), lineWidth: TelosStroke.hair)

        for (i, d) in days.enumerated() {
            let cx: CGFloat = slot * (CGFloat(i) + 0.5)
            if d.state == .beforeEra {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 1, y: h - 1, width: 2, height: 2)),
                         with: .color(TelosColor.textTertiary.opacity(0.35)))
                continue
            }
            if d.minutes > 0 {
                let topY: CGFloat = y(d.minutes)
                let rect = CGRect(x: cx - barW / 2, y: topY, width: barW, height: h - topY)
                let bar = Path(roundedRect: rect, cornerRadius: min(barW / 2, 3), style: .continuous)
                if d.state == .done {
                    ctx.fill(bar, with: .linearGradient(Gradient(colors: [TelosColor.magentaInk, TelosColor.violet.opacity(0.55)]),
                                                        startPoint: CGPoint(x: cx, y: topY),
                                                        endPoint: CGPoint(x: cx, y: h)))
                    // The luminous cap: one small halo dot, no blur.
                    let halo = CGRect(x: cx - barW * 0.7, y: topY - barW * 0.7, width: barW * 1.4, height: barW * 1.4)
                    ctx.fill(Path(ellipseIn: halo), with: .color(TelosColor.magenta.opacity(0.22)))
                } else {
                    ctx.fill(bar, with: .color(TelosColor.textTertiary.opacity(0.4)))
                }
            } else if d.state == .missed {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.5, y: h - 1.5, width: 3, height: 3)),
                         with: .color(TelosColor.critical.opacity(0.8)))
            }
            // The minimum in force that day, as a step.
            let floorY: CGFloat = y(d.minimum)
            var step = Path()
            step.move(to: CGPoint(x: cx - slot / 2, y: floorY))
            step.addLine(to: CGPoint(x: cx + slot / 2, y: floorY))
            ctx.stroke(step, with: .color(TelosColor.textSecondary.opacity(0.7)),
                       style: StrokeStyle(lineWidth: TelosStroke.line, dash: [2, 2]))
        }
        if let last = days.last {
            ctx.draw(Text(verbatim: "\(TelosFormat.integer(last.minimum)) MIN").font(TelosType.scaleNumber)
                        .foregroundColor(TelosColor.textSecondary),
                     at: CGPoint(x: size.width, y: y(last.minimum) - 2), anchor: .bottomTrailing)
        }
        if let first = days.first {
            ctx.draw(Text(verbatim: TelosFormat.dayLabel(first.date)).font(TelosType.scaleNumber)
                        .foregroundColor(TelosColor.textTertiary),
                     at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
        }
        ctx.draw(Text("TODAY").font(TelosType.scaleNumber).foregroundColor(TelosColor.textTertiary),
                 at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
    }
}

/// Minutes per week (Monday first), with the week's summed minimums as a dashed step.
struct MeditationWeekField: View {
    let weeks: [MeditationWeek]

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Minutes per week, last 12 weeks"))
        .accessibilityValue(Text("This week \(TelosFormat.integer(weeks.last?.minutes ?? 0)) minutes"))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard !weeks.isEmpty, size.width > 0 else { return }
        let peak: Double = weeks.map(\.minutes).max() ?? 0
        let floorPeak: Double = weeks.map(\.minimumSum).max() ?? 0
        let top: Double = max(peak, floorPeak, 10) * 1.15
        let slot: CGFloat = size.width / CGFloat(weeks.count)
        let barW: CGFloat = max(3, slot * 0.5)
        let h: CGFloat = size.height - 12
        func y(_ v: Double) -> CGFloat { h - CGFloat(v / top) * h }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: h))
        base.addLine(to: CGPoint(x: size.width, y: h))
        ctx.stroke(base, with: .color(TelosColor.lineSoft), lineWidth: TelosStroke.hair)
        for (i, w) in weeks.enumerated() {
            let cx: CGFloat = slot * (CGFloat(i) + 0.5)
            if w.isBeforeEra {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 1, y: h - 1, width: 2, height: 2)),
                         with: .color(TelosColor.textTertiary.opacity(0.35)))
                continue
            }
            if w.minutes > 0 {
                let topY: CGFloat = y(w.minutes)
                let rect = CGRect(x: cx - barW / 2, y: topY, width: barW, height: h - topY)
                let met = w.minutes >= w.minimumSum
                let colors: [Color] = met
                    ? [TelosColor.magentaInk, TelosColor.violet.opacity(0.5)]
                    : [TelosColor.violet.opacity(0.7), TelosColor.violet.opacity(0.25)]
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(barW / 2, 3), style: .continuous),
                         with: .linearGradient(Gradient(colors: colors),
                                               startPoint: CGPoint(x: cx, y: topY), endPoint: CGPoint(x: cx, y: h)))
            }
            if w.minimumSum > 0 {
                let floorY: CGFloat = y(w.minimumSum)
                var step = Path()
                step.move(to: CGPoint(x: cx - slot / 2, y: floorY))
                step.addLine(to: CGPoint(x: cx + slot / 2, y: floorY))
                ctx.stroke(step, with: .color(TelosColor.textSecondary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: TelosStroke.line, dash: [2, 2]))
            }
        }
        if let first = weeks.first {
            ctx.draw(Text(verbatim: TelosFormat.dayLabel(first.start)).font(TelosType.scaleNumber)
                        .foregroundColor(TelosColor.textTertiary),
                     at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
        }
        ctx.draw(Text("THIS WEEK").font(TelosType.scaleNumber).foregroundColor(TelosColor.textTertiary),
                 at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
    }
}
