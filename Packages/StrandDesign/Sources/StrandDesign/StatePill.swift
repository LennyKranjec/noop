import SwiftUI

// MARK: - StatePill (§9.4 chrome) & ConnectionDot (sidebar status footer)
//
// Small status chips used in chrome: a capsule with an optional leading dot and a tinted `scale`
// label (§5.5: dot 7 + `scale`, tone colour). Tones map to the V2 status palette (positive / warning /
// critical) plus neutral and accent. The ConnectionDot is the presence indicator used in the
// strap-status footer / menu bar; when pulsing it runs the gated `live` loop (§4.8) — never a halo.

public enum StrandTone: Sendable {
    case neutral
    case accent
    case positive
    case warning
    case critical

    public var color: Color {
        switch self {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }
}

public struct StatePill: View {

    public var title: LocalizedStringKey
    public var tone: StrandTone
    public var showsDot: Bool
    /// Pulse the leading dot (e.g. "live" / "syncing").
    public var pulsing: Bool

    public init(_ title: LocalizedStringKey, tone: StrandTone = .neutral, showsDot: Bool = true, pulsing: Bool = false) {
        self.title = title
        self.tone = tone
        self.showsDot = showsDot
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                ConnectionDot(tone: tone, pulsing: pulsing, size: 7)
            }
            Text(title)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(tone.color)
                .lineLimit(1)
        }
        .padding(.horizontal, TelosSpace.s)
        .padding(.vertical, TelosSpace.xxs)
        .frame(minHeight: 20)
        // Shared tinted-chip weights (`TelosOpacity.fill` / `.border`) so this pill, a ScoreStatePill
        // and a TrendChip in the same row draw the same fill and edge.
        .background(
            Capsule(style: .continuous)
                .fill(tone.color.opacity(NoopVisualStyle.chipFillOpacity))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tone.color.opacity(NoopVisualStyle.chipBorderOpacity), lineWidth: TelosStroke.line)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - ConnectionDot

/// A tiny status dot. `pulsing` runs the V2 `live` loop (opacity 1 to 0.35 over 2 s) while it is true —
/// the one allowed never-settling animation, reserved for something actually live (a stream, a sync).
public struct ConnectionDot: View {

    public var tone: StrandTone
    public var pulsing: Bool
    public var size: CGFloat

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP". The loop is on screen for long stretches — a connected
    /// strap in Settings, a backfill on every scaffolded screen — so it sits behind the same gate as the
    /// liquid surfaces.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    private var looping: Bool { pulsing && !poseStill }

    public init(tone: StrandTone = .positive, pulsing: Bool = false, size: CGFloat = 9) {
        self.tone = tone
        self.pulsing = pulsing
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.35 : 1)
            // Honour the quiet-motion gate (system Reduce Motion, Low Power Mode, or the in-app toggle):
            // the loop only exists while `looping`; turning it off snaps back to the resting dot.
            .animation(TelosMotion.liveLoop(poseStill: !looping), value: dimmed)
            .onAppear { dimmed = looping }
            .onChangeCompat(of: looping) { active in dimmed = active }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("StatePill / ConnectionDot") {
    VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
            StatePill("Connected", tone: .positive)
            StatePill("Syncing", tone: .accent, pulsing: true)
            StatePill("Battery 14%", tone: .warning)
            StatePill("Disconnected", tone: .critical)
            StatePill("Idle", tone: .neutral, showsDot: false)
        }
        HStack(spacing: 16) {
            ConnectionDot(tone: .positive)
            ConnectionDot(tone: .accent, pulsing: true)
            ConnectionDot(tone: .warning)
            ConnectionDot(tone: .critical, pulsing: true)
        }
        // mimic the sidebar strap-status footer chip
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whoop 4.0").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("87% · streaming").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ConnectionDot(tone: .positive, pulsing: true)
        }
        .padding(12)
        .background(NoopPanelSurface(cornerRadius: 12))
        .frame(width: 300)
    }
    .padding(28)
    .frame(width: 560, height: 280)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
