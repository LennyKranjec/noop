import WidgetKit
import SwiftUI
import StrandDesign

// TelosStripWidget.swift — the day under the clock: steps, effort against its target, stress now.
//
// A LOCK-SCREEN RECTANGLE, read like an instrument: three readings side by side, each a big number over
// a fine gauge, with a small tracked caption on one shared baseline.
//   · left, today's steps, over a row of ten cells — a thousand steps a cell toward the 10 000 goal;
//   · centre, today's effort inside a ring of hairline ticks that light clockwise from twelve o'clock,
//     with a caret where the day's recommended effort tops out — "how much" and "how much is enough"
//     in one glance;
//   · right, stress on its 0–3 scale: three segments, the one it sits in lit, a caret at the reading.
//
// THE FIGURES ARE TODAY'S OWN. The Today screen publishes exactly what it displays; the background
// publisher fills in when it has not. Each figure carries the day it was read for, and that — not the
// snapshot's `updated` — decides whether it is shown under today's clock.
//
// LIVE AS FAR AS A WIDGET CAN BE. iOS draws a widget from a timeline, not a stream, so this redraws when
// the app publishes and at least every fifteen minutes on its own.
//
// LOCK-SCREEN COLOUR IS NOT COLOUR. The system renders this family vibrant and flattens any hue into the
// wallpaper, so hierarchy is carried by primary / secondary / opacity and by the accentable marks alone.

