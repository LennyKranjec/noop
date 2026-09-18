import WidgetKit
import SwiftUI
import StrandDesign

// TelosStripWidget.swift — the day under the clock: steps, effort against its target, stress now.
//
// A LOCK-SCREEN RECTANGLE, three readings side by side:
//   · left, today's steps;
//   · centre, today's effort as a ring that fills clockwise from twelve o'clock, with a tick where the
//     day's recommended effort tops out — so "how much" and "how much is enough" are one glance;
//   · right, stress on its 0–3 scale with the reading marked on it.
//
// LIVE AS FAR AS A WIDGET CAN BE. iOS draws a widget from a timeline, not a stream, so this redraws when
// the app publishes (every refresh while it is open, and quietly in the background, where the app keeps
// running for the strap) and at least every fifteen minutes on its own. The stress figure is the last
// ten minutes as of that publish.
//
// LOCK-SCREEN COLOUR IS NOT COLOUR. The system renders this family vibrant and flattens any hue into the
// wallpaper, so hierarchy is carried by primary / secondary and by the accentable fill alone.

struct StripEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StripProvider: TimelineProvider {
    func placeholder(in context: Context) -> StripEntry {
        var snap = WidgetSnapshot.placeholder
        snap.stepsToday = 8_420
        snap.effortToday = 46
        snap.effortTodayDisplay = "46"
        snap.effortTarget = 67
        snap.stressNow = 1.3
        snap.stressNowAt = Date()
        return StripEntry(date: Date(), snapshot: snap)
    }

    func getSnapshot(in context: Context, completion: @escaping (StripEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context)
                                     : StripEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StripEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [StripEntry(date: now, snapshot: WidgetSnapshot.load())],
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct TelosStripView: View {
    let entry: StripEntry

    private var snap: WidgetSnapshot? { entry.snapshot }

    /// The published day's figures only count on that day; after midnight they read as empty.
    private var isToday: Bool {
        guard let updated = snap?.updated else { return false }
        return Calendar.current.isDate(updated, inSameDayAs: entry.date)
    }

    private var steps: Int? { isToday ? snap?.stepsToday : nil }
    private var effort: Int? { isToday ? snap?.effortToday : nil }
    private var stress: Double? { snap?.stressForStrip(now: entry.date) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            stepsColumn
                .frame(maxWidth: .infinity)
            effortRing
                .frame(width: 50, height: 50)
            stressColumn
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Steps

    private var stepsColumn: some View {
        VStack(spacing: 1) {
            Image(systemName: "figure.walk")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(steps.map(Self.compact) ?? "–")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .widgetAccentable()
            Text("steps")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(steps ?? 0) steps today"))
    }

    /// 8420 → "8.4k", 12 900 → "12.9k", 950 → "950".
    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: - Effort

    private var effortRing: some View {
        let fraction = min(1, max(0, Double(effort ?? 0) / 100))
        let target = snap?.effortTarget.map { min(1, max(0, Double($0) / 100)) }
        return ZStack {
            Circle()
                .stroke(.secondary.opacity(0.35), lineWidth: 5)
            // Clockwise from twelve: trim runs from 3 o'clock, so the whole ring is turned back a quarter.
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            if let target {
                // The recommended effort: a notch across the track at its angle.
                Capsule()
                    .fill(.primary)
                    .frame(width: 2.5, height: 9)
                    .offset(y: -22.5)
                    .rotationEffect(.degrees(target * 360))
            }
            Text(isToday ? (snap?.effortTodayDisplay ?? effort.map(String.init) ?? "–") : "–")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort \(snap?.effortTodayDisplay ?? "none")"
                                 + (snap?.effortTarget != nil ? ", target marked" : "")))
    }

    // MARK: - Stress

    private var stressColumn: some View {
        VStack(spacing: 3) {
            Text(stress.map { String(format: "%.1f", $0) } ?? "–")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .widgetAccentable()
            // The 0–3 scale with the reading marked on it: the system's own lock-screen gauge, which
            // draws the track and the marker in the wallpaper's own vibrancy.
            Gauge(value: min(3, max(0, stress ?? 0)), in: 0...3) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinear)
            .opacity(stress == nil ? 0.35 : 1)
            Text("stress")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stress.map { String(format: "Stress %.1f of 3", $0) } ?? "Stress unavailable"))
    }
}

struct TelosStripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TelosStripWidget", provider: StripProvider()) { entry in
            TelosStripView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Steps · Effort · Stress")
        .description("Today's steps, effort against its target, and stress right now.")
        .supportedFamilies([.accessoryRectangular])
    }
}
