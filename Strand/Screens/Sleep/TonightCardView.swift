import SwiftUI
import StrandDesign
import StrandAnalytics

// TonightCardView.swift — "Tonight": the sleep anchor's evening, on the Sleep screen (DESIGN_V2 §6.14).
//
// The ONE sleep schedule (`SleepScheduleProvider`, HEALTH_V2 S2) laid out as the evening ahead: when to
// stop caffeine, when to start winding down, lights out, and the wake it all hangs from. Every number and
// every sentence comes from the plan — `needLine`, `paybackLine` and `insomniaLine` are the model's own
// words, shown verbatim; nothing here re-derives a bedtime.
//
// HONEST ABSTENTION. Without a plan the card shows "—" plus the provider's own reason (calibrating n of 7,
// or a wake time too irregular to anchor), and a pip bar toward the seven nights while calibrating. It never
// falls back to a default bedtime — a bedtime off a median that describes nobody's night is a fabricated
// schedule (SleepAnchor.swift).
//
// The timeline is a SEQUENCE, not a scale: the four steps sit evenly spaced with their clock times under
// them, because a proportional axis would crush wind-down / lights-out into one corner next to a noon
// caffeine cutoff. The step that is next is marked (a violet ring); the ones already passed dim.
//
// Cost (§2.1 rule 8): shapes and text only. One `TimelineView(.everyMinute)` so "next" moves with the
// clock — a periodic minute tick, not a frame clock; no Canvas, no blur, no shadow.

// MARK: - The evening's steps (pure)

/// One step of the evening, resolved to a real local instant.
struct TonightStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case caffeine, windDown, lightsOut, wake
    }

    let kind: Kind
    let date: Date
    var id: String { kind.rawValue }

    var title: LocalizedStringKey {
        switch kind {
        case .caffeine:  return "Caffeine cutoff"
        case .windDown:  return "Wind down"
        case .lightsOut: return "Lights out"
        case .wake:      return "Wake"
        }
    }

    var symbol: String {
        switch kind {
        case .caffeine:  return "cup.and.saucer"
        case .windDown:  return "moon.zzz"
        case .lightsOut: return "bed.double"
        case .wake:      return "sunrise"
        }
    }
}

enum TonightSchedule {

    /// The steps of `plan` for the night that ends on `wakeDate`'s day, in clock order. Each step is placed
    /// on its own local day with the plan's own day-shift rule (clock minutes, never 86 400-second
    /// arithmetic), so a bedtime before midnight lands on the evening before the wake.
    static func steps(plan: SleepSchedulePlan, wakeDate: Date, calendar: Calendar = .current) -> [TonightStep] {
        let wakeDay = calendar.startOfDay(for: wakeDate)
        let cutoffMin: Int = CaffeineBedtime.cutoffMinutes(plan: plan, fallback: plan.bedtimeMin)
        let caffeineLead: Int = plan.bedtimeLeadMin + SleepClock.wrap(plan.bedtimeMin - cutoffMin)
        let windDownLead: Int = plan.bedtimeLeadMin + SleepAnchor.windDownLeadMin

        func instant(minute: Int, lead: Int) -> Date? {
            let shift: Int = plan.dayShift(leadBeforeAnchorMin: lead)
            guard let day = calendar.date(byAdding: .day, value: shift, to: wakeDay) else { return nil }
            let m: Int = SleepClock.wrap(minute)
            return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)
        }

        var out: [TonightStep] = []
        if let d = instant(minute: cutoffMin, lead: caffeineLead) { out.append(TonightStep(kind: .caffeine, date: d)) }
        if let d = instant(minute: plan.windDownStartMin, lead: windDownLead) { out.append(TonightStep(kind: .windDown, date: d)) }
        if let d = instant(minute: plan.bedtimeMin, lead: plan.bedtimeLeadMin) { out.append(TonightStep(kind: .lightsOut, date: d)) }
        if let d = instant(minute: plan.anchorMin, lead: 0) { out.append(TonightStep(kind: .wake, date: d)) }
        return out.sorted { $0.date < $1.date }
    }

    /// The first step still ahead of `now`, or nil once the wake has passed.
    static func next(_ steps: [TonightStep], now: Date) -> TonightStep.Kind? {
        steps.first { $0.date > now }?.kind
    }

    /// The plan's confidence in the Telos vocabulary.
    static func confidence(_ plan: SleepSchedulePlan) -> TelosConfidence {
        switch plan.confidence {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating(done: plan.nightsUsed, total: SleepAnchor.windowNights)
        }
    }

    /// The asleep-by instant: lights out plus the onset buffer.
    static func asleepBy(_ steps: [TonightStep]) -> Date? {
        steps.first { $0.kind == .lightsOut }
            .map { $0.date.addingTimeInterval(TimeInterval(SleepAnchor.onsetBufferMin * 60)) }
    }
}

