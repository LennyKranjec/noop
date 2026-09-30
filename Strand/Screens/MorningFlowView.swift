import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MorningFlowView.swift — the first open of the day: the dream, the night in a few taps, the daily brief.
//
// THREE STAGES, ONE SCREEN AT A TIME, in the look of a diagnostic: a segmented progress bar and a step
// counter beside a glass close/back control, a small wide-tracked overline, a heavy wide headline, four
// option cards with an icon, a title, a line of explanation and a radio, and one white CONFIRM at the foot.
//
//   1. The dream, written down before it fades.
//   2. The night, as four-option questions (`DreamQuestions`).
//   3. The daily brief: the level the day starts on; Rest and Charge; the night's key figures against
//      yesterday's; a written brief — light, and how to shape the day; and the gate's checklist.
//   4. The day's gear: Steady, Push or Relentless, which sets the day's quest targets
//      (`QuestDifficulty`), with the level still on screen.
//
// THE BRIEF DOES NOT LET GO UNTIL THE NIGHT IS IN. Its continue control is gated on `MorningGate`:
// the strap's backlog drained, the pass that scores the night finished, and today's level actually
// written to the ledger. It says which of those it is waiting for, and after a bounded wait it opens
// with an explicit note that the figures may still move. See `MorningGate.swift`.
//
// THE DAY'S LEVEL IS COMPUTED HERE. Opening the flow marks the day as begun (`LevelDayFreeze.beginDay`),
// forces a fresh sync of strap and cloud, and reloads the level — so by the time the brief is on screen,
// today's level has been scored from the night and written to the ledger. The work starts the moment the
// flow opens, and runs while the wearer is writing, so the brief is ready when they reach it.
//
// IF THE NIGHT IS NOT IN YET, THE BRIEF SAYS SO. It used to show whatever the strip was holding up, which
// before the night landed was yesterday's level under the heading "your level today". Now the brief shows
// a level only once TODAY's entry exists in the ledger, and until then says the night is still syncing —
// and keeps looking, for a while, as syncs come in.
//
// TELOS 2.0 (§6.12): the diagnostic register, dark-only and TOKENISED. Every colour is a
// `TelosColor.diag*` token (signal = the wearer's accent, alarm = `critical`), every face a `TelosType`
// token (`diagnostic` / `diagnosticS` ceremonial, `scale` overlines, `scaleNumber` qualifiers). No
// literal colour or point size lives in this file. Motion: nothing loops; the level counts up only when
// its value CHANGES (`CountUpText`), Rest / Charge rings settle on a new value only (`TelosRing`), the
// progress segments step with `TelosMotion.settle`. Reduce Motion is honoured by those components.

// MARK: - The look

/// The morning flow's surfaces, built from the design-system tokens only (§4.1 diagnostic register).
private enum Diag {
    static let cardRadius: CGFloat = TelosRadius.tile
    /// The card shape every surface in the flow uses.
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
    /// The primary (CONFIRM / continue) capsule height — a 44 pt target with room for AX sizes.
    static let actionHeight: CGFloat = 56
}

private extension View {
    /// A diagnostic card: `diagCard` fill + 1 pt `diagLine` hairline. No shadow (§4.6 flat).
    func diagCard(stroke: Color = TelosColor.diagLine, lineWidth: CGFloat = TelosStroke.line) -> some View {
        self
            .background(TelosColor.diagCard, in: Diag.card)
            .overlay(Diag.card.strokeBorder(stroke, lineWidth: lineWidth))
    }

    /// Glass role 5 (§4.9): the close / back control on a full-screen cover. iOS 26 Liquid Glass through
    /// the one helper family; everywhere else the solid fallback surface (no material, no blur).
    func morningGlassControl() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .regular) {
            self
                .buttonStyle(TelosPressButtonStyle())
                .nativeLiquidGlassFallbackSurface(Circle())
        }
    }
}

/// The wide-tracked small-caps overline of the register (`scale`, `diagMuted`).
private struct DiagOverline: View {
    let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    init(verbatim: String) { self.text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .telosScale()
            .textCase(.uppercase)
            .foregroundStyle(TelosColor.diagMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The ceremonial primary action: `diagnosticS` on a white capsule (§6.12). Disabled = the same capsule
/// at `disabled` opacity. No glow: one flat capsule, nothing stacked.
private struct DiagPrimaryButton: View {
    let title: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(TelosType.diagnosticS)
                .tracking(TelosType.Tracking.diagnosticS)
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.diagField)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Diag.actionHeight)
                .background(TelosColor.diagText, in: Capsule(style: .continuous))
                .opacity(enabled ? TelosOpacity.full : TelosOpacity.disabled)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(TelosPressButtonStyle())
        .disabled(!enabled)
    }
}

