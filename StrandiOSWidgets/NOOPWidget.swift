import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        let fallback: WidgetSnapshot = context.isPreview ? .placeholder : .unavailable
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? fallback))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        // Gallery previews use `placeholder(in:)` / getSnapshot's preview branch. A real timeline
        // with no shared snapshot must show missing data honestly, never plausible sample numbers.
        let snap = WidgetSnapshot.load() ?? .unavailable
        // Refresh roughly every 15 minutes; the app also forces a reload when it publishes fresh data.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

/// The glanceable widget — the iOS analogue of the macOS menu-bar extra.
/// Home Screen families mirror Today's hero trio (Rest · Charge · Effort, the Telos 2.0 order) as thin
/// luminous `TelosRing`s. Lock Screen accessories are compact: a single line, a gauge, or the rectangular
/// glyph-over-value trio.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// `.fullColor` on the home screen and in the gallery; `.vibrant` or `.accented` on the lock screen,
    /// where the system desaturates any colour it is handed. The accessory cells check this rather than
    /// tinting unconditionally — see `accessoryScore`.
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            recoveryGauge
        case .accessoryInline:
            Text(inlineText)
                .monospacedDigit()
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            large
        case .systemMedium:
            medium
        default:
            // systemSmall (and any future compact family)
            small
        }
    }

    // MARK: - The trio (Telos metric identity: ring hue + text ink)

    /// One of the three hero scores, resolved once so every family draws the same figures.
    private struct Score {
        let label: String
        /// SF Symbol naming the metric where a word does not fit (the small tile, the lock screen).
        let symbol: String
        /// The centre read-out, already formatted; nil = absent ("—").
        let text: String?
        /// The ring's value on the stored 0–100 axis; nil = absent (dashed bare track, never a zero arc).
        let value: Double?
        let color: Color
        let ink: Color
        let accessibilityOutOf: Int
    }

    /// Effort centre/accessory text: pre-formatted #313 display when present, else whole-number 0–100.
    private var effortText: String? {
        snap.effortDisplay ?? snap.effort.map(String.init)
    }

    private var restScore: Score {
        Score(label: "Rest", symbol: "moon.fill",
              text: snap.rest.map(String.init), value: snap.rest.map { Double($0) },
              color: TelosColor.rest, ink: TelosColor.restInk, accessibilityOutOf: 100)
    }

    private var chargeScore: Score {
        Score(label: "Charge", symbol: "figure.mind.and.body",
              text: snap.recovery.map(String.init), value: snap.recovery.map { Double($0) },
              color: TelosColor.charge, ink: TelosColor.chargeInk, accessibilityOutOf: 100)
    }

    private var effortScore: Score {
        // The ring is always the stored 0–100 axis so WHOOP 0–21 and native 0–100 agree on arc length;
        // the centre prints the wearer's own scale.
        Score(label: "Effort", symbol: "figure.strengthtraining.traditional",
              text: effortText, value: snap.effort.map { Double($0) },
              color: TelosColor.effort, ink: TelosColor.effortInk,
              accessibilityOutOf: (snap.effortWhoop == true) ? 21 : 100)
    }

    /// Rest · Charge · Effort — the reference's order (DESIGN_V2 §6.13 and the Today hero).
    private var scores: [Score] { [restScore, chargeScore, effortScore] }

    /// "C 72 · E 41 · R 88" (DESIGN_V2 §6.13). Every slot is always present, so an absent figure reads
    /// "C —" rather than vanishing — the slot's letter says WHICH figure is missing.
    private var inlineText: String {
        let absent = TelosType.absent
        let c = snap.recovery.map(String.init) ?? absent
        let e = effortText ?? absent
        let r = snap.rest.map(String.init) ?? absent
        return "C \(c) · E \(e) · R \(r)"
    }

    // MARK: - Lock Screen accessories

    /// The Charge gauge. With NO Charge it does not draw a gauge at all: a `Gauge` has no absent state,
    /// and an empty arc at 0 would read as a scored zero. The absent tile is the system's accessory disc
    /// with the heart glyph over "—".
    @ViewBuilder
    private var recoveryGauge: some View {
        if let recovery = snap.recovery {
            Gauge(value: Double(recovery), in: 0...100) {
                Image(systemName: "heart.fill")
            } currentValueLabel: {
                Text("\(recovery)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(TelosColor.charge)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                    Text(verbatim: TelosType.absent)
                        .font(TelosType.numeralFont(size: 20, weight: .medium))
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Charge"))
            .accessibilityValue(Text("No data"))
        }
    }

    /// Lock-Screen rectangular accessory: Rest · Charge · Effort, same trio as the Home Screen rings.
    private var rectangular: some View {
        // The lock screen gives this family roughly 72pt of height for everything. A "NOOP" title spent
        // a whole row of that restating which widget the user chose to add, leaving the three scores —
        // the only reason to add it — squeezed underneath. The title is gone and the heart-rate line is
        // now conditional, so with no live HR the scores get the entire area.
        VStack(spacing: 2) {
            if let bpm = snap.bpm {
                Text("\(bpm) bpm")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(scores.indices, id: \.self) { i in
                    accessoryScore(scores[i])
                }
            }
        }
    }

    /// One score cell. On the LOCK SCREEN the domain tint is deliberately dropped; it survives only
    /// where the system actually renders full colour, which for this family means a gallery preview.
    ///
    /// Lock-screen widgets render in `.vibrant` (or `.accented`), where the system desaturates whatever
    /// colour it is given and maps it onto the wallpaper. A domain colour handed to it does not survive
    /// as that colour — it lands as an arbitrary grey whose luminance nobody chose, so Charge, Effort and
    /// Rest stopped being distinguishable AND stopped being legible. `.primary`/`.secondary` are the two
    /// levels the system is designed to map, so the value reads at full strength and the glyph above it
    /// recedes, which is the hierarchy the tint was there to express in the first place. The glyph —
    /// not the colour — names the metric, so nothing here relies on colour alone.
    ///
    /// The `.fullColor` branch is defensive rather than hot: this family renders `.vibrant` on the lock
    /// screen and in StandBy, so the tint realistically only reaches a gallery preview.
    private func accessoryScore(_ score: Score) -> some View {
        VStack(spacing: 1) {
            // Glyph over value, the shape the request asked for. A 9pt word under each number was
            // spending scarce height on text nobody needs twice — the icons carry the metric identity.
            Image(systemName: score.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(renderingMode == .fullColor
                                 ? AnyShapeStyle(TelosColor.textTertiary)
                                 : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            Text(score.text ?? TelosType.absent)
                // Medium, not the app's light numerals: vibrant lock-screen rendering thins strokes, and
                // a light 16 pt figure there stops being legible.
                .font(TelosType.numeralFont(size: 16, weight: .medium))
                .foregroundStyle(scoreStyle(hasValue: score.text != nil, tint: score.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        // An icon says nothing to VoiceOver, and the word it replaced was the only thing naming this
        // metric. Collapse the cell to one element that still speaks "Charge, 68 percent".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(score.label))
        // Plain literal, not String(localized:). This extension's sources are StrandiOSWidgets +
        // StrandiOSShared only — Strand/Resources/Localizable.xcstrings is NOT in the target, and
        // String(localized:) resolves against Bundle.main, which for an app extension is the extension's
        // own bundle. It would compile, look localized, and render English in every locale. Every other
        // string in this file is a bare literal for the same reason: the widget is not localized yet.
        .accessibilityValue(Text(score.text ?? "No data"))
    }

    private func scoreStyle(hasValue: Bool, tint: Color) -> AnyShapeStyle {
        // Spelled out rather than leaning on leading-dot inference through AnyShapeStyle's generic
        // init, which is the kind of expression that type-checks in a playground and not in a build.
        guard renderingMode == .fullColor else {
            return hasValue ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
        return hasValue ? AnyShapeStyle(tint) : AnyShapeStyle(TelosColor.textTertiary)
    }

    // MARK: - Home Screen: systemSmall

    /// Compact three-ring hero. The diameter is FITTED to the content width rather than fixed: three
    /// 44 pt rings (§6.13) do not fit the narrowest small tile (SE: ~116 pt inside the system content
    /// margins), so each ring takes a third of what is there, capped at 44. Under each ring the metric's
    /// glyph, because a tracked word at the 11 pt floor does not fit a 36 pt column.
    ///
    /// No extra padding: on iOS 17 `containerBackground` already applies the system content margins, and
    /// the old additional 10 pt pushed three fixed 40 pt rings wider than the tile.
    private var small: some View {
        VStack(spacing: 6) {
            headerRow
            GeometryReader { geo in
                let d = min(44, max(28, (geo.size.width - 8) / 3))
                scoreRings(diameter: d, showsLabels: false)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            vitalsFooter(compact: true)
        }
    }

    // MARK: - Home Screen: systemMedium

    /// The trio with its words, and the live heart beside it: HR as the big figure in the heart hue,
    /// then HRV and the strap battery as mono qualifiers (§6.13).
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            HStack(alignment: .center, spacing: 12) {
                scoreRings(diameter: 58, showsLabels: true)
                // Hairline divider. Cost: one 1 pt fill.
                Rectangle()
                    .fill(TelosColor.line)
                    .frame(width: 1)
                    .padding(.vertical, 4)
                heartColumn
            }
            Spacer(minLength: 0)
        }
    }

    /// Live HR `numeralL`-sized in `heartInk`, then HRV and battery in `scaleNumber`.
    private var heartColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TelosColor.heart)
                Text("bpm")
                    .font(TelosType.scaleFixed)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
            }
            Text(snap.bpm.map(String.init) ?? TelosType.absent)
                // Fixed at numeralL's 34 pt rather than the Dynamic-Type token: the medium tile's height
                // is fixed, and a scaled 48 pt figure would push the rings out of it.
                .font(TelosType.numeralFont(size: 34, weight: .light))
                .tracking(TelosType.Tracking.numeralL)
                .foregroundStyle(snap.bpm == nil ? TelosColor.textTertiary : TelosColor.heartInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Heart rate"))
                .accessibilityValue(Text(snap.bpm.map { "\($0) beats per minute" } ?? "No data"))
            if let hrv = snap.hrv {
                vital(symbol: "waveform.path.ecg", text: "\(hrv)",
                      name: "Heart rate variability", spoken: "\(hrv) milliseconds")
            }
            vital(symbol: "battery.50", text: snap.batteryPct.map { "\($0)%" },
                  name: "Strap battery", spoken: snap.batteryPct.map { "\($0) percent" })
        }
        .font(TelosType.scaleNumber)
        .foregroundStyle(TelosColor.textSecondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Home Screen: systemLarge

    /// Rings on top, then the richer stat grid (HRV, RHR, live HR, battery) — "show me more".
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            scoreRings(diameter: 88, showsLabels: true)
            // Hairline divider (was the system `Divider`, which draws the system separator grey on the
            // Telos ground). Cost: one 1 pt fill.
            Rectangle()
                .fill(TelosColor.line)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                statCell("HRV", value: snap.hrv.map { "\($0)" }, unit: "ms",
                         name: "Heart rate variability",
                         spoken: snap.hrv.map { "\($0) milliseconds" })
                statCell("Rest HR", value: snap.restingHr.map { "\($0)" }, unit: "bpm",
                         name: "Resting heart rate",
                         spoken: snap.restingHr.map { "\($0) beats per minute" })
                statCell("HR", value: snap.bpm.map { "\($0)" }, unit: "bpm",
                         tint: TelosColor.heartInk,
                         name: "Heart rate",
                         spoken: snap.bpm.map { "\($0) beats per minute" })
                statCell("Battery", value: snap.batteryPct.map { "\($0)%" },
                         name: "Strap battery",
                         spoken: snap.batteryPct.map { "\($0) percent" })
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared pieces

    /// The widget's name in the label voice, and the strap link. The link dot differs in SHAPE as well
    /// as hue (filled = connected, hollow ring = disconnected), so it does not rest on colour alone.
    private var headerRow: some View {
        HStack {
            Text("NOOP")
                .font(TelosType.scaleFixed)
                .tracking(TelosType.Tracking.scale)
                .foregroundStyle(TelosColor.textSecondary)
            Spacer()
            Group {
                if snap.bonded {
                    Circle().fill(TelosColor.positive)
                } else {
                    Circle().strokeBorder(TelosColor.critical, lineWidth: 1.5)
                }
            }
            .frame(width: 8, height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snap.bonded ? Text("Connected") : Text("Disconnected"))
        }
    }

    /// The Today hero trio as static Telos rings. Order: Rest · Charge · Effort. Each cell is
    /// honest-null ("—" over a dashed bare track) until scored.
    private func scoreRings(diameter: CGFloat, showsLabels: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(scores.indices, id: \.self) { i in
                let score = scores[i]
                WidgetScoreRing(text: score.text, value: score.value, label: score.label,
                                symbol: score.symbol, color: score.color, diameter: diameter,
                                showsLabel: showsLabels, accessibilityOutOf: score.accessibilityOutOf)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Home-Screen footer: heart rate, HRV, strap battery, under the score rings.
    ///
    /// `heart.fill` is HR and `waveform.path.ecg` is HRV, which is the metric pairing the rest of the app
    /// uses — `TodayView` renders them as adjacent rows that way, and `DashboardCards`,
    /// `TodayCustomizationMetadata`, `MetricCatalog` and this extension's own Live Activity all agree.
    /// The two were inverted here from #1022 until #1795 reported it.
    ///
    /// The inversion was an easy one to make and is worth naming so it is not "corrected" back:
    /// `waveform.path.ecg` IS the right symbol for Live HR as a FEATURE — `RootView`, `RootTabView` and
    /// `HomeScreenQuickActions` all use it for the Live screen. As a METRIC icon it belongs to HRV, and
    /// this footer is the one place that renders both metrics side by side, where the collision is the
    /// entire problem: nothing here carries a text label, so the glyph is the only thing naming a number.
    private func vitalsFooter(compact: Bool) -> some View {
        HStack {
            vital(symbol: "heart.fill", text: snap.bpm.map(String.init),
                  name: "Heart rate", spoken: snap.bpm.map { "\($0) beats per minute" })
            Spacer()
            if !compact, let hrv = snap.hrv {
                vital(symbol: "waveform.path.ecg", text: "\(hrv)",
                      name: "Heart rate variability", spoken: "\(hrv) milliseconds")
                Spacer()
            }
            vital(symbol: "battery.50", text: snap.batteryPct.map { "\($0)%" },
                  name: "Strap battery", spoken: snap.batteryPct.map { "\($0) percent" })
        }
        .font(TelosType.scaleNumber)
        .foregroundStyle(TelosColor.textSecondary)
        .labelStyle(.titleAndIcon)
    }

    /// One footer vital. `spoken` is carried separately from the rendered `text` because VoiceOver gets
    /// neither of the two things a sighted reader uses here: the glyph that names the metric, and the
    /// unit, which the footer shows for none of them. Without this a reader hears "58", "64", "84 percent"
    /// — three anonymous numbers. Same reasoning as `accessoryScore`, which #1715 fixed for the lock
    /// screen; this footer predates it.
    ///
    /// Plain literals rather than `String(localized:)`, for the reason spelled out on `accessoryScore`:
    /// this extension does not carry the app's string catalog, so `String(localized:)` would look
    /// localized and render English anyway.
    private func vital(symbol: String, text: String?, name: String, spoken: String?) -> some View {
        Label(text ?? TelosType.absent, systemImage: symbol)
            // Collapse first, like `accessoryScore` and `WidgetScoreRing` already do. A `Label` under
            // `.titleAndIcon` renders an image beside a text, so without this the bare number stays its
            // own element and whether the label below wins is SwiftUI container semantics rather than
            // something this file decides. Every other labelled graphic here ignores its children.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(spoken ?? "No data"))
    }

    /// One labelled stat in the large grid — value over a caption, equal-width so the columns align.
    ///
    /// `name` and `spoken` exist because the on-screen caption is abbreviated for width and the unit is a
    /// separate view: read as-is, VoiceOver produces "64", "ms", "HRV" — three fragments, value before
    /// label, with "ms" and "bpm" spelled out letter by letter. Collapsing to one element lets the cell
    /// speak "Heart rate variability, 64 milliseconds". `spoken` falls back to the rendered value rather
    /// than to "No data", so a caller that omits it degrades to the old reading instead of lying.
    private func statCell(_ label: String, value: String?, unit: String? = nil,
                          tint: Color = TelosColor.textPrimary,
                          name: String? = nil, spoken: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? TelosType.absent)
                    .font(TelosType.numeralFont(size: 22, weight: .light))
                    .foregroundStyle(value == nil ? TelosColor.textTertiary : tint)
                if let unit, value != nil {
                    Text(unit).font(TelosType.scaleNumber).foregroundStyle(TelosColor.textTertiary)
                }
            }
            Text(label)
                .font(TelosType.scale)
                .tracking(TelosType.Tracking.scale)
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.92)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name ?? label))
        .accessibilityValue(Text(spoken ?? value ?? "No data"))
    }
}

// MARK: - WidgetScoreRing

/// A static, widget-safe score ring: the app's own `TelosRing` (thin track in the metric hue, luminous
/// arc, halo stroke, tip dot; dashed bare track when absent; extra laps above one scale — never clipped)
/// with its centre replaced by the widget's pre-formatted figure.
///
/// `animatesChanges: false`, and `TelosRing` draws the settled value on its first render without
/// waiting for `onAppear` — so the old worry (WidgetKit not reliably firing `onAppear`, freezing an
/// animated ring empty) does not apply. The centre is the widget's own because the stored Effort text is
/// on the wearer's scale (0–21 or 0–100) while the arc is always the 0–100 axis.
///
/// Cost: `TelosRing`'s own budget — shapes only (track, one halo stroke, arc, tip), no blur, no Canvas.
private struct WidgetScoreRing: View {
    /// Centre read-out already formatted (whole number, or one-decimal WHOOP Effort).
    let text: String?
    /// The value on the 0–100 axis; nil draws the dashed bare track (unscored).
    let value: Double?
    let label: String
    let symbol: String
    let color: Color
    let diameter: CGFloat
    /// true = the tracked word under the ring; false = the metric's glyph (narrow tiles).
    let showsLabel: Bool
    let accessibilityOutOf: Int

    /// Never below the 11 pt floor; light only where the figure is large enough to stay legible.
    private var numeralSize: CGFloat { max(TelosType.minimumSize, diameter * 0.3) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                TelosRing(value: value, scale: 100, color: color, diameter: diameter,
                          showsValue: false, animatesChanges: false)
                Text(text ?? TelosType.absent)
                    .font(TelosType.numeralFont(size: numeralSize,
                                                weight: numeralSize >= 20 ? .light : .regular))
                    .foregroundStyle(text == nil ? TelosColor.textTertiary : TelosColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(TelosType.minimumSize / numeralSize)
                    .padding(.horizontal, TelosRingMath.defaultLineWidth(diameter: diameter) * 2.2)
            }
            .frame(width: diameter, height: diameter)
            if showsLabel {
                Text(label)
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
            } else {
                // The glyph names the metric (the hue alone would not).
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text.map { "\($0) out of \(accessibilityOutOf)" } ?? "unavailable"))
    }
}

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                // The system strips this for the accessory families on the Lock Screen, so the ground
                // only ever reaches the Home-Screen tiles.
                NOOPWidgetView(entry: entry)
                    .containerBackground(for: .widget) { TelosWidgetGround() }
            } else {
                NOOPWidgetView(entry: entry)
                    .padding()
                    .background(TelosColor.canvas)
            }
        }
        .configurationDisplayName("NOOP")
        .description("Charge, Effort and Rest as score rings, plus live HR and strap battery at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
