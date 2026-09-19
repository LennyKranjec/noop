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
// THE DIAL IS LIVE. It shows the stress of the last ten minutes (`DaytimeStress.live`), re-read every
// minute while the tile is on screen, against the same calm reference the day's hours are scored on.
// When the last ten minutes cannot be read — too little heart rate, or the wearer was moving — it shows
// the latest scored hour, and the caption says which of the two it is.
//
// WITH NO HOUR SCORED YET the dial takes the app's own DAILY stress — the 0–3 figure the Stress screen
// headlines — and the caption says it is the day's, not this moment's. Highest / Lowest / Average stay
// blank then, because those genuinely need hours.

/// How often the hourly curve is re-asked. It is hourly-grain, so faster buys nothing.
private let stressRescoreSeconds: TimeInterval = 5 * 60   // every five minutes, as asked

/// How often the live reading is re-taken, and the window it reads.
private let liveEverySeconds: UInt64 = 5 * 60   // every five minutes, as asked
private let liveWindowSeconds = 10 * 60
/// PERF: the motion trace is the big read of the three — ten minutes of accelerometer at strap rate.
/// The live level only needs enough of it to tell sitting from moving, so the read is capped rather
/// than pulled whole every minute. Hundreds of samples decide that; thousands only cost main-actor
/// time merging them.
private let liveGravityLimit = 6_000

struct TodayStressTileView: View {
    @EnvironmentObject var repo: Repository

    /// The app's whole-day 0–3 score, for when no hour has been scored yet.
    let dailyFallback: Double?
    let onOpen: () -> Void

    @State private var dayHours: [DaytimeStress.HourPoint] = []
    @State private var liveLevel: Double?
    @State private var liveAt: Date?

    /// The loop below runs while Today is on screen, and Today stays mounted behind the other tabs. It
    /// does nothing while the app is in the background: re-reading ten minutes of raw trace a minute
    /// there buys a reading nobody is looking at and wakes the store for it.
    @Environment(\.scenePhase) private var scenePhase

    /// Highest / lowest / average / latest over the SCORED hours, derived once when the hours land.
    ///
    /// They used to be four computed properties, each walking `hours` again, and the body reads all of
    /// them plus the dial and the accessibility label — six passes per render on a tile that re-renders
    /// every minute.
    private struct Stats: Equatable {
        var highest: Double?
        var lowest: Double?
        var average: Double?
        var latest: (ts: Int, level: Double)?
        static func == (a: Stats, b: Stats) -> Bool {
            a.highest == b.highest && a.lowest == b.lowest && a.average == b.average
                && a.latest?.ts == b.latest?.ts && a.latest?.level == b.latest?.level
        }
        init(_ hours: [DaytimeStress.HourPoint] = []) {
            let scored = hours.compactMap { h in h.level.map { (ts: h.startTs, level: $0) } }
            highest = scored.map(\.level).max()
            lowest = scored.map(\.level).min()
            average = scored.isEmpty ? nil : scored.map(\.level).reduce(0, +) / Double(scored.count)
            latest = scored.max { $0.ts < $1.ts }
        }
    }

    @State private var stats = Stats()

    private var shown: Double? { liveLevel ?? stats.latest?.level ?? dailyFallback }

    /// One formatter, not one per render.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var caption: String {
        if liveLevel != nil, let liveAt {
            return "Live · last 10 min, " + Self.clock.string(from: liveAt)
        }
        if let latest = stats.latest {
            return "Last updated at " + Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(latest.ts)))
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
                            // Full strength while the dial is live, dimmer when it is showing an earlier hour.
                            .opacity(liveLevel != nil ? 1 : 0.7)
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
                        stat("Highest", stats.highest)
                        divider
                        stat("Lowest", stats.lowest)
                        divider
                        stat("Average", stats.average)
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
        // KEYED ON THE SCENE PHASE, so the loop is torn down when the app leaves the foreground and
        // started again when it comes back. `.task` captures the view as it was when it started, so a
        // phase read INSIDE the loop would never change.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // One loop for as long as Today is on screen and in front; cancelled with it. The hourly
            // curve and the live window every five minutes.
            var curveAt = Date.distantPast
            while !Task.isCancelled {
                if Date().timeIntervalSince(curveAt) >= stressRescoreSeconds,
                   let curve = await StressDayCurve.today(repo: repo) {
                    stats = Stats(curve.result.timeline)
                    dayHours = curve.result.hours
                    curveAt = Date()
                    await repo.bankDaytimeRmssd(hours: curve.result.hours)
                }
                await readLive()
                try? await Task.sleep(nanoseconds: liveEverySeconds * 1_000_000_000)
            }
        }
    }

    private func readLive() async {
        let to = Int(Date().timeIntervalSince1970)
        let from = to - liveWindowSeconds
        let hr = await repo.hrSamples(from: from, to: to, limit: 5_000)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 10_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: liveGravityLimit)
        // OFF THE MAIN ACTOR. `live` is a pure function over three Sendable arrays, and scoring ten
        // minutes of trace on the main actor every minute is a stutter on a screen that is scrolling.
        let dayHours = dayHours
        let level = await Task.detached(priority: .utility) {
            DaytimeStress.live(hr: hr, rr: rr, gravity: gravity, dayHours: dayHours)
        }.value
        liveLevel = level
        liveAt = level == nil ? nil : Date()
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
