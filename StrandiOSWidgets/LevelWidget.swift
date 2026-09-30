import WidgetKit
import SwiftUI
import StrandDesign

// LevelWidget.swift — the level on the Home Screen, and which way it went.
//
// ONE NUMBER AND ONE COMPARISON, in the smallest square iOS offers. The level sits inside a thin luminous
// `TelosRing`; above it the arrow and the signed points against the day before; under it one line saying
// what the number is.
//
// THE LEVEL IS UNBOUNDED (DESIGN_V2 coordinator decision 9). The ring's `scale: 100` is ONE LAP — the
// wearer's own 95th percentile — not a maximum: 134 draws a full first lap plus a second one to 34 %, and
// the centre prints 134. Nothing here clamps, saturates or calls 100 "max". (The old circular `Gauge`
// clamped at 100; it is gone for exactly that reason.)
//
// IT NEVER SCORES ANYTHING. Every figure here was written to `LevelLedger` by the app, once, on the day it
// belongs to, and published into the App Group by `LevelBarModel.publish` — the same resolution the strip's
// radar shows. The widget's whole job is to draw what it was handed and to be honest about what it was not:
//
//   · NOTHING PUBLISHED YET — a fresh install. "—" and "open Telos to score". NOT "not scored yet": the app
//     may well have a level and simply not have run since this tile was added. (The water tile got exactly
//     this wrong in the other direction, reading a fresh install as a setting the wearer had switched off.)
//   · NO LEVEL — the app published and had none: too little of the formula had data behind it, so the day
//     settled as a gap (`LevelEngine.minCoverage`). "—" and "not scored yet". A level the app refuses to
//     show is never shown here either, and nothing is imputed to fill the space. The ring is the dashed
//     bare track, never a zero arc.
//   · A LEVEL, BUT NO DAY BEFORE IT — the first scored day, or a gap behind it. The arrow and the points are
//     ABSENT, not "+0": a zero would claim a comparison that was never made.
//   · A PARTIAL LEVEL — part of the formula had no data, or the day was written at its deadline with the
//     night only half in. The figure and its ring dim to 0.55, carry a dot, and — when the published
//     coverage says how much was measured — a "NN% measured" line, so it cannot read like a whole
//     measurement.
//   · A DAY THAT IS NOT TODAY — the level day's own entry has not landed (its night is still syncing), or
//     this morning's flow has not run. Each figure carries the day it is FOR, the caption names that day
//     ("yesterday's level", "3 days ago"), and the ring draws in its CARRIED state (arc at half
//     opacity), so a stale snapshot can never render as today.
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
    /// How much of the formula the level rested on, 0–1, exactly as published (`levelCoverage`). Read
    /// only to SAY it ("83% measured"); the partial decision itself stays in `levelRender`.
    var coverage: Double? = nil
}

struct LevelProvider: TimelineProvider {
    func placeholder(in context: Context) -> LevelEntry {
        LevelEntry(date: Date(),
                   render: .level(.init(value: 72, day: WidgetSnapshot.dayKey(), delta: 3,
                                        partial: false, daysBehind: 0)))
    }

