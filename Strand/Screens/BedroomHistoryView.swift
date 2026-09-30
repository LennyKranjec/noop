import SwiftUI
import Charts
import StrandDesign

// BedroomHistoryView.swift — the room sensor's chip on Today, and the room over time.

/// The room's current figures as a small chip under Today's date, plus what to do with the windows.
/// Tapping it opens the room's own screen (`BedroomHistoryView`).
///
/// THE TAP DID NOTHING, and two things about it were wrong. Which of them the wearer was hitting is not
/// something the source can state, so both are fixed and neither is blamed:
///
///  1. THE TARGET. The capsule is caption-height — about 25 points with its padding, well under the 44 the
///     platform asks for — and it sits in the sky band with the day-title button (whose label is
///     `maxWidth: .infinity`, so it spans the whole row) directly above it and the wordmark's own
///     `onTapGesture` directly below. A near miss lands on a neighbour, which is the same defect the
///     wake-buzz alarm row had (`SleepView`: "a bare Label in a `.plain` Button is hit-tested on the text
///     + glyph boxes alone"). `minHitTarget` + an explicit content shape make the whole strip the target
///     while the capsule keeps its size.
///  2. THE PRESENTER. It used to hand an `onOpen` closure up to `LiquidTodayView`, which flipped a
///     `@State` read by the FOURTH of seven `.sheet` modifiers chained onto Today's `ScrollView`, itself
///     inside a `ScrollViewReader` inside a `GeometryReader`. That is the shape the alarm fix moved AWAY
///     from — a presenter far from the control, stacked behind others, where a failure to present is
///     silent. It now sits on the button that triggers it: one `.sheet`, unconditional, with nothing
///     between the tap and the presentation.
///
/// Neither change can regress the other, and the chip no longer depends on anything in Today's modifier
/// chain to open its own screen.
///
/// GATED BY THE CALL SITE, not here: Today already draws it only when a sensor is configured (it also has
/// to know, for the wordmark's spacing), and a second copy of the condition inside this view only made the
/// button's identity depend on a Keychain read.
struct BedroomClimateChip: View {
    @ObservedObject private var climate = BedroomClimate.shared
    @State private var showRoom = false

    var body: some View {
        Button { showRoom = true } label: {
            // Once a minute: the advice counts down ("Open in 25 min") and the window of the day flips at
            // its boundary, neither of which waits for a new sensor reading.
            TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                face(now: timeline.date)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(climate.latest.map {
            String(format: "Room %.1f degrees, %.0f percent humidity. Opens the room screen.",
                   $0.temperatureC, $0.humidityPct)
        } ?? "Room sensor, no reading yet"))
        .sheet(isPresented: $showRoom) { BedroomHistoryView() }
    }

