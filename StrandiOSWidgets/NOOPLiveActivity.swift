import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
///
/// DURING A WORKOUT it becomes the session's own banner: its name, how long it has run, and either the
/// effort it has cost so far or — for a recovery session such as a meditation — how stress has moved
/// from its opening minutes to now. The clock is `Text(timerInterval:)`, which the system ticks by
/// itself, so the time is live to the second without the app sending a single update for it.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            Group {
                if context.state.inWorkout {
                    workoutBanner(context.state)
                } else {
                    liveHRBanner(title: context.attributes.title, state: context.state)
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.inWorkout {
                        Label {
                            workoutClock(context.state)
                        } icon: {
                            Image(systemName: workoutSymbol(context.state))
                        }
                        .foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Label("\(context.state.bpm.map(String.init) ?? "–")", systemImage: "heart.fill")
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.inWorkout {
                        workoutMetric(context.state, compact: false)
                    } else {
                        // Charge + Effort (#446) — one more stat alongside the leading live HR.
                        HStack(spacing: 10) {
                            if let r = context.state.recovery {
                                statColumn(label: "Charge", value: "\(r)%")
                            }
                            if let e = context.state.effort {
                                statColumn(label: "Effort", value: "\(e)")
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.workoutName ?? context.attributes.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                if context.state.inWorkout {
                    Image(systemName: workoutSymbol(context.state))
                        .foregroundStyle(StrandPalette.effortColor)
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            } compactTrailing: {
                if context.state.inWorkout {
                    workoutClock(context.state)
                        .frame(maxWidth: 52)
                } else {
                    Text("\(context.state.bpm.map(String.init) ?? "–")")
                }
            } minimal: {
                if context.state.inWorkout {
                    Image(systemName: workoutSymbol(context.state))
                        .foregroundStyle(StrandPalette.effortColor)
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }
}

// MARK: - The live-HR banner (between sessions)

@ViewBuilder
private func liveHRBanner(title: String, state: NOOPActivityAttributes.ContentState) -> some View {
    HStack(spacing: 14) {
        Image(systemName: "waveform.path.ecg")
            .font(.title2)
            .foregroundStyle(StrandPalette.statusCritical)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("\(state.bpm.map(String.init) ?? "–") bpm")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        Spacer()
        // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
        HStack(spacing: 12) {
            if let r = state.recovery {
                bannerStat(label: "Charge", value: "\(r)%")
            }
            if let e = state.effort {
                bannerStat(label: "Effort", value: "\(e)")
            }
        }
    }
}

// MARK: - The workout banner

@ViewBuilder
private func workoutBanner(_ state: NOOPActivityAttributes.ContentState) -> some View {
    HStack(alignment: .center, spacing: 14) {
        Image(systemName: workoutSymbol(state))
            .font(.title2)
            .foregroundStyle(state.workoutRecovery == true ? StrandPalette.restColor : StrandPalette.effortColor)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(state.workoutName ?? "Workout")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                if let bpm = state.bpm {
                    Text("· \(bpm) bpm")
                        .font(.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            workoutClock(state)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        Spacer(minLength: 8)
        workoutMetric(state, compact: false)
    }
}

/// The session's active time: ticking by itself while running, frozen while paused.
@ViewBuilder
private func workoutClock(_ state: NOOPActivityAttributes.ContentState) -> some View {
    if let paused = state.workoutPausedSeconds {
        Text(clockText(paused)).monospacedDigit()
    } else if let start = state.workoutClockStart {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    } else {
        Text("–")
    }
}

/// Effort for a load session; stress then → now for a recovery one.
@ViewBuilder
private func workoutMetric(_ state: NOOPActivityAttributes.ContentState, compact: Bool) -> some View {
    if state.workoutRecovery == true {
        VStack(alignment: .trailing, spacing: 2) {
            Text("STRESS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(stressLine(state))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            if let start = state.stressStart, let now = state.stressNow {
                let change = now - start
                Text(String(format: "%+.1f", change))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(change <= 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            } else {
                Text(state.stressStart == nil ? "reading in 5 min" : "change from 10 min")
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    } else {
        ZStack {
            Circle()
                .stroke(StrandPalette.effortColor.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(1, max(0, state.workoutEffortFraction ?? 0)))
                .stroke(StrandPalette.effortColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(state.workoutEffort ?? "–")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("effort")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

private func stressLine(_ state: NOOPActivityAttributes.ContentState) -> String {
    func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
    return state.stressNow == nil ? f(state.stressStart) : "\(f(state.stressStart)) → \(f(state.stressNow))"
}

private func workoutSymbol(_ state: NOOPActivityAttributes.ContentState) -> String {
    let name = (state.workoutName ?? "").lowercased()
    if state.workoutRecovery == true { return "figure.mind.and.body" }
    if name.contains("run") { return "figure.run" }
    if name.contains("walk") || name.contains("hik") { return "figure.walk" }
    if name.contains("cycl") || name.contains("bike") || name.contains("ride") { return "figure.outdoor.cycle" }
    if name.contains("swim") { return "figure.pool.swim" }
    if name.contains("lift") || name.contains("strength") || name.contains("weight") {
        return "figure.strengthtraining.traditional"
    }
    return "figure.mixed.cardio"
}

private func clockText(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
