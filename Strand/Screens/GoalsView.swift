import SwiftUI
import StrandAnalytics
import StrandDesign

// GoalsView.swift — the Goals screen, laid out like a calendar (DESIGN_V2 coordinator decision 14).
//
// WHAT THE WEARER SEES:
//   * a month grid (Monday first) with each goal as a glowing dated marker on its target day, coloured by
//     its verdict; the selected goal's span from today to its date is lit on the grid, and its projection
//     band from Look ahead is drawn under the grid between today and the date (with the target marked);
//   * each goal as a card: target and date, the verdict as a chip — on track / ambitious but plausible /
//     unrealistic at this date (with a realistic date or value) / can't judge yet — and ALWAYS the numbers
//     behind it (current, target, required weekly change, projected range at the date, the plausible rate
//     and its basis);
//   * a passed date as an honest review (how far it moved, what was left), never a penalty;
//   * the short coach panel (`GoalCoachPanel`).
//
// Reached from More, the Level breakdown and Look ahead. Goals never alter measured values; the Level stays
// unbounded (a Level goal of 140 is allowed and judged like any other).
//
// TELOS 2.0 (PROGRESS): glass cards on the ground, the calendar as a luminous dotted field, verdict chips
// (colour + word, never colour alone), the band chart shared with Look ahead.
// COST: static; one refresh on appear. No animation, no timer.

