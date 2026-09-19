import Foundation

// HealthWriteFingerprint.swift — skip Apple Health write-back passes that would rewrite what is already there.
//
// Every write-back pass (each strap offload, each foreground sync, each background refresh) used to DELETE
// and re-SAVE 48 h of 1-minute heart rate, 14 days of vitals and sleep, and every workout of 14 days, even
// when not one value had changed. HealthKit deletes and saves are real work (a database transaction, sync
// to the Watch and iCloud), so a pass that changes nothing is pure energy cost.
//
// The fix is a CONTENT fingerprint per kind: a stable FNV-1a hash over the exact values a pass would write
// (never `hashValue`, which is seeded per process). When it matches the fingerprint of the last pass that
// wrote successfully, Health already holds exactly those samples and the delete + save is skipped. The
// fingerprint is CLEARED before any delete/save and stored only after the whole kind saved, so a pass that
// fails half-way is never mistaken for a completed one: the next pass rewrites, exactly as before.
//
// Heart rate gets a finer record (`HealthHRWriteRecord`): one digest per 1-minute bucket, so a pass whose
// only change is new minutes at the end APPENDS them, and a pass with an earlier change rewrites from the
// first changed minute instead of the whole window.
//
// Pure Foundation, no HealthKit, so it is unit-tested on the macOS test host.

/// A stable 64-bit FNV-1a hash. Every value is fed as fixed-width little-endian bytes (strings as UTF-8
/// plus their length), so the hash depends only on the values, never on the process or platform.
struct HealthWriteFingerprint: Equatable {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    init() {}

    /// A hasher already primed with `seed` (the kind + whatever scopes it, e.g. the device ids).
    init(seed: [String]) {
        for s in seed { add(s) }
    }

    private mutating func byte(_ b: UInt8) {
        value ^= UInt64(b)
        value = value &* Self.prime
    }

