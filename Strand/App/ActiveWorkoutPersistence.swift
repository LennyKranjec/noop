import Foundation
import WhoopProtocol

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// A manual workout used to live ONLY in `AppModel.activeWorkout` (in memory), so if iOS killed the app
/// mid-session — a backgrounded phone under memory pressure — the whole session was lost and could never
/// be ended + saved. (Apple has no GPS-route session like Android's `GpsSession`; every manual workout
/// here is the "non-GPS" case, so they all need this.) This is the Apple analogue of Android's
/// `ActiveWorkoutStore`/`ActiveWorkoutPersistence`, read back on launch so an interrupted session can
/// still be ended and saved.
///
/// Two parts, split by how often they change:
///   - `Header` (start, sport, pause state, zone lock): a tiny JSON value in `UserDefaults`, written on
///     start / pause / resume / lock — never per sample.
///   - The HR samples: appended to a flat binary file (`SampleLog`, 12 bytes a sample) as they are
///     captured. The running stats (avg / peak / Effort) are NOT stored; the rehydrate recomputes them from
///     the samples with the same functions the live capture uses.
/// The old layout JSON-encoded the WHOLE session (every sample so far) into `UserDefaults` on every
/// captured sample — at 1 Hz, re-serializing and re-writing a growing plist each second of a workout.
///
/// LEGACY: a session in flight across the update was written in the old one-blob `Snapshot` format under
/// `defaultsKey`. `load` still reads it (the header key wins when both exist), and the caller migrates it
/// into the new layout. The codec is pure so the round-trips are unit-testable.
enum ActiveWorkoutPersistence {

