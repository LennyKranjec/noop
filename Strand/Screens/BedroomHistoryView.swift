import SwiftUI
import Charts
import StrandDesign

// BedroomHistoryView.swift — the room sensor's chip on Today, and the room over time.

/// The room's current figures as a small chip under Today's date. Nothing when no sensor is set up.
struct BedroomClimateChip: View {
    @ObservedObject private var climate = BedroomClimate.shared
    let onOpen: () -> Void

    var body: some View {
        if climate.isConfigured {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    if let r = climate.latest {
                        let good = ClimateAdvice.isGood(r)
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(good ? StrandPalette.restColor : StrandPalette.statusWarning)
                        Text(String(format: "%.1f°", r.temperatureC))
                            .font(StrandFont.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                        Image(systemName: "humidity.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(good ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                        Text(String(format: "%.0f%%", r.humidityPct))
                            .font(StrandFont.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("Room: no reading yet")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(StrandPalette.surfaceRaised.opacity(0.85)))
                .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(climate.latest.map {
                String(format: "Room %.1f degrees, %.0f percent humidity. Opens the history.",
                       $0.temperatureC, $0.humidityPct)
            } ?? "Room sensor, no reading yet"))
        }
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
                    current
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
            .background(StrandPalette.surfaceBase)
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
    }

    private var current: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                if let r = climate.latest {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f °C", r.temperatureC))
                                .font(StrandFont.number(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("temperature").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f %%", r.humidityPct))
                                .font(StrandFont.number(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("humidity").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(ClimateAdvice.issues(r).first ?? "A good room to sleep in.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(ClimateAdvice.isGood(r) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
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

    private func chartCard(title: String, unit: String, tint: Color, band: ClosedRange<Double>,
                           values: [(Date, Double)]) -> some View {
        let ys = values.map(\.1)
        let lo = min(ys.min() ?? band.lowerBound, band.lowerBound) - 1
        let hi = max(ys.max() ?? band.upperBound, band.upperBound) + 1
        return StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(StrandFont.overline).tracking(1.2)
                        .foregroundStyle(StrandPalette.textSecondary)
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
                    }
                }
                .chartYScale(domain: lo...hi)
                .frame(height: 160)
            }
        }
    }
}