    private func entry(at date: Date) -> LevelEntry {
        let snapshot = WidgetSnapshot.load()
        return LevelEntry(date: date,
                          render: WidgetSnapshot.levelRender(snapshot: snapshot, now: date),
                          coverage: snapshot?.levelCoverage)
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

    /// "83% measured" — only for a level that IS shown and rests on less than the whole formula. Rounded
    /// DOWN, so 99.95 % can never print "100% measured" beside the partial dot.
    private var measuredText: String? {
        guard level != nil, let coverage = entry.coverage, coverage.isFinite,
              coverage < WidgetSnapshot.levelFullCoverage else { return nil }
        let percent = Int((max(0, coverage) * 100).rounded(.down))
        return "\(percent)% measured"
    }

    /// The pending-day dim (DESIGN_V2 §6.13): a partial level draws at 0.55.
    private var partialOpacity: Double { level?.partial == true ? 0.55 : 1 }

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
            TelosWidgetGround()
        }
    }

    // MARK: - systemSmall

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("LEVEL")
                    .font(TelosType.scaleFixed)
                    .tracking(TelosType.Tracking.scale)
                    .foregroundStyle(TelosColor.textSecondary)
                if level?.partial == true {
                    // THE COVERAGE CAVEAT, compactly: one dot beside the label and a dimmed figure below.
                    // The number is still the honest arithmetic — an absent part's weight went to the
                    // parts that had data — but it rests on less of the formula than a full one, and
                    // without this it drew identically to one that rested on all of it.
                    Circle()
                        .fill(TelosColor.warning)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                if let deltaText {
                    HStack(spacing: 2) {
                        Image(systemName: arrowSymbol)
                            .font(.system(size: 11, weight: .bold))
                        Text(deltaText)
                            .font(TelosType.numeralFont(size: 13, weight: .medium))
                    }
                    .foregroundStyle(deltaTint)
                    .lineLimit(1)
                }
            }
            GeometryReader { geo in
                let d = max(40, min(geo.size.width, geo.size.height, 92))
                levelRing(diameter: d, numeralSize: d * 0.34)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
                if let measuredText {
                    Text(measuredText)
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The level inside its ring. `TelosRing(scale: 100)` draws laps past 100 — never a clamp — and the
    /// centre is the real, unclamped figure. Past `TelosRingMath.maxDrawnLaps` the rings stay full and a
    /// "3.2×" line states the rest, because the centre here is the widget's own (the ring's built-in
    /// numeral is sized for in-app rings, too small for a tile's one number).
    ///
    /// Cost: `TelosRing`'s shapes (track, halo, arc per lap, tip), `animatesChanges: false`. No blur.
    private func levelRing(diameter: CGFloat, numeralSize: CGFloat) -> some View {
        let value = level.map { Double($0.value) }
        let laps = TelosRingMath.laps(value: value, scale: 100)
        return ZStack {
            TelosRing(value: value, scale: 100, color: TelosColor.mint, diameter: diameter,
                      isCarried: level.map { !$0.isToday } ?? false,
                      showsValue: false, animatesChanges: false)
            VStack(spacing: 0) {
                Text(level.map { "\($0.value)" } ?? TelosType.absent)
                    .font(TelosType.numeralFont(size: numeralSize, weight: .light))
                    .tracking(TelosType.Tracking.numeralL)
                    .foregroundStyle(numberTint)
                    .lineLimit(1)
                    .minimumScaleFactor(max(0.3, TelosType.minimumSize / numeralSize))
                if let laps, TelosRingMath.exceedsDrawnLaps(laps) {
                    Text(verbatim: laps.formatted(.number.precision(.fractionLength(1))) + "\u{00D7}")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.mint)
                }
            }
            .padding(.horizontal, TelosRingMath.defaultLineWidth(diameter: diameter) * 2.5)
        }
        .frame(width: diameter, height: diameter)
        .opacity(partialOpacity)
    }

    private var numberTint: Color {
        guard let level else { return TelosColor.textTertiary }
        return level.partial ? TelosColor.textSecondary : TelosColor.textPrimary
    }

    /// The same three tints the in-app delta chips use, so the arrow means the same thing in both places.
    /// The arrow's direction carries the meaning too, so it never rests on colour alone.
    private var deltaTint: Color {
        guard let delta = level?.delta, delta != 0 else { return TelosColor.textTertiary }
        return delta > 0 ? TelosColor.positive : TelosColor.critical
    }

    private var arrowSymbol: String {
        guard let delta = level?.delta else { return "minus" }
        if delta > 0 { return "arrow.up" }
        if delta < 0 { return "arrow.down" }
        return "arrow.right"
    }

    // MARK: - accessoryCircular
    //
    // The same figure inside the same unbounded ring, the arrow under it. NO TINT — the lock screen
    // desaturates this family, so the ring is drawn in `.primary` and made accentable; the partial case is
    // said with secondary weight instead of a hue.

    private var circular: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                AccessoryWidgetBackground()
                // Cost: TelosRing's shapes only; no animation.
                TelosRing(value: level.map { Double($0.value) }, scale: 100, color: Color.primary,
                          diameter: d, showsValue: false, animatesChanges: false)
                    .widgetAccentable()
                VStack(spacing: 0) {
                    Text(level.map { "\($0.value)" } ?? TelosType.absent)
                        .font(TelosType.numeralFont(size: 20, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(level?.partial == true
                                         ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    Image(systemName: arrowSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                }
                .padding(.horizontal, TelosRingMath.defaultLineWidth(diameter: d) * 2.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
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
