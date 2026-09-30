import StrandDesign
import SwiftUI
import WidgetKit

/// Home-screen widget: the live heart rate with the last `HrTrace.windowSec` drawn as a trace (#1957).
///
/// Swift twin of the Android `HrGlanceWidget`, but the drawing is NOT a port. Glance compiles to
/// RemoteViews and cannot draw, so Android renders the trace to a Bitmap under a payload budget and a
/// reduced pixel depth. WidgetKit is SwiftUI: the trace is a stroked `Path`, resolution-independent,
/// with no bitmap to size and nothing to budget. What IS shared is `HrTrace` — the retention rule, the
/// normalisation and the tick choices — because those are the same reading of the same heart.
///
/// Honest-blank throughout, matching the twin: no reading shows an em dash and no chart, never a flat
/// line at zero. A single point draws a dot, because a widget added this minute has exactly one.
struct HeartRateEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct HeartRateProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeartRateEntry {
        HeartRateEntry(date: Date(), snap: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeartRateEntry) -> Void) {
        completion(HeartRateEntry(date: Date(), snap: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartRateEntry>) -> Void) {
        let entry = HeartRateEntry(date: Date(), snap: WidgetSnapshot.load())
        // The app reloads timelines when the heart rate moves, so this is only the safety net for when
        // it is not running. Fifteen minutes rather than the trace's one-minute bucket: a widget cannot
        // outrun its publisher, and asking more often spends budget WidgetKit would decline anyway.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// The trace itself: a stroked path with a fill beneath it.
///
/// Takes its size from the geometry rather than a guess, which is the whole advantage over the Android
/// twin — there is no bitmap, so nothing has to predict the box or survive being stretched into it.
private struct HrTraceShape: Shape {
    let series: [HrPoint]
    /// When true, close the path down to the baseline for the gradient fill.
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pts = HrTrace.points(series, width: rect.width, height: rect.height)
        guard let first = pts.first else { return path }
        if pts.count == 1 {
            // One reading is not a line. A dot says "one reading"; an empty box says "no data", and
            // those are different things.
            guard !filled else { return path }
            let r: CGFloat = 2.5
            path.addEllipse(in: CGRect(x: max(first.x, r) - r, y: first.y - r, width: r * 2, height: r * 2))
            return path
        }
        // Draw a run at a time, lifting the pen across the gaps. x is mapped by TIME, so a gap already
        // occupies its true width; it was only the line drawn across it that was never measured.
        for run in HrTrace.runs(pts) {
            let head = pts[run.lowerBound]
            guard run.lowerBound != run.upperBound else {
                // A lone reading between two gaps is not a line either, and gets the same dot the
                // single-point series above does.
                if !filled {
                    // Held a full dot inside the box: the likeliest lone run of all is the NEWEST
                    // reading after a long disconnect, which sits exactly on the right edge.
                    let dot: CGFloat = 2.5
                    let cx = min(max(head.x, dot), max(rect.maxX - dot, dot))
                    path.addEllipse(in: CGRect(x: cx - dot, y: head.y - dot,
                                               width: dot * 2, height: dot * 2))
                }
                continue
            }
            // Each run closes its own area, so the gradient stops at the gap along with the line.
            if filled {
                path.move(to: CGPoint(x: head.x, y: rect.maxY))
                path.addLine(to: CGPoint(x: head.x, y: head.y))
            } else {
                path.move(to: CGPoint(x: head.x, y: head.y))
            }
            for i in (run.lowerBound + 1)...run.upperBound {
                path.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y))
            }
            if filled {
                path.addLine(to: CGPoint(x: pts[run.upperBound].x, y: rect.maxY))
                path.closeSubpath()
            }
        }
        return path
    }
}

struct HeartRateWidgetView: View {
    let entry: HeartRateEntry

    /// Pruned on the way OUT as well as on the way in, matching the Kotlin twin. A widget rendered
    /// hours after the last publish would otherwise draw a trace whose newest point is long stale, under
    /// a time axis implying it is current — and WidgetKit renders an entry at ITS date, which is why the
    /// window is measured from `entry.date` rather than from `Date()`.
    private var series: [HrPoint] {
        HrTrace.prune(entry.snap?.hrSeries ?? [], nowSec: Int64(entry.date.timeIntervalSince1970))
    }
    private var stats: HrTrace.Stats? { HrTrace.stats(series) }
    /// Age-checked, so an hours-old reading is not printed as current. Without this the prune above made
    /// the card incoherent: the trace emptied while the headline kept its confident number.
    private var shown: (bpm: Int?, stale: Bool) {
        HrDisplay.resolve(bpm: entry.snap?.bpm, newestPointTs: series.last?.ts, now: entry.date)
    }
    /// The Telos `heart` identity hue (DESIGN_V2 §4.1): the trace, its fill and the glyph. The figure
    /// itself uses `heartInk`, the text variant. (The Android twin still mirrors the old zone-5 hexes;
    /// the two widgets now differ in hue, not in what they draw.)
    private var accent: Color { TelosColor.heart }

