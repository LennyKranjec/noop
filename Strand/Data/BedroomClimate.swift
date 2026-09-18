import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import UserNotifications

// BedroomClimate.swift — the bedroom's temperature and humidity, from a Govee sensor.
//
// Sleep is the heaviest part of the level, and the room is the one input to it the wearer can change
// in thirty seconds: a window, a radiator, a humidifier. So the app reads the bedroom and says, in the
// evening, when it is not a room to sleep well in.
//
// TWO WAYS IN, because Govee sells two kinds of sensor:
//
//   · BLUETOOTH — the H5072 / H5075 / H5101 / H5102 / H5174 / H5177 family and the H5074 / H5051 pair
//     broadcast their reading in every advertisement. No pairing, no account, no key: the phone
//     listens for a few seconds and reads it off the air. This is the one most bedrooms have.
//   · GOVEE'S CLOUD — Wi-Fi models (and Bluetooth ones behind a Govee gateway) report through Govee's
//     public developer API, with the API key the Govee Home app issues. Kept in the Keychain.
//
// A READING IS ONLY EVER WHAT A SENSOR SAID. No reading is no tile and no advice; a stale one says how
// old it is. An invented "probably fine" would be exactly the kind of number this app does not print.
//
// THE RANGES are the widely used sleep-environment guidance — roughly 16–19.5 °C and 40–60 % relative
// humidity — and are applied as a nudge, not a diagnosis.

struct ClimateReading: Codable, Equatable {
    let temperatureC: Double
    let humidityPct: Double
    let battery: Int?
    let deviceName: String
    let source: String
    let at: Date
}

enum ClimateAdvice {

    static let tempLowC = 16.0
    static let tempHighC = 19.5
    static let humidityLow = 40.0
    static let humidityHigh = 60.0

    /// One line per problem, empty when the room is fine.
    static func issues(_ r: ClimateReading) -> [String] {
        var out: [String] = []
        if r.temperatureC > tempHighC {
            out.append(String(format: "The bedroom is %.1f °C — about %.0f° warmer than is good for sleep. Air it out or turn the heating down before bed.",
                              r.temperatureC, r.temperatureC - tempHighC))
        } else if r.temperatureC < tempLowC {
            out.append(String(format: "The bedroom is %.1f °C — on the cold side for sleep. A little heat or a warmer duvet will help.",
                              r.temperatureC))
        }
        if r.humidityPct < humidityLow {
            out.append(String(format: "Humidity is %.0f %% — dry air dries out the airways overnight. A humidifier or a bowl of water helps.",
                              r.humidityPct))
        } else if r.humidityPct > humidityHigh {
            out.append(String(format: "Humidity is %.0f %% — damp air sleeps worse. Air the room briefly before bed.",
                              r.humidityPct))
        }
        return out
    }

    static func isGood(_ r: ClimateReading) -> Bool { issues(r).isEmpty }
}

@MainActor
final class BedroomClimate: NSObject, ObservableObject {

    static let shared = BedroomClimate()

    /// A sensor the Bluetooth scan heard, for the picker.
    struct Heard: Identifiable, Equatable {
        let id: String
        let name: String
        let reading: ClimateReading
    }

    @Published private(set) var latest: ClimateReading?
    @Published private(set) var heard: [Heard] = []
    @Published private(set) var scanning = false
    @Published var lastError: String?

    private static let latestKey = "climate.latest"
    private static let bleDeviceKey = "climate.ble.device"
    private static let cloudDeviceKey = "climate.cloud.device"
    private static let cloudSkuKey = "climate.cloud.sku"
    private static let notifiedDayKey = "climate.notified.day"
    private static let keychainService = "noop.govee"
    private static let keychainAccount = "api-key"

    #if canImport(CoreBluetooth)
    private var central: CBCentralManager?
    /// The central's own queue. NOT the main one: with no service filter the delegate hears EVERY
    /// advertisement from every device in radio range — in a flat with a few dozen of them that is
    /// hundreds of callbacks a second, and on the main queue each one competed with the frame the app
    /// was drawing. Discovery is parsed here and only a Govee reading is handed to the main actor.
    private let bleQueue = DispatchQueue(label: "noop.bedroom.ble", qos: .utility)

