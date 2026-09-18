import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MorningFlowView.swift — the first open of the day: the dream, the night in a few taps, the daily brief.
//
// THREE STAGES, ONE SCREEN AT A TIME, in the look of a diagnostic: a thin progress bar under a back
// chevron, a small grey overline, a heavy wide headline, four option cards with an icon, a title, a line
// of explanation and a radio, and one blue CONFIRM at the foot.
//
//   1. The dream, written down before it fades.
//   2. The night, as four-option questions (`DreamQuestions`).
//   3. The daily brief: the level the day starts on, counted up; Rest and Charge; the night's key figures
//      against yesterday's; and a written brief — light, and how to shape the day.
//
// THE DAY'S LEVEL IS COMPUTED HERE. Opening the flow marks the day as begun (`LevelDayFreeze.beginDay`),
// forces a fresh sync of strap and cloud, and reloads the level — so by the time the brief is on screen,
// today's level has been scored from the night and frozen for the day. The work starts the moment the
// flow opens, and runs while the wearer is writing, so the brief is ready when they reach it.

// MARK: - The look

private enum Diag {
    static let background = Color.black
    static let card = Color(.sRGB, red: 0.071, green: 0.071, blue: 0.078, opacity: 1)
    static let cardBorder = Color(white: 0.17)
    static let blue = Color(.sRGB, red: 0.18, green: 0.46, blue: 1.0, opacity: 1)
    static let selectedFill = Color(.sRGB, red: 0.035, green: 0.09, blue: 0.2, opacity: 1)
    static let track = Color(white: 0.13)
    static let grey = Color(white: 0.55)
    static let icon = Color(white: 0.62)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.expanded) }
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.expanded) }
}

// MARK: - The flow

struct MorningFlowView: View {
    @ObservedObject var levelBar: LevelBarModel
    let onDone: () -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine

    @StateObject private var brief = DailyBriefModel()
    @State private var step = 0
    @State private var dream = ""
    @State private var answers: [String: Int] = [:]
    @State private var selection: Int?

    private var questions: [DreamQuestion] { DreamQuestions.all }
    /// Dream, questions, brief.
    private var total: Int { questions.count + 2 }
    private var isBrief: Bool { step == total - 1 }