    /// When the headline figure was READ: the newest trace point. Shown only when the figure is stale, so
    /// a dimmed number always says how old it is.
    private var readAt: Date? {
        series.last.map { Date(timeIntervalSince1970: TimeInterval($0.ts)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title in the label voice; the publish time rides on the same row (it used to take a row of
            // its own at the bottom, which the medium tile could not spare for the trace).
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Heart rate")
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let updated = entry.snap?.updated, updated != .distantPast {
                    Text("Updated \(updated, format: .dateTime.hour().minute())")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                // numeralL's 34 pt, fixed: the medium tile's height is fixed and the trace needs the rest.
                Text(shown.bpm.map(String.init) ?? TelosType.absent)
                    .font(TelosType.numeralFont(size: 34, weight: .light))
                    .tracking(TelosType.Tracking.numeralL)
                    .foregroundStyle(shown.bpm == nil ? TelosColor.textTertiary
                                     : (shown.stale ? TelosColor.textSecondary : TelosColor.heartInk))
                if shown.bpm != nil {
                    Text("bpm")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                }
                if shown.stale, let readAt {
                    // Stale → secondary + "as of HH:MM" (§6.13), so a carried reading never reads as live.
                    Text("as of \(readAt, format: .dateTime.hour().minute())")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let stats {
                    // A faux-glass pill: translucent fill + the heart hue at 16 %. Cost: one capsule fill.
                    Text("Min \(stats.min) • Max \(stats.max)")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(TelosOpacity.fill), in: Capsule())
                }
            }

            if !series.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    HrTraceChart(series: series, accent: accent)
                    // A scale of one repeated number says nothing the headline has not, so it waits for
                    // a range — the same rule the Android twin follows.
                    if let stats, stats.max > stats.min {
                        // Ticks computed ONCE, and the gap keyed on the INDEX. Comparing the value to
                        // `.last` happened to work only because a scale is drawn solely when there is a
                        // range; with two equal ticks it would have dropped a spacer and skewed the scale.
                        let ticks = HrTrace.bpmTicks(stats)
                        VStack(alignment: .trailing) {
                            ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                                Text("\(tick)")
                                    .font(TelosType.scaleNumber)
                                    .foregroundStyle(TelosColor.textSecondary)
                                if index < ticks.count - 1 { Spacer(minLength: 0) }
                            }
                        }
                    }
                }
                HrTimeAxis(series: series)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// One spoken sentence rather than a run of loose numbers. The Android twin had to settle for
    /// per-label descriptions because Glance cannot mark a Text decorative; SwiftUI can combine the
    /// whole card, so it does. Staleness is not encoded in colour here at all, so nothing needs saying
    /// about it.
    private var accessibilityText: String {
        // String(localized:) rather than bare literals. The audit DOES scan `.accessibilityLabel(`, but
        // it matches a literal sitting immediately after the paren — and this is a computed property, so
        // extracting the sentence here hid it from the check. Hardcoded English would have shipped to
        // every locale with the gate green, which is the same trap the Kotlin twin records for copy
        // written inside a semantics {} lambda.
        guard let bpm = shown.bpm else { return String(localized: "Heart rate, no reading") }
        guard let stats else { return String(localized: "Heart rate \(bpm) bpm") }
        return String(localized: "Heart rate \(bpm) bpm, minimum \(stats.min), maximum \(stats.max)")
    }
}

private struct HrTraceChart: View {
    let series: [HrPoint]
    let accent: Color

    var body: some View {
        ZStack {
            HrTraceShape(series: series, filled: true)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.35), accent.opacity(0)],
                    startPoint: .top, endPoint: .bottom,
                ))
            HrTraceShape(series: series, filled: false)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HrTimeAxis: View {
    let series: [HrPoint]

    var body: some View {
        let ticks = HrTrace.timeTicks(series)
        // One instant pinned to the left edge reads as a stray rather than an axis, so it waits for a
        // span to label — matching the twin.
        if ticks.count >= 2 {
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, ts in
                    Text(Date(timeIntervalSince1970: TimeInterval(ts)),
                         format: .dateTime.hour().minute())
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct HeartRateWidget: Widget {
    static let kind = "HeartRateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HeartRateProvider()) { entry in
            if #available(iOS 17.0, *) {
                HeartRateWidgetView(entry: entry)
                    .containerBackground(for: .widget) { TelosWidgetGround() }
            } else {
                HeartRateWidgetView(entry: entry)
                    .padding()
                    .background(TelosColor.canvas)
            }
        }
        .configurationDisplayName("Heart Rate")
        .description("Live heart rate with the last three hours as a trace.")
        .supportedFamilies([.systemMedium])
    }
}
