#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The floating rest pill ("2:26"): a luminous ring draining toward zero, the time, and −15 s / +15 s / skip.
///
/// The number is `endsAt − now`, redrawn by a 1 s `TimelineView` — never a counter — so it is right after the
/// phone has been in a pocket (see `LiftRestTimer`). The ring animates only by being redrawn each second; nothing
/// runs while the pill is not on screen, and the view is not in the tree when no rest is running.
struct LiftRestTimerPill: View {
    @ObservedObject var recorder: LiftSessionRecorder

    var body: some View {
        if let end = recorder.rest.endsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, end.timeIntervalSince(context.date))
                let fraction = recorder.rest.fractionElapsed(at: context.date) ?? 1
                HStack(spacing: TelosSpace.s) {
                    adjustButton(delta: -LiftRestTimer.adjustStepSeconds, symbol: "minus")
                    HStack(spacing: TelosSpace.s) {
                        ZStack {
                            Circle().stroke(TelosColor.mintMuted, lineWidth: TelosStroke.data)
                            Circle()
                                .trim(from: 0, to: max(0.001, 1 - fraction))
                                .stroke(TelosColor.mint, style: StrokeStyle(lineWidth: TelosStroke.data, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 26, height: 26)
                        .shadow(color: TelosColor.glow.opacity(0.6), radius: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Rest").liftOverline()
                            Text(verbatim: LiftRestTimer.clock(remaining))
                                .font(TelosType.numeralFont(size: 26))
                                .monospacedDigit()
                                .foregroundStyle(TelosColor.textPrimary)
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(minWidth: 110)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Rest timer"))
                    .accessibilityValue(Text(verbatim: LiftRestTimer.clock(remaining)))
                    adjustButton(delta: LiftRestTimer.adjustStepSeconds, symbol: "plus")
                    Button { recorder.skipRest() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(TelosType.glyphControl)
                            .foregroundStyle(TelosColor.textSecondary)
                            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Skip rest"))
                }
                .padding(.horizontal, TelosSpace.s)
                .padding(.vertical, TelosSpace.xs)
                .liftGlass(radius: TelosRadius.pill, raised: true)
            }
            .transition(.opacity)
        }
    }

    private func adjustButton(delta: Int, symbol: String) -> some View {
        Button { recorder.adjustRest(bySeconds: delta) } label: {
            VStack(spacing: 0) {
                Image(systemName: symbol).font(TelosType.glyphRow)
                Text(verbatim: "15s").font(TelosType.scaleFixed)
            }
            .foregroundStyle(TelosColor.mint)
            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(delta > 0 ? Text("Add 15 seconds") : Text("Remove 15 seconds"))
    }
}
#endif
