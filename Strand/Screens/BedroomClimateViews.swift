import SwiftUI
import StrandDesign

// BedroomClimateViews.swift — the bedroom tile on Today, and where the sensor is set up.

/// The bedroom's temperature and humidity, and whether it is a room to sleep well in.
///
/// Absent until a sensor is set up: a tile that only ever says "no sensor" is clutter on the screen
/// people open first. It is set up from More → Bedroom.
struct BedroomClimateTileView: View {
    @ObservedObject private var climate = BedroomClimate.shared
    let onOpen: () -> Void

    var body: some View {
        if climate.isConfigured {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "bed.double.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.restColor)
                        Text("BEDROOM")
                            .font(StrandFont.overline)
                            .tracking(1.2)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        if let r = climate.latest {
                            Text(age(r.at))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    if let r = climate.latest {
                        HStack(spacing: 24) {
                            figure(String(format: "%.1f °C", r.temperatureC), "thermometer.medium",
                                   ok: (ClimateAdvice.tempLowC...ClimateAdvice.tempHighC).contains(r.temperatureC))
                            figure(String(format: "%.0f %%", r.humidityPct), "humidity.fill",
                                   ok: (ClimateAdvice.humidityLow...ClimateAdvice.humidityHigh).contains(r.humidityPct))
                            Spacer(minLength: 0)
                        }
                        Text(ClimateAdvice.issues(r).first ?? "A good room to sleep in.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(ClimateAdvice.isGood(r) ? StrandPalette.textTertiary : StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(climate.scanning ? "Listening for the sensor…" : "No reading yet.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .task { await climate.refresh() }
        }
    }

    private func figure(_ text: String, _ icon: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ok ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            Text(text)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func age(_ at: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }
}

/// Setting up the sensor: Bluetooth (no account) or Govee's cloud (API key).
struct BedroomClimateSettingsView: View {
    @ObservedObject private var climate = BedroomClimate.shared
    @State private var keyDraft = ""
    @State private var cloudDevices: [GoveeCloud.Device] = []
    @State private var cloudStatus: String?

    var body: some View {
        ScreenScaffold(title: "Bedroom",
                       subtitle: "Temperature and humidity from a Govee sensor, and an evening tip when the room is off.",
                       topBackground: liquidScaffoldSky()) {
            StrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    header("BLUETOOTH SENSOR — NO ACCOUNT NEEDED")
                    Text("For H5072, H5074, H5075, H5101, H5102, H5174, H5177 and H5179. Keep the phone near the sensor and scan.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await climate.scan(seconds: 10) }
                    } label: {
                        Label(climate.scanning ? "Scanning…" : "Scan for sensors", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(climate.scanning)
                    ForEach(climate.heard) { h in
                        Button {
                            climate.bleDeviceId = h.id
                            climate.setCloudDevice(sku: nil, device: nil)
                            Task { await climate.refresh() }
                            SystemHaptics.play(.confirm)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name.isEmpty ? "Govee sensor" : h.name)
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(String(format: "%.1f °C · %.0f %%", h.reading.temperatureC, h.reading.humidityPct))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                if climate.bleDeviceId == h.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.statusPositive)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if !climate.scanning && climate.heard.isEmpty && climate.bleDeviceId == nil {
                        Text("No sensor heard yet.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }

            StrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    header("WI-FI SENSOR — GOVEE CLOUD")
                    Text("For Wi-Fi models such as the H5179 — the most reliable way for those — or Bluetooth ones behind a Govee gateway. Request an API key in the Govee Home app (Profile → Settings → Apply for API key).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField(climate.apiKey == nil ? "Govee API key" : "API key saved — paste to replace", text: $keyDraft)
                        .font(StrandFont.body)
                        .padding(10)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack {
                        Button("Load devices") {
                            if !keyDraft.isEmpty { climate.apiKey = keyDraft; keyDraft = "" }
                            Task { await loadCloudDevices() }
                        }
                        .disabled(keyDraft.isEmpty && climate.apiKey == nil)
                        Spacer()
                        if climate.apiKey != nil {
                            Button("Remove key", role: .destructive) {
                                climate.apiKey = nil
                                climate.setCloudDevice(sku: nil, device: nil)
                                cloudDevices = []
                            }
                        }
                    }
                    .font(StrandFont.subhead)
                    if let cloudStatus {
                        Text(cloudStatus).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    ForEach(cloudDevices) { d in
                        Button {
                            climate.setCloudDevice(sku: d.sku, device: d.device)
                            climate.bleDeviceId = nil
                            Task { await climate.refresh() }
                            SystemHaptics.play(.confirm)
                        } label: {
                            HStack {
                                Text("\(d.name) (\(d.sku))")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                if climate.cloudDevice?.device == d.device {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.statusPositive)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            StrandCard {
                VStack(alignment: .leading, spacing: 6) {
                    header("AIR PURIFIER")
                    Text("Philips air purifiers are not connected. Philips publishes no API for them: the Air+ app talks to a private cloud, and the local protocol on older models is an undocumented, encrypted one that differs by model — reading it would be guesswork that could break with any firmware update.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(StrandFont.overline).tracking(1.2).foregroundStyle(StrandPalette.textSecondary)
    }

    private func loadCloudDevices() async {
        guard let key = climate.apiKey else { return }
        cloudStatus = "Loading…"
        if let list = await GoveeCloud.devices(apiKey: key) {
            cloudDevices = list
            cloudStatus = list.isEmpty ? "No temperature sensors on this account." : nil
            // Nothing chosen yet: choose the first, so a loaded list is a connected sensor rather than
            // a list waiting for a tap nobody knew was needed.
            if climate.cloudDevice == nil, let first = list.first {
                climate.setCloudDevice(sku: first.sku, device: first.device)
                climate.bleDeviceId = nil
                await climate.refresh()
            }
        } else {
            cloudStatus = "Govee did not accept the key, or could not be reached."
        }
    }
}
