import Foundation
import Network

// WizLights.swift — Philips WiZ bulbs on the home Wi-Fi, driven directly.
//
// NO ACCOUNT, NO CLOUD. A WiZ bulb answers small JSON messages over UDP on port 38899 of the local
// network (`getPilot` reads it, `setPilot` sets it). That is the whole integration: the phone and the
// bulb only have to be on the same Wi-Fi, and "Allow local communication" has to be on in the WiZ app.
//
// FINDING THEM WITHOUT A BROADCAST. The usual discovery is a UDP broadcast, which iOS only permits with a
// multicast entitlement Apple grants on request — not something a sideloaded build can carry. So the
// search asks each address of the phone's own /24 subnet directly instead: two hundred and fifty-four
// small unicast questions, which need nothing but the local-network permission.
//
// WHAT IT IS FOR, here: light that follows the day. Bright, cold light in the morning to set the body
// clock; warm, dim light in the evening so it is not pushed back again. Two automations do that at the
// wearer's times, and four scenes do it by hand.

/// One bulb, as remembered.
struct WizBulb: Codable, Identifiable, Equatable, Hashable {
    /// The bulb's MAC where known, else its address.
    let id: String
    var name: String
    var ip: String
}

/// What a bulb says it is doing.
struct WizPilot: Equatable {
    var on: Bool
    var dimming: Int?
    var temp: Int?
}

/// A light setting for every bulb at once.
enum WizScene: String, CaseIterable, Identifiable {
    case daylight, focus, evening, windDown, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daylight: return "Daylight"
        case .focus: return "Focus"
        case .evening: return "Evening"
        case .windDown: return "Wind-down"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .daylight: return "sun.max.fill"
        case .focus: return "lightbulb.max.fill"
        case .evening: return "sunset.fill"
        case .windDown: return "moon.fill"
        case .off: return "power"
        }
    }

    /// `setPilot` parameters. Colour temperatures in kelvin, brightness in percent.
    var params: [String: Any] {
        switch self {
        case .daylight: return ["state": true, "temp": 6500, "dimming": 100]
        case .focus: return ["state": true, "temp": 4600, "dimming": 100]
        case .evening: return ["state": true, "temp": 2700, "dimming": 55]
        case .windDown: return ["state": true, "temp": 2200, "dimming": 15]
        case .off: return ["state": false]
        }
    }
}

// MARK: - The protocol

enum WizClient {
    static let port: NWEndpoint.Port = 38899

    /// Send one JSON message to `ip` and return the reply's bytes, or nil on no answer within `timeout`.
    static func request(_ ip: String, method: String, params: [String: Any] = [:],
                        timeout: TimeInterval = 1.5) async -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .udp)
            let once = ResumeOnce()
            let finish: @Sendable (Data?) -> Void = { data in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: data)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: body, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    connection.receiveMessage { content, _, _, _ in finish(content) }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// The bulb's state, or nil when it does not answer.
    static func pilot(_ ip: String) async -> (pilot: WizPilot, mac: String?)? {
        guard let data = await request(ip, method: "getPilot"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [String: Any] else { return nil }
        let pilot = WizPilot(on: result["state"] as? Bool ?? false,
                             dimming: (result["dimming"] as? NSNumber)?.intValue,
                             temp: (result["temp"] as? NSNumber)?.intValue)
        return (pilot, result["mac"] as? String)
    }

    /// Set the bulb. True when it acknowledged.
    @discardableResult
    static func set(_ ip: String, _ params: [String: Any]) async -> Bool {
        guard let data = await request(ip, method: "setPilot", params: params),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [String: Any] else { return false }
        return result["success"] as? Bool ?? true
    }

    /// Every address on the phone's own /24 that answers as a WiZ bulb: address → MAC.
    static func search() async -> [(ip: String, mac: String?)] {
        guard let prefix = localSubnetPrefix() else { return [] }
        var found: [(ip: String, mac: String?)] = []
        // In batches, so two hundred sockets are not open at once.
        for batchStart in stride(from: 1, through: 254, by: 32) {
            let batch = batchStart..<min(batchStart + 32, 255)
            await withTaskGroup(of: (ip: String, mac: String?)?.self) { group in
                for host in batch {
                    let ip = "\(prefix).\(host)"
                    group.addTask {
                        guard let answer = await pilot(ip) else { return nil }
                        return (ip: ip, mac: answer.mac)
                    }
                }
                for await hit in group { if let hit { found.append(hit) } }
            }
        }
        return found.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// The first three octets of the Wi-Fi address, e.g. "192.168.1".
    static func localSubnetPrefix() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidate: String?
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4, ip != "127.0.0.1" else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if name == "en0" { return prefix }
            if candidate == nil, name.hasPrefix("en") { candidate = prefix }
        }
        return candidate
    }
}

/// Resumes a continuation exactly once, from whichever of the answer, the failure or the timeout is first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - The store

@MainActor
final class WizLightStore: ObservableObject {
    static let shared = WizLightStore()