@MainActor
struct GoalsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var source = ProjectionSource.shared
    @ObservedObject private var store = GoalStore.shared
    @State private var month: String = GoalsCalendar.firstOfMonth(Repository.localDayKey(Date()))
    @State private var selectedId: String?
    @State private var editing: GoalEditorTarget?

    private var today: String { Repository.localDayKey(Date()) }

    var body: some View {
        let assessments = store.activeGoals.map { source.assess($0, today: today) }
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.cardGap) {
                calendar(assessments)
                if let sel = assessments.first(where: { $0.goal.id == selectedId }) ?? assessments.first {
                    selectedBand(sel)
                }
                HStack(alignment: .center) {
                    SectionHeader("Goals", overline: "Targets on dates")
                    Spacer()
                    Button {
                        TelosHaptics.play(.select)
                        editing = GoalEditorTarget(goal: nil)
                    } label: {
                        Label("Add a goal", systemImage: "plus")
                    }
                    .buttonStyle(.noopGhost)
                }
                if assessments.isEmpty {
                    StrandCard {
                        TelosEmptyState(systemImage: "flag.checkered",
                                        title: "No goals yet",
                                        message: "Pick a figure, a target and a date — the screen shows how realistic it is on your own trend.",
                                        actionTitle: "Add a goal",
                                        action: { editing = GoalEditorTarget(goal: nil) })
                    }
                }
                ForEach(assessments, id: \.goal.id) { a in
                    GoalCard(assessment: a, selected: a.goal.id == (selectedId ?? assessments.first?.goal.id),
                             onSelect: { selectedId = a.goal.id },
                             onEdit: { editing = GoalEditorTarget(goal: a.goal) },
                             onArchive: { store.archive(id: a.goal.id) })
                }
                GoalCoachPanel(assessments: assessments, today: today)
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.vertical, TelosSpace.l)
        }
        .background(TelosColor.groundGradient.ignoresSafeArea())
        .navigationTitle(Text("Goals"))
        .sheet(item: $editing) { target in
            GoalEditorSheet(existing: target.goal, source: source, store: store, today: today)
        }
        .task {
            await source.refresh(model: model)
            store.noteAssessments(store.activeGoals.map { source.assess($0, today: today) }, today: today)
        }
    }

    // MARK: Calendar

    private func calendar(_ assessments: [GoalAssessment]) -> some View {
        let days = GoalsCalendar.gridDays(month: month)
        let byDay = Dictionary(grouping: assessments, by: { $0.goal.targetDate })
        let sel = assessments.first(where: { $0.goal.id == selectedId }) ?? assessments.first
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return StrandCard(tint: TelosColor.mint) {
            VStack(spacing: TelosSpace.s) {
                HStack {
                    monthButton("chevron.left", label: "Previous month") { month = GoalsCalendar.shift(month, by: -1) }
                    Spacer()
                    Text(GoalsCalendar.title(month).uppercased())
                        .font(TelosType.labelLarge)
                        .tracking(TelosType.Tracking.scale)
                        .foregroundStyle(TelosColor.textPrimary)
                    Spacer()
                    monthButton("chevron.right", label: "Next month") { month = GoalsCalendar.shift(month, by: 1) }
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(GoalsCalendar.weekdaySymbols[i])
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                    ForEach(days, id: \.self) { day in
                        dayCell(day, goals: byDay[day] ?? [], selected: sel)
                    }
                }
                HStack(spacing: TelosSpace.m) {
                    ForEach([GoalVerdict.onTrack, .ambitiousButPlausible, .unrealistic, .cantJudgeYet], id: \.self) { v in
                        HStack(spacing: TelosSpace.xs) {
                            Circle().fill(GoalVerdictStyle.color(v)).frame(width: 6, height: 6)
                            Text(v.title)
                                .font(TelosType.scaleNumber)
                                .foregroundStyle(TelosColor.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func monthButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            TelosHaptics.play(.select)
            action()
        } label: {
            Image(systemName: symbol)
                .font(TelosType.glyphChevron)
                .foregroundStyle(TelosColor.textSecondary)
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text(label))
    }

    private func dayCell(_ day: String, goals: [GoalAssessment], selected: GoalAssessment?) -> some View {
        let inMonth = day.hasPrefix(String(month.prefix(7)))
        let inSpan: Bool = {
            guard let s = selected else { return false }
            return day >= today && day <= s.goal.targetDate
        }()
        let isTarget = selected.map { $0.goal.targetDate == day } ?? false
        return VStack(spacing: 2) {
            Text(String(Int(day.suffix(2)) ?? 0))
                .font(TelosType.numeralFont(size: 12, weight: day == today ? .semibold : .regular))
                .foregroundStyle(day == today ? TelosColor.mint
                                 : (inMonth ? TelosColor.textPrimary : TelosColor.textTertiary.opacity(0.6)))
            HStack(spacing: 2) {
                ForEach(goals.prefix(3), id: \.goal.id) { g in
                    Circle()
                        .fill(GoalVerdictStyle.color(g.verdict))
                        .frame(width: 5, height: 5)
                        .background(Circle().fill(GoalVerdictStyle.color(g.verdict).opacity(0.3)).frame(width: 10, height: 10))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous)
                .fill(inSpan ? TelosColor.mint.opacity(TelosOpacity.whisper) : Color.clear)
        )
        .overlay(
            Group {
                if day == today {
                    Circle().strokeBorder(TelosColor.mint.opacity(0.6), lineWidth: TelosStroke.line).frame(width: 26, height: 26)
                        .offset(y: -4)
                } else if isTarget {
                    RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous)
                        .strokeBorder(TelosColor.mint.opacity(0.7), lineWidth: TelosStroke.line)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { if let g = goals.first { selectedId = g.goal.id } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(goals.isEmpty ? day : day + ", " + goals.map { $0.goal.metric.displayName + " " + $0.verdict.title }.joined(separator: ", ")))
    }

    // MARK: Selected goal's band

    @ViewBuilder
    private func selectedBand(_ a: GoalAssessment) -> some View {
        let m = a.goal.metric
        StrandCard(tint: LookAheadStyle.tint(m)) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                PGOverline(verbatim: m.displayName, ink: TelosColor.textSecondary)
                Text(verbatim: "→ \(m.formatWithUnit(a.goal.target)) · \(a.goal.targetDate)")
                    .font(TelosType.numeralS)
                    .foregroundStyle(TelosColor.textPrimary)
                if let p = source.trend(m).projection {
                    let weeks = ProjectionEngine.weeksBetween(p.currentWeek, a.goal.targetDate)
                    let upTo = p.bands.filter { Double($0.weeksAhead) <= (weeks ?? 0) + 1 }
                    ProjectionBandChart(metric: m, currentWeek: p.currentWeek, history: p.window,
                                        trend: upTo.isEmpty ? p.bands : upTo, plan: [],
                                        targetWeeksAhead: weeks, targetValue: a.goal.target,
                                        historyTint: LookAheadStyle.tint(m))
                    if a.projectedAtDate == nil {
                        AbsentValue(verbatimReason: a.noBandReason ?? "no projection at the date")
                    }
                } else {
                    AbsentValue(verbatimReason: source.trend(m).abstention?.text ?? "No projection")
                }
            }
        }
    }
}

// MARK: - One goal

@MainActor
struct GoalCard: View {
    let assessment: GoalAssessment
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void

    var body: some View {
        let a = assessment
        let m = a.goal.metric
        StrandCard(tint: GoalVerdictStyle.color(a.verdict)) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Text(m.displayName)
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: TelosSpace.s)
                    GoalVerdictChip(verdict: a.verdict)
                }
                Text(verbatim: "TARGET \(m.formatWithUnit(a.goal.target)) · \(a.goal.targetDate)"
                     + (a.goal.startDate.map { " · FROM \($0)" } ?? ""))
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(a.verdictLine)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(a.numbersLine)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(TelosSpace.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pgInsetBand()
                if let p = a.plausible {
                    Text("Plausible rate: " + p.basisText)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(a.caveats, id: \.self) { c in
                    Text(c)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: TelosSpace.xs) {
                    action("Show on calendar", onSelect)
                    action("Edit", onEdit)
                    action(LocalizedStringKey(a.verdict == .datePassed || a.verdict == .reached ? "Archive" : "Remove from calendar"),
                           onArchive)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous)
                .strokeBorder(selected ? TelosColor.mint.opacity(0.6) : Color.clear, lineWidth: TelosStroke.line)
        )
    }

    private func action(_ title: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        Button {
            TelosHaptics.play(.select)
            run()
        } label: {
            Text(title)
                .font(TelosType.footnote.weight(.semibold))
                .foregroundStyle(TelosColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, TelosSpace.s)
                .frame(minHeight: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
    }
}

/// The verdict as a chip: a lit dot + the verdict word, in the verdict's colour (never colour alone).
struct GoalVerdictChip: View {
    let verdict: GoalVerdict

    var body: some View {
        let c = GoalVerdictStyle.color(verdict)
        HStack(spacing: TelosSpace.xs) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(verbatim: verdict.title)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(c)
                .lineLimit(1)
        }
        .padding(.horizontal, TelosSpace.s)
        .frame(minHeight: 22)
        .background(Capsule(style: .continuous).fill(c.opacity(TelosOpacity.wash)))
        .overlay(Capsule(style: .continuous).strokeBorder(c.opacity(TelosOpacity.border), lineWidth: TelosStroke.line))
        .accessibilityElement(children: .combine)
    }
}

enum GoalVerdictStyle {
    static func color(_ v: GoalVerdict) -> Color {
        switch v {
        case .reached, .onTrack: return TelosColor.positive
        case .ambitiousButPlausible: return TelosColor.teal
        case .unrealistic: return TelosColor.warning
        case .datePassed, .cantJudgeYet: return TelosColor.textTertiary
        }
    }
}

// MARK: - Editor

struct GoalEditorTarget: Identifiable {
    let id = UUID()
    let goal: Goal?
}

@MainActor
struct GoalEditorSheet: View {
    let existing: Goal?
    @ObservedObject var source: ProjectionSource
    @ObservedObject var store: GoalStore
    let today: String
    @Environment(\.dismiss) private var dismiss

    @State private var metricId: String = ProjectionMetricID.level.id
    @State private var targetText = ""
    @State private var targetDate = Date().addingTimeInterval(12 * 7 * 86_400)
    @State private var useStart = false
    @State private var startDate = Date()

    private var metric: ProjectionMetricID { ProjectionMetricID(id: metricId) ?? .level }
    private var target: Double? { Double(targetText.replacingOccurrences(of: ",", with: ".")) }

    private var choices: [ProjectionMetricID] {
        var out: [ProjectionMetricID] = [.level] + LevelPart.allCases.map { ProjectionMetricID.part($0) }
        out += [.restingHR, .hrv, .vo2max, .aerobicMinutes, .steps, .sleepRegularity, .meditationMinutes]
        out += source.allLifts.map { ProjectionMetricID.e1rm(lift: $0) }
        if let e = existing, !out.contains(e.metric) { out.append(e.metric) }
        return out
    }

    /// The goal as currently entered (for the live verdict preview).
    private var draft: Goal? {
        guard let t = target else { return nil }
        let current = source.current(metric)?.value
        return Goal(id: existing?.id ?? "draft", metric: metric, target: t,
                    targetDate: Repository.localDayKey(targetDate),
                    startDate: useStart ? Repository.localDayKey(startDate) : nil,
                    createdOn: existing?.createdOn ?? today, startValue: existing?.startValue ?? current,
                    direction: Goal.direction(metric: metric, current: current, target: t))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Figure", selection: $metricId) {
                    ForEach(choices, id: \.id) { m in Text(m.displayName).tag(m.id) }
                }
                .disabled(existing != nil)
                if let c = source.current(metric) {
                    Text("Now: " + metric.formatWithUnit(c.value) + " (week of " + c.weekStart + ")")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                } else {
                    AbsentValue(reason: "no reading of this figure yet", arrangement: .inline)
                }
                TextField("Target" + (metric.unit.isEmpty ? "" : " (" + metric.unit + ")"), text: $targetText)
                DatePicker("Target date", selection: $targetDate, in: Date()..., displayedComponents: .date)
                Toggle("Start date", isOn: $useStart)
                    .tint(TelosColor.mint)
                if useStart {
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                }
                if let d = draft {
                    let a = source.assess(d, today: today)
                    VStack(alignment: .leading, spacing: TelosSpace.xs) {
                        GoalVerdictChip(verdict: a.verdict)
                        Text(a.verdictLine)
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(a.numbersLine)
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let e = existing {
                    Button("Delete this goal", role: .destructive) {
                        store.remove(id: e.id)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TelosColor.canvas.ignoresSafeArea())
            .navigationTitle(Text(existing == nil ? "New goal" : "Edit goal"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(target == nil)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let g = existing else { return }
        metricId = g.metric.id
        targetText = g.metric.format(g.target).replacingOccurrences(of: ",", with: "")
        if let d = GoalsCalendar.date(g.targetDate) { targetDate = d }
        if let s = g.startDate, let d = GoalsCalendar.date(s) {
            useStart = true
            startDate = d
        }
    }

    private func save() {
        guard let t = target else { return }
        let current = source.current(metric)?.value
        let date = Repository.localDayKey(targetDate)
        let start = useStart ? Repository.localDayKey(startDate) : nil
        if let e = existing {
            store.update(id: e.id, target: t, targetDate: date, startDate: start, current: current)
        } else {
            store.add(metric: metric, target: t, targetDate: date, startDate: start, current: current, today: today)
        }
        dismiss()
    }
}

// MARK: - Calendar arithmetic (strings, integer calendar math)

enum GoalsCalendar {
    static let weekdaySymbols = ["M", "T", "W", "T", "F", "S", "S"]

    /// "yyyy-MM-01" for the month containing `day`.
    static func firstOfMonth(_ day: String) -> String { String(day.prefix(8)) + "01" }

    /// Month `n` months after the month starting `first`.
    static func shift(_ first: String, by n: Int) -> String {
        guard let (y, m, _) = WeeklyDigestEngine.parseYMD(first) else { return first }
        let total = y * 12 + (m - 1) + n
        return String(format: "%04d-%02d-01", total / 12, total % 12 + 1)
    }

    /// 42 days (6 Monday-first weeks) covering the month.
    static func gridDays(month first: String) -> [String] {
        let start = WeeklyDigestEngine.mondayOfWeek(containing: first) ?? first
        return (0..<42).map { WeeklyDigestEngine.addDays(start, $0) }
    }

    static func title(_ first: String) -> String {
        guard let d = date(first) else { return first }
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: d)
    }

    /// Local midnight of a `yyyy-MM-dd` day.
    static func date(_ day: String) -> Date? {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }
}
