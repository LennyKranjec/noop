#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The Telos Lift door on the workout picker (DESIGN_V2 decision 16): the strength logger's own entry, at the top
/// of "Choose a workout", so the plan is one tap from Today's "+" → Start workout (and from Live / Workouts).
///
/// WITH A PLAN: "Today: Upper A (Mo)" — the day the logger itself would open (`LiftSessionRecorder.suggestion`:
/// the same `LiftTemplatePicker` rule — weekday tag, then the rotation after the last completed day — over the
/// same stored sessions `attach` reads) — and the plan's other days as chips. Either tap starts a Strength workout
/// with that day waiting for the logger (`preferStart`), which then opens straight into its per-set rows, rest
/// timer and Finish.
/// WITHOUT ONE (the bundled seed failed, or the wearer deleted the plan): import the Alphaprog export (the same
/// importer as Data Sources and the logger's empty state), or start a freehand session.
///
/// Until the stored sessions are read, only a WEEKDAY pick is shown as "Today" (history cannot change it); a
/// rotation pick waits for the read rather than flash one day and then another.
struct TelosLiftStartCard: View {
    let onStart: @MainActor (LiftSessionRecorder.StartPreference) -> Void

    @ObservedObject private var programs = LiftProgramStore.shared
    @ObservedObject private var recorder = LiftSessionRecorder.shared
    @Environment(\.appModelRef) private var modelRef
    @State private var refreshed = false

    private var templates: [LiftDayTemplate] { programs.library.allTemplates }

    private var todayPick: LiftSessionRecorder.Suggestion? {
        if refreshed {
            guard let s = recorder.suggestion, let t = programs.library.template(id: s.template.id) else { return nil }
            return LiftSessionRecorder.Suggestion(template: t, reason: s.reason)
        }
        let weekday = Calendar.current.component(.weekday, from: Date())
        guard let pick = LiftTemplatePicker.pick(templates: templates, weekday: weekday, lastCompletedTemplateId: nil),
              pick.reason == .weekday else { return nil }
        return LiftSessionRecorder.Suggestion(template: pick.template, reason: pick.reason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            HStack(spacing: TelosSpace.s) {
                Image(systemName: "dumbbell.fill")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(TelosColor.textSecondary)
                    .accessibilityHidden(true)
                Text("Strength · Telos Lift").liftOverline()
                Spacer(minLength: 0)
            }
            if templates.isEmpty {
                noPlan
            } else {
                withPlan
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Decision 19 (clinical restraint): the SAME flat faux-glass surface + hairline as the catalogue cards
        // below it — no top glow, no halo, no shadow (it scrolls).
        .background {
            FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card)
        }
        // Re-read when the plan's days change (an import from this card, an edit elsewhere).
        .task(id: templates.map(\.id)) {
            let repo = resolvedAppModel(modelRef)?.repo
            await recorder.refreshSuggestion(storeProvider: { await repo?.storeHandle() })
            refreshed = true
        }
    }

    // MARK: - With a plan

    @ViewBuilder
    private var withPlan: some View {
        let today = todayPick
        if let today {
            Button { onStart(.template(today.template.id, reason: today.reason)) } label: {
                HStack(spacing: TelosSpace.m) {
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        Text("Today: \(today.template.name)")
                            .font(TelosType.headline)
                            .foregroundStyle(TelosColor.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(today.template.exercises.count) exercises · \(today.template.plannedSetCount) sets")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textSecondary)
                        Text(verbatim: reasonText(today.reason))
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "play.fill")
                        .font(TelosType.glyphControl)
                        .foregroundStyle(TelosColor.onAccent)
                        .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                        .background(Circle().fill(StrandPalette.accent))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TelosPressButtonStyle())
            .accessibilityHint(Text("Double tap to start"))
        }
        let others = LiftTemplatePicker.rotation(templates).filter { $0.id != today?.template.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                if today == nil {
                    Text("Your plan").liftOverline()
                } else {
                    Text("Other days").liftOverline()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TelosSpace.s) {
                        ForEach(others) { day in
                            Button { onStart(.template(day.id, reason: nil)) } label: {
                                Text(verbatim: day.name)
                                    .font(TelosType.callout)
                                    .foregroundStyle(TelosColor.textPrimary)
                                    .lineLimit(1)
                                    .padding(.horizontal, TelosSpace.m)
                                    .padding(.vertical, TelosSpace.s)
                                    .frame(minHeight: TelosSpace.hitTarget)
                                    .background(Capsule(style: .continuous).fill(TelosColor.glassFill))
                                    .overlay(Capsule(style: .continuous)
                                        .strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(TelosPressButtonStyle())
                            .accessibilityHint(Text("Double tap to start"))
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
    }

    /// The logger header's own wording (`LiftLoggerView.pickReasonText`), so the two read the same.
    private func reasonText(_ reason: LiftTemplatePicker.Reason) -> String {
        switch reason {
        case .weekday: return String(localized: "Today's day in your plan")
        case .rotation: return String(localized: "Next in your rotation")
        case .first: return String(localized: "First day of your plan")
        }
    }

    // MARK: - No plan

    private var noPlan: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            Text("No training plan yet")
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textPrimary)
            Text("Import your Alphaprog plan export to get your days, exercises, sets and rep targets — or log this session without a plan.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LiftPlanImportButton(programs: programs)
            Button { onStart(.freehand) } label: {
                Text("Start without a plan").frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
    }
}
#endif