    private func face(now: Date) -> some View {
        let advice = WindowAdvicePlan.advice(for: climate.latest, now: now)
        return HStack(spacing: 8) {
            if let r = climate.latest {
                // Judged for the window the day is in: focus by day, sleep from the wind-down on.
                let good = RoomClimatePlan.context(for: r, now: now).isGood
                Image(systemName: "thermometer.medium")
                    .font(TelosType.scaleFixed)
                    .foregroundStyle(good ? StrandPalette.restColor : StrandPalette.statusWarning)
                Text(String(format: "%.1f°", r.temperatureC))
                    .font(StrandFont.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "humidity.fill")
                    .font(TelosType.scaleFixed)
                    .foregroundStyle(good ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                Text(String(format: "%.0f%%", r.humidityPct))
                    .font(StrandFont.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                // THE WINDOWS, in three or four words. Only when there is something to do: no forecast,
                // no crossing or a room already in its band all draw nothing here rather than filling the
                // chip with the news that there is no news. The screen behind the tap says why.
                if let phrase = advice.chipPhrase(now: now) {
                    Image(systemName: "wind")
                        .font(TelosType.scaleFixed)
                        .foregroundStyle(StrandPalette.accent)
                    Text(phrase)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "thermometer.medium")
                    .font(TelosType.scaleFixed)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Room: no reading yet")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(TelosType.glyphDelta)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(TelosColor.glassFill))
        .overlay(Capsule(style: .continuous).strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
        // The hit area, not the capsule: the pill keeps its size and the target grows around it.
        .frame(minHeight: NoopButtonMetrics.minHitTarget)
        .contentShape(Rectangle())
    }
}

/// The room over the last day or two weeks: temperature and humidity against the band a bedroom
/// sleeps best in.
struct BedroomHistoryView: View {
    @ObservedObject private var climate = BedroomClimate.shared
    @Environment(\.dismiss) private var dismiss

    enum Span: String, CaseIterable, Identifiable {
        case day = "24 h", week = "7 d", fortnight = "14 d"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .fortnight: return 14 * 86_400
            }
        }
    }

    @State private var span: Span = .day
    @State private var points: [ClimateHistory.Point] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Both the reading and the window advice move with the clock (the band flips at the
                    // wind-down, the countdown counts down), so the two cards that show them are redrawn
                    // once a minute rather than only when a new reading lands.
                    TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                        VStack(alignment: .leading, spacing: 16) {
                            current(now: timeline.date)
                            windows(now: timeline.date)
                        }
                    }
                    Picker("", selection: $span) {
                        ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if points.count < 2 {
                        Text("The history fills as the sensor is read, every ten minutes while the app runs. Govee's service only keeps the current figure, so the history starts from when the sensor was connected.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        chartCard(title: "TEMPERATURE", unit: "°C", tint: StrandPalette.restColor,
                                  band: ClimateAdvice.tempLowC...ClimateAdvice.tempHighC,
                                  values: points.map { ($0.at, $0.temperatureC) })
                        chartCard(title: "HUMIDITY", unit: "%", tint: StrandPalette.metricCyan,
                                  band: ClimateAdvice.humidityLow...ClimateAdvice.humidityHigh,
                                  values: points.map { ($0.at, $0.humidityPct) })
                    }
                }
                .padding(16)
            }
            .background(TelosColor.canvas)
            .navigationTitle("Bedroom")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sensor") { showSettings = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { BedroomClimateSettingsView() }
            }
        }
        .task(id: "\(span.rawValue)-\(climate.historyVersion)") {
            points = ClimateHistory.since(Date().addingTimeInterval(-span.seconds))
        }
        .task { await climate.refresh() }
        // The window advice needs the outdoor curve. Not forced: the 30-minute staleness gate is the right
        // one here — this screen can be opened repeatedly and the sky does not move in between.
        .task { await WeatherService.refresh() }
    }

    /// The room now, against the band the part of the day asks for.
    private func current(now: Date) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                if let r = climate.latest {
                    let ctx = RoomClimatePlan.context(for: r, now: now)
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        figure(String(format: "%.1f °C", r.temperatureC), "temperature",
                               target: "target " + WindowVentilation.bandText(ctx.targets.temp),
                               ok: ctx.temperature.status == .good)
                        figure(String(format: "%.0f %%", r.humidityPct), "humidity",
                               target: String(format: "target %.0f–%.0f %%", ctx.targets.humidity.lowerBound,
                                              ctx.targets.humidity.upperBound),
                               ok: ctx.humidity.status == .good)
                        Spacer(minLength: 0)
                    }
                    Text("\(ctx.mode.label) · \(ctx.hint)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(ctx.isGood ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(r.deviceName) · \(r.at.formatted(date: .omitted, time: .shortened))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("No reading yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// `name` stays a `LocalizedStringKey` so the two words keep being auto-extracted into the String
    /// Catalog; `value` and `target` are formatted figures, which are not copy.
    private func figure(_ value: String, _ name: LocalizedStringKey, target: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .telosNumeral(.numeralL)
                .foregroundStyle(TelosColor.textPrimary)
            Text(name).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(target)
                .font(StrandFont.caption)
                .foregroundStyle(ok ? StrandPalette.statusPositive : StrandPalette.statusWarning)
        }
    }

    /// THE WINDOWS: when to open them, when to shut them, and why — or an explicit "no recommendation"
    /// naming what is missing. See `WindowVentilation`; nothing here decides anything itself.
    private func windows(now: Date) -> some View {
        let advice = WindowAdvicePlan.advice(for: climate.latest, now: now)
        // Hoisted out of the modifiers below: this file has been through the type-checker budget before.
        let tint: Color = advice.isActionable ? StrandPalette.accent : StrandPalette.textTertiary
        let lineFont = StrandFont.subhead.weight(advice.isActionable ? .semibold : .regular)
        let lineTint: Color = advice.isActionable ? StrandPalette.textPrimary : StrandPalette.textTertiary
        return StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wind")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(tint)
                    Text("WINDOWS")
                        .telosScale()
                        .foregroundStyle(TelosColor.textSecondary)
                    Spacer(minLength: 0)
                    // Only for an actual abstention. A settled room HAS a recommendation — "keep them
                    // shut" — and badging that as "no recommendation" would read as a failure.
                    if advice.isAbstention {
                        Text("NO RECOMMENDATION")
                            .telosScale()
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                }
                Text(advice.actionLine(now: now))
                    .font(lineFont)
                    .foregroundStyle(lineTint)
                    .fixedSize(horizontal: false, vertical: true)
                // Only alongside an instruction: for `settled` and for an abstention the line above IS the
                // reasoning, and printing it twice would read as two different findings.
                if advice.isActionable, let reason = advice.reason {
                    Text(reason)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat = advice.caveat {
                    Text(caveat)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("From today's hourly forecast, which does not reach past midnight.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chartCard(title: String, unit: String, tint: Color, band: ClosedRange<Double>,
                           values: [(Date, Double)]) -> some View {
        let ys = values.map(\.1)
        let lo = min(ys.min() ?? band.lowerBound, band.lowerBound) - 1
        let hi = max(ys.max() ?? band.upperBound, band.upperBound) + 1
        return StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).telosScale()
                        .foregroundStyle(TelosColor.textSecondary)
                    Spacer()
                    if let mn = ys.min(), let mx = ys.max() {
                        Text(String(format: "%.1f – %.1f ", mn, mx) + unit)
                            .font(StrandFont.caption)
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Chart {
                    // The band a bedroom sleeps best in, behind the line.
                    RectangleMark(yStart: .value("low", band.lowerBound), yEnd: .value("high", band.upperBound))
                        .foregroundStyle(StrandPalette.statusPositive.opacity(0.10))
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        LineMark(x: .value("time", v.0), y: .value(title, v.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: TelosStroke.data, lineCap: .round, lineJoin: .round))
                    }
                }
                .chartYScale(domain: lo...hi)
                .frame(height: 160)
            }
        }
    }
}
