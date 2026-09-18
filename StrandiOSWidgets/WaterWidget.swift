import WidgetKit
import SwiftUI
import AppIntents
import StrandDesign

// WaterWidget.swift — the day's water on the Home Screen, with + and − that work without the app.
//
// The level of water behind the figure IS the progress: it rises from the bottom of the tile as the day
// fills towards its goal. The buttons run `AddWaterIntent` / `RemoveWaterIntent` in the widget's own
// process, which queue the change for the app (see `WaterWidgetStore`) and redraw at once.

struct WaterEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct WaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaterEntry {
        var snap = WidgetSnapshot.placeholder
        snap.waterEnabled = true
        snap.waterDay = WidgetSnapshot.dayKey()
        snap.waterMl = 1250
        snap.waterGoalMl = 2800
        return WaterEntry(date: Date(), snapshot: snap)
    }

    func getSnapshot(in context: Context, completion: @escaping (WaterEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context)
                                     : WaterEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntry>) -> Void) {
        // Midnight is the one moment the tile must change on its own: the day's glass empties.
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        let next = min(midnight, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: [WaterEntry(date: now, snapshot: WidgetSnapshot.load())],
                            policy: .after(next)))
    }
}

struct WaterWidgetView: View {
    let entry: WaterEntry

    private var enabled: Bool { entry.snapshot?.waterEnabled ?? false }
    private var ml: Int { WaterWidgetStore.shownMl(snapshot: entry.snapshot, now: entry.date) }
    private var goal: Int { max(1, entry.snapshot?.waterGoalMl ?? 2500) }
    private var fraction: Double { min(1, Double(ml) / Double(goal)) }

    private var water: Color { Color(.sRGB, red: 0.30, green: 0.71, blue: 0.96, opacity: 1) }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(water)
                Text("Water")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            if enabled {
                Text(litres(ml))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("of \(litres(goal))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button(intent: RemoveWaterIntent()) {
                        glassButton("minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(ml <= 0)
                    .opacity(ml <= 0 ? 0.4 : 1)
                    Button(intent: AddWaterIntent()) {
                        glassButton("plus")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Turn on water tracking in Telos to log from here.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func glassButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(water.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(water.opacity(0.6), lineWidth: 1))
    }

    private func litres(_ value: Int) -> String {
        String(format: "%.2f L", Double(value) / 1000)
    }

    /// The water itself — the Today tile's own: three sheets, lit at the surface and dark at the floor,
    /// the dashed quarter rules behind them and the glint along the waterline. Still rather than moving:
    /// a widget is a picture, so it is posed at one moment of the tile's swell.
    var background: some View {
        let level = enabled ? fraction : 0
        return ZStack {
            StrandPalette.surfaceRaised
            WaterRules()
                .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            WaterSheet(fraction: level, depth: 6, offset: 1.7, wobble: 0.6)
                .fill(LinearGradient(colors: [bright.opacity(0.44), deep.opacity(0.38)],
                                     startPoint: .top, endPoint: .bottom))
            WaterSheet(fraction: level, depth: 3, offset: 0.6, wobble: 0.8)
                .fill(LinearGradient(colors: [bright.opacity(0.60), deep.opacity(0.52)],
                                     startPoint: .top, endPoint: .bottom))
            WaterSheet(fraction: level, depth: 0, offset: 0, wobble: 1.0)
                .fill(LinearGradient(colors: [bright.opacity(0.83), deep.opacity(0.72)],
                                     startPoint: .top, endPoint: .bottom))
            if level > 0.02 {
                WaterSheet(fraction: level, depth: 0, offset: 0, wobble: 1.0, surfaceOnly: true)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.2)
            }
        }
    }

    private var deep: Color { Color(.sRGB, red: 0.06, green: 0.36, blue: 0.62, opacity: 1) }
    private var bright: Color { Color(.sRGB, red: 0.30, green: 0.71, blue: 0.96, opacity: 1) }
}

/// The dashed rules at a quarter, half and three quarters — a scale to judge the level against.
private struct WaterRules: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for share in [0.25, 0.5, 0.75] {
            let y = rect.height * (1 - share)
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return p
    }
}

/// One sheet of water up to `fraction` of the tile, its surface the Today tile's three-sine swell.
private struct WaterSheet: Shape {
    let fraction: Double
    let depth: Double
    let offset: Double
    let wobble: Double
    var surfaceOnly = false

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        let surfaceY = rect.height * (1 - clamped)
        let amplitude = rect.height * 0.03
        let steps = 48
        var p = Path()
        for i in 0...steps {
            let x = rect.width * Double(i) / Double(steps)
            let phase = x / rect.width * .pi * 2
            let y = surfaceY + depth
                + amplitude * wobble * sin(phase + offset)
                + amplitude * wobble * 0.5 * sin(phase * 2.3)
                + amplitude * wobble * 0.25 * sin(phase * 3.7 + offset)
            if i == 0 {
                if surfaceOnly { p.move(to: CGPoint(x: x, y: y)) } else {
                    p.move(to: CGPoint(x: 0, y: rect.height))
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            } else {
                p.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if !surfaceOnly {
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.closeSubpath()
        }
        return p
    }
}

struct WaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WaterWidgetStore.widgetKind, provider: WaterProvider()) { entry in
            let view = WaterWidgetView(entry: entry)
            view.containerBackground(for: .widget) { view.background }
        }
        .configurationDisplayName("Water")
        .description("Today's water against your goal, with a glass in or out at a tap.")
        .supportedFamilies([.systemSmall])
    }
}