    mutating func add(_ v: UInt64) {
        for i in 0..<8 { byte(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    mutating func add(_ v: Int) { add(UInt64(bitPattern: Int64(v))) }

    /// The exact bit pattern, so any change in a written value changes the hash.
    mutating func add(_ v: Double) { add(v.bitPattern) }

    mutating func add(_ d: Date) { add(d.timeIntervalSince1970) }

    mutating func add(_ b: Bool) { byte(b ? 1 : 0) }

    /// UTF-8 bytes then the byte count, so ("ab","c") and ("a","bc") hash differently.
    mutating func add(_ s: String) {
        var count = 0
        for b in s.utf8 { byte(b); count += 1 }
        add(count)
    }

    /// Persisted form: fixed-width lowercase hex.
    var hex: String {
        let raw = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}

/// The per-kind fingerprints of the last SUCCESSFUL write, in UserDefaults.
enum HealthWriteFingerprintStore {
    enum Kind: String, CaseIterable {
        case vitals, sleep, workouts
    }

    static func key(_ kind: Kind) -> String { "hkWriteFingerprint.v1.\(kind.rawValue)" }
    static let hrRecordKey = "hkWriteFingerprint.v1.hrSeries"

    static func matches(_ kind: Kind, _ fp: HealthWriteFingerprint, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key(kind)) == fp.hex
    }

    static func store(_ kind: Kind, _ fp: HealthWriteFingerprint, defaults: UserDefaults = .standard) {
        defaults.set(fp.hex, forKey: key(kind))
    }

    static func clear(_ kind: Kind, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(kind))
    }

    /// Forget every fingerprint (re-authorization, the #1503 sweep): the next pass rewrites everything.
    static func clearAll(defaults: UserDefaults = .standard) {
        for kind in Kind.allCases { clear(kind, defaults: defaults) }
        HealthHRWriteRecord.clear(defaults: defaults)
    }
}

/// What the last successful heart-rate write left in Health: for the window starting at `from`, one
/// (bucket ts, digest of the exact sample written) per minute, oldest first. `seed` scopes it (format
/// version + device ids), so a record from another scope never matches.
struct HealthHRWriteRecord: Equatable {
    struct Entry: Equatable {
        let ts: Int
        let digest: UInt64
    }

    let seed: UInt64
    let from: Int
    let entries: [Entry]

    /// The digest of one written sample: its bucket, its exact end (clamped to "now" at the live edge)
    /// and its exact bpm. The seed does not enter it; the record carries the seed once.
    static func digest(ts: Int, endTs: Int, bpm: Double) -> UInt64 {
        var h = HealthWriteFingerprint()
        h.add(ts)
        h.add(endTs)
        h.add(bpm)
        return h.value
    }

    // MARK: Persistence (compact little-endian blob: seed, from, then ts + digest per entry)

    var encoded: Data {
        var out = Data(capacity: 16 + entries.count * 16)
        func put(_ v: UInt64) { for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        put(seed)
        put(UInt64(bitPattern: Int64(from)))
        for e in entries {
            put(UInt64(bitPattern: Int64(e.ts)))
            put(e.digest)
        }
        return out
    }

    init(seed: UInt64, from: Int, entries: [Entry]) {
        self.seed = seed
        self.from = from
        self.entries = entries
    }

    init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes.count % 16 == 0 else { return nil }
        func get(_ at: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return v
        }
        seed = get(0)
        from = Int(Int64(bitPattern: get(8)))
        var list: [Entry] = []
        list.reserveCapacity(bytes.count / 16 - 1)
        var at = 16
        while at < bytes.count {
            list.append(Entry(ts: Int(Int64(bitPattern: get(at))), digest: get(at + 8)))
            at += 16
        }
        entries = list
    }

    static func load(defaults: UserDefaults = .standard) -> HealthHRWriteRecord? {
        defaults.data(forKey: HealthWriteFingerprintStore.hrRecordKey).flatMap { HealthHRWriteRecord(encoded: $0) }
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(encoded, forKey: HealthWriteFingerprintStore.hrRecordKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: HealthWriteFingerprintStore.hrRecordKey)
    }

    // MARK: Planning

    enum Plan: Equatable {
        /// Health already holds exactly these samples: write nothing.
        case skip
        /// Everything already written is unchanged; save `entries[fromIndex...]` (all newer), delete nothing.
        case append(fromIndex: Int)
        /// Delete OUR samples starting at or after `deleteFromTs`, then save `entries[fromIndex...]`.
        case rewrite(deleteFromTs: Int, fromIndex: Int)
        /// No usable record: the original full-window delete + rewrite.
        case full
    }

    /// Decide how little of the window has to be written for Health to end up holding exactly `entries`.
    ///
    /// Sound because every pass leaves Health holding, for every sample starting in its window, exactly
    /// its own entries (the full path deletes the window; the partial paths prove the untouched prefix
    /// equal), and the window start never moves backwards. So the previous record describes Health for
    /// every bucket that can overlap this window, provided it covered this window's start (`from`).
    ///
    /// The comparison region is every bucket that overlaps the window (`ts > windowStart - 60`), which is
    /// what the full path's overlap delete would reach; a bucket the record has and `entries` lacks is a
    /// change (the full path would have deleted it without rewriting it).
    static func plan(previous: HealthHRWriteRecord?, seed: UInt64, windowStart: Int,
                     entries: [Entry], bucketSeconds: Int = 60) -> Plan {
        guard let previous, previous.seed == seed, previous.from <= windowStart else { return .full }
        let old = previous.entries.filter { $0.ts > windowStart - bucketSeconds }
        let common = min(old.count, entries.count)
        var i = 0
        while i < common, old[i] == entries[i] { i += 1 }
        if i < common {
            return .rewrite(deleteFromTs: min(old[i].ts, entries[i].ts), fromIndex: i)
        }
        if old.count > entries.count {
            // Trailing minutes Health holds that are no longer in the store: delete them.
            return .rewrite(deleteFromTs: old[entries.count].ts, fromIndex: entries.count)
        }
        if entries.count > old.count { return .append(fromIndex: old.count) }
        return .skip
    }
}
