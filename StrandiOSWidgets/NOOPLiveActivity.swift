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
///
/// TELOS 2.0 (DESIGN_V2 §6.13): the Telos ground as the banner tint, HR as the big light figure in the
/// `heart` hue, Effort in the mono `scaleNumber` voice, labels in the tracked small-caps voice, the
/// workout's effort as a static `TelosRing`. Every API here is iOS 16.1+ (ActivityKit / Dynamic Island),
/// inside the extension's iOS 17 floor — nothing needs an availability guard.
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
            // The Telos ground. A tint, not a gradient: the banner API takes one colour. Cost: none.
            .activityBackgroundTint(TelosColor.canvas)
            .activitySystemActionForegroundColor(TelosColor.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.inWorkout {
                        Label {
                            workoutClock(context.state)
                        } icon: {
                            Image(systemName: workoutSymbol(context.state))
                                .foregroundStyle(workoutTint(context.state))
                        }
                        .font(TelosType.numeralFont(size: 17, weight: .regular))
                        .foregroundStyle(TelosColor.textPrimary)
                    } else {
                        Label {
                            Text(context.state.bpm.map(String.init) ?? TelosType.absent)
                                .font(TelosType.numeralFont(size: 22, weight: .light))
                                .foregroundStyle(context.state.bpm == nil
                                                 ? TelosColor.textTertiary : TelosColor.heartInk)
                        } icon: {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(TelosColor.heart)
                        }
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
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textSecondary)
                }
            } compactLeading: {
                if context.state.inWorkout {
                    Image(systemName: workoutSymbol(context.state))
                        .foregroundStyle(workoutTint(context.state))
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(TelosColor.heart)
                }
            } compactTrailing: {
                if context.state.inWorkout {
                    workoutClock(context.state)
                        .font(TelosType.numeralFont(size: 14, weight: .regular))
                        .frame(maxWidth: 52)
                } else {
                    // The live bpm, in the heart ink. "—" until the first reading.
                    Text(context.state.bpm.map(String.init) ?? TelosType.absent)
                        .font(TelosType.numeralFont(size: 15, weight: .medium))
                        .foregroundStyle(context.state.bpm == nil
                                         ? TelosColor.textTertiary : TelosColor.heartInk)
                }
            } minimal: {
                if context.state.inWorkout {
                    Image(systemName: workoutSymbol(context.state))
                        .foregroundStyle(workoutTint(context.state))
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(TelosColor.heart)
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
            .foregroundStyle(TelosColor.heart)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TelosType.scale)
                .tracking(TelosType.Tracking.scale)
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // numeralL (34 pt) in the heart hue — the banner's one big figure.
                Text(state.bpm.map(String.init) ?? TelosType.absent)
                    .font(TelosType.numeralFont(size: 34, weight: .light))
                    .tracking(TelosType.Tracking.numeralL)
                    .foregroundStyle(state.bpm == nil ? TelosColor.textTertiary : TelosColor.heartInk)
                Text("bpm")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
            }
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
            .foregroundStyle(workoutTint(state))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(state.workoutName ?? "Workout")
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                if let bpm = state.bpm {
                    Text("· \(bpm) bpm")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.heartInk)
                }
            }
            workoutClock(state)
                .font(TelosType.numeralFont(size: 30, weight: .light))
                .foregroundStyle(TelosColor.textPrimary)
        }
        Spacer(minLength: 8)
        workoutMetric(state, compact: false)
    }
}

/// The session's hue: `rest` for a recovery session, `effort` for a load session.
private func workoutTint(_ state: NOOPActivityAttributes.ContentState) -> Color {
    state.workoutRecovery == true ? TelosColor.rest : TelosColor.effort
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
        Text(verbatim: TelosType.absent)
    }
}

/// Effort for a load session; stress then → now for a recovery one.
@ViewBuilder
private func workoutMetric(_ state: NOOPActivityAttributes.ContentState, compact: Bool) -> some View {
    if state.workoutRecovery == true {
        VStack(alignment: .trailing, spacing: 2) {
            Text("STRESS")
                .font(TelosType.scaleFixed)
                .tracking(TelosType.Tracking.scale)
                .foregroundStyle(TelosColor.textSecondary)
            Text(stressLine(state))
                .font(TelosType.numeralFont(size: 17, weight: .regular))
                .foregroundStyle(TelosColor.stressInk)
            if let start = state.stressStart, let now = state.stressNow {
                let change = now - start
                // The sign carries the direction as well as the hue.
                Text(String(format: "%+.1f", change))
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(change <= 0 ? TelosColor.positive : TelosColor.warning)
            } else {
                Text(state.stressStart == nil ? "reading in 5 min" : "change from 10 min")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
    } else {
        VStack(spacing: 2) {
            ZStack {
                // The effort so far as a static Telos ring: `scale: 1` because the fraction is 0–1; a
                // fraction past 1 draws a second lap rather than being clipped, and a missing fraction is
                // the dashed bare track rather than an empty arc that reads as zero.
                // Cost: TelosRing's shapes only; `animatesChanges: false` (each update is a new render).
                TelosRing(value: state.workoutEffortFraction, scale: 1, color: TelosColor.effort,
                          diameter: 48, showsValue: false, animatesChanges: false)
                Text(state.workoutEffort ?? TelosType.absent)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(state.workoutEffort == nil ? TelosColor.textTertiary : TelosColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: 48, height: 48)
            Text("effort")
                .font(TelosType.scaleFixed)
                .tracking(TelosType.Tracking.scale)
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private func stressLine(_ state: NOOPActivityAttributes.ContentState) -> String {
    func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? TelosType.absent }
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
///
/// Telos: label in the tracked small-caps voice, value in the mono `scaleNumber` voice (§6.13: "effort
/// `scaleNumber`") — the banner's one big figure is the heart rate.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label)
            .font(TelosType.scaleFixed)
            .tracking(TelosType.Tracking.scale)
            .textCase(.uppercase)
            .foregroundStyle(TelosColor.textSecondary)
        Text(value)
            .font(TelosType.scaleNumber)
            .foregroundStyle(TelosColor.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label)
            .font(TelosType.scaleFixed)
            .tracking(TelosType.Tracking.scale)
            .textCase(.uppercase)
            .foregroundStyle(TelosColor.textSecondary)
        Text(value)
            .font(TelosType.scaleNumber)
            .foregroundStyle(TelosColor.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
