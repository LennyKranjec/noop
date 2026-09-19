import Foundation
import StrandAnalytics

// StrainCalibration.swift — the app side of O8: WHICH days calibrate NOOP's Effort onto WHOOP's 0–21
// Day Strain, where the result lives, and how often it is refreshed. The math is
// `EffortStrainCalibration` (StrandAnalytics, unit-tested there).
//
// PAIRS. A day counts when it has BOTH the app's own Effort from the COMPUTED lane (`noopRecentDays`,
// 0–100 — never the merged day, which can carry an imported WHOOP strain rescaled ×100/21 and would
// calibrate WHOOP against itself) AND WHOOP's own day strain from the cloud source (`whoopRecentDays`,
// 0–21). Today is left out: both sides are still accruing, at different times of day.
//
// STORAGE. JSON in UserDefaults, refreshed at most once per local day. Reads are served from an in-memory
// copy behind a lock, because `UnitFormatter.effortValue` — which every Effort read-out routes through —
// asks for it on every render, from whatever thread is formatting.
//
// FALLBACK. No calibration (fewer than `EffortStrainCalibration.minPairs` paired days, or a fit that was
// refused) means the linear ×21/100 the app has always used, byte-identical to before.

enum StrainCalibration {

    static let storageKey = "effort.whoopCalibration.v1"
    static let refreshedDayKey = "effort.whoopCalibration.refreshedDay"
    /// How far back paired days are looked for. Long enough to collect ≥ 10 pairs for an occasional
    /// WHOOP-cloud user; short enough that an old scoring recipe ages out of the fit.
    static let lookbackDays = 120

    private static let lock = NSLock()
    private static var loaded = false
    private static var cached: EffortStrainCalibration?

    /// The active calibration, or nil for the linear fallback.
    static var current: EffortStrainCalibration? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            cached = decode(UserDefaults.standard.data(forKey: storageKey))
            loaded = true
        }
        return cached
    }

    /// Replace (or with nil, clear) the persisted calibration.
    static func store(_ calibration: EffortStrainCalibration?) {
        lock.lock()
        cached = calibration
        loaded = true
        lock.unlock()
        if let calibration, let data = try? JSONEncoder().encode(calibration) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// NOOP Effort (0–100) → WHOOP's 0–21. Calibrated when a calibration exists, else the linear ×21/100
    /// (unclamped, exactly the old `UnitFormatter.effortValue`).
    static func strain21(effort100: Double) -> Double {
        guard let cal = current else { return effort100 * EffortStrainCalibration.linearFactor }
        return cal.strain21(effort100: effort100)
    }

    /// The inverse: a WHOOP-scale strain (e.g. the optimal-strain ceiling) → the Effort (0–100) that maps
    /// onto it. Linear ×100/21 without a calibration.
    static func effort100(strain21: Double) -> Double {
        guard let cal = current else { return strain21 / EffortStrainCalibration.linearFactor }
        return cal.effort100(strain21: strain21)
    }

    /// Refit from the store, at most once per local day. Cheap when already done today (one defaults read).
    ///
    /// When BOTH reads come back empty — no store yet, or a user who never connected the WHOOP cloud — the
    /// persisted calibration is left alone and the day is not marked, so a transient store miss can never
    /// wipe a good calibration. Otherwise the fit's result replaces it, nil included: a wearer whose paired
    /// days fell under the minimum goes back to the honest linear mapping.
    @MainActor
    static func refreshIfDue(repo: Repository, now: Date = Date()) async {
        let today = Repository.localDayKey(now)
        guard UserDefaults.standard.string(forKey: refreshedDayKey) != today else { return }
        let own = await repo.noopRecentDays(days: lookbackDays)
        let whoop = await repo.whoopRecentDays(days: lookbackDays)
        guard !own.isEmpty || !whoop.isEmpty else { return }
        let paired = pairs(own: own.map { (day: $0.day, effort: $0.effort) },
                           whoop: whoop.map { (day: $0.day, strain: $0.strain) },
                           excludingDay: today)
        store(EffortStrainCalibration.fit(paired))
        UserDefaults.standard.set(today, forKey: refreshedDayKey)
    }

    /// Join the two lanes by day key. Pure, so it is testable without a store.
    static func pairs(own: [(day: String, effort: Double?)],
                      whoop: [(day: String, strain: Double?)],
                      excludingDay: String? = nil) -> [(effort100: Double, strain21: Double)] {
        var strainByDay: [String: Double] = [:]
        for w in whoop {
            if let s = w.strain { strainByDay[w.day] = s }
        }
        var out: [(effort100: Double, strain21: Double)] = []
        for o in own where o.day != excludingDay {
            guard let e = o.effort, let s = strainByDay[o.day] else { continue }
            out.append((effort100: e, strain21: s))
        }
        return out
    }

    private static func decode(_ data: Data?) -> EffortStrainCalibration? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(EffortStrainCalibration.self, from: data)
    }
}