struct StripEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StripProvider: TimelineProvider {
    func placeholder(in context: Context) -> StripEntry {
        let now = Date()
        var snap = WidgetSnapshot.placeholder
        snap.stepsToday = 8_420
        snap.stepsDay = WidgetSnapshot.dayKey(now)
        snap.effortToday = 46
        snap.effortTodayDisplay = "46"
        snap.effortTarget = 67
        snap.effortDay = WidgetSnapshot.dayKey(now)
        snap.stressNow = 1.3
        snap.stressNowAt = now
        return StripEntry(date: now, snapshot: snap)
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

    @Environment(\.widgetFamily) private var family

    private var snap: WidgetSnapshot? { entry.snapshot }

    // Each figure is judged by its OWN day stamp, so a live or water publish that moved `updated` can
    // neither vouch for a stale figure nor blank a fresh one.
    private var steps: Int? { snap?.stripSteps(now: entry.date) }
    private var effortIsCurrent: Bool { snap?.stripEffortIsCurrent(now: entry.date) ?? false }
    private var effort: Int? { effortIsCurrent ? snap?.effortToday : nil }
    private var effortText: String? {
        guard effortIsCurrent else { return nil }
        return snap?.effortTodayDisplay ?? effort.map(String.init)
    }
    private var target: Int? { effortIsCurrent ? snap?.effortTarget : nil }
    private var stress: Double? { snap?.stressForStrip(now: entry.date) }

    private var stepsText: String? { steps.map(Self.compact) }
    private var stressText: String? { stress.map { String(format: "%.1f", $0) } }

    var body: some View {
        Group {
            if family == .accessoryInline {
                // Minimal, as the inline slot wants: "8.4k · 9.8 · 1.2".
                Text("\(stepsText ?? "–") · \(effortText ?? "–") · \(stressText ?? "–")")
                    .monospacedDigit()
            } else {
                rectangular
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        let s = steps.map { "\($0) steps" } ?? "Steps unavailable"
        let e = effortText.map { "effort \($0)" + (target != nil ? ", target marked" : "") } ?? "effort unavailable"
        let st = stress.map { String(format: "stress %.1f of 3", $0) } ?? "stress unavailable"
        return "\(s), \(e), \(st)"
    }

    // MARK: - Layout

    /// Instrument area height: the ring's diameter, and the box the side columns centre their number
    /// and gauge in, so all three captions sit on one baseline beneath.
    private static let instrument: CGFloat = 46

    private var rectangular: some View {
        HStack(alignment: .top, spacing: 4) {
            column(caption: "STEPS") {
                VStack(spacing: 6) {
                    number(stepsText)
                    StepCells(steps: steps, goal: WidgetSnapshot.stepsGoal)
                }
            }
            column(caption: "LOAD") {
                EffortTicks(effort: effort, target: target, text: effortText)
                    .frame(width: Self.instrument, height: Self.instrument)
            }
            column(caption: "STRESS") {
                VStack(spacing: 6) {
                    number(stressText)
                    StressScale(level: stress)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column<Content: View>(caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 3) {
            content()
                .frame(height: Self.instrument)
            Text(caption)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ text: String?) -> some View {
        Text(text ?? "–")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(text == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
    }

    /// 950 → "950", 8420 → "8.4k", 8000 → "8k", 12 900 → "12.9k", 123 400 → "123k".
    static func compact(_ n: Int) -> String {
        guard n >= 1000 else { return "\(max(0, n))" }
        let k = Double(n) / 1000
        if n >= 100_000 { return "\(Int(k.rounded()))k" }
        var s = String(format: "%.1f", k)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s + "k"
    }
}

// MARK: - Steps: ten cells toward the goal

private struct StepCells: View {
    let steps: Int?
    let goal: Int

    private static let cells = 10

    private var lit: Int {
        guard let steps, goal > 0 else { return 0 }
        return min(Self.cells, steps * Self.cells / goal)
    }

    var body: some View {
        HStack(spacing: 1.6) {
            ForEach(0..<Self.cells, id: \.self) { i in
                if i < lit {
                    Circle().fill(.primary).frame(width: 3, height: 3).widgetAccentable()
                } else {
                    Circle().fill(.secondary).opacity(0.35).frame(width: 3, height: 3)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Effort: a ring of hairline ticks, a caret at the target

private struct EffortTicks: View {
    let effort: Int?
    let target: Int?
    let text: String?

    private static let ticks = 36
    private static let tickLength: CGFloat = 4
    /// The ticks' outer edge, inside the frame's radius to leave the caret room outside them.
    private static let tickOuter: CGFloat = 20

    private var fraction: Double { min(1, max(0, Double(effort ?? 0) / 100)) }

    var body: some View {
        ZStack {
            // Unlit track, then the lit arc on its own layer so only the lit ticks take the accent.
            ForEach(0..<Self.ticks, id: \.self) { i in
                if !isLit(i) { tick(i).opacity(0.3) }
            }
            ZStack {
                ForEach(0..<Self.ticks, id: \.self) { i in
                    if isLit(i) { tick(i) }
                }
                if let target {
                    // The recommended effort: a caret just outside the ring, pointing in at its angle.
                    Caret()
                        .fill(.primary)
                        .frame(width: 5, height: 3.5)
                        .offset(y: -(Self.tickOuter + 1.75 + 0.5))
                        .rotationEffect(.degrees(min(1, max(0, Double(target) / 100)) * 360))
                }
            }
            .widgetAccentable()
            Text(text ?? "–")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(text == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .frame(width: 28)
        }
    }

    /// A tick is lit when the arc has passed its middle — clockwise from twelve o'clock.
    private func isLit(_ i: Int) -> Bool {
        effort != nil && (Double(i) + 0.5) / Double(Self.ticks) <= fraction
    }

    private func tick(_ i: Int) -> some View {
        Capsule()
            .fill(.primary)
            .frame(width: 1.4, height: Self.tickLength)
            .offset(y: -(Self.tickOuter - Self.tickLength / 2))
            .rotationEffect(.degrees(Double(i) / Double(Self.ticks) * 360))
    }
}

/// A small triangle pointing DOWN (toward the ring's centre once offset above it and rotated).
private struct Caret: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Stress: the 0–3 scale, the segment it sits in lit, a caret at the reading

private struct StressScale: View {
    let level: Double?

    private static let segment: CGFloat = 13
    private static let gap: CGFloat = 2
    private static var width: CGFloat { segment * 3 + gap * 2 }

    private var clamped: Double? { level.map { min(3, max(0, $0)) } }
    /// The segment the reading falls in (a reading of exactly 3 belongs to the top one).
    private var litSegment: Int? { clamped.map { min(2, Int($0)) } }

    var body: some View {
        VStack(spacing: 1) {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: Self.width, height: 3.5)
                if let clamped {
                    Caret()
                        .fill(.primary)
                        .frame(width: 5, height: 3.5)
                        .offset(x: CGFloat(clamped / 3) * Self.width - 2.5)
                        .widgetAccentable()
                }
            }
            HStack(spacing: Self.gap) {
                ForEach(0..<3, id: \.self) { i in
                    if i == litSegment {
                        Capsule().fill(.primary).frame(width: Self.segment, height: 2).widgetAccentable()
                    } else {
                        Capsule().fill(.secondary).opacity(0.35).frame(width: Self.segment, height: 2)
                    }
                }
            }
        }
    }
}

struct TelosStripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.stripWidgetKind, provider: StripProvider()) { entry in
            TelosStripView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Steps · Effort · Stress")
        .description("Today's steps, effort against its target, and stress right now.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}
