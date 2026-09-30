import SwiftUI
import StrandDesign

/// Caffeine window (#526) — log a caffeine intake (time + OPTIONAL mg) and see a plain on-device
/// "still active" hint. OPT-IN, manual-first: nothing shows until the user logs an intake, and the
/// estimate is clearly framed as a rough guide from a ~5–6 h half-life decay, never a measurement or a
/// health claim.
///
/// Honesty is enforced in the model (`CaffeineDecay` / `CaffeineLogStore`): an unknown amount stays
/// unknown (we never invent mg), the active hint covers the dose-unknown case in words, and the copy
/// states it's an estimate from what was logged.
///
/// TELOS 2.0 (PROGRESS): a glass card in the fuel amber. The CUTOFF now follows tonight's bedtime from the
/// sleep anchor (`CaffeineBedtime.bedtimeMinutes(fallback:)` — HEALTH_V2 S2) and falls back to the manual
/// bedtime only when there is no plan; the label says which one it used. The same bedtime drives the
/// late-intake nudge, so the card can never warn against one bedtime and print another.
/// COST: static, plus the existing once-a-minute re-read of the decay estimate.
struct CaffeineLogCard: View {
    /// The shared UserDefaults-backed store (#949). Shared rather than owned here so the Apple Health
    /// import and this card write through the same instance — see `CaffeineLogStore.shared`.
    @ObservedObject private var store = CaffeineLogStore.shared

    /// Drives a live recompute of the estimate while the card is on screen (the decay is time-based).
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @State private var mgDraft = ""
    /// "How long ago" quick options for logging — hours back from now.
    private let quickHoursAgo: [Int] = [0, 1, 2, 3]

    // PR#566 (mvanhorn) — caffeine cutoff window + late-intake nudge. OPT-IN (default OFF, manual-first).
    // Keys MIRROR the Android prefs (KEY_CAFFEINE_CUTOFF / KEY_CAFFEINE_BEDTIME_MIN, default 23:00).
    @AppStorage(Self.cutoffEnabledKey) private var cutoffEnabled = false
    @AppStorage(Self.bedtimeMinutesKey) private var bedtimeMinutes = 23 * 60
    static let cutoffEnabledKey = "noop.caffeine.cutoffNudge"
    static let bedtimeMinutesKey = "noop.caffeine.bedtimeMinutes"