/// One cell per step: `diagSignal` (the accent) up to and including the current step, `diagLine`
/// after it, plus the "2/7" counter. The segments step with `settle` when the step changes.
private struct MorningProgress: View {
    let step: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: TelosSpace.s) {
            HStack(spacing: TelosSpace.xs) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index <= step ? TelosColor.diagSignal : TelosColor.diagLine)
                        .frame(height: TelosStroke.rail)
                }
            }
            .animation(TelosMotion.gated(TelosMotion.settle, reduced: reduceMotion), value: step)
            Text("\(min(step + 1, total))/\(total)")
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.diagMuted)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(min(step + 1, total))/\(total)"))
    }
}

// MARK: - The flow

struct MorningFlowView: View {
    @ObservedObject var levelBar: LevelBarModel
    /// When the flow was put up. The day it begins is the day of THIS moment, not of whenever the view's
    /// task gets to run — a flow presented at 23:59 must not begin tomorrow.
    var presentedAt: Date = Date()
    let onDone: () -> Void

    @EnvironmentObject private var repo: Repository
    /// NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    /// actions. Observing it re-rendered the whole view per chunk while any generation ran.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var brief = DailyBriefModel()
    @State private var step = 0
    @State private var dream = ""
    @State private var answers: [String: Int] = [:]
    @State private var selection: Int?

    private var questions: [DreamQuestion] { DreamQuestions.all }
    /// Dream, questions, brief, the day's gear.
    private var total: Int { questions.count + 3 }
    private var briefStep: Int { total - 2 }
    private var isBrief: Bool { step == briefStep }
    /// The last page: the three gears. NOT where the flow ends by itself — `onDone` runs when one is
    /// picked, so the day always leaves here with a gear set or with the wearer having said "not today".
    private var isChoice: Bool { step == total - 1 }

    /// The page swap (`screen` token; a plain fade under Reduce Motion).
    private var pageAnimation: Animation {
        reduceMotion ? TelosMotion.fade : TelosMotion.screen
    }

    var body: some View {
        ZStack {
            TelosColor.diagField.ignoresSafeArea()
            if isChoice {
                DifficultyChoiceView(brief: brief, presentedAt: presentedAt, onDone: onDone,
                                     step: step, total: total)
                    .transition(.opacity)
            } else if isBrief {
                DailyBriefView(model: brief, levelBar: levelBar, presentedAt: presentedAt,
                               step: step, total: total) {
                    withAnimation(pageAnimation) { step = total - 1 }
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                        .padding(.top, TelosSpace.s)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if step == 0 { dreamStage } else { questionStage(questions[step - 1]) }
                        }
                        .padding(.top, TelosSpace.xxl)
                    }
                    confirmButton
                        .padding(.bottom, TelosSpace.m)
                }
                .padding(.horizontal, TelosSpace.xl)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // The day begins now: today's level from here on, and the work that scores it starts at once.
            LevelDayFreeze.beginDay(now: presentedAt)
            // A SYNC IS ASKED FOR, NOT MERELY WAITED ON. The last page will not hand the day over until
            // an offload has COMPLETED since this moment (`MorningGate`), and the periodic floor is
            // fifteen minutes wide — so the flow requests one itself, through the same rate-limited
            // `.foreground` entry the app uses on every resume: floored at 90 s, unable to double-start,
            // and a no-op when no strap is bonded.
            resolvedAppModel(nil)?.ble.requestSync(.foreground)
            await brief.prepare(repo: repo, levelBar: levelBar, presentedAt: presentedAt)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: TelosSpace.m) {
            Button {
                TelosHaptics.play(.tap)
                if step == 0 {
                    // Skipping the morning goes straight to the brief rather than out of it.
                    finishEntry()
                } else {
                    withAnimation(pageAnimation) {
                        step -= 1
                        selection = step == 0 ? nil : answers[questions[step - 1].id]
                    }
                }
            } label: {
                Image(systemName: step == 0 ? "xmark" : "chevron.left")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(TelosColor.diagText)
                    .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                    .contentShape(Circle())
            }
            .morningGlassControl()
            .accessibilityLabel(step == 0 ? "Skip to the brief" : "Back")
            MorningProgress(step: step, total: total)
        }
    }

    // MARK: Stage 1 — the dream

    private var dreamStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiagOverline("DREAM JOURNAL")
            Text("What did you dream?")
                .font(TelosType.diagnostic)
                .tracking(TelosType.Tracking.diagnostic)
                .foregroundStyle(TelosColor.diagText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, TelosSpace.m)
            ZStack(alignment: .topLeading) {
                if dream.isEmpty {
                    Text("Write it down before it fades. A few words are enough.")
                        .font(TelosType.callout)
                        .foregroundStyle(TelosColor.diagMuted)
                        .padding(TelosSpace.l)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $dream)
                    .font(TelosType.callout)
                    .foregroundStyle(TelosColor.diagText)
                    .scrollContentBackground(.hidden)
                    .padding(TelosSpace.m)
                    .frame(minHeight: 220)
            }
            .diagCard()
            .padding(.top, TelosSpace.xxl)
        }
    }

    // MARK: Stage 2 — the night

    private func questionStage(_ q: DreamQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DiagOverline(verbatim: q.overline)
            Text(q.title)
                .font(TelosType.diagnostic)
                .tracking(TelosType.Tracking.diagnostic)
                .foregroundStyle(TelosColor.diagText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, TelosSpace.m)
            VStack(spacing: TelosSpace.m) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                    OptionCard(option: option, selected: selection == index) {
                        TelosHaptics.play(.select)
                        withAnimation(TelosMotion.gated(TelosMotion.select, reduced: reduceMotion)) {
                            selection = index
                        }
                    }
                }
            }
            .padding(.top, TelosSpace.xxl)
        }
    }

    // MARK: Confirm

    private var confirmEnabled: Bool { step == 0 || selection != nil }

    private var confirmButton: some View {
        DiagPrimaryButton(title: "CONFIRM", enabled: confirmEnabled) {
            guard confirmEnabled else { return }
            TelosHaptics.play(.commit)
            if step > 0, let selection { answers[questions[step - 1].id] = selection }
            if step >= questions.count {
                finishEntry()
            } else {
                withAnimation(pageAnimation) {
                    step += 1
                    selection = answers[questions[step - 1].id]
                }
            }
        }
        .padding(.top, TelosSpace.l)
    }

    /// Save the morning's entry (whatever of it was given) and move on to the brief.
    private func finishEntry() {
        let entry = DreamEntry(day: Repository.localDayKey(Date()), text: dream, answers: answers,
                               updatedAt: Date())
        let hasSomething = !dream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !answers.isEmpty
        withAnimation(pageAnimation) { step = briefStep }
        Task {
            if hasSomething { await DreamJournalStore.shared.save(entry, repo: repo) }
            await brief.writeSummary(coach: coach, repo: repo, levelBar: levelBar,
                                     dream: hasSomething ? entry : nil)
        }
    }
}

