import Foundation
import StrandAnalytics

// LevelBaselineStore.swift — keeping the yardstick still.
//
// Swift twin of the Android `LevelBaselineStore`. The baselines are derived once and then persisted
// verbatim. Every later read returns exactly what was written, so the level means the same thing in
// December as it did in March.
//
// WRITTEN ONCE, DELIBERATELY. `resolve` derives only when nothing is stored; it never re-derives, even
// when far more history is now available. A caller that wants a fresh scale has to say so through
// `refreeze`, which is a visible, explicit act — the wearer should know their yardstick moved, because
// every level they remember was measured against the old one.
//
// STORED AS NUMBERS, NOT AS A SNAPSHOT DATE. What matters is the scale itself; when it was taken is
// recorded alongside only so the app can tell the wearer how thin the history behind it was.

enum LevelBaselineStore {

    private static let key = "level.baselines"
    private static let frozenAtKey = "level.baselinesFrozenAt"

    private struct Stored: Codable {
        let mean: Double
        let sd: Double
        let min: Double
        let max: Double
    }

    /// The frozen baselines, deriving and storing them on the first call.
    ///
    /// `history` is only consulted when there is nothing stored, so the (potentially expensive) read of
    /// a whole metric history can be a closure the caller never pays for on a warm start.
    static func resolve(history: () -> [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        if let stored = read() { return stored }
        let derived = LevelBaselines.deriveAll(history: history())
        write(derived)
        return derived
    }

    /// The stored set, or nil when the scale has never been frozen.
    static func read() -> [LevelMetric: Baseline]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return nil }
        var out: [LevelMetric: Baseline] = [:]
        for metric in LevelMetric.allCases {
            // A metric missing from the payload falls back to the table rather than being dropped — a
            // set with a hole in it would silently stop scoring that component, and the wearer would
            // see their level move for no reason they could observe.
            if let s = decoded[metric.rawValue] {
                out[metric] = Baseline(mean: s.mean, sd: s.sd, min: s.min, max: s.max)
            } else if let fallback = LevelBaselines.table[metric] {
                out[metric] = fallback
            }
        }
        return out.count == LevelMetric.allCases.count ? out : nil
    }

    /// When the scale was frozen, or nil when it never was.
    static var frozenAt: Date? {
        let t = UserDefaults.standard.double(forKey: frozenAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Derive the scale again from current history, replacing what was stored.
    ///
    /// The ONLY way the yardstick moves. Every level the wearer has seen was measured against the old
    /// scale, so a caller must treat this as a visible change and not as maintenance.
    @discardableResult
    static func refreeze(history: [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        let derived = LevelBaselines.deriveAll(history: history)
        write(derived)
        return derived
    }

    private static func write(_ baselines: [LevelMetric: Baseline]) {
        var payload: [String: Stored] = [:]
        for (metric, b) in baselines {
            payload[metric.rawValue] = Stored(mean: b.mean, sd: b.sd, min: b.min, max: b.max)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: frozenAtKey)
    }
}
