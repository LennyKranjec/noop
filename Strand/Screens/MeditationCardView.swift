import SwiftUI
import StrandDesign

// MeditationCardView.swift — the meditation log, at the top of Focus.
//
// SwiftUI twin of the Android `MeditationCard`. Three things, in the order they answer: how long you
// have sat ALTOGETHER, whether you have sat on each of the last three days, and a way to sit now.
//
// THE THREE CIRCLES ARE THE LEVEL'S OWN WINDOW. They are not a streak — a streak breaks and shames, and
// this is a rolling three days: the oldest circle empties as it falls past the third, which is exactly
// the figure `LevelEngine.focus` multiplies the calm score by. What is on screen IS the input, so the
// wearer can see why their focus score moved rather than being told.
//
// THE TIMER MEASURES, IT DOES NOT COUNT DOWN. There is no target length here and inventing one would be
// a prescription nobody asked for: start it, sit, stop it, and what was actually sat is what is logged.
//
// IT IS A WALL-CLOCK DIFFERENCE, not an accumulated tick count, so a second the phone spent asleep or
// the app spent backgrounded is still a second the wearer spent sitting.
//
// THE BIN DELETES THE DAY, and it is the wearer's own request — they wanted to be able to throw away a
// session that went wrong and sit it again properly. It clears the day rather than the last session,
// because the store holds a day's total and subtracting a session it does not remember would be
// arithmetic on a guess.

private let dayCircleSize: CGFloat = 26
private let dayDotSize: CGFloat = 12
private let roundButtonSize: CGFloat = 40

struct MeditationCardView: View {
    @EnvironmentObject var repo: Repository

    @State private var lifetime: Double = 0
    @State private var window: [Double] = Array(repeating: 0, count: MeditationLog.windowDays)
    @State private var runningSince: Date?
    @State private var elapsed = 0
    /// What the last stop did. Nil until they have stopped one, and cleared the moment they start
    /// another — a stale "too short" hanging over a session in progress would be the wrong news.
    @State private var lastOutcome: MeditationLog.Outcome?

    private var running: Bool { runningSince != nil }
    private var doneToday: Bool { (window.last ?? 0) > 0 }

    /// The 4 Hz tick that moves the stopwatch. It exists only while a session runs.
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                headline
                controls
                footer
            }
        }
        .task(id: repo.refreshSeq) { await reload() }
        .onReceive(ticker) { _ in
            guard let start = runningSince else {
                if elapsed != 0 { elapsed = 0 }
                return
            }
            elapsed = Int(Date().timeIntervalSince(start))
        }
    }

    // MARK: - 1 · The headline: everything ever sat

    /// While the timer runs this shows the total PLUS the seconds so far, so the figure the wearer is
    /// watching is the one the session is adding to. That is a live reading, not a stored one — nothing
    /// is written until they stop.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TOTAL MEDITATED")
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .bottom, spacing: 4) {
                Text("\(Int((lifetime + (running ? Double(elapsed) / 60 : 0)).rounded()))")
                    .font(StrandFont.title1)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransitionNumericIfAvailable()
                Text("min")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.bottom, 3)
                if running {
                    Spacer(minLength: 8)
                    Text(clock(elapsed))
                        .font(StrandFont.title2)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.statusPositive)
                }
            }
        }
    }

    // MARK: - 2 · The window, and the controls that fill it

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(Array(window.enumerated()), id: \.offset) { i, minutes in
                // The last circle is today, and it is the one the buttons act on.
                DayCircle(lit: minutes > 0, isToday: i == window.count - 1)
            }
            Spacer(minLength: 8)

            // START / STOP. Disabled once the day is logged — the wearer asked for exactly one
            // meditation a day to count, and a button that runs a timer whose result is thrown away
            // would be a control that lies about what it does.
            RoundAction(
                icon: running ? "stop.fill" : "play.fill",
                tint: running ? StrandPalette.statusWarning : StrandPalette.statusPositive,
                enabled: running || !doneToday,
                label: running ? "Stop meditation" : "Start meditation"
            ) {
                toggleTimer()
            }

            // THE BIN. Only live when there is something to throw away, and never while the timer is
            // running — stopping is what the stop button is for.
            RoundAction(
                icon: "trash.fill",
                tint: StrandPalette.statusCritical,
                enabled: doneToday && !running,
                label: "Delete today's meditation"
            ) {
                SystemHaptics.play(.select)
                Task {
                    lastOutcome = nil
                    await repo.clearMeditation()
                    await reload()
                }
            }
        }
    }

    // MARK: - 3 · What just happened

    /// The two FAILURE cases outrank the standing hints: a session that was not stored has to say so, or
    /// the button reads as broken. That is not hypothetical — it is how the Android one was reported.
    private var footer: some View {
        Text(footerText)
            .font(StrandFont.caption)
            .foregroundStyle(footerTint)
    }

    private var footerText: String {
        if running { return "Sitting. Stop when you are done — what you actually sat is what is logged." }
        switch lastOutcome {
        case .tooShort:
            return "Under \(MeditationLog.minSessionSeconds) seconds, so it was not logged."
        case .failed:
            return "That session could not be saved."
        default:
            return doneToday
                ? "Logged for today. The circle stays lit for three days, then frees up again."
                : "Three days in a row is what the focus score reads. Sit one today."
        }
    }

    private var footerTint: Color {
        switch lastOutcome {
        case .tooShort, .failed: return running ? StrandPalette.textTertiary : StrandPalette.statusWarning
        default: return StrandPalette.textTertiary
        }
    }

    // MARK: - Behaviour

    private func toggleTimer() {
        guard let start = runningSince else {
            SystemHaptics.play(.tap)
            lastOutcome = nil
            elapsed = 0
            runningSince = Date()
            return
        }
        let seconds = Int(Date().timeIntervalSince(start))
        runningSince = nil
        elapsed = 0
        SystemHaptics.play(.confirm)
        Task {
            lastOutcome = await repo.logMeditation(seconds: seconds).outcome
            await reload()
        }
    }

    private func reload() async {
        lifetime = await repo.meditationLifetimeMinutes()
        window = await repo.meditationWindow()
    }

    /// `m:ss`, or `h:mm:ss` once a session runs past the hour.
    private func clock(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
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

/// A circular icon button. Dim and inert when disabled rather than absent, so the control can be learnt.
private struct RoundAction: View {
    let icon: String
    let tint: Color
    let enabled: Bool
    let label: String
    let action: () -> Void

    private var alpha: Double { enabled ? 1 : 0.28 }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(tint.opacity(0.14 * alpha))
                .overlay(Circle().strokeBorder(tint.opacity(0.55 * alpha), lineWidth: 1))
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint.opacity(alpha))
                }
                .frame(width: roundButtonSize, height: roundButtonSize)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

private extension View {
    /// The digits roll rather than jump when a session lands, where the OS can do it.
    @ViewBuilder
    func contentTransitionNumericIfAvailable() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}