    /// DUPLICATES ON. A sensor's first packet often carries neither its name nor a fresh reading — the
    /// name comes in the scan response, the figures in each later broadcast — and with duplicates off
    /// iOS reports a device once and never again, so the thermometer was never recognised. The cost of
    /// duplicates is paid on `bleQueue`, where everything that is not a Govee sensor is dropped.
    nonisolated static var scanOptions: [String: Any] { [CBCentralManagerScanOptionAllowDuplicatesKey: true] }
    #endif
    private var scanEndsAt: Date?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.latestKey) {
            latest = try? JSONDecoder().decode(ClimateReading.self, from: data)
        }
    }

    // MARK: - Configuration

    var bleDeviceId: String? {
        get { UserDefaults.standard.string(forKey: Self.bleDeviceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bleDeviceKey); objectWillChange.send() }
    }

    var cloudDevice: (sku: String, device: String)? {
        guard let sku = UserDefaults.standard.string(forKey: Self.cloudSkuKey),
              let device = UserDefaults.standard.string(forKey: Self.cloudDeviceKey) else { return nil }
        return (sku, device)
    }

    func setCloudDevice(sku: String?, device: String?) {
        UserDefaults.standard.set(sku, forKey: Self.cloudSkuKey)
        UserDefaults.standard.set(device, forKey: Self.cloudDeviceKey)
        objectWillChange.send()
    }

    var apiKey: String? {
        get { KeychainItem.read(service: Self.keychainService, account: Self.keychainAccount) }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                KeychainItem.write(newValue.trimmingCharacters(in: .whitespaces),
                                   service: Self.keychainService, account: Self.keychainAccount)
            } else {
                KeychainItem.delete(service: Self.keychainService, account: Self.keychainAccount)
            }
            objectWillChange.send()
        }
    }

    var isConfigured: Bool { bleDeviceId != nil || (apiKey != nil && cloudDevice != nil) }

    // MARK: - Refresh

    /// Read the configured sensor, whichever way it is configured, and act on the result.
    func refresh() async {
        if let key = apiKey, let device = cloudDevice {
            if let r = await GoveeCloud.read(apiKey: key, sku: device.sku, device: device.device) {
                accept(r)
                return
            }
        }
        if bleDeviceId != nil { await scan(seconds: 10) }
    }

    /// Listen for Govee advertisements for `seconds`. Fills `heard`; accepts the configured sensor's.
    func scan(seconds: Double = 10) async {
        #if canImport(CoreBluetooth)
        heard = []
        scanning = true
        scanEndsAt = Date().addingTimeInterval(seconds)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: bleQueue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: nil, options: Self.scanOptions)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        central?.stopScan()
        scanning = false
        #endif
    }

    fileprivate func heardAdvertisement(id: String, name: String, manufacturerData: Data) {
        guard let parsed = GoveeAdvertisement.parse(name: name, manufacturerData: manufacturerData) else { return }
        heard(id: id, name: name, parsed: parsed)
    }

    /// One parsed Govee advertisement. Ignored unless a scan is running, so a late delivery cannot
    /// repopulate the picker after it closed.
    fileprivate func heard(id: String, name: String, parsed: GoveeAdvertisement.Parsed) {
        guard scanning else { return }
        let reading = ClimateReading(temperatureC: parsed.temperatureC, humidityPct: parsed.humidityPct,
                                     battery: parsed.battery, deviceName: name, source: "govee-ble", at: Date())
        if let i = heard.firstIndex(where: { $0.id == id }) {
            heard[i] = Heard(id: id, name: name, reading: reading)
        } else {
            heard.append(Heard(id: id, name: name, reading: reading))
        }
        if id == bleDeviceId { accept(reading) }
    }

    private func accept(_ r: ClimateReading) {
        latest = r
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: Self.latestKey) }
        ClimateHistory.record(r)
        historyVersion &+= 1
        Task { await self.adviseIfEvening(r) }
    }

    /// Bumped whenever a reading is added to the history, so a chart re-reads.
    @Published private(set) var historyVersion = 0

    // MARK: - Polling

    /// How often the sensor is read while the app runs. Govee's cloud refreshes a sensor's figure
    /// roughly every ten minutes, so asking more often only reads the same number again.
    static let pollSeconds: UInt64 = 10 * 60
    private var polling = false

    /// Read the sensor now and then every ten minutes for as long as the app runs — which, with the
    /// strap connected, is in the background too. That is what builds the history the chart draws:
    /// Govee's API returns the current figure only, never a past one.
    func startPolling() {
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.isConfigured { await self.refresh() }
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    // MARK: - The evening tip

    /// After five in the evening, a room that is out of range gets ONE notification that day, and the
    /// 21:00 reminder is kept in step with the latest reading — scheduled while the room is off, removed
    /// the moment it is fine.
    private func adviseIfEvening(_ r: ClimateReading, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let hour = Calendar.current.component(.hour, from: now)
        let issues = ClimateAdvice.issues(r)
        let reminderId = "bedroom.climate.evening"

        guard !issues.isEmpty else {
            center.removePendingNotificationRequests(withIdentifiers: [reminderId])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Bedroom check"
        content.body = issues.joined(separator: " ")
        content.sound = .default

        // The 21:00 reminder, from this reading.
        var at = DateComponents()
        at.hour = 21
        at.minute = 0
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        if hour < 21 {
            try? await center.add(UNNotificationRequest(
                identifier: reminderId, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false)))
        }

        // And now, once, if it is already evening.
        let today = Repository.localDayKey(now)
        guard hour >= 17, UserDefaults.standard.string(forKey: Self.notifiedDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.notifiedDayKey)
        try? await center.add(UNNotificationRequest(identifier: "bedroom.climate.now", content: content, trigger: nil))
    }
}