    var body: some View {
        ZStack {
            Diag.background.ignoresSafeArea()
            if isBrief {
                DailyBriefView(model: brief, levelBar: levelBar, onDone: onDone)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                        .padding(.top, 8)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if step == 0 { dreamStage } else { questionStage(questions[step - 1]) }
                        }
                        .padding(.top, 36)
                    }
                    confirmButton
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // The day begins now: today's level from here on, and the work that scores it starts at once.
            LevelDayFreeze.beginDay()
            await brief.prepare(repo: repo, levelBar: levelBar)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 20) {
            Button {
                if step == 0 {
                    // Skipping the morning goes straight to the brief rather than out of it.
                    finishEntry()
                } else {
                    withAnimation(.easeOut(duration: 0.25)) {
                        step -= 1
                        selection = step == 0 ? nil : answers[questions[step - 1].id]
                    }
                }
            } label: {
                Image(systemName: step == 0 ? "xmark" : "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step == 0 ? "Skip to the brief" : "Back")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Diag.track)
                    Capsule().fill(Diag.blue)
                        .frame(width: geo.size.width * Double(step + 1) / Double(total))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.3), value: step)
        }
    }

    // MARK: Stage 1 — the dream

    private var dreamStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DREAM JOURNAL")
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Diag.grey)
            Text("What did you dream?")
                .font(Diag.display(38))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            ZStack(alignment: .topLeading) {
                if dream.isEmpty {
                    Text("Write it down before it fades. A few words are enough.")
                        .font(.system(size: 16))
                        .foregroundStyle(Diag.grey)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $dream)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 220)
            }
            .background(Diag.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Diag.cardBorder, lineWidth: 1))
            .padding(.top, 32)
        }
    }

    // MARK: Stage 2 — the night

    private func questionStage(_ q: DreamQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(q.overline.uppercased())
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Diag.grey)
            Text(q.title)
                .font(Diag.display(38))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            VStack(spacing: 14) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                    OptionCard(option: option, selected: selection == index) {
                        SystemHaptics.play(.select)
                        withAnimation(.easeOut(duration: 0.15)) { selection = index }
                    }
                }
            }
            .padding(.top, 32)
        }
    }

    // MARK: Confirm

    private var confirmEnabled: Bool { step == 0 || selection != nil }

    private var confirmButton: some View {
        Button {
            guard confirmEnabled else { return }
            SystemHaptics.play(.confirm)
            if step > 0, let selection { answers[questions[step - 1].id] = selection }
            if step >= questions.count {
                finishEntry()
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    step += 1
                    selection = answers[questions[step - 1].id]
                }
            }
        } label: {
            Text("CONFIRM")
                .font(Diag.heavy(20))
                .tracking(1.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(Diag.blue.opacity(confirmEnabled ? 1 : 0.35), in: Capsule())
                .shadow(color: Diag.blue.opacity(confirmEnabled ? 0.55 : 0), radius: 22, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    /// Save the morning's entry (whatever of it was given) and move on to the brief.
    private func finishEntry() {
        let entry = DreamEntry(day: Repository.localDayKey(Date()), text: dream, answers: answers,
                               updatedAt: Date())
        let hasSomething = !dream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !answers.isEmpty
        withAnimation(.easeOut(duration: 0.3)) { step = total - 1 }
        Task {
            if hasSomething { await DreamJournalStore.shared.save(entry, repo: repo) }
            await brief.writeSummary(coach: coach, repo: repo, levelBar: levelBar,
                                     dream: hasSomething ? entry : nil)
        }
    }
}

/// One of the four answers: icon, title, line of explanation, radio.
private struct OptionCard: View {
    let option: DreamQuestion.Option
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: option.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected ? Diag.blue : Diag.icon)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(Diag.heavy(20))
                        .foregroundStyle(selected ? .white : Color(white: 0.9))
                    Text(option.subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(Diag.grey)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Diag.blue : Color(white: 0.35), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    if selected {
                        Circle().fill(Diag.blue).frame(width: 16, height: 16)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Diag.selectedFill : Diag.card,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Diag.blue : Diag.cardBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The brief's figures

@MainActor
final class DailyBriefModel: ObservableObject {

    /// One key figure of the night, today against yesterday.
    struct Metric: Identifiable {
        let id: String
        let label: String
        let value: String
        /// Positive when today is higher than yesterday.
        let change: Double?
        /// Whether a rise is good news (HRV) or bad (resting HR).
        let higherIsBetter: Bool?
    }

    @Published private(set) var ready = false
    @Published private(set) var level: Double?
    @Published private(set) var levelYesterday: Double?
    @Published private(set) var charge: Double?
    @Published private(set) var rest: Double?
    @Published private(set) var metrics: [Metric] = []
    @Published private(set) var summary: String?
    @Published private(set) var writing = false
    @Published private(set) var summaryUnavailable = false

    private var prepared = false

    /// Sync, score and freeze the day's level, and gather the night's figures.
    func prepare(repo: Repository, levelBar: LevelBarModel) async {
        guard !prepared else { return }
        prepared = true
        await repo.refreshEverything(force: true)
        await levelBar.reload(repo: repo)
        level = levelBar.trend?.now?.level
        levelYesterday = levelBar.trend?.yesterdayLevel

        let today = Repository.localDayKey(Date())
        let own = await repo.noopScores(day: today)
        let row = repo.days.first { $0.day == today }
        // WHOOP's own night first, as everywhere else: it may have held the strap overnight.
        charge = await repo.whoopCloudDay(today)?.recovery ?? own.charge ?? row?.recovery
        rest = await repo.whoopCloudSleepScore(day: today) ?? own.rest

        let yesterdayKey = Repository.localDayKey(Date().addingTimeInterval(-86_400))
        let prev = repo.days.first { $0.day == yesterdayKey }
        metrics = Self.metrics(today: row, yesterday: prev)
        ready = true
    }

    static func metrics(today: DailyMetric?, yesterday: DailyMetric?) -> [Metric] {
        func m(_ id: String, _ label: String, _ now: Double?, _ then: Double?, _ fmt: (Double) -> String,
               _ higherIsBetter: Bool?) -> Metric? {
            guard let now else { return nil }
            return Metric(id: id, label: label, value: fmt(now), change: then.map { now - $0 },
                          higherIsBetter: higherIsBetter)
        }
        func hm(_ min: Double) -> String { "\(Int(min) / 60)h \(String(format: "%02d", Int(min) % 60))m" }
        let restorative: (DailyMetric?) -> Double? = { d in
            guard let deep = d?.deepMin, let rem = d?.remMin else { return nil }
            return deep + rem
        }
        return [
            m("hrv", "HRV", today?.avgHrv, yesterday?.avgHrv, { "\(Int($0.rounded())) ms" }, true),
            m("rhr", "Resting HR", today?.restingHr.map(Double.init), yesterday?.restingHr.map(Double.init),
              { "\(Int($0.rounded())) bpm" }, false),
            m("sleep", "Sleep", today?.totalSleepMin, yesterday?.totalSleepMin, hm, true),
            m("restorative", "Deep + REM", restorative(today), restorative(yesterday), hm, true),
            m("resp", "Resp. rate", today?.respRateBpm, yesterday?.respRateBpm,
              { String(format: "%.1f /min", $0) }, false),
            m("spo2", "SpO₂", today?.spo2Pct, yesterday?.spo2Pct, { String(format: "%.0f %%", $0) }, true),
            m("skin", "Skin temp", today?.skinTempDevC, yesterday?.skinTempDevC,
              { String(format: "%+.1f °C", $0) }, nil),
        ].compactMap { $0 }
    }

    /// The written brief: the morning briefing, grounded in the night, the level and the morning's answers.
    func writeSummary(coach: AICoachEngine, repo: Repository, levelBar: LevelBarModel, dream: DreamEntry?) async {
        guard summary == nil, !writing else { return }
        writing = true
        defer { writing = false }
        // The figures it is grounded in have to be in first.
        while !ready { try? await Task.sleep(nanoseconds: 200_000_000) }
        var extra: [String] = []
        if let level { extra.append(String(format: "Today's level: %.0f (50 = their own average)", level)) }
        for metric in metrics {
            var line = "\(metric.label): \(metric.value)"
            if let c = metric.change { line += String(format: " (%+.1f vs yesterday)", c) }
            extra.append(line)
        }
        if let dream {
            extra += DreamJournalStore.summary(dream)
            if !dream.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extra.append("They wrote down a dream this morning.")
            }
        }
        let grounding = RitualGrounding(recovery: charge, sleepScore: rest, strain: nil, extra: extra)
        if let result = await DayRitualScheduler.runIfDue(.morning, repo: repo, coach: coach, grounding: grounding) {
            summary = result.text
        } else {
            summaryUnavailable = true
        }
    }
}

// MARK: - The brief

struct DailyBriefView: View {
    @ObservedObject var model: DailyBriefModel
    @ObservedObject var levelBar: LevelBarModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("DAILY BRIEF · " + Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Diag.grey)
                        .padding(.top, 28)
                    levelBlock
                    HStack(spacing: 12) {
                        scoreCard("REST", model.rest, StrandPalette.restColor)
                        scoreCard("CHARGE", model.charge, StrandPalette.statusPositive)
                    }
                    if !model.metrics.isEmpty { metricsGrid }
                    summaryCard
                    daylightCard
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            Button {
                SystemHaptics.play(.confirm)
                onDone()
            } label: {
                Text("START THE DAY")
                    .font(Diag.heavy(20))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(Diag.blue, in: Capsule())
                    .shadow(color: Diag.blue.opacity(0.55), radius: 22, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private var levelBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR LEVEL TODAY")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Diag.grey)
            if let level = model.level {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    CountUpText(value: level,
                                format: { "\(Int($0.rounded()))" },
                                font: Diag.display(88),
                                color: .white,
                                animation: .easeOut(duration: 1.6))
                    if let y = model.levelYesterday {
                        trendLabel(level - y, higherIsBetter: true, suffix: " vs yesterday")
                    }
                }
            } else {
                Text(model.ready ? "–" : "…")
                    .font(Diag.display(88))
                    .foregroundStyle(.white)
                Text(model.ready ? "Last night has not synced yet, so today's level is still to come."
                                 : "Scoring the night…")
                    .font(.system(size: 14))
                    .foregroundStyle(Diag.grey)
            }
        }
    }

    private func scoreCard(_ title: String, _ value: Double?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Diag.grey)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(Diag.display(34))
                .foregroundStyle(tint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Diag.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Diag.cardBorder, lineWidth: 1))
    }

    private var metricsGrid: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.metrics.enumerated()), id: \.element.id) { index, metric in
                HStack {
                    Text(metric.label)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(white: 0.8))
                    Spacer()
                    Text(metric.value)
                        .font(.system(size: 17, weight: .bold).width(.expanded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if let change = metric.change {
                        trendLabel(change, higherIsBetter: metric.higherIsBetter, suffix: "")
                            .frame(width: 64, alignment: .trailing)
                    } else {
                        Color.clear.frame(width: 64, height: 1)
                    }
                }
                .padding(.vertical, 12)
                if index < model.metrics.count - 1 {
                    Rectangle().fill(Diag.cardBorder).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .background(Diag.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Diag.cardBorder, lineWidth: 1))
    }

    /// An arrow and the change, green when it is good news and amber when it is not.
    private func trendLabel(_ change: Double, higherIsBetter: Bool?, suffix: String) -> some View {
        let flat = abs(change) < 0.05
        let good: Bool? = flat ? nil : higherIsBetter.map { $0 == (change > 0) }
        let tint: Color = good == nil ? Diag.grey : (good! ? StrandPalette.statusPositive : StrandPalette.statusWarning)
        let magnitude = abs(change) >= 10 ? String(format: "%.0f", abs(change)) : String(format: "%.1f", abs(change))
        return HStack(spacing: 2) {
            Image(systemName: flat ? "arrow.right" : (change > 0 ? "arrow.up" : "arrow.down"))
                .font(.system(size: 11, weight: .bold))
            Text(magnitude + suffix)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("THE SYSTEM").font(.system(size: 13, weight: .semibold)).tracking(0.6)
            }
            .foregroundStyle(Diag.blue)
            if let summary = model.summary {
                Text(summary)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.summaryUnavailable {
                Text("No written brief this morning: the coach needs its connection and data access in Settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(Diag.grey)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Writing today's brief…")
                        .font(.system(size: 15))
                        .foregroundStyle(Diag.grey)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Diag.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Diag.cardBorder, lineWidth: 1))
    }

    private var daylightCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 24))
                .foregroundStyle(StrandPalette.statusWarning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Get daylight in the next hour")
                    .font(Diag.heavy(16))
                    .foregroundStyle(.white)
                Text("Ten minutes outside in sun, twenty to thirty under cloud. Morning light sets the clock that decides when you get tired tonight.")
                    .font(.system(size: 14))
                    .foregroundStyle(Diag.grey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Diag.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Diag.cardBorder, lineWidth: 1))
    }
}
