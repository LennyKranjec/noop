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
//
// E4 — ONE RECIPE PER FIT. The stored days only carry the CURRENT Effort recipe once the one-shot
// full-history rescore (`IntelligenceEngine.nightlyMetricsRescoreFlagKey`) has finished. The first Today
// load used to fit before that pass ended — mixing pre-O6 and post-O6 Effort in one curve — and then kept
// that fit for the rest of the day. Now: no fit at all until the rescore flag is up; ONE refit the first
// refresh after it goes up (whatever day it is); daily after that. Every stored calibration is tagged with
// `strainRecipeVersion`, and a calibration from an older recipe is ignored (linear fallback) rather than
// applied to numbers it was never fitted on.

enum StrainCalibration {

    static let storageKey = "effort.whoopCalibration.v1"
    static let refreshedDayKey = "effort.whoopCalibration.refreshedDay"
    /// E4: the `strainRecipeVersion` the stored calibration was fitted against. Absent (0) = pre-E4.
    static let recipeKey = "effort.whoopCalibration.recipe"
    /// E4: "<rescore flag key>|r<recipe>" of the last fit made AFTER the full-history rescore. When it does
    /// not match the current one, the next refresh with the rescore done refits at once, not tomorrow.
    static let fittedAfterRescoreKey = "effort.whoopCalibration.fittedAfterRescore"

    /// The Effort RECIPE version a calibration belongs to. BUMP whenever the stored day Effort changes shape
    /// (zones, gates, floors, the log map) — a curve fitted on the old numbers is wrong on the new ones.
    ///   1 — O6: Edwards zones on %HRmax.
    ///   2 — E1: the day integral pays zone 1 only while moving; E3: Banister sedentary floor 0.10 → 0.04.
    static let strainRecipeVersion = 2
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
            // A calibration from an older recipe is not a calibration of THESE numbers (E4).
            let recipe = UserDefaults.standard.integer(forKey: recipeKey)
            cached = decodeIfCurrent(UserDefaults.standard.data(forKey: storageKey), recipe: recipe)
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
            UserDefaults.standard.set(strainRecipeVersion, forKey: recipeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            UserDefaults.standard.removeObject(forKey: recipeKey)
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

    /// Refit from the store when due. Cheap when not due (a few defaults reads).
    ///
    /// DUE (E4): never while the full-history rescore is still pending (the store mixes recipes); at once
    /// on the first refresh after it completes (`fittedAfterRescoreKey` does not match yet); otherwise at
    /// most once per local day. Called on every Today refresh, so the flag flipping is noticed promptly.
    ///
    /// When BOTH reads come back empty — no store yet, or a user who never connected the WHOOP cloud — the
    /// persisted calibration is left alone and nothing is marked, so a transient store miss can never wipe
    /// a good calibration. Otherwise the fit's result replaces it, nil included: a wearer whose paired days
    /// fell under the minimum goes back to the honest linear mapping.
    @MainActor
    static func refreshIfDue(repo: Repository, now: Date = Date()) async {
        let defaults = UserDefaults.standard
        let today = Repository.localDayKey(now)
        let rescoreKey = IntelligenceEngine.nightlyMetricsRescoreFlagKey
        let marker = fitMarker(rescoreFlagKey: rescoreKey)
        guard isDue(rescoreDone: defaults.bool(forKey: rescoreKey),
                    fittedMarker: defaults.string(forKey: fittedAfterRescoreKey),
                    currentMarker: marker,
                    refreshedDay: defaults.string(forKey: refreshedDayKey),
                    today: today) else { return }
        let own = await repo.noopRecentDays(days: lookbackDays)
        let whoop = await repo.whoopRecentDays(days: lookbackDays)
        guard !own.isEmpty || !whoop.isEmpty else { return }
        let paired = pairs(own: own.map { (day: $0.day, effort: $0.effort) },
                           whoop: whoop.map { (day: $0.day, strain: $0.strain) },
                           excludingDay: today)
        store(EffortStrainCalibration.fit(paired))
        defaults.set(today, forKey: refreshedDayKey)
        defaults.set(marker, forKey: fittedAfterRescoreKey)
    }

    /// The marker a post-rescore fit leaves behind: which rescore it followed and which recipe it fitted.
    /// A bumped rescore key (a new full-history pass) or a bumped recipe both make it stale, so both refit.
    static func fitMarker(rescoreFlagKey: String) -> String {
        "\(rescoreFlagKey)|r\(strainRecipeVersion)"
    }

    /// E4's refit rule, pure so it is testable without defaults or a store.
    static func isDue(rescoreDone: Bool, fittedMarker: String?, currentMarker: String,
                      refreshedDay: String?, today: String) -> Bool {
        guard rescoreDone else { return false }                   // the store still mixes recipes
        guard fittedMarker == currentMarker else { return true }  // first refresh after the rescore / a bump
        return refreshedDay != today                              // then daily
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

    /// The stored calibration only when it was fitted against the CURRENT recipe (E4); nil otherwise, which
    /// is the linear fallback. Pure, so the recipe gate is testable without resetting the in-memory copy.
    static func decodeIfCurrent(_ data: Data?, recipe: Int) -> EffortStrainCalibration? {
        guard recipe == strainRecipeVersion else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data?) -> EffortStrainCalibration? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(EffortStrainCalibration.self, from: data)
    }
}
