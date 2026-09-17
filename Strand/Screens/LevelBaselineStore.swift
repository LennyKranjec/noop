import Foundation
import StrandAnalytics

// LevelBaselineStore.swift — keeping the yardstick still.
//
// The baselines are derived from the wearer's own history and then persisted verbatim, so the level
// means the same thing in December as it did in March.
//
// FROZEN PER METRIC, ONCE EACH METRIC IS WORTH FREEZING. A metric with fewer than two weeks of readings
// is scored against the table for now and NOT written down; the first load on which it has enough of
// its own history freezes it. That matters more than it used to: daytime calm, for instance, only
// starts being recorded when this build first runs, and freezing it on day one would measure it against
// a stranger forever.
//
// v3: the level was rebuilt with no ceiling and new inputs (see `LevelEngine`); every older scale was
// for metrics that no longer exist.

enum LevelBaselineStore {

    private static let key = "level.baselines.v3"
    private static let frozenAtKey = "level.baselinesFrozenAt.v3"

    private struct Stored: Codable {
        let mean: Double
        let sd: Double
        let min: Double
        let max: Double
    }

    /// The baselines: every frozen metric as stored, every other one derived from `history` now — and
    /// frozen on the spot if its history has become deep enough.
    static func resolve(history: () -> [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        var stored = readStored()
        var out: [LevelMetric: Baseline] = [:]
        var missing: [LevelMetric] = []
        for metric in LevelMetric.allCases {
            if let s = stored[metric.rawValue] {
                out[metric] = Baseline(mean: s.mean, sd: s.sd, min: s.min, max: s.max)
            } else {
                missing.append(metric)
            }
        }
        guard !missing.isEmpty else { return out }

        let readings = history()
        var changed = false
        for metric in missing {
            let h = readings[metric] ?? []
            let b = LevelBaselines.derive(metric, history: h)
            out[metric] = b
            if LevelBaselines.isDerivable(h) {
                stored[metric.rawValue] = Stored(mean: b.mean, sd: b.sd, min: b.min, max: b.max)
                changed = true
            }
        }
        if changed { write(stored) }
        return out
    }

    /// Whether every metric's scale is frozen.
    static var isFrozen: Bool { readStored().count == LevelMetric.allCases.count }

    static var frozenAt: Date? {
        let t = UserDefaults.standard.double(forKey: frozenAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Derive every metric again from current history, replacing what was stored. The ONLY way a frozen
    /// yardstick moves.
    @discardableResult
    static func refreeze(history: [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        var stored: [String: Stored] = [:]
        var out: [LevelMetric: Baseline] = [:]
        for metric in LevelMetric.allCases {
            let h = history[metric] ?? []
            let b = LevelBaselines.derive(metric, history: h)
            out[metric] = b
            if LevelBaselines.isDerivable(h) {
                stored[metric.rawValue] = Stored(mean: b.mean, sd: b.sd, min: b.min, max: b.max)
            }
        }
        write(stored)
        return out
    }

    private static func readStored() -> [String: Stored] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ stored: [String: Stored]) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: frozenAtKey)
    }
}
