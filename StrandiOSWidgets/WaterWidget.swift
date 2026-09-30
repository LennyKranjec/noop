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
    /// Whether tracking is on, off, or NOT KNOWN YET — resolved in the provider, where the App Group is
    /// read once per entry, rather than in the view body, which SwiftUI may evaluate many times.
    let tracking: WidgetSnapshot.WaterTracking
}

struct WaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaterEntry {
        var snap = WidgetSnapshot.placeholder
        snap.waterEnabled = true
        snap.waterDay = WidgetSnapshot.dayKey()
        snap.waterMl = 1250
        snap.waterGoalMl = 2800
        return WaterEntry(date: Date(), snapshot: snap, tracking: .on)
    }

    /// One read of the App Group per entry: the snapshot and the mirrored opt-in.
    private func entry(at date: Date) -> WaterEntry {
        let snapshot = WidgetSnapshot.load()
        return WaterEntry(date: date, snapshot: snapshot,
                          tracking: WidgetSnapshot.waterTracking(snapshot: snapshot))
    }

    func getSnapshot(in context: Context, completion: @escaping (WaterEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntry>) -> Void) {
        // Midnight is the one moment the tile must change on its own: the day's glass empties.
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        let next = min(midnight, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: [entry(at: now)], policy: .after(next)))
    }
}

struct WaterWidgetView: View {
    let entry: WaterEntry

    /// ON, OFF, or NOT KNOWN YET. It used to be `entry.snapshot?.waterEnabled ?? false`, which read a
    /// fresh install — where nothing has published into the App Group at all — as the wearer having
    /// turned the setting off, and told them to go and switch on something already on.
    private var tracking: WidgetSnapshot.WaterTracking { entry.tracking }
    private var enabled: Bool { tracking == .on }
    private var ml: Int { WaterWidgetStore.shownMl(snapshot: entry.snapshot, now: entry.date) }
    private var goal: Int { max(1, entry.snapshot?.waterGoalMl ?? 2500) }
    private var fraction: Double { min(1, Double(ml) / Double(goal)) }

    /// Water's hue: the Telos luminous `teal` (the reference palette's cyan). A token, so light mode gets
    /// its deepened pair and every sheet below derives from this one colour.
    private var water: Color { TelosColor.teal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(water)
                Text("Water")
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
            }
            Spacer(minLength: 0)
            if enabled {
                Text(litres(ml))
                    .font(TelosType.numeralM)
                    .tracking(TelosType.Tracking.numeralM)
                    .foregroundStyle(TelosColor.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    // The one motion here: the figure rolls when a + / − tap changes it (motion encodes a
                    // value change, §7.1). Cost: a system text transition between two timeline renders;
                    // zero while idle.
                    .contentTransition(.numericText())
                Text("of \(litres(goal))")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
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
                Text(WaterWidgetView.message(for: tracking))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// What the tile says when it cannot show a figure. Two DIFFERENT sentences, because they are two
    /// different situations and only one of them is the wearer's to fix: `off` is a setting to turn on,
    /// `unknown` is an app that has not yet written anything here (a fresh install, or one just updated)
    /// and simply needs opening once. `.on` never reaches this.
    static func message(for tracking: WidgetSnapshot.WaterTracking) -> String {
        switch tracking {
        case .off: return "Turn on water tracking in Telos to log from here."
        case .on, .unknown: return "Open Telos once to sync today's water."
        }
    }

    /// Faux glass (DESIGN_V2 "Tiles"): the translucent `glassFill` plus a teal hairline — NOT a material.
    /// Cost: one capsule fill + one 1 pt stroke.
    private func glassButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(TelosType.glyphControl)
            .foregroundStyle(TelosColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(TelosColor.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(water.opacity(0.6), lineWidth: 1))
    }

    private func litres(_ value: Int) -> String {
        String(format: "%.2f L", Double(value) / 1000)
    }

    /// The water itself — the Today tile's own: three sheets, lit at the surface and dark at the floor,
    /// the dashed quarter rules behind them and the glint along the waterline. Still rather than moving:
    /// a widget is a picture, so it is posed at one moment of the tile's swell.
    ///
    /// Telos: the water is bioluminescent rather than opaque — translucent teal sheets on the Telos ground,
    /// lit at the surface and fading to the floor, with a luminous teal waterline. Kept translucent so the
    /// figure above stays legible over it (the old 83 % blue sheet sat under white text).
    /// Cost: the ground's two gradients + one dashed stroke + three gradient-filled 48-segment paths + one
    /// stroke, all static; no blur, no material, no animation.
    var background: some View {
        let level = enabled ? fraction : 0
        return ZStack {
            TelosWidgetGround()
            WaterRules()
                .stroke(TelosColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            WaterSheet(fraction: level, depth: 6, offset: 1.7, wobble: 0.6)
                .fill(LinearGradient(colors: [water.opacity(0.12), water.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
            WaterSheet(fraction: level, depth: 3, offset: 0.6, wobble: 0.8)
                .fill(LinearGradient(colors: [water.opacity(0.18), water.opacity(0.07)],
                                     startPoint: .top, endPoint: .bottom))
            WaterSheet(fraction: level, depth: 0, offset: 0, wobble: 1.0)
                .fill(LinearGradient(colors: [water.opacity(0.26), water.opacity(0.10)],
                                     startPoint: .top, endPoint: .bottom))
            if level > 0.02 {
                // The luminous waterline. Cost: one 1.2 pt stroke.
                WaterSheet(fraction: level, depth: 0, offset: 0, wobble: 1.0, surfaceOnly: true)
                    .stroke(water.opacity(0.9), lineWidth: 1.2)
            }
        }
    }
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
