import WidgetKit
import SwiftUI
import StrandDesign

// LevelWidget.swift — the level on the Home Screen, and which way it went.
//
// ONE NUMBER AND ONE COMPARISON, in the smallest square iOS offers. The level fills the tile; under it an
// arrow and the signed points against the day before; under that one line saying what the number is.
//
// IT NEVER SCORES ANYTHING. Every figure here was written to `LevelLedger` by the app, once, on the day it
// belongs to, and published into the App Group by `LevelBarModel.publish` — the same resolution the strip's
// radar shows. The widget's whole job is to draw what it was handed and to be honest about what it was not:
//
//   · NOTHING PUBLISHED YET — a fresh install. "–" and "open Telos to score". NOT "not scored yet": the app
//     may well have a level and simply not have run since this tile was added. (The water tile got exactly
//     this wrong in the other direction, reading a fresh install as a setting the wearer had switched off.)
//   · NO LEVEL — the app published and had none: too little of the formula had data behind it, so the day
//     settled as a gap (`LevelEngine.minCoverage`). "–" and "not scored yet". A level the app refuses to
//     show is never shown here either, and nothing is imputed to fill the space.
//   · A LEVEL, BUT NO DAY BEFORE IT — the first scored day, or a gap behind it. The arrow and the points are
//     ABSENT, not "+0": a zero would claim a comparison that was never made.
//   · A PARTIAL LEVEL — part of the formula had no data, or the day was written at its deadline with the
//     night only half in. The figure is dimmed and carries a dot, so it cannot read like a whole measurement.
//   · A DAY THAT IS NOT TODAY — the level day's own entry has not landed (its night is still syncing), or
//     this morning's flow has not run. Each figure carries the day it is FOR, and the caption names that day
//     ("yesterday's level", "3 days ago"), so a stale snapshot can never render as today.
//
// REFRESH. iOS draws a widget from a timeline, not a stream: this redraws whenever the app publishes a level
// that moved, on its own every twenty minutes, and at the next local midnight — the one moment the tile
// changes by itself, because a level that was today's becomes yesterday's. There is deliberately no button:
// a tap-to-refresh AppIntent on a tile showing one frozen daily number would promise a recomputation that
// cannot happen (a past level is a fact, not a formula). To force it, open the app.

struct LevelEntry: TimelineEntry {
    let date: Date
    /// Resolved in the PROVIDER, where the App Group is read once per entry, rather than in the view body,
    /// which SwiftUI may evaluate many times.
    let render: WidgetSnapshot.LevelRender
}

struct LevelProvider: TimelineProvider {
    func placeholder(in context: Context) -> LevelEntry {
        LevelEntry(date: Date(),
                   render: .level(.init(value: 72, day: WidgetSnapshot.dayKey(), delta: 3,
                                        partial: false, daysBehind: 0)))
    }

    private func entry(at date: Date) -> LevelEntry {
        LevelEntry(date: date,
                   render: WidgetSnapshot.levelRender(snapshot: WidgetSnapshot.load(), now: date))
    }

    func getSnapshot(in context: Context, completion: @escaping (LevelEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LevelEntry>) -> Void) {
        let now = Date()
        // Midnight, because the caption's claim about the day expires there: today's level becomes
        // yesterday's without anything being published.
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(1_200)
        let next = min(midnight, now.addingTimeInterval(20 * 60))
        completion(Timeline(entries: [entry(at: now)], policy: .after(next)))
    }
}

struct LevelWidgetView: View {
    let entry: LevelEntry

    @Environment(\.widgetFamily) private var family

    private var render: WidgetSnapshot.LevelRender { entry.render }

    private var level: WidgetSnapshot.LevelRender.Level? {
        if case .level(let l) = render { return l }
        return nil
    }

    private var deltaText: String? { WidgetSnapshot.levelDeltaText(level?.delta) }
    private var caption: String { WidgetSnapshot.levelCaption(render) }

    var body: some View {
        Group {
            if family == .accessoryCircular {
                circular
            } else {
                small
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var background: some View {
        // The accessory families are rendered vibrant by the system, which flattens any fill into the
        // wallpaper: they get nothing, and hierarchy comes from primary / secondary alone.
        if family == .accessoryCircular {
            Color.clear
        } else {
            StrandPalette.surfaceRaised
        }
    }

    // MARK: - systemSmall

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("LEVEL")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textSecondary)
                if level?.partial == true {
                    // THE COVERAGE CAVEAT, compactly: one dot beside the label and a dimmed figure below.
                    // The number is still the honest arithmetic — an absent part's weight went to the
                    // parts that had data — but it rests on less of the formula than a full one, and
                    // without this it drew identically to one that rested on all of it.
                    Circle()
                        .fill(StrandPalette.statusWarning)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(level.map { "\($0.value)" } ?? "–")
                .font(.system(size: 54, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(numberTint)
            if let deltaText {
                HStack(spacing: 3) {
                    Image(systemName: arrowSymbol)
                        .font(.system(size: 11, weight: .bold))
                    Text(deltaText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(deltaTint)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var numberTint: Color {
        guard let level else { return StrandPalette.textTertiary }
        return level.partial ? StrandPalette.textSecondary : StrandPalette.textPrimary
    }

    /// The same three tints the in-app delta chips use, so the arrow means the same thing in both places.
    private var deltaTint: Color {
        guard let delta = level?.delta, delta != 0 else { return StrandPalette.textTertiary }
        return delta > 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
    }

    private var arrowSymbol: String {
        guard let delta = level?.delta else { return "minus" }
        if delta > 0 { return "arrow.up" }
        if delta < 0 { return "arrow.down" }
        return "arrow.right"
    }

    // MARK: - accessoryCircular
    //
    // Nearly free, so it is here: the same figure in the gauge, the arrow as its bottom label. NO TINT —
    // the lock screen desaturates this family, so a hue would carry no meaning and the partial case is
    // said with secondary weight instead.

    private var circular: some View {
        Gauge(value: Double(min(max(level?.value ?? 0, 0), 100)), in: 0...100) {
            Image(systemName: arrowSymbol)
        } currentValueLabel: {
            Text(level.map { "\($0.value)" } ?? "–")
                .minimumScaleFactor(0.6)
                .foregroundStyle(level?.partial == true
                                 ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
        }
        .gaugeStyle(.accessoryCircular)
    }

    // MARK: - Spoken

    private var accessibilityText: String {
        guard let level else {
            switch render {
            case .unknown: return "Level unavailable. Open Telos to score today."
            default: return "Level not scored yet."
            }
        }
        var out = "Level \(level.value)"
        switch level.daysBehind {
        case 0: out += " today"
        case 1: out += " for yesterday"
        case .some(let n): out += " for \(n) days ago"
        case .none: out += " for the last scored day"
        }
        if let delta = level.delta {
            if delta == 0 {
                out += ", unchanged from the day before"
            } else {
                out += ", \(delta > 0 ? "up" : "down") \(abs(delta)) from the day before"
            }
        } else {
            out += ", no day before it to compare"
        }
        if level.partial { out += ". Built without part of the formula." }
        return out
    }
}

struct LevelWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.levelWidgetKind, provider: LevelProvider()) { entry in
            LevelWidgetView(entry: entry)
        }
        .configurationDisplayName("Level")
        .description("Today's level, with the arrow and the points against yesterday.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