    /// The LEGACY durable shape (the whole session in one `Codable` value). Read for migration only.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds (stable across encodings; `AppModel` maps to/from `Date`).
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrain: Double
        var pausedAtSec: Int? = nil
        var pausedDurationSec: Int? = nil
        /// The ZONE LOCK target (1...5) the wearer set for this session, nil when unlocked. Optional, so a
        /// snapshot written before the lock existed decodes as "unlocked" rather than failing.
        var lockedZone: Int? = nil
    }

    /// Everything about the session except its samples — the part that changes only on user action.
    struct Header: Codable, Equatable {
        var startSec: Int
        var sport: String
        var pausedAtSec: Int? = nil
        var pausedDurationSec: Int? = nil
        var lockedZone: Int? = nil
    }

    /// What `load` hands back: the header, the samples, and whether it came from the legacy blob (the
    /// caller then rewrites it in the new layout).
    struct Restored: Equatable {
        var header: Header
        var samples: [HRSample]
        var fromLegacy: Bool
    }

    /// The LEGACY `UserDefaults` key (JSON-encoded `Snapshot`). Namespaced like `moments`/`sleepMarks`.
    static let defaultsKey = "noop.activeWorkout"
    /// The `UserDefaults` key of the current layout's JSON-encoded `Header`.
    static let headerKey = "noop.activeWorkout.header"

    // MARK: - Legacy snapshot codec

    /// Encode a legacy snapshot to JSON `Data` (tests + migration fixtures).
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot from JSON `Data`, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no
    /// in-flight session" rather than reviving a broken card.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop any out-of-range persisted HR samples (a real bpm + a positive ts only) — never trust the
        // blob to be clean. Parity with the Android decoder's 1...300 bpm / ts > 0 gate.
        let samples = raw.samples.filter(isPlausible)
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrain: raw.liveStrain.isFinite ? max(0, raw.liveStrain) : 0,
            pausedAtSec: raw.pausedAtSec.flatMap { $0 > 0 ? $0 : nil },
            pausedDurationSec: raw.pausedDurationSec.map { max(0, $0) },
            lockedZone: raw.lockedZone.flatMap { (1...5).contains($0) ? $0 : nil },
        )
    }

    // MARK: - Header codec

    /// Sorted keys, so equal headers encode to equal bytes and `storeHeader` can skip an unchanged write.
    static func encodeHeader(_ header: Header) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(header)
    }

    /// Same bound-checks as the legacy `decode`, for the same reason.
    static func decodeHeader(_ data: Data?) -> Header? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        return Header(
            startSec: raw.startSec,
            sport: raw.sport,
            pausedAtSec: raw.pausedAtSec.flatMap { $0 > 0 ? $0 : nil },
            pausedDurationSec: raw.pausedDurationSec.map { max(0, $0) },
            lockedZone: raw.lockedZone.flatMap { (1...5).contains($0) ? $0 : nil })
    }

    /// A real bpm + a positive ts only. Parity with the Android decoder's 1...300 bpm / ts > 0 gate.
    static func isPlausible(_ s: HRSample) -> Bool {
        s.ts > 0 && (1...300).contains(s.bpm)
    }

    /// Keep one sample per whole second, the LATER reading winning — the rule the live capture applies. The
    /// log only ever appends, so a same-second overwrite lands in it as a second record; this folds it back.
    /// Also folds the same-second repeats a pre-fix legacy blob may still carry.
    static func collapseSameSecond(_ samples: [HRSample]) -> [HRSample] {
        var out: [HRSample] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            if let last = out.last, last.ts == s.ts { out[out.count - 1] = s } else { out.append(s) }
        }
        return out
    }

    // MARK: - Store / load / clear

    /// Persist the header, skipping the write when the stored bytes already match. Called on start and on
    /// every pause / resume / zone-lock change — never per sample.
    static func storeHeader(_ header: Header, into defaults: UserDefaults = .standard) {
        guard let data = encodeHeader(header), defaults.data(forKey: headerKey) != data else { return }
        defaults.set(data, forKey: headerKey)
    }

    /// Read back the in-flight session: the current layout when its header is stored, else the legacy blob.
    /// nil when neither is stored (or what is stored is corrupt).
    static func load(from defaults: UserDefaults = .standard, log: SampleLog) -> Restored? {
        if let header = decodeHeader(defaults.data(forKey: headerKey)) {
            let samples = collapseSameSecond(log.readAll().filter(isPlausible))
            return Restored(header: header, samples: samples, fromLegacy: false)
        }
        guard let legacy = decode(defaults.data(forKey: defaultsKey)) else { return nil }
        return Restored(
            header: Header(startSec: legacy.startSec, sport: legacy.sport, pausedAtSec: legacy.pausedAtSec,
                           pausedDurationSec: legacy.pausedDurationSec, lockedZone: legacy.lockedZone),
            samples: collapseSameSecond(legacy.samples),
            fromLegacy: true)
    }

    /// Drop the legacy blob once its session has been rewritten in the current layout.
    static func clearLegacy(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Clear everything — called the instant a session ends (saved or discarded).
    static func clear(from defaults: UserDefaults = .standard, log: SampleLog?) {
        defaults.removeObject(forKey: headerKey)
        defaults.removeObject(forKey: defaultsKey)
        log?.remove()
    }

    // MARK: - Sample log

    /// The session's HR samples as a flat file of fixed 12-byte little-endian records (Int64 ts, Int32
    /// bpm), appended through one open handle. No fsync: a kill loses at most what the OS had not yet
    /// flushed, and a torn trailing record is ignored on read and trimmed before the next append.
    final class SampleLog {
        static let recordSize = 12

        let url: URL?
        private var handle: FileHandle?

        /// `url` nil (Application Support unavailable) makes every call a no-op; the header still persists.
        init(url: URL? = SampleLog.defaultURL()) {
            self.url = url
        }

        deinit {
            try? handle?.close()
        }

        /// `<AppSupport>/OpenWhoop/active-workout-samples.bin`, next to the app's other on-device logs.
        static func defaultURL() -> URL? {
            let fm = FileManager.default
            guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent("OpenWhoop", isDirectory: true) else { return nil }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("active-workout-samples.bin")
        }

        /// Append one captured sample.
        func append(_ sample: HRSample) {
            guard let h = openForAppend() else { return }
            do {
                try h.write(contentsOf: Self.encode([sample]))
            } catch {
                closeHandle()
            }
        }

        /// Replace the whole file with `samples` (start of a session: empty; legacy migration: its samples).
        /// Returns whether the write landed.
        @discardableResult
        func replaceAll(_ samples: [HRSample]) -> Bool {
            closeHandle()
            guard let url else { return false }
            do {
                try Self.encode(samples).write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        /// Every whole record in the file, in capture order; [] when there is no file.
        func readAll() -> [HRSample] {
            guard let url, let data = try? Data(contentsOf: url) else { return [] }
            return Self.decode(data)
        }

        /// Delete the file.
        func remove() {
            closeHandle()
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }

        private func closeHandle() {
            try? handle?.close()
            handle = nil
        }

        private func openForAppend() -> FileHandle? {
            if let handle { return handle }
            guard let url else { return nil }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return nil }
            do {
                // A kill mid-write can leave a torn record; cut it so every later record stays aligned.
                // `truncate(atOffset:)` also leaves the file pointer there, i.e. at the new end.
                let end = try h.seekToEnd()
                let aligned = end - end % UInt64(Self.recordSize)
                if aligned != end { try h.truncate(atOffset: aligned) }
            } catch {
                try? h.close()
                return nil
            }
            handle = h
            return h
        }

        static func encode(_ samples: [HRSample]) -> Data {
            var data = Data(capacity: samples.count * recordSize)
            for s in samples {
                withUnsafeBytes(of: Int64(s.ts).littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: Int32(clamping: s.bpm).littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        /// Decode every WHOLE record; a torn trailing partial record is ignored.
        static func decode(_ data: Data) -> [HRSample] {
            let n = data.count / recordSize
            var out: [HRSample] = []
            out.reserveCapacity(n)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<n {
                    let o = i * recordSize
                    let ts = Int64(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int64.self))
                    let bpm = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: Int32.self))
                    out.append(HRSample(ts: Int(ts), bpm: Int(bpm)))
                }
            }
            return out
        }
    }
}
