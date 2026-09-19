import SwiftUI
import StrandDesign
import WhoopStore

/// The trailing "AI feedback" control on a Today "Last workouts" row.
///
/// Gathers the workout's full dossier (`WorkoutFeedbackGatherer` → `WorkoutFeedbackDossier`), parks it on
/// the coach as the thread's subject, and routes to Coach with a short visible question. Like the Coach
/// launcher sheet it performs NO provider request itself: `CoachView` sends the parked question, so
/// consent, streaming and errors stay in the one place that owns them.
///
/// Laid over the row as a sibling of its NavigationLink (not inside the link's label), so tapping it
/// never also opens the Workouts screen, and the rest of the row keeps its tap.
struct WorkoutFeedbackButton: View {
    let row: WorkoutRow
    /// The stress change the tile already shows for a recovery session, if it has one.
    let stressStart: Double?
    let stressEnd: Double?

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter

    @State private var preparing = false

    /// Horizontal room the row reserves so its trailing figure is not covered by this button.
    static let reservedWidth: CGFloat = 40

    var body: some View {
        Button {
            Task { await start() }
        } label: {
            ZStack {
                if preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
            }
            .frame(width: 34, height: 34)
            .background(Circle().fill(StrandPalette.surfaceInset))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .accessibilityLabel(Text("AI feedback"))
    }

    private func start() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        let input = await WorkoutFeedbackGatherer.input(for: row, repo: repo, profile: profile,
                                                        stressStart: stressStart, stressEnd: stressEnd)
        let prompt = WorkoutFeedbackDossier.visiblePrompt(
            sport: input.sport, start: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        coach.beginWorkoutFeedback(dossier: WorkoutFeedbackDossier.build(input), prompt: prompt)
        router.openCoach()
    }
}