    @Published private(set) var bulbs: [WizBulb] = []
    @Published private(set) var pilots: [String: WizPilot] = [:]
    @Published private(set) var searching = false

    // The two automations: the morning's daylight and the evening's wind-down, each at its own time.
    @Published var wakeLightOn: Bool { didSet { d.set(wakeLightOn, forKey: K.wakeOn) } }
    @Published var wakeMinute: Int { didSet { d.set(wakeMinute, forKey: K.wakeMinute) } }
    @Published var windDownOn: Bool { didSet { d.set(windDownOn, forKey: K.windOn) } }
    @Published var windDownMinute: Int { didSet { d.set(windDownMinute, forKey: K.windMinute) } }

    private let d = UserDefaults.standard
    private enum K {
        static let bulbs = "wiz.bulbs.v1"
        static let wakeOn = "wiz.auto.wake.on", wakeMinute = "wiz.auto.wake.minute"
        static let windOn = "wiz.auto.wind.on", windMinute = "wiz.auto.wind.minute"
        static let wakeRan = "wiz.auto.wake.ran", windRan = "wiz.auto.wind.ran"
    }
    private var automating = false

    private init() {
        wakeLightOn = d.bool(forKey: K.wakeOn)
        wakeMinute = d.object(forKey: K.wakeMinute) as? Int ?? 6 * 60 + 30
        windDownOn = d.bool(forKey: K.windOn)
        windDownMinute = d.object(forKey: K.windMinute) as? Int ?? 21 * 60 + 30
        if let data = d.data(forKey: K.bulbs), let stored = try? JSONDecoder().decode([WizBulb].self, from: data) {
            bulbs = stored
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bulbs) { d.set(data, forKey: K.bulbs) }
    }

    /// Add the bulb at `ip`, if it answers. Returns whether it did.
    @discardableResult
    func add(ip: String, name: String? = nil) async -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard let answer = await WizClient.pilot(trimmed) else { return false }
        let id = answer.mac ?? trimmed
        if let i = bulbs.firstIndex(where: { $0.id == id }) {
            bulbs[i].ip = trimmed
        } else {
            bulbs.append(WizBulb(id: id, name: name ?? "Light \(bulbs.count + 1)", ip: trimmed))
        }
        pilots[id] = answer.pilot
        persist()
        return true
    }

    func remove(_ bulb: WizBulb) {
        bulbs.removeAll { $0.id == bulb.id }
        pilots[bulb.id] = nil
        persist()
    }

    func rename(_ bulb: WizBulb, to name: String) {
        guard let i = bulbs.firstIndex(where: { $0.id == bulb.id }) else { return }
        bulbs[i].name = name
        persist()
    }

    /// Search the subnet and add everything that answers.
    func search() async -> Int {
        searching = true
        defer { searching = false }
        let found = await WizClient.search()
        var added = 0
        for hit in found where !bulbs.contains(where: { $0.id == (hit.mac ?? hit.ip) }) {
            if await add(ip: hit.ip) { added += 1 }
        }
        return added
    }

    /// Read every bulb's current state.
    func refresh() async {
        for bulb in bulbs {
            if let answer = await WizClient.pilot(bulb.ip) { pilots[bulb.id] = answer.pilot }
        }
    }

    func set(_ bulb: WizBulb, on: Bool? = nil, dimming: Int? = nil, temp: Int? = nil) async {
        var params: [String: Any] = [:]
        if let on { params["state"] = on }
        if let dimming { params["dimming"] = min(100, max(10, dimming)); params["state"] = true }
        if let temp { params["temp"] = min(6500, max(2200, temp)); params["state"] = true }
        guard !params.isEmpty else { return }
        await WizClient.set(bulb.ip, params)
        if let answer = await WizClient.pilot(bulb.ip) { pilots[bulb.id] = answer.pilot }
    }

    func apply(_ scene: WizScene) async {
        for bulb in bulbs { await WizClient.set(bulb.ip, scene.params) }
        await refresh()
    }

    // MARK: Automations

    /// Check the two automations once a minute for as long as the app runs — which, with the strap
    /// connected, is in the background too. Each fires at most once a day.
    func startAutomation() {
        guard !automating else { return }
        automating = true
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.runDueAutomations()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func runDueAutomations(now: Date = Date()) async {
        guard !bulbs.isEmpty else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = Repository.localDayKey(now)
        // Within fifteen minutes of the set time, so a phone that slept through the exact minute still
        // turns the lights; never after that, so an evening scene cannot fire at midnight.
        func due(_ on: Bool, _ at: Int, _ ranKey: String) -> Bool {
            on && minute >= at && minute < at + 15 && d.string(forKey: ranKey) != today
        }
        if due(wakeLightOn, wakeMinute, K.wakeRan) {
            d.set(today, forKey: K.wakeRan)
            await apply(.daylight)
        }
        if due(windDownOn, windDownMinute, K.windRan) {
            d.set(today, forKey: K.windRan)
            await apply(.windDown)
        }
    }
}
