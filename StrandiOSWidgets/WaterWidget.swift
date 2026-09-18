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

    /// The water itself, rising from the bottom of the tile to the day's fraction of its goal.
    var background: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                StrandPalette.surfaceBase
                LinearGradient(colors: [water.opacity(0.45), water.opacity(0.18)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: geo.size.height * (enabled ? fraction : 0))
            }
        }
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