#if canImport(CoreBluetooth)
extension BedroomClimate: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn, self.scanning else {
                if central.state == .unauthorized { self.lastError = "Bluetooth access is off for this app." }
                return
            }
            central.scanForPeripherals(withServices: nil, options: Self.scanOptions)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        // PARSED HERE, on the central's own queue: `parse` is pure, and everything that is not a Govee
        // sensor — which is most of what a scan hears — is dropped without ever touching the main actor.
        guard let parsed = GoveeAdvertisement.parse(name: name, manufacturerData: data) else { return }
        let id = peripheral.identifier.uuidString
        // One hand-over per sensor every two seconds: a Govee broadcasts several times a second, and
        // the picker and the reading need none of the repeats.
        guard GoveeHopThrottle.admit(id) else { return }
        let shownName = name.isEmpty ? "Govee sensor" : name
        Task { @MainActor in self.heard(id: id, name: shownName, parsed: parsed) }
    }
}
#endif

/// The room's readings over time, as this app has collected them.
///
/// Kept on the device in defaults — two weeks at one point per five minutes is a few thousand small
/// records — because Govee's cloud offers the current reading only and a chart needs the past.
enum ClimateHistory {
    struct Point: Codable, Equatable, Identifiable {
        let at: Date
        let temperatureC: Double
        let humidityPct: Double
        var id: Date { at }
    }

    private static let key = "climate.history.v1"
    static let keepDays = 14
    /// Readings closer together than this replace the previous point rather than adding one.
    static let minSpacing: TimeInterval = 5 * 60

    static func all(_ d: UserDefaults = .standard) -> [Point] {
        guard let data = d.data(forKey: key),
              let points = try? JSONDecoder().decode([Point].self, from: data) else { return [] }
        return points
    }

    static func record(_ r: ClimateReading, _ d: UserDefaults = .standard) {
        var points = all(d)
        let point = Point(at: r.at, temperatureC: r.temperatureC, humidityPct: r.humidityPct)
        if let last = points.last, point.at.timeIntervalSince(last.at) < minSpacing {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
        let floor = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        points.removeAll { $0.at < floor }
        if let data = try? JSONEncoder().encode(points) { d.set(data, forKey: key) }
    }

    /// The points since `since`, oldest first.
    static func since(_ since: Date, _ d: UserDefaults = .standard) -> [Point] {
        all(d).filter { $0.at >= since }
    }
}

/// One hand-over to the main actor per sensor per interval. Touched only from the central's serial
/// queue, and locked anyway so a second central could never race it.
final class GoveeHopThrottle: @unchecked Sendable {
    private static let lock = NSLock()
    private static var last: [String: Date] = [:]
    static let interval: TimeInterval = 2

    static func admit(_ id: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let at = last[id], now.timeIntervalSince(at) < interval { return false }
        last[id] = now
        return true
    }
}

// MARK: - Reading a Govee advertisement

enum GoveeAdvertisement {

    struct Parsed: Equatable {
        let temperatureC: Double
        let humidityPct: Double
        let battery: Int?
    }

    /// Govee's company identifier, little-endian at the head of the manufacturer data.
    static let companyId: UInt16 = 0xEC88
    static let h5179CompanyId: UInt16 = 0x8801