/// The radio of an option / gear card: a 1.5 pt ring, and when selected a 2 pt accent ring with a
/// filled accent dot (§6.12 "accent radio").
private struct DiagRadio: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? TelosColor.diagSignal : TelosColor.diagMuted,
                              lineWidth: selected ? TelosStroke.data : TelosStroke.strong)
                .frame(width: 28, height: 28)
            if selected {
                Circle().fill(TelosColor.diagSignal).frame(width: 14, height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One of the four answers: icon, title, line of explanation, radio.
private struct OptionCard: View {
    let option: DreamQuestion.Option
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TelosSpace.l) {
                Image(systemName: option.symbol)
                    .font(TelosType.title2)
                    .foregroundStyle(selected ? TelosColor.diagSignal : TelosColor.diagMuted)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    Text(option.title)
                        .font(TelosType.diagnosticS)
                        .foregroundStyle(TelosColor.diagText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(option.subtitle)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.diagMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: TelosSpace.s)
                DiagRadio(selected: selected)
            }
            .padding(TelosSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .diagCard(stroke: selected ? TelosColor.diagSignal : TelosColor.diagLine,
                      lineWidth: selected ? TelosStroke.data : TelosStroke.line)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
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
    /// How much of the level's formula had data behind it, as whole per cent (nil with no level). Shown
    /// beside the level when below 100, so a partial level never reads like a full one.
    @Published private(set) var coveragePercent: Int?
    /// Today is settled with NO level: its night was never recorded. Not the same as still syncing.
    @Published private(set) var noNight = false
    @Published private(set) var charge: Double?
    @Published private(set) var rest: Double?
    @Published private(set) var metrics: [Metric] = []
    @Published private(set) var summary: String?
    @Published private(set) var writing = false
    @Published private(set) var summaryUnavailable = false

    private var prepared = false

    /// How long the brief keeps looking for today's level after it is first drawn, and how often.
    static let pollSeconds: UInt64 = 15
    static let pollWindowSeconds = 600
    /// The most the poll is ever extended to reach the night's wake + settle (see `keepPolling`).
    static let pollWindowMaxSeconds = 90 * 60

    /// Whether the brief keeps looking after `waited` seconds: for its ten minutes, and BEYOND them until
    /// just past the level day's wake + settle, when the night counts as over and the day becomes
    /// writable — a brief opened right after waking would otherwise stop looking twenty minutes before
    /// its own level could be written. Never past `pollWindowMaxSeconds`. Pure.
    nonisolated static func keepPolling(waited: Int, now: Date, wakeSettledAt: Date?) -> Bool {
        if waited < pollWindowSeconds { return true }
        guard waited < pollWindowMaxSeconds, let settled = wakeSettledAt else { return false }
        return now < settled.addingTimeInterval(2 * TimeInterval(pollSeconds))
    }

    /// Sync, score and freeze the day's level, and gather the night's figures.
    func prepare(repo: Repository, levelBar: LevelBarModel, presentedAt: Date = Date()) async {
        guard !prepared else { return }
        prepared = true
        await repo.refreshEverything(force: true)
        await levelBar.reload(repo: repo)
        readLevel(presentedAt: presentedAt)
        await gatherNight(repo: repo)
        ready = true

        // THE NIGHT MAY STILL BE ON ITS WAY. Rather than settle for "still syncing", the brief keeps
        // looking for ten minutes — longer when the night's wake + settle is still ahead (`keepPolling`):
        // the ledger is read again every poll (the strip's own retries may have written the day meanwhile), every new sync reloads the level, and every other minute it reloads
        // anyway, in case the deadline has passed and the day has been written as it stands.
        var seq = repo.refreshSeq
        var waited = 0
        while level == nil, !noNight,
              Self.keepPolling(waited: waited, now: Date(), wakeSettledAt: levelBar.levelDayWakeSettledAt) {
            try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            waited += Int(Self.pollSeconds)
            readLevel(presentedAt: presentedAt)
            if level == nil, repo.refreshSeq != seq || waited % 120 == 0 {
                seq = repo.refreshSeq
                await levelBar.reload(repo: repo)
                readLevel(presentedAt: presentedAt)
            }
            if level != nil { await gatherNight(repo: repo) }
        }
    }

    /// Today's level and yesterday's, from the ledger only. Nil until TODAY is written — the last written
    /// day is never passed off as this morning's, and neither is the level day when it is not today (a
    /// flow whose day did not begin, before 04:00, leaves the level day on yesterday).
    private func readLevel(presentedAt: Date) {
        let calendar = Calendar.current
        let dayKey = LevelWiring.key(from: LevelDayFreeze.levelDay(calendar: calendar), calendar: calendar)
        let ledger = LevelLedger.shared
        let isToday = dayKey == LevelWiring.key(from: presentedAt, calendar: calendar)
        guard isToday, let entry = ledger.entry(dayKey) else {
            level = nil
            levelYesterday = nil
            coveragePercent = nil
            // SETTLED WITH NO ENTRY is a night that was never recorded — no amount of waiting brings it.
            noNight = isToday && ledger.isSettled(dayKey)
            return
        }
        noNight = false
        level = entry.level
        coveragePercent = Int((min(max(entry.coverage, 0), 1) * 100).rounded())
        levelYesterday = LevelWiring.shift(dayKey, -1, calendar).flatMap { LevelLedger.shared.entry($0)?.level }
    }

    /// Rest, Charge and the night's key figures against the night before.
    private func gatherNight(repo: Repository) async {
        let today = Repository.localDayKey(Date())
        let own = await repo.noopScores(day: today)
        let row = repo.days.first { $0.day == today }
        // WHOOP's own night first, as everywhere else: it may have held the strap overnight.
        charge = await repo.whoopCloudDay(today)?.recovery ?? own.charge ?? row?.recovery
        rest = await repo.whoopCloudSleepScore(day: today) ?? own.rest

        let yesterdayKey = Repository.localDayKey(Date().addingTimeInterval(-86_400))
        let prev = repo.days.first { $0.day == yesterdayKey }
        metrics = Self.metrics(today: row, yesterday: prev)
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
        if let level {
            extra.append(String(format: "Today's level: %.0f (50 = their own average)", level))
        } else if noNight {
            extra.append("No level for today: last night wasn't recorded.")
        } else {
            extra.append("Today's level is not set yet: last night is still syncing.")
        }
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
    /// When the flow opened — the moment its forced sync started. The gate's freshness test is anchored
    /// to it, not to when this page appeared. See `MorningGateInputs.flowOpenedAt`.
    var presentedAt: Date = Date()
    /// Where this page sits in the flow, for the progress strip.
    var step: Int = 0
    var total: Int = 1
    let onDone: () -> Void

    /// THE GATE. The brief is the last page of figures, and it does not hand the day over until the
    /// night behind those figures is actually in. See `MorningGate.swift`.
    @StateObject private var gate = MorningGateModel()

    var body: some View {
        VStack(spacing: 0) {
            MorningProgress(step: step, total: total)
                .padding(.horizontal, TelosSpace.xl)
                .padding(.top, TelosSpace.m)
            ScrollView {
                VStack(alignment: .leading, spacing: TelosSpace.l) {
                    DiagOverline(verbatim: "DAILY BRIEF · "
                                 + Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .padding(.top, TelosSpace.l)
                    levelBlock
                    HStack(spacing: TelosSpace.m) {
                        scoreCard("REST", model.rest, TelosColor.rest)
                        scoreCard("CHARGE", model.charge, TelosColor.charge)
                    }
                    // The wearer's own word on their energy, matched later to the first balance Today
                    // computes (`EnergyCheckInStore.attach`). Renders nothing once answered today.
                    EnergyCheckInPrompt(slot: .morning, question: "How much energy do you have this morning?")
                    if !model.metrics.isEmpty { metricsGrid }
                    summaryCard
                    daylightCard
                }
                .padding(.horizontal, TelosSpace.xl)
                .padding(.bottom, TelosSpace.l)
            }
            VStack(spacing: TelosSpace.m) {
                if gate.stage != .ready { gateBlock }
                continueButton
            }
            .padding(.horizontal, TelosSpace.xl)
            .padding(.bottom, TelosSpace.m)
        }
        // The gate asks the brief whether today's level is resolved on every tick: the brief's own poll
        // is what resolves it, and it can land while the gate is waiting. `noNight` counts as resolved —
        // "last night wasn't recorded" is an answer, and no amount of waiting improves it.
        .task {
            await gate.start(flowOpenedAt: presentedAt) { [model] in
                model.level != nil || model.noNight
            }
        }
    }

    /// WHAT IS HAPPENING AND WHY, while the wearer waits. Named states, the real failure when there is
    /// one, and the only honest progress the protocol offers — a chunk count, never a percentage, because
    /// the strap never says how much it is holding. Under it, the gate's three conditions as a checklist
    /// (pending ○ / done ●), read from the same inputs the gate decides on.
    private var gateBlock: some View {
        let timedOut = gate.stage == .timedOut
        let inputs = gate.inputs
        return VStack(alignment: .leading, spacing: TelosSpace.m) {
            HStack(alignment: .top, spacing: TelosSpace.m) {
                if timedOut {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.warning)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().tint(TelosColor.diagText).frame(width: 24)
                }
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    Text(gate.headline)
                        .telosScale()
                        .foregroundStyle(timedOut ? TelosColor.warning : TelosColor.diagMuted)
                    Text(gate.detail)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.diagText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                gateRow("Strap drained", done: !MorningGate.syncOutstanding(inputs))
                gateRow("Night scored", done: !MorningGate.analysisOutstanding(inputs))
                gateRow("Level written", done: inputs.levelResolved)
            }
            .padding(.leading, 24 + TelosSpace.m)
        }
        .padding(TelosSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .diagCard(stroke: timedOut ? TelosColor.warning : TelosColor.diagLine)
        .accessibilityElement(children: .combine)
    }

    /// One gate condition: ○ while pending, ● once met. The word carries the state too (never colour alone).
    private func gateRow(_ title: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: TelosSpace.s) {
            Image(systemName: done ? "circle.fill" : "circle")
                .font(TelosType.caption)
                .foregroundStyle(done ? TelosColor.diagSignal : TelosColor.diagMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(TelosType.scaleNumber)
                .textCase(.uppercase)
                .foregroundStyle(done ? TelosColor.diagText : TelosColor.diagMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? Text("Done") : Text("Pending"))
    }

    /// CONTINUE ANYWAY IS NOT THE SAME BUTTON. A gate that ran out says so on the button itself, so the
    /// wearer who goes on knows they are going on early rather than being told everything was fine.
    private var continueButton: some View {
        let enabled = gate.stage.allowsContinue
        return DiagPrimaryButton(title: gate.stage == .timedOut ? "CONTINUE ANYWAY" : "SET TODAY'S GEAR",
                                 enabled: enabled) {
            guard enabled else { return }
            TelosHaptics.play(.commit)
            onDone()
        }
        .accessibilityHint(Text(enabled ? "" : gate.detail))
    }

    private var levelBlock: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            DiagOverline("YOUR LEVEL TODAY")
            if let level = model.level {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.m) {
                    // Counts up only when the value CHANGES (a poll that lands a later figure), never on
                    // appear — one `Animatable` numeral, no dispatch loop. Unbounded: no clamp.
                    CountUpText(value: level,
                                format: { "\(Int($0.rounded()))" },
                                font: TelosType.hero,
                                color: TelosColor.diagText,
                                animation: TelosMotion.countUp)
                    if let y = model.levelYesterday {
                        trendLabel(level - y, higherIsBetter: true, suffix: " vs yesterday")
                    }
                }
                // A level built from part of the formula must not read like one built from all of it.
                if let pct = model.coveragePercent, pct < 100 {
                    Text("\(pct)% measured")
                        .font(TelosType.scaleNumber)
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.diagMuted)
                }
            } else {
                Text(model.ready ? TelosType.absent : "…")
                    .font(TelosType.hero)
                    .foregroundStyle(TelosColor.diagMuted)
                Text(model.noNight ? "No level for today: last night wasn't recorded."
                     : model.ready ? "Last night is still syncing. Today's level is set once it lands."
                     : "Scoring the night…")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.diagMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Rest / Charge as a thin luminous ring (`TelosRing`): the arc settles on a NEW value only; an
    /// absent score is a dashed bare track with "—", never an empty-looking 0.
    private func scoreCard(_ title: LocalizedStringKey, _ value: Double?, _ tint: Color) -> some View {
        HStack(spacing: TelosSpace.m) {
            TelosRing(value: value, scale: 100, color: tint, diameter: 56, unit: "%",
                      accessibilityLabel: Text(title))
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(title)
                    .telosScale()
                    .foregroundStyle(TelosColor.diagMuted)
                if value == nil {
                    Text("Not enough data yet")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.diagMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(TelosSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .diagCard()
    }

    private var metricsGrid: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.metrics.enumerated()), id: \.element.id) { index, metric in
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Text(metric.label)
                        .font(TelosType.scaleNumber)
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.diagMuted)
                    Spacer(minLength: TelosSpace.s)
                    Text(metric.value)
                        .font(TelosType.numeralS)
                        .foregroundStyle(TelosColor.diagText)
                    Group {
                        if let change = metric.change {
                            trendLabel(change, higherIsBetter: metric.higherIsBetter, suffix: "")
                        } else {
                            // No yesterday to compare with: a dash, not a zero change.
                            Text(TelosType.absent)
                                .font(TelosType.numeralXS)
                                .foregroundStyle(TelosColor.diagMuted)
                        }
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.vertical, TelosSpace.m)
                .accessibilityElement(children: .combine)
                if index < model.metrics.count - 1 {
                    Rectangle().fill(TelosColor.diagLine).frame(height: TelosStroke.line)
                }
            }
        }
        .padding(.horizontal, TelosSpace.l)
        .diagCard()
    }

    /// An arrow and the SIGNED change (true minus), green when it is good news and amber when it is not.
    /// Flat reads "±0" so it stays distinguishable from "no comparison" ("—").
    private func trendLabel(_ change: Double, higherIsBetter: Bool?, suffix: String) -> some View {
        let flat = abs(change) < 0.05
        let good: Bool? = flat ? nil : higherIsBetter.map { $0 == (change > 0) }
        let tint: Color
        switch good {
        case .some(true): tint = TelosColor.positive
        case .some(false): tint = TelosColor.warning
        case .none: tint = TelosColor.diagMuted
        }
        let magnitude = abs(change) >= 10 ? String(format: "%.0f", abs(change)) : String(format: "%.1f", abs(change))
        let sign = flat ? "±" : (change > 0 ? "+" : TelosType.minus)
        return HStack(spacing: TelosSpace.xxs) {
            Image(systemName: flat ? "arrow.right" : (change > 0 ? "arrow.up" : "arrow.down"))
                .font(TelosType.glyphDelta)
                .accessibilityHidden(true)
            Text(verbatim: sign + (flat ? "0" : magnitude) + suffix)
                .font(TelosType.numeralXS)
        }
        .foregroundStyle(tint)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack(spacing: TelosSpace.xs) {
                Image(systemName: "sparkles")
                    .font(TelosType.caption)
                    .accessibilityHidden(true)
                Text("THE SYSTEM").telosScale()
            }
            .foregroundStyle(TelosColor.diagSignal)
            if let summary = model.summary {
                Text(summary)
                    .font(TelosType.body)
                    .foregroundStyle(TelosColor.diagText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.summaryUnavailable {
                Text("No written brief this morning: the coach needs its connection and data access in Settings.")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.diagMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: TelosSpace.s) {
                    ProgressView().tint(TelosColor.diagText)
                    Text("Writing today's brief…")
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.diagMuted)
                }
            }
        }
        .padding(TelosSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .diagCard()
    }

    private var daylightCard: some View {
        HStack(alignment: .top, spacing: TelosSpace.m) {
            Image(systemName: "sun.max.fill")
                .font(TelosType.title2)
                .foregroundStyle(TelosColor.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                Text("Get daylight in the next hour")
                    .font(TelosType.diagnosticS)
                    .foregroundStyle(TelosColor.diagText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ten minutes outside in sun, twenty to thirty under cloud. Morning light sets the clock that decides when you get tired tonight.")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.diagMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TelosSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .diagCard()
    }
}

// MARK: - The day's gear
//
// The last page, and the only one where the wearer decides something about the day ahead rather than
// reporting on the night behind it: three gears, and the day's quest targets follow from the choice.
//
// THE CHOICE SETS THE MULTIPLIER, NEVER THE NUMBER. "Relentless" does not mean fifteen thousand steps;
// it means 1.35 × what this wearer's own median already is, the top of the band today's charge
// recommends, their own sleep need. The whole table is `QuestDifficulty.Scale`, and the numbers each
// card shows are the real targets, computed from the real baselines before the wearer commits — so the
// choice is made against what it will actually ask for rather than against an adjective.
//
// PREVIEW == ISSUED. The cards read the SAME composer the issuer does (`QuestPlanComposer.targets`): the
// week plan's bounds for the day, an illness heads-up, the running trial's excluded metrics, and the
// gear floor (a day already issued at a higher gear keeps it — `QuestGearFloor`). A card that showed
// the raw gear table would promise targets the issuer then bounds differently.
//
// A GEAR CANNOT INVENT A TARGET. Every card lists only the directives this wearer's data can actually
// scale and check (`QuestBaselineReader`, `QuestDayPlan`); a metric with no baseline produces no
// directive, and a card that can offer nothing says so instead of promising three of them.
//
// THE LEVEL STAYS ON SCREEN, as asked — and it is what orders the directives: the day leads with
// whatever moves the level's weakest MEASURED part. An abstaining part is never called weak
// (`QuestDayPlan.focus`), because a part with no data behind it is not a low score.

struct DifficultyChoiceView: View {
    @ObservedObject var brief: DailyBriefModel
    var presentedAt: Date = Date()
    let onDone: () -> Void
    /// Where this page sits in the flow, for the progress strip.
    var step: Int = 0
    var total: Int = 1

    @EnvironmentObject private var repo: Repository
    /// NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    /// actions. Observing it re-rendered the whole view per chunk while any generation ran.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var baseline: QuestBaseline?
    @State private var loaded = false
    @State private var selection: QuestDifficulty?

    /// The quest day the choice is recorded for — the same key the quests themselves carry.
    private var dayKey: String { DailyMissionStore.dayKey() }

    /// TODAY's own written level, or nil. Read from the ledger like every other surface, and only when
    /// the level day IS today: a stand-in from an earlier day is not this morning's number, and ordering
    /// the day's directives by yesterday's weakest part would be aiming at the wrong thing.
    private var breakdown: LevelBreakdown? {
        let calendar = Calendar.current
        let key = LevelWiring.key(from: LevelDayFreeze.levelDay(calendar: calendar), calendar: calendar)
        guard key == LevelWiring.key(from: presentedAt, calendar: calendar) else { return nil }
        return LevelLedger.shared.entry(key)?.breakdown
    }

    private var focus: LevelPart? { QuestDayPlan.focus(breakdown) }

    /// The gear a pick actually runs at: the pick, unless today's plan already went out higher.
    private func effectiveGear(_ picked: QuestDifficulty) -> QuestDifficulty {
        QuestGearFloor.effective(picked: picked, issued: QuestGearFloor.issued(for: dayKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            MorningProgress(step: step, total: total)
                .padding(.horizontal, TelosSpace.xl)
                .padding(.top, TelosSpace.m)
            ScrollView {
                VStack(alignment: .leading, spacing: TelosSpace.l) {
                    DiagOverline("TODAY'S GEAR")
                        .padding(.top, TelosSpace.l)
                    levelStrip
                    Text("How hard is today?")
                        .font(TelosType.diagnostic)
                        .tracking(TelosType.Tracking.diagnostic)
                        .foregroundStyle(TelosColor.diagText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lead)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.diagMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: TelosSpace.m) {
                        ForEach(QuestDifficulty.allCases, id: \.rawValue) { difficulty in
                            DifficultyCard(difficulty: difficulty,
                                           targets: targets(difficulty),
                                           loaded: loaded,
                                           selected: selection == difficulty) {
                                TelosHaptics.play(.select)
                                withAnimation(TelosMotion.gated(TelosMotion.select, reduced: reduceMotion)) {
                                    selection = difficulty
                                }
                            }
                        }
                    }
                    downgradeNote
                }
                .padding(.horizontal, TelosSpace.xl)
                .padding(.bottom, TelosSpace.l)
            }
            VStack(spacing: TelosSpace.s) {
                confirmButton
                // THE WAY OUT. A wearer who wants no directives today must be able to say so; a flow
                // that cannot be left without accepting a commitment is a flow people force-quit.
                Button {
                    TelosHaptics.play(.tap)
                    onDone()
                } label: {
                    Text("Not today")
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.diagMuted)
                        .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TelosPressButtonStyle())
            }
            .padding(.horizontal, TelosSpace.xl)
            .padding(.bottom, TelosSpace.m)
        }
        .task {
            baseline = await QuestBaselineReader.read(repo: repo, day: dayKey)
            loaded = true
        }
    }

    /// What the targets are built from, and — when the level has one — which part the day leads with.
    private var lead: String {
        let common = "Every target below is scaled from your own numbers: your median steps, your sleep "
            + "need, the effort band today's charge recommends."
        guard let focus else { return common }
        return common + " The day leads with \(Self.partName(focus)) — the measured part of your level "
            + "with the most room in it."
    }

    /// A downward re-pick on a day already issued higher keeps the higher gear's targets — said under the
    /// cards, before LOCK IT IN, rather than discovered afterwards (`QuestGearFloor.downgradeNote`).
    @ViewBuilder
    private var downgradeNote: some View {
        if let picked = selection {
            let held = effectiveGear(picked)
            if QuestGearFloor.downgradeNote(picked: picked, held: held) != nil {
                Text("Today's quests already went out at \(held.title). The gear can go up once the day is issued, not down, so \(held.title)'s targets stand.")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The level, small, so it is in view while the choice is made — the same ledger figure the brief
    /// showed, never a second reading of it.
    private var levelStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.m) {
            Text(brief.level.map { "\(Int($0.rounded()))" } ?? TelosType.absent)
                .telosNumeral(.numeralL)
                .foregroundStyle(brief.level == nil ? TelosColor.diagMuted : TelosColor.diagText)
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                DiagOverline("YOUR LEVEL TODAY")
                if brief.level == nil {
                    Text(brief.noNight ? "Last night wasn't recorded." : "Not set yet.")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.diagMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// EXACTLY what issuing would produce for this pick: the gear floor applied first, then the week
    /// plan's bounds, the illness heads-up and the running trial's exclusions (`QuestPlanComposer`).
    private func targets(_ difficulty: QuestDifficulty) -> [QuestPlanTarget] {
        guard let baseline else { return [] }
        return QuestPlanComposer.targets(baseline: baseline, difficulty: effectiveGear(difficulty),
                                         focus: focus, day: dayKey, repo: repo)
    }

    private var confirmButton: some View {
        DiagPrimaryButton(title: "LOCK IT IN", enabled: selection != nil) {
            guard let difficulty = selection else { return }
            TelosHaptics.play(.commit)
            // CHOOSE, THEN GENERATE. The choice is recorded first so Today can name the day's gear the
            // moment it draws, and the quests are issued from it — replacing whatever an earlier pick
            // for the same day left behind (`QuestIssuer.issuePlan`). The recorded gear is the EFFECTIVE
            // one: a downward re-pick on an issued day keeps the higher gear (the issuer does the same).
            QuestModeStore.shared.set(effectiveGear(difficulty), for: dayKey)
            // The issuing runs in a task of its OWN, not the view's: naming each quest is a round trip
            // to the coach, and this view is about to go away. The same shape `finishEntry` uses for the
            // dream it has just saved.
            let repo = self.repo
            let coach = self.coach
            let focus = self.focus
            let day = self.dayKey
            Task { @MainActor in
                await QuestIssuer.issuePlan(difficulty, repo: repo, coach: coach, focus: focus,
                                            dayKey: day)
            }
            onDone()
        }
    }

    /// The level part in the words the level's own surfaces use.
    static func partName(_ part: LevelPart) -> String {
        switch part {
        case .sleep: return "sleep"
        case .heart: return "heart"
        case .lungs: return "lungs"
        case .muscle: return "muscle"
        case .focus: return "focus"
        }
    }
}

/// One gear: its name, what it costs, and the directives it would actually issue.
private struct DifficultyCard: View {
    let difficulty: QuestDifficulty
    let targets: [QuestPlanTarget]
    /// Whether the baselines have been read. Before that the card shows nothing rather than an empty
    /// state — "no targets" and "not looked yet" are different things.
    let loaded: Bool
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch difficulty {
        case .steady: return "tortoise.fill"
        case .push: return "figure.run"
        case .relentless: return "flame.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                HStack(spacing: TelosSpace.l) {
                    Image(systemName: symbol)
                        .font(TelosType.title2)
                        .foregroundStyle(selected ? TelosColor.diagSignal : TelosColor.diagMuted)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TelosSpace.xs) {
                        Text(difficulty.title)
                            .font(TelosType.diagnosticS)
                            .foregroundStyle(TelosColor.diagText)
                        Text(difficulty.blurb)
                            .font(TelosType.subhead)
                            .foregroundStyle(TelosColor.diagMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: TelosSpace.s)
                    DiagRadio(selected: selected)
                }
                if loaded { plan }
            }
            .padding(TelosSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .diagCard(stroke: selected ? TelosColor.diagSignal : TelosColor.diagLine,
                      lineWidth: selected ? TelosStroke.data : TelosStroke.line)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var plan: some View {
        if targets.isEmpty {
            // HONEST, NOT EMPTY. A wearer with no history yet is told why there is nothing here rather
            // than being handed targets off a population average.
            Text("Nothing to scale a target from yet: a few more days of your own steps, sleep and "
                 + "training, and this fills in.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.diagMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36 + TelosSpace.l)
        } else {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                ForEach(targets, id: \.id) { target in
                    HStack(alignment: .top, spacing: TelosSpace.s) {
                        Text(verbatim: "·").foregroundStyle(TelosColor.diagMuted)
                        Text(target.target)
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.diagText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 36 + TelosSpace.l)
        }
    }
}