// MARK: - The card (Sleep screen, under the Rest hero)

/// "Tonight" on the Sleep screen: lights out and asleep-by, the need line, the evening's steps, the debt
/// payback and the insomnia note — or "—" plus the provider's reason.
struct TonightCardView: View {
    @ObservedObject private var provider = SleepScheduleProvider.shared

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            TonightCardContent(provider: provider, now: timeline.date, compact: false, navigates: false)
                .padding(TelosSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Plain faux glass (static fills; no top glow, no material, no shadow — decision 19).
                .background(FrostedCardSurface(tint: TelosColor.violet, cornerRadius: TelosRadius.card))
        }
    }
}

/// The shared body of the Sleep-screen card and the Today evening panel: the header, then the plan or
/// the abstention. `compact` (the panel) uses the smaller lights-out numeral, carries the confidence tag
/// in the header and drops the provenance row; `navigates` adds the tap-through chevron.
struct TonightCardContent: View {
    @ObservedObject var provider: SleepScheduleProvider
    let now: Date
    let compact: Bool
    let navigates: Bool

    var body: some View {
        let wakeDate = SleepScheduleProvider.comingWakeDate(now: now)
        // The clock-correct night (`current` is refreshed on data/pref changes and can lag the noon turn).
        let plan: SleepSchedulePlan? = provider.plan(wakingOn: wakeDate) ?? provider.current
        VStack(alignment: .leading, spacing: compact ? TelosSpace.s : TelosSpace.m) {
            header(plan)
            if let plan {
                planBody(plan, wakeDate: wakeDate)
            } else {
                abstentionBody
            }
        }
    }

    private func header(_ plan: SleepSchedulePlan?) -> some View {
        HStack(alignment: .center, spacing: TelosSpace.s) {
            Image(systemName: "moon.stars.fill")
                .font(TelosType.glyphRow)
                .foregroundStyle(TelosColor.violetInk)
                .accessibilityHidden(true)
            Text("Tonight")
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: TelosSpace.s)
            if compact, let plan {
                ConfidenceTag(TonightSchedule.confidence(plan))
            }
            if navigates {
                Image(systemName: "chevron.right")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Plan

    @ViewBuilder
    private func planBody(_ plan: SleepSchedulePlan, wakeDate: Date) -> some View {
        let steps = TonightSchedule.steps(plan: plan, wakeDate: wakeDate)
        let next = TonightSchedule.next(steps, now: now)
        let lightsOut = steps.first { $0.kind == .lightsOut }?.date
        let asleepBy = TonightSchedule.asleepBy(steps)

        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text("Lights out")
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                Text(verbatim: lightsOut.map { AppClock.hourMinute($0) } ?? TelosType.absent)
                    .telosNumeral(compact ? .numeralM : .numeralL)
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: TelosSpace.s)
            if let asleepBy {
                Text("Asleep by \(AppClock.hourMinute(asleepBy))")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.violetInk)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)

        // The model's own sentence (need, and whether it is the adult recommendation) — verbatim.
        Text(verbatim: plan.needLine)
            .font(TelosType.footnote)
            .foregroundStyle(TelosColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        TonightTimeline(steps: steps, next: next)

        if let payback = plan.paybackLine {
            TonightNoteRow(symbol: "arrow.uturn.backward.circle", tint: TelosColor.restInk, text: payback)
        }
        if let insomnia = plan.insomniaLine {
            TonightNoteRow(symbol: "exclamationmark.circle", tint: TelosColor.warning, text: insomnia)
        }
        if !compact {
            ProvenanceRow(window: Text("\(plan.nightsUsed) nights"),
                          confidence: TonightSchedule.confidence(plan))
        }
    }

    // MARK: Abstention

    @ViewBuilder
    private var abstentionBody: some View {
        // Before the first store read there is neither a plan nor a reason: say so plainly.
        let reason: Text = provider.abstention.map { Text(verbatim: $0.reason) } ?? Text("Not enough data yet")
        AbsentValue(reasonText: reason, dashFont: TelosType.numeralS)
        if let progress = calibrationProgress {
            // Progress to the threshold (§5.13 "abstaining"): n of the nights the anchor needs.
            PipBar(value: Double(min(progress.nights, progress.needed)), range: 0...Double(progress.needed),
                   segments: progress.needed, tint: TelosColor.violet, height: 6)
                .accessibilityLabel(Text("Calibrating (\(progress.nights) of \(progress.needed))"))
        }
    }

    /// Nights so far and nights needed while the anchor calibrates; nil otherwise.
    private var calibrationProgress: (nights: Int, needed: Int)? {
        guard case .calibrating(let nights, let needed)? = provider.abstention, needed > 0 else { return nil }
        return (nights, needed)
    }
}

/// A one-line qualifier under the timeline (payback, insomnia note). The text is the model's, verbatim.
private struct TonightNoteRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            Image(systemName: symbol)
                .font(TelosType.footnote)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Timeline

/// The evening's steps as nodes on one thin thread. Evenly spaced (a sequence, not a scale); the next
/// step is marked, passed steps dim. At accessibility text sizes the thread becomes a list.
struct TonightTimeline: View {
    let steps: [TonightStep]
    let next: TonightStep.Kind?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func state(_ step: TonightStep) -> NodeState {
        guard let next else { return .passed }
        if step.kind == next { return .next }
        let nextIndex = steps.firstIndex { $0.kind == next } ?? 0
        let index = steps.firstIndex { $0.kind == step.kind } ?? 0
        return index < nextIndex ? .passed : .ahead
    }