    /// Decode one advertisement, or nil when it is not a Govee thermo-hygrometer this understands.
    ///
    /// Two encodings, told apart by model, because the payloads are the same length and read as
    /// plausible numbers under the wrong one:
    ///   · H5074 / H5051 — signed 16-bit temperature ×100 and 16-bit humidity ×100, little-endian, from
    ///     byte 3, battery at byte 7.
    ///   · H5072 / H5075 / H5101 / H5102 / H5174 / H5177 — one 24-bit big-endian value from byte 3 that
    ///     packs temperature ×10 × 1000 + humidity ×10, top bit set for below zero, battery at byte 6.
    static func parse(name: String, manufacturerData d: Data) -> Parsed? {
        let b = [UInt8](d)
        let model = name.uppercased()
        let company: UInt16 = b.count >= 2 ? UInt16(b[0]) | (UInt16(b[1]) << 8) : 0
        // A PACKET WITHOUT A NAME IS STILL READ. iOS often delivers the manufacturer data before the
        // scan response that carries the name, and an unnamed packet under Govee's own company id is a
        // Govee sensor; the layout is then told apart by length. A packet WITH a name that is not a
        // model this understands is still refused — a named speaker is not a thermometer.
        let unnamed = model.trimmingCharacters(in: .whitespaces).isEmpty
        // H5179 — the Wi-Fi model — advertises under a different company id (0x8801) with its own
        // layout: signed 16-bit temperature ×100 and 16-bit humidity ×100, little-endian, from byte 6,
        // battery at byte 10. The company id alone identifies it.
        if model.contains("5179") || company == h5179CompanyId {
            guard b.count >= 11, company == h5179CompanyId else { return nil }
            let rawT = Int16(bitPattern: UInt16(b[6]) | (UInt16(b[7]) << 8))
            let rawH = UInt16(b[8]) | (UInt16(b[9]) << 8)
            return sane(Double(rawT) / 100, Double(rawH) / 100, battery: Int(b[10]))
        }
        guard b.count >= 7, company == companyId else { return nil }
        if model.contains("5074") || model.contains("5051") || (unnamed && b.count >= 9) {
            guard b.count >= 8 else { return nil }
            let rawT = Int16(bitPattern: UInt16(b[3]) | (UInt16(b[4]) << 8))
            let rawH = UInt16(b[5]) | (UInt16(b[6]) << 8)
            return sane(Double(rawT) / 100, Double(rawH) / 100, battery: Int(b[7]))
        }
        guard unnamed || ["5072", "5075", "5101", "5102", "5174", "5177"].contains(where: { model.contains($0) })
        else { return nil }
        let packed = (Int(b[3]) << 16) | (Int(b[4]) << 8) | Int(b[5])
        let negative = packed & 0x800000 != 0
        let value = packed & 0x7FFFFF
        let t = Double(value / 1000) / 10
        let h = Double(value % 1000) / 10
        return sane(negative ? -t : t, h, battery: Int(b[6]))
    }

    /// Anything outside what a room can be is a mis-decode, not a reading.
    private static func sane(_ t: Double, _ h: Double, battery: Int?) -> Parsed? {
        guard (-40...60).contains(t), (0...100).contains(h) else { return nil }
        return Parsed(temperatureC: t, humidityPct: h, battery: battery.map { min(max($0, 0), 100) })
    }
}

// MARK: - Govee's cloud

enum GoveeCloud {

    struct Device: Identifiable, Equatable {
        let sku: String
        let device: String
        let name: String
        var id: String { device }
    }

    private static let base = "https://openapi.api.govee.com/router/api/v1"

    /// The account's sensors that report temperature or humidity.
    static func devices(apiKey: String) async -> [Device]? {
        guard let url = URL(string: base + "/user/devices") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["data"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { d in
            guard let sku = d["sku"] as? String, let device = d["device"] as? String else { return nil }
            let caps = (d["capabilities"] as? [[String: Any]]) ?? []
            let senses = caps.contains { ["sensorTemperature", "sensorHumidity"].contains($0["instance"] as? String ?? "") }
            let isThermo = (d["type"] as? String ?? "").contains("thermometer")
            guard senses || isThermo else { return nil }
            return Device(sku: sku, device: device, name: (d["deviceName"] as? String) ?? sku)
        }
    }

    /// One device's current reading.
    ///
    /// GOVEE REPORTS TEMPERATURE IN FAHRENHEIT through this API. A bedroom above 45 °C is not a thing,
    /// and one below 45 °F is not either, so a value above 45 is read as Fahrenheit and converted —
    /// which also keeps a device whose firmware reports Celsius from being converted twice.
    static func read(apiKey: String, sku: String, device: String) async -> ClimateReading? {
        guard let url = URL(string: base + "/device/state") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "requestId": UUID().uuidString,
            "payload": ["sku": sku, "device": device],
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let caps = payload["capabilities"] as? [[String: Any]]
        else { return nil }

        func value(_ instance: String, _ nested: String) -> Double? {
            guard let state = caps.first(where: { ($0["instance"] as? String) == instance })?["state"] as? [String: Any]
            else { return nil }
            if let n = state["value"] as? NSNumber { return n.doubleValue }
            if let d = state["value"] as? [String: Any], let n = d[nested] as? NSNumber { return n.doubleValue }
            return nil
        }
        guard var t = value("sensorTemperature", "currentTemperature"),
              let h = value("sensorHumidity", "currentHumidity")
        else { return nil }
        if t > 45 { t = (t - 32) * 5 / 9 }
        return ClimateReading(temperatureC: t, humidityPct: h, battery: nil, deviceName: sku,
                              source: "govee-cloud", at: Date())
    }
}