    /// Tonight's bedtime: the sleep anchor's when a plan exists, else the manual one.
    private var effectiveBedtime: Int { CaffeineBedtime.bedtimeMinutes(fallback: bedtimeMinutes, now: tick) }
    /// Whether tonight's bedtime came from the sleep plan (so the manual picker is only the fallback).
    private var bedtimeFromPlan: Bool {
        SleepScheduleProvider.shared.plan(wakingOn: SleepScheduleProvider.comingWakeDate(now: tick)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Caffeine", overline: "Log")
            StrandCard(tint: TelosColor.amber) {
                VStack(alignment: .leading, spacing: TelosSpace.m) {
                    activeHint

                    // PR#566 — the late-intake nudge sits right under the active hint when the cutoff is on
                    // and a logged intake is past it, so the timing warning is the first thing read.
                    lateIntakeNudge

                    Text("Log a coffee, tea, or energy drink and NOOP shows a rough estimate of how much may still be active. It's a guide based on a typical 5 to 6 hour half-life, not a measurement.")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    TelosListDivider(leadingInset: 0)

                    // Optional amount — leave blank if you don't know it. We never invent a number.
                    HStack(spacing: TelosSpace.s) {
                        TextField("Amount in mg (optional)", text: $mgDraft)
                            .textFieldStyle(.plain)
                            .font(TelosType.body)
                            .foregroundStyle(TelosColor.textPrimary)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        Text("mg")
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                    .padding(.horizontal, TelosSpace.m)
                    .frame(minHeight: TelosSpace.hitTarget)
                    .pgInsetBand()

                    // Log "now" or a quick number of hours ago — mirrors the journal's day-pill row.
                    HStack(spacing: TelosSpace.xs) {
                        PGOverline("Had it")
                        Spacer(minLength: TelosSpace.xs)
                        ForEach(quickHoursAgo, id: \.self) { h in
                            logPill(h == 0 ? "Now" : "\(h)h ago", hoursAgo: h)
                        }
                    }

                    TelosListDivider(leadingInset: 0)
                    cutoffSection

                    if !store.intakes.isEmpty {
                        TelosListDivider(leadingInset: 0)
                        loggedList
                    }
                }
            }
        }
        .onReceive(ticker) { tick = $0 }
    }

    // MARK: - Cutoff window (PR#566) — bedtime + late-intake nudge

    /// The bedtime + cutoff controls: a toggle, and (when on) the bedtime (the sleep plan's, or the manual
    /// fallback) plus the derived "stop after" time — computed from the dose-decay lead, never a magic number.
    @ViewBuilder private var cutoffSection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack(alignment: .top, spacing: TelosSpace.s) {
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    Text("Cutoff before bed")
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textPrimary)
                    Text("Warn me when I log caffeine too close to bedtime. A timing guide from your own bedtime, not a measurement.")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: TelosSpace.s)
                Toggle("", isOn: $cutoffEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(TelosColor.amber)
                    .accessibilityLabel("Warn me about caffeine close to bedtime")
            }
            if cutoffEnabled {
                if bedtimeFromPlan {
                    HStack(alignment: .firstTextBaseline) {
                        PGOverline("Bedtime · sleep plan")
                        Spacer()
                        Text(verbatim: timeLabel(effectiveBedtime))
                            .font(TelosType.numeralS)
                            .foregroundStyle(TelosColor.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    Text(bedtimeFromPlan ? "Bedtime when there is no plan" : "Bedtime")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                    Spacer()
                    DatePicker("", selection: bedtimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel(bedtimeFromPlan ? "Bedtime when there is no plan" : "Bedtime")
                }
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Image(systemName: "cup.and.saucer")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.amber)
                        .accessibilityHidden(true)
                    Text("Stop caffeine after about \(cutoffTimeLabel) to keep most of it cleared by \(timeLabel(effectiveBedtime)).")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The late-intake nudge — shown only when the cutoff is ON and at least one logged intake (today) falls
    /// past the cutoff for tonight's bedtime. Honest: it warns about TIMING ("may keep you up"), never a
    /// health claim, and it disappears the moment no logged intake is past cutoff.
    @ViewBuilder private var lateIntakeNudge: some View {
        if cutoffEnabled, latePastCutoffCount > 0 {
            HStack(alignment: .top, spacing: TelosSpace.s) {
                Image(systemName: "moon.zzz")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.warning)
                    .accessibilityHidden(true)
                Text(lateNudgeText)
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TelosSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TelosColor.warning.opacity(TelosOpacity.wash),
                        in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    /// Count of logged intakes whose local time-of-day is past the bedtime cutoff. Uses the shared decay
    /// model's `isPastCutoff` so the UI and the cutoff math can't drift, against tonight's bedtime.
    private var latePastCutoffCount: Int {
        let bedtime = effectiveBedtime
        return store.intakes.filter { intake in
            CaffeineDecay.isPastCutoff(intakeMinutes: minutesSinceMidnight(intake.at),
                                       bedtimeMinutes: bedtime)
        }.count
    }

    private var lateNudgeText: String {
        let n = latePastCutoffCount
        // Whole-phrase variants per count so translators see complete sentences (never a stitched lead).
        return n == 1
            ? String(localized: "A logged caffeine is past your bedtime cutoff. It may still be on board and keep you up. Just a timing heads-up.")
            : String(localized: "\(n) logged caffeines are past your bedtime cutoff. They may still be on board and keep you up. Just a timing heads-up.")
    }

    /// The cutoff time-of-day label, derived from tonight's bedtime minus the dose-decay lead (shared model).
    private var cutoffTimeLabel: String {
        timeLabel(CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes: effectiveBedtime))
    }

    /// Local minutes-since-midnight for a logged intake's wall-clock time.
    private func minutesSinceMidnight(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Bridges the minutes-since-midnight bedtime pref to the DatePicker's Date.
    private var bedtimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = bedtimeMinutes / 60
                c.minute = bedtimeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                bedtimeMinutes = min(max((c.hour ?? 23) * 60 + (c.minute ?? 0), 0), 24 * 60 - 1)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        var c = DateComponents()
        c.hour = minutes / 60
        c.minute = minutes % 60
        let date = Calendar.current.date(from: c) ?? Date()
        return Self.cutoffTimeFormatter.string(from: date)
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label.
    private static var cutoffTimeFormatter: DateFormatter { AppClock.hourMinuteFormatter() }

    // MARK: - Active hint

    /// The "caffeine still active" readout. Shows an mg estimate only when at least one active intake had a
    /// known amount; otherwise it's worded without a number (we don't fabricate a dose). A calm "all clear"
    /// line when nothing is active so the card always reads as live, never blank.
    @ViewBuilder private var activeHint: some View {
        let est = store.estimate()
        if est.hasActive {
            HStack(alignment: .top, spacing: TelosSpace.m) {
                Circle()
                    .fill(TelosColor.amber)
                    .frame(width: 8, height: 8)
                    .background(TelosRadialGlow(color: TelosColor.amber, intensity: 0.5, radius: 12).frame(width: 24, height: 24))
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    Text(activeTitle(est))
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(activeDetail(est))
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(store.intakes.isEmpty
                 ? "No caffeine logged. Log an intake to see an estimate."
                 : "Estimated mostly cleared. Nothing logged is likely still active.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activeTitle(_ est: CaffeineActiveEstimate) -> String {
        if let mg = est.totalRemainingMg {
            return String(localized: "About \(Int(mg.rounded())) mg may still be active")
        }
        return String(localized: "Caffeine may still be active")
    }

    /// Whole-phrase variants per combination so translators always see a complete sentence.
    private func activeDetail(_ est: CaffeineActiveEstimate) -> String {
        let recent = est.hoursSinceMostRecentActive.map(hoursLabel)
        let count = est.activeIntakeCount
        switch (recent, count > 1) {
        case (let r?, true):
            return String(localized: "most recent intake about \(r) ago · \(count) intakes still in the estimate. Rough guide only, based on what you logged.")
        case (let r?, false):
            return String(localized: "most recent intake about \(r) ago. Rough guide only, based on what you logged.")
        case (nil, true):
            return String(localized: "\(count) intakes still in the estimate. Rough guide only, based on what you logged.")
        case (nil, false):
            return String(localized: "Rough guide only, based on what you logged.")
        }
    }

    private func hoursLabel(_ hrs: Double) -> String {
        if hrs < 1 { return String(localized: "under an hour") }
        let rounded = Int(hrs.rounded())
        return rounded == 1 ? String(localized: "1 hour") : String(localized: "\(rounded) hours")
    }

    // MARK: - Logged list

    @ViewBuilder private var loggedList: some View {
        PGOverline("Logged today")
        ForEach(store.intakes) { intake in
            HStack {
                Text(intakeLabel(intake))
                    .font(TelosType.body)
                    .foregroundStyle(TelosColor.textPrimary)
                Spacer()
                // No remove control on an imported intake (#949): the next sync re-reads the same window
                // from Apple Health and would bring it straight back. Remove it where it was logged.
                if intake.isImported {
                    TelosTag("Apple Health", ink: TelosColor.textTertiary)
                } else {
                    Button {
                        TelosHaptics.play(.select)
                        store.remove(intake.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(TelosType.glyphControl)
                            .foregroundStyle(TelosColor.critical)
                            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .accessibilityLabel("Remove caffeine intake at \(Self.timeFormatter.string(from: intake.at))")
                }
            }
        }
    }

    private func intakeLabel(_ intake: CaffeineIntake) -> String {
        let time = Self.timeFormatter.string(from: intake.at)
        if let mg = intake.mg {
            return String(localized: "\(time) · \(Int(mg.rounded())) mg")
        }
        return String(localized: "\(time) · amount not logged")
    }

    // MARK: - Controls

    private func logPill(_ label: LocalizedStringKey, hoursAgo: Int) -> some View {
        TelosChip(label, isOn: false) {
            let mg = Double(mgDraft.trimmingCharacters(in: .whitespaces))   // nil if blank/invalid
            let at = Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: tick) ?? tick
            store.log(at: at, mg: mg)
            mgDraft = ""
        }
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label.
    private static var timeFormatter: DateFormatter { AppClock.hourMinuteFormatter() }
}