    enum NodeState { case passed, next, ahead }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                ForEach(steps) { step in
                    HStack(spacing: TelosSpace.s) {
                        TonightNode(symbol: step.symbol, state: state(step))
                        Text(step.title)
                            .font(TelosType.subhead)
                            .foregroundStyle(TelosColor.textSecondary)
                        Spacer(minLength: TelosSpace.s)
                        Text(verbatim: AppClock.hourMinute(step.date))
                            .font(TelosType.numeralXS)
                            .foregroundStyle(TelosColor.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(steps) { step in
                    VStack(spacing: TelosSpace.xs) {
                        TonightNode(symbol: step.symbol, state: state(step))
                        Text(step.title)
                            .telosScale()
                            .textCase(.uppercase)
                            .foregroundStyle(TelosColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: AppClock.hourMinute(step.date))
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(state(step) == .passed ? TelosColor.textTertiary : TelosColor.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            // The thread behind the nodes, at the node centre line (node 28 → y 14).
            .background(alignment: .top) {
                TonightThread()
                    .padding(.horizontal, TelosSpace.xl)
                    .padding(.top, TonightNode.diameter / 2 - 0.75)
            }
        }
    }
}

/// The connecting thread: one neutral hairline (no halo, no gradient — decision 19). The 4.5 pt frame is
/// kept so the node row's layout is unchanged.
private struct TonightThread: View {
    var body: some View {
        Capsule().fill(TelosColor.lineStrong).frame(height: 1)
            .frame(height: 4.5)
            .accessibilityHidden(true)
    }
}

/// One node: a small glass disc with the step's glyph. The next step is marked with a violet ring and
/// a faint violet fill (no glow — decision 19); passed steps dim.
private struct TonightNode: View {
    static let diameter: CGFloat = 28
    let symbol: String
    let state: TonightTimeline.NodeState

    var body: some View {
        let lit = state == .next
        let ink: Color = state == .passed ? TelosColor.textTertiary : (lit ? TelosColor.violetInk : TelosColor.restInk)
        ZStack {
            Circle()
                .fill(TelosColor.canvas)
            Circle()
                .fill(lit ? TelosColor.violet.opacity(TelosOpacity.fill) : TelosColor.glassFill)
            Circle()
                .strokeBorder(lit ? TelosColor.violetInk : TelosColor.line, lineWidth: lit ? 1.5 : 1)
            Image(systemName: symbol)
                .font(TelosType.glyphChevron)
                .foregroundStyle(ink)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }
}
