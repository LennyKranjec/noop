//  StateTileViews.swift
//  NOOP · Liquid Today — the STATE tile's interactive parts: the refresh button, tappable recommendation
//  rows (deficits and the mission), the "WORKOUTS TODAY" section, and the sheets they raise.
//
//  Kept out of LiquidTodayView on purpose: that file is large and shared by several changes at once, and
//  every piece here is self-contained — it reads the shared `StateCoachController` and routes through the
//  app's existing destinations (NavRouter, TabRoute, the live workout, the coach chat).

import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Routing

@MainActor
enum StateActionPerformer {

    /// A short pause between a sheet dismissing and the next presentation/route, so the shell never tries
    /// to present over a sheet that is still animating away.
    static let handoffDelayNs: UInt64 = 450_000_000

    /// Run a recommendation's action. `navigate` pushes a Today route (the caller owns the stack).
    static func perform(_ rec: StateRecommendation, router: NavRouter, navigate: (TabRoute) -> Void) {
        let c = StateCoachController.shared
        switch rec.action {
        case .hydration: navigate(.hydration)
        case .sleep: navigate(.sleep)
        case .metric(let key): navigate(.metric(key))
        case .journal: router.openJournal()
        case .breathe: c.presented = .breathe
        case .pickWorkout: c.pickingWorkout = true
        case .startWorkout(let sport, let zone): startWorkout(sport: sport, zone: zone, router: router)
        case .detail: c.presented = .detail(rec)
        }
    }

    /// Start a live workout of `sport`, lock `zone` when given, and open it. A session already running is
    /// simply opened — never replaced by a tap on a suggestion.
    static func startWorkout(sport: String, zone: Int?, router: NavRouter) {
        guard let model = AppModel.shared else {
            StateCoachController.shared.pickingWorkout = true
            return
        }
        if model.activeWorkout == nil {
            model.startWorkout(sport: sport)
            RecentSportsPrefs.recordSelection(sport)
            if let zone, model.activeWorkout != nil, model.activeWorkout?.lockedZone != zone {
                model.toggleWorkoutZoneLock(zone)
            }
        }
        router.openActiveWorkout()
    }

    /// Hand a question to the coach chat (the same seam the Today coach launcher uses).
    static func askCoach(_ prompt: String, coach: AICoachEngine, router: NavRouter) {
        coach.pendingPrompt = prompt
        router.openCoach()
    }

    /// Run `work` after the handoff pause.
    static func afterHandoff(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: handoffDelayNs)
            work()
        }
    }
}

// MARK: - Refresh button

/// The STATE tile's top-right refresh: regenerates the state, the mission and the workout suggestions.
/// Spins (a progress indicator) and is disabled while running; the throttle lives in the controller.
struct StateRefreshButton: View {
    let action: () async -> Void
    @ObservedObject private var controller = StateCoachController.shared

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            ZStack {
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRefreshing)
        .accessibilityLabel(Text("Refresh state"))
        .accessibilityHint(Text("Asks the coach to update today's state, mission and workout suggestions."))
    }
}

// MARK: - Recommendation rows

/// One deficit line, tappable. Visually the same dot + text the card always had, plus a chevron.
struct StateRecommendationRow: View {
    let recommendation: StateRecommendation
    let tint: Color
    let navigate: (TabRoute) -> Void
    @EnvironmentObject private var router: NavRouter
    // NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    // actions/tasks (it never renders coach state), so a non-observing reference is enough.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }

    var body: some View {
        Button {
            StateActionPerformer.perform(recommendation, router: router, navigate: navigate)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(recommendation.title)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                StateCoachController.shared.presented = .detail(recommendation)
            } label: { Label("Why?", systemImage: "info.circle") }
            Button {
                StateActionPerformer.askCoach(recommendation.askCoachPrompt, coach: coach, router: router)
            } label: { Label("Ask coach", systemImage: "sparkles") }
        }
    }
}

/// Today's mission under the STATE card, tappable: it routes to the action its goal names, or opens the
/// detail sheet when the goal has no in-app action.
struct StateMissionNote: View {
    let mission: String
    let navigate: (TabRoute) -> Void
    @EnvironmentObject private var router: NavRouter
    // NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    // actions/tasks (it never renders coach state), so a non-observing reference is enough.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }

