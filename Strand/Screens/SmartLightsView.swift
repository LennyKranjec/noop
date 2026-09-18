import SwiftUI
import StrandDesign

// SmartLightsView.swift — the WiZ bulbs: find them, set them, and let the day drive them.

struct SmartLightsView: View {
    @ObservedObject private var store = WizLightStore.shared
    @State private var ipDraft = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                if store.bulbs.isEmpty {
                    Text("No lights yet. Search the network, or add one by its address below.")
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(store.bulbs) { bulb in
                    BulbRow(bulb: bulb)
                }
                .onDelete { offsets in
                    for i in offsets { store.remove(store.bulbs[i]) }
                }
            } header: {
                Text("Lights")
            }

            if !store.bulbs.isEmpty {
                Section("Scenes") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(WizScene.allCases) { scene in
                                Button {
                                    SystemHaptics.play(.select)
                                    Task { await store.apply(scene) }
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: scene.symbol).font(.system(size: 18))
                                        Text(scene.title).font(StrandFont.caption)
                                    }
                                    .frame(width: 76, height: 64)
                                    .background(StrandPalette.surfaceInset,
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Toggle("Morning daylight", isOn: $store.wakeLightOn)
                    if store.wakeLightOn {
                        DatePicker("At", selection: minuteBinding($store.wakeMinute),
                                   displayedComponents: .hourAndMinute)
                    }
                    Toggle("Evening wind-down", isOn: $store.windDownOn)
                    if store.windDownOn {
                        DatePicker("At", selection: minuteBinding($store.windDownMinute),
                                   displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Light that follows the day")
                } footer: {
                    Text("Cold, full light in the morning sets the body clock; warm, dim light in the evening keeps it from being pushed back. Runs while the app is running, which with the strap connected includes the background.")
                }
            }

            Section {
                Button {
                    busy = true
                    message = nil
                    Task {
                        let added = await store.search()
                        busy = false
                        message = added > 0 ? "Found \(added) new light\(added == 1 ? "" : "s")."
                            : "No new WiZ light answered on this network."
                    }
                } label: {
                    HStack {
                        Label("Search this network", systemImage: "magnifyingglass")
                        if store.searching { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.searching)

                HStack {
                    TextField("Address, e.g. 192.168.1.42", text: $ipDraft)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Button("Add") {
                        busy = true
                        message = nil
                        let ip = ipDraft
                        Task {
                            let ok = await store.add(ip: ip)
                            busy = false
                            message = ok ? "Added." : "Nothing answered at \(ip)."
                            if ok { ipDraft = "" }
                        }
                    }
                    .disabled(ipDraft.isEmpty || busy)
                }
                if let message {
                    Text(message).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            } header: {
                Text("Add lights")
            } footer: {
                Text("The phone and the lights must be on the same Wi-Fi, and \"Allow local communication\" must be on in the WiZ app (Settings → Security). iOS asks once for permission to reach devices on your network.")
            }
        }
        .navigationTitle("Smart Lights")
        .task { await store.refresh() }
    }

    /// A minute-of-day as a Date the time picker can edit.
    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minute.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// One bulb: on/off, brightness and warmth.
private struct BulbRow: View {
    let bulb: WizBulb
    @ObservedObject private var store = WizLightStore.shared
    @State private var dimming: Double = 50
    @State private var temp: Double = 3000
    @State private var renaming = false
    @State private var nameDraft = ""

    private var pilot: WizPilot? { store.pilots[bulb.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bulb.name).font(StrandFont.headline)
                    Text(pilot == nil ? "\(bulb.ip) · not answering" : bulb.ip)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pilot?.on ?? false },
                    set: { on in Task { await store.set(bulb, on: on) } }))
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(StrandPalette.textTertiary)
                Slider(value: $dimming, in: 10...100, onEditingChanged: { editing in
                    if !editing { Task { await store.set(bulb, dimming: Int(dimming)) } }
                })
            }
            HStack(spacing: 10) {
                Image(systemName: "thermometer.sun").foregroundStyle(StrandPalette.textTertiary)
                Slider(value: $temp, in: 2200...6500, onEditingChanged: { editing in
                    if !editing { Task { await store.set(bulb, temp: Int(temp)) } }
                })
                Text("\(Int(temp)) K")
                    .font(StrandFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Rename") { nameDraft = bulb.name; renaming = true }
        }
        .alert("Rename light", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { store.rename(bulb, to: nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { sync() }
        .onChangeCompat(of: pilot) { _ in sync() }
    }

    private func sync() {
        if let d = pilot?.dimming { dimming = Double(d) }
        if let t = pilot?.temp { temp = Double(t) }
    }
}
