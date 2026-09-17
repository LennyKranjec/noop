import SwiftUI
import StrandAnalytics
import StrandDesign

// TodayStressTileView.swift — today's stress, live, above the energy bar.
//
// SwiftUI twin of the Android `TodayStressCard` in `StressEnergySection`: a dot and a title, when the
// reading is from, the day's Highest / Lowest / Average, and a radial tick dial lit up to the latest
// scored hour.
//
// LIVE MEANS RE-SCORED WHILE IT IS ON SCREEN. It reads the same intraday curve the widget publishes
// (`StressDayCurve`), whose own fingerprint gate makes an unchanged hour cost one indexed count, and
// asks again every few minutes for as long as Today is visible. Highest / Lowest / Average are taken
// across SCORED hours only: an hour the motion gate masked as activity carries no level and is skipped
// rather than counted as calm.
//
// WITH NO HOUR SCORED YET the dial takes the app's own DAILY stress — the 0–3 figure the Stress screen
// headlines — and the caption says it is the day's, not this moment's. Highest / Lowest / Average stay
// blank then, because those genuinely need hours.

/// How often the tile re-asks while it is on screen. The curve is hourly-grain, so faster buys nothing.
private let stressRescoreSeconds: UInt64 = 5 * 60

struct TodayStressTileView: View {
    @EnvironmentObject var repo: Repository

    /// The app's whole-day 0–3 score, for when no hour has been scored yet.
    let dailyFallback: Double?
    let onOpen: () -> Void

    @State private var hours: [DaytimeStress.HourPoint] = []

    private var scored: [(ts: Int, level: Double)] {
        hours.compactMap { h in h.level.map { (h.startTs, $0) } }
    }
    private var highest: Double? { scored.map(\.level).max() }
    private var lowest: Double? { scored.map(\.level).min() }
    private var average: Double? {
        scored.isEmpty ? nil : scored.map(\.level).reduce(0, +) / Double(scored.count)
    }
    private var latest: (ts: Int, level: Double)? { scored.max { $0.ts < $1.ts } }
    private var shown: Double? { latest?.level ?? dailyFallback }

    private var caption: String {
        if let latest {
            let f = DateFormatter()
            f.timeStyle = .short
            return "Last updated at " + f.string(from: Date(timeIntervalSince1970: TimeInterval(latest.ts)))
        }
        return dailyFallback != nil ? "Today's score, no hour scored yet" : "No reading yet"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(shown.map(StressRamp.color) ?? StrandPalette.textTertiary)
                            .frame(width: 8, height: 8)
                        Text("Today's stress")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(caption)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                    Spacer().frame(height: 10)
                    HStack(spacing: 0) {
                        stat("Highest", highest)
                        divider
                        stat("Lowest", lowest)
                        divider
                        stat("Average", average)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 8) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    StressTickDial(level: shown)
                        .frame(width: 96, height: 96)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Today's stress, \(shown.map { String(format: "%.1f", $0) } ?? "no reading")"))
        .task {
            // One loop for as long as the tile is on screen; cancelled with it.
            while !Task.isCancelled {
                if let curve = await StressDayCurve.today(repo: repo) {
                    hours = curve.result.timeline
                }
                try? await Task.sleep(nanoseconds: stressRescoreSeconds * 1_000_000_000)
            }
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { String(format: "%.1f", $0) } ?? "–")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 8)
    }
}

/// The radial tick dial: the 0–3 stress scale as spokes around an open gauge, lit up to `level`.
///
/// Every tick carries its OWN place on the ramp, so the dial shows the scale it reads against even
/// before it has a reading. Unlit ticks keep that colour at a low alpha rather than going grey, so the
/// dial reads as one instrument dimmed rather than two different gauges.
private struct StressTickDial: View {
    let level: Double?

    private let ticks = 40
    private let startDeg: Double = 150
    private let spanDeg: Double = 240

    var body: some View {
        ZStack {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = radius * 0.96
                let inner = radius * 0.72
                let stroke = max(1.5, radius * 0.055)
                let lit = level.map { min(max($0 / 3, 0), 1) } ?? 0
                for i in 0..<ticks {
                    let t = Double(i) / Double(ticks - 1)
                    let angle = (startDeg + spanDeg * t) * .pi / 180
                    var p = Path()
                    p.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    p.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                    let color = StressRamp.color(3 * t).opacity(t <= lit ? 1 : 0.22)
                    context.stroke(p, with: .color(color),
                                   style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }
            }
            Text(level.map { String(format: "%.1f", $0) } ?? "–")
                .font(StrandFont.number(level == nil ? 18 : 22))
                .foregroundStyle(level == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }
}
