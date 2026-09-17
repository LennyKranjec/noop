import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MeditationCardView.swift — the meditation log, at the top of Focus.
//
// THE DAILY MEDITATION IS AN ACTIVITY, not a timer on this card. The wearer logs a "Meditation" session
// the way they log any other — Start workout, the WHOOP app, Apple Health — and this card reads those
// sessions back (`Repository.meditationMinutesByDay`). Three things, in the order they answer: how long
// they have sat altogether, how many of the last 28 days carried a meditation (the share the level's
// focus part reads), and the most recent sessions themselves.
//
// THE PLAY BUTTON STARTS THAT ACTIVITY. It opens the in-exercise screen with the sport already set to
// Meditation, so sitting from here is the same recording as Start workout → Meditation — heart rate,
// duration, saved as a workout when it ends.
//
// A DAY COUNTS FROM `LevelEngine.meditationMinMinutes`. The circles light on exactly the rule the level
// uses, so what is on screen IS the input.

private let dayCircleSize: CGFloat = 26
private let dayDotSize: CGFloat = 12
private let playButtonSize: CGFloat = 40
private let meditationSport = "Meditation"

struct MeditationCardView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var model: AppModel

    @State private var showLiveWorkout = false

    @State private var lifetime: Double = 0
    /// Minutes per day for the last seven days, oldest first.
    @State private var week: [Double] = Array(repeating: 0, count: 7)
    /// Days in the level's 28-day window that carried a meditation.
    @State private var daysInWindow = 0
    @State private var recent: [WorkoutRow] = []

    private var doneToday: Bool { (week.last ?? 0) >= LevelEngine.meditationMinMinutes }

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                headline
                circles
                if !recent.isEmpty { sessions }
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

    // MARK: - 1 · The headline: everything ever sat, and the level's window

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL MEDITATED")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(lifetime.rounded()))")
                        .font(StrandFont.title1)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("min")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("LAST \(LevelEngine.meditationWindowDays) DAYS")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("\(daysInWindow)/\(LevelEngine.meditationWindowDays)")
                    .font(StrandFont.title2)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    // MARK: - 2 · The last seven days

    private var circles: some View {
        HStack(spacing: 8) {
            ForEach(Array(week.enumerated()), id: \.offset) { i, minutes in
                DayCircle(lit: minutes >= LevelEngine.meditationMinMinutes, isToday: i == week.count - 1)
            }
            Spacer(minLength: 8)
            playButton
        }
    }

    /// Starts a Meditation activity and opens the in-exercise screen — or, when a session is already
    /// running, just reopens it rather than starting a second one.
    private var playButton: some View {
        let running = model.activeWorkout != nil
        return Button {
            SystemHaptics.play(.tap)
            if !running { model.startWorkout(sport: meditationSport) }
            showLiveWorkout = true
        } label: {
            Circle()
                .fill(StrandPalette.statusPositive.opacity(0.14))
                .overlay(Circle().strokeBorder(StrandPalette.statusPositive.opacity(0.55), lineWidth: 1))
                .overlay {
                    Image(systemName: running ? "waveform.path.ecg" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                }
                .frame(width: playButtonSize, height: playButtonSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(running ? "Open the running session" : "Start a meditation"))
    }

    // MARK: - 3 · The sessions themselves

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(recent.prefix(3).enumerated()), id: \.offset) { _, w in
                HStack(spacing: 8) {
                    Image(systemName: "figure.mind.and.body")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                    Text(Self.when(w))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    Text("\(Int(((w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60).rounded())) min")
                        .font(StrandFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    private var footer: some View {
        Text(doneToday
             ? "Meditated today. A day counts from \(Int(LevelEngine.meditationMinMinutes)) minutes."
             : "Press play to start a Meditation activity, or log one in the WHOOP app or Apple Health. A day counts from \(Int(LevelEngine.meditationMinMinutes)) minutes.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: - Behaviour

    private func reload() async {
        let byDay = await repo.meditationMinutesByDay()
        lifetime = byDay.values.reduce(0, +)
        let calendar = Calendar.current
        let now = Date()
        func minutes(back: Int) -> Double {
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { return 0 }
            return byDay[Repository.localDayKey(d)] ?? 0
        }
        week = (0..<7).reversed().map { minutes(back: $0) }
        daysInWindow = (0..<LevelEngine.meditationWindowDays)
            .filter { minutes(back: $0) >= LevelEngine.meditationMinMinutes }.count
        recent = Array(await repo.meditationSessions(days: 60).prefix(3))
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

/// One day of the window. Lit with a green dot when it carried a meditation.
private struct DayCircle: View {
    let lit: Bool
    let isToday: Bool

    var body: some View {
        Circle()
            .fill(StrandPalette.surfaceInset)
            .overlay(
                Circle().strokeBorder(
                    isToday ? StrandPalette.textSecondary : StrandPalette.hairline,
                    lineWidth: isToday ? 1.5 : 1)
            )
            .overlay {
                if lit {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: dayDotSize, height: dayDotSize)
                }
            }
            .frame(width: dayCircleSize, height: dayCircleSize)
    }
}