    private var recommendation: StateRecommendation {
        // The stored mission carries the goal line the text was written with; only trust it while it is
        // the one on screen.
        let stored = DailyMissionStore.today()
        let goal = stored?.text == mission ? stored?.goal : nil
        return StateActionMapper.recommendation(forMission: mission, goal: goal)
    }

    var body: some View {
        let rec = recommendation
        Button {
            StateActionPerformer.perform(rec, router: router, navigate: navigate)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("MISSION")
                        .font(StrandFont.overline)
                        .tracking(1.6)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(mission)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                StateCoachController.shared.presented = .detail(rec)
            } label: { Label("Why?", systemImage: "info.circle") }
            Button {
                StateActionPerformer.askCoach(rec.askCoachPrompt, coach: coach, router: router)
            } label: { Label("Ask coach", systemImage: "sparkles") }
        }
    }
}

// MARK: - WORKOUTS TODAY

/// The tile's second section: 1–3 further workouts for today. A tap starts the workout (sport preselected,
/// zone locked); the info button opens the reasoning with an "Ask coach".
struct StateWorkoutsSection: View {
    let figures: StateTrainingFigures
    @ObservedObject private var controller = StateCoachController.shared
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    // NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    // actions/tasks (it never renders coach state), so a non-observing reference is enough.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @EnvironmentObject private var router: NavRouter
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Re-read when the day's figures or its workouts move. Effort in steps of 5 so the live score
    /// creeping up does not re-run this every few seconds.
    private var loadKey: String {
        "\(Int(figures.charge ?? -1))|\(Int(figures.effortTarget ?? -1))|\(Int((figures.effortNow ?? -5) / 5))"
            + "|\(Int(figures.sleepDebtMin ?? -1))|\(repo.workoutsSeq)|\(repo.refreshSeq)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(StrandPalette.textTertiary.opacity(0.18))
                .frame(height: 1)
                .padding(.bottom, 2)
            HStack(spacing: 6) {
                Text("WORKOUTS TODAY").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                } else if controller.source == .fallback {
                    Text("Built-in").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else if controller.source == .coach {
                    Text("Coach").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if controller.suggestions.isEmpty {
                Text("Nothing more to suggest for today.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                ForEach(controller.suggestions) { s in row(s) }
            }
            if let notice = controller.notice {
                Text(notice)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: loadKey) {
            await controller.load(figures: figures, repo: repo, profile: profile, coach: coach)
        }
    }

    private func zoneRange(_ zone: Int) -> String? {
        profile.hrZoneSet.bpmRanges.first { $0.zone == zone }.map { "\($0.lower)–\($0.upper) bpm" }
    }

    private func detailLine(_ s: WorkoutSuggestion) -> String {
        var parts: [String] = []
        if let w = s.window { parts.append(w) }
        if let r = zoneRange(s.zone) { parts.append(r) }
        if let e = s.effort, e > 0 {
            parts.append(String(localized: "≈ +\(UnitFormatter.effortDeltaDisplay(e, scale: effortScale)) effort"))
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ s: WorkoutSuggestion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                StateActionPerformer.startWorkout(sport: s.sport, zone: s.lockZone, router: router)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle().fill(StrandPalette.effortColor.opacity(0.16))
                        Text("Z\(s.zone)")
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.effortColor)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(WorkoutSource.displaySport(s.sport)) · \(s.minutes) min")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        let detail = detailLine(s)
                        if !detail.isEmpty {
                            Text(detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        if !s.why.isEmpty {
                            Text(s.why)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(StrandPalette.effortColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Start \(s.sport), \(s.minutes) minutes, zone \(s.zone)"))

            Button {
                controller.presented = .workoutDetail(s)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Why this workout"))
        }
        .contextMenu {
            Button {
                StateActionPerformer.askCoach(s.askCoachPrompt, coach: coach, router: router)
            } label: { Label("Ask coach", systemImage: "sparkles") }
        }
    }
}

// MARK: - Sheets

/// Presents whatever the STATE tile raised: the detail sheets, the breathing session, the workout picker.
/// Attach once, to the tile.
struct StateTilePresentationHost: ViewModifier {
    let navigate: (TabRoute) -> Void
    @ObservedObject private var controller = StateCoachController.shared
    @EnvironmentObject private var router: NavRouter
    // NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    // actions/tasks (it never renders coach state), so a non-observing reference is enough.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.presented) { presentation in
                sheet(presentation)
            }
            .workoutSelectionCover(isPresented: $controller.pickingWorkout) {
                StartWorkoutSheet { name in
                    let r = router
                    StateActionPerformer.afterHandoff {
                        StateActionPerformer.startWorkout(sport: name, zone: nil, router: r)
                    }
                }
            }
    }

    private func primaryTitle(_ action: StateAction) -> String? {
        switch action {
        case .hydration: return String(localized: "Log water")
        case .breathe: return String(localized: "Start breathing")
        case .sleep: return String(localized: "Open sleep")
        case .journal: return String(localized: "Open journal")
        case .metric: return String(localized: "Open details")
        case .startWorkout(let sport, _): return String(localized: "Start \(WorkoutSource.displaySport(sport))")
        case .pickWorkout: return String(localized: "Start a workout")
        case .detail: return nil
        }
    }

    @ViewBuilder
    private func sheet(_ presentation: StateCoachController.Presentation) -> some View {
        let r = router
        let c = coach
        let nav = navigate
        switch presentation {
        case .detail(let rec):
            StateRecommendationSheet(
                title: rec.title, message: rec.rationale, facts: [],
                primaryTitle: primaryTitle(rec.action),
                onPrimary: {
                    StateActionPerformer.afterHandoff {
                        StateActionPerformer.perform(rec, router: r, navigate: nav)
                    }
                },
                onAsk: {
                    StateActionPerformer.afterHandoff {
                        StateActionPerformer.askCoach(rec.askCoachPrompt, coach: c, router: r)
                    }
                })
        case .workoutDetail(let s):
            StateRecommendationSheet(
                title: WorkoutSource.displaySport(s.sport),
                message: s.why.isEmpty ? String(localized: "Suggested for the rest of today.") : s.why,
                facts: workoutFacts(s),
                primaryTitle: s.lockZone.map { String(localized: "Start with Zone \($0) locked") }
                    ?? String(localized: "Start workout"),
                onPrimary: {
                    StateActionPerformer.afterHandoff {
                        StateActionPerformer.startWorkout(sport: s.sport, zone: s.lockZone, router: r)
                    }
                },
                onAsk: {
                    StateActionPerformer.afterHandoff {
                        StateActionPerformer.askCoach(s.askCoachPrompt, coach: c, router: r)
                    }
                })
        case .breathe:
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { controller.presented = nil }
                        }
                    }
            }
        }
    }

    private func workoutFacts(_ s: WorkoutSuggestion) -> [String] {
        var out = [String(localized: "\(s.minutes) min in Zone \(s.zone)")]
        if let r = profile.hrZoneSet.bpmRanges.first(where: { $0.zone == s.zone }) {
            out[0] += " (\(r.lower)–\(r.upper) bpm)"
        }
        if let w = s.window { out.append(String(localized: "Best window: \(w)")) }
        if let e = s.effort, e > 0 {
            let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
            out.append(String(localized: "Adds about \(UnitFormatter.effortDeltaDisplay(e, scale: scale)) effort"))
        }
        return out
    }
}

/// The detail sheet: the line, why, the in-app action when there is one, and "Ask coach".
struct StateRecommendationSheet: View {
    let title: String
    let message: String
    let facts: [String]
    let primaryTitle: String?
    let onPrimary: () -> Void
    let onAsk: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(StrandFont.rounded(22))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !facts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(facts, id: \.self) { fact in
                                Text(fact).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                    Text(message)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) {
                        if let primaryTitle {
                            Button {
                                dismiss()
                                onPrimary()
                            } label: {
                                pill(primaryTitle, icon: "play.fill", filled: true)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            dismiss()
                            onAsk()
                        } label: {
                            pill(String(localized: "Ask coach"), icon: "sparkles", filled: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pill(_ label: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(label)
        }
        .font(StrandFont.subhead.weight(.semibold))
        .foregroundStyle(filled ? Color.white : StrandPalette.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Capsule().fill(filled ? StrandPalette.accent : StrandPalette.accent.opacity(0.12)))
        .contentShape(Capsule())
    }
}
