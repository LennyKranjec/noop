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
//
// v5 — THE RE-FREEZE. Every v4 scale was frozen once a metric had 14 readings, and a reading is a 7-day
// rolling mean taken one per calendar day, so fourteen of them overlap into about two independent weeks.
// The 5th/95th percentiles of that sample are what 0 and 100 mean for the wearer, permanently, and two
// weeks is not enough to place them. `LevelBaselines.minSamples` is now 42; the stored key moves with it
// so that every v4 scale is DISCARDED and derived again from the history as it stands today. A metric
// that now has 42 readings re-freezes at once on a better estimate; one that does not falls back to the
// table and freezes when it has them. `samples` is recorded from here on so a future correction can tell
// how much history a scale was frozen from without having to throw all of them away again.

enum LevelBaselineStore {

    private static let key = "level.baselines.v5"
    private static let frozenAtKey = "level.baselinesFrozenAt.v5"

    private struct Stored: Codable {
        let mean: Double
        let sd: Double
        let min: Double
        let max: Double
        /// How many readings this scale was frozen from. Absent on anything written before v5.
        var samples: Int? = nil
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
                stored[metric.rawValue] = Stored(mean: b.mean, sd: b.sd, min: b.min, max: b.max,
                                                 samples: h.filter(\.isFinite).count)
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
    /// yardstick moves — and it moves together with the ledger: `LevelBarModel` calls this once per ledger
    /// epoch (`LevelLedger.currentEpoch`), right before the ledger is emptied, so the days written from here
    /// on are scored against baselines built from the SAME re-scored nights.
    ///
    /// `resolve` is the other reader, and it is only ever called when a day is about to be scored.
    @discardableResult
    static func refreeze(history: [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        var stored: [String: Stored] = [:]
        var out: [LevelMetric: Baseline] = [:]
        for metric in LevelMetric.allCases {
            let h = history[metric] ?? []
            let b = LevelBaselines.derive(metric, history: h)
            out[metric] = b
            if LevelBaselines.isDerivable(h) {
                stored[metric.rawValue] = Stored(mean: b.mean, sd: b.sd, min: b.min, max: b.max,
                                                 samples: h.filter(\.isFinite).count)
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
