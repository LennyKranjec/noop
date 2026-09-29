import Foundation
import WhoopStore

// ScoreConfidence.swift — per-score certainty tier for Charge / Effort / Rest.
//
// Each daily score rides a confidence tier so a sparse 5/MG day (or a cold-start
// baseline) reads truthfully instead of faking a number. Surfaced as a small
// label/dot under each score; the score itself stays nil-honest where it can't
// compute at all.
//
// Tiers (ordered lowest → highest):
//   .calibrating — the baseline/seed isn't usable yet, or the core input window is
//                  absent (no HR window for Effort, no in-bed data for Rest, HRV
//                  baseline not yet usable for Charge). The number, if shown, is a
//                  placeholder.
//   .building    — usable but thin: enough to compute, but the baseline is still
//                  provisional or the inputs are partial (e.g. a day backed mostly by
//                  PPG-derived HR, or a short baseline history).
//   .solid       — full inputs present and the baseline is trusted.
//
// Kept deliberately small and dependency-free so the Kotlin mirror is byte-identical.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid

    // MARK: - Persistence (so a UI can actually read the tier)

    /// The metricSeries keys the per-score tiers are persisted under, beside the score they qualify.
    /// The tiers were computed on every `DayResult` and read by nothing — they never left the engine, so a
    /// Charge on a provisional four-night baseline and one on a year of history rendered identically.
    /// Persisted as an ORDINAL (see `ordinal`) because `metric_series` carries a Double per (day, key):
    /// no schema change, and an upsert is idempotent per day, so a re-score simply replaces the tier.
    public enum SeriesKey {
        public static let charge = "charge_confidence"
        public static let effort = "effort_confidence"
        public static let rest = "rest_confidence"
    }

    /// The persisted encoding: 0 calibrating, 1 building, 2 solid. Ordered, so a reader can compare
    /// tiers numerically without decoding, and a value outside 0...2 is not a tier (`from(ordinal:)`
    /// returns nil rather than guessing).
    public var ordinal: Double {
        switch self {
        case .calibrating: return 0
        case .building: return 1
        case .solid: return 2
        }
    }

    /// Decode a persisted ordinal. nil for anything that is not exactly one of the three — an unreadable
    /// row means "the tier is unknown", which a UI must render as no badge, never as `.solid`.
    public static func from(ordinal: Double) -> ScoreConfidence? {
        switch ordinal {
        case 0: return .calibrating
        case 1: return .building
        case 2: return .solid
        default: return nil
        }
    }

    // MARK: - Night coverage (how much of the night NOOP actually holds)

    /// Least share of the night window that must carry heart rate before a night may back a `.solid`
    /// Charge or Rest.
    ///
    /// `stageCoverage` measures the hypnogram against the DETECTED span, which is derived from the very
    /// rows whose completeness is in question: a night that synced only two hours yields a two-hour
    /// session whose stages cover it completely, and it is then scored and rendered exactly like a whole
    /// night. This is the independent measurement — the covered seconds of a CLOCK-derived night window
    /// (`NightCoverage` in the app target computes it; this package takes the plain numbers).
    ///
    /// Half, matching `NightCoverage.sparseFraction`: below it the majority of the night is absent and any
    /// duration, efficiency or HRV figure taken from it describes the minority that arrived. Confidence
    /// only — it never changes a score and never claims the missing time was anything.
    public static let minNightCoverage: Double = 0.5

    /// Coverage as a fraction of the window, or nil when the window is unknown/empty or the read could not
    /// be measured — the guards below fail OPEN on nil, so an unmeasurable night keeps its tier rather
    /// than being downgraded on no evidence.
    public static func nightCoverageFraction(coveredSeconds: Int?, windowSeconds: Int?) -> Double? {
        guard let covered = coveredSeconds, let window = windowSeconds, window > 0 else { return nil }
        return Double(max(0, covered)) / Double(window)
    }

    /// True when coverage is KNOWN and below the bar. nil (unknown) is not a downgrade.
    static func coverageIsThin(_ nightCoverage: Double?) -> Bool {
        guard let c = nightCoverage else { return false }
        return c < minNightCoverage
    }

    // MARK: - Derivations (one per score; mirror the Android helpers exactly)

    /// Charge (recovery) confidence.
    /// - calibrating: no score (HRV baseline not usable / cold-start) → the number is absent.
    /// - solid:       a score exists AND the HRV baseline is fully trusted.
    /// - building:    a score exists but the HRV baseline is only provisional.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?) -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// Charge confidence WITH the night-coverage guard. A Charge is read off ONE night's HRV and resting
    /// HR, so a night NOOP holds only part of cannot earn a `.solid` however trusted the baseline behind it
    /// is. Downgrades `.solid` to `.building` when coverage is known and below `minNightCoverage`; fails
    /// open on nil (coverage unknown), and leaves `.calibrating`/`.building` alone.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?,
                              nightCoverage: Double?) -> ScoreConfidence {
        let base = charge(recovery: recovery, hrvBaseline: hrvBaseline)
        guard base == .solid else { return base }
        return coverageIsThin(nightCoverage) ? .building : base
    }

    /// Readiness confidence from the HRV/RHR baseline density backing the read (readiness is HRV-led).
    /// - calibrating: no read (insufficient history — the readiness level is `.insufficient`).
    /// - solid:       a read exists AND the full baseline window is present.
    /// - building:    a read exists but the baseline is shorter than the full window (e.g. 7–29 of 30).
    public static func readiness(hasRead: Bool, baselineNights: Int, fullWindow: Int) -> ScoreConfidence {
        guard hasRead else { return .calibrating }
        return baselineNights >= fullWindow ? .solid : .building
    }

    /// Effort (strain) confidence.
    /// - calibrating: no score (no usable HR window) → absent.
    /// - solid:       a score exists AND the HR window is dense (≥ solidReadings samples).
    /// - building:    a score exists but the HR window is thin (PPG-backed / short day).
    public static let solidEffortReadings: Int = 3600  // ~1 h at 1 Hz of HR coverage
    public static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Rest (sleep) confidence.
    /// - calibrating: no in-bed data (no matched session) → absent.
    /// - solid:       a session exists AND every Rest component had real input
    ///                (staged sleep present so restorative + efficiency are real).
    /// - building:    a session exists but stages/inputs are partial.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }

    // MARK: - H9 stage low-confidence (restorative-share floor on a high-efficiency night)

    /// Restorative (deep+REM) share of asleep time below which staging is treated as LOW-CONFIDENCE on an
    /// otherwise high-efficiency night. A genuine well-structured adult night sits ~40–50% deep+REM; a near-
    /// zero restorative share on a night that ALSO scored high efficiency (lots of "asleep") is far more
    /// likely a staging miss (the EEG-free classifier's weakest link is light/deep/REM separation) than a
    /// real night with no deep or REM — so we flag the LOW CONFIDENCE rather than fake stages or tank Rest.
    /// ~10% is well below the healthy band yet above true edge cases. (#H9)
    public static let restorativeLowConfidenceShare: Double = 0.10

    /// Efficiency above which the restorative-share floor applies. A low-efficiency (fragmented) night
    /// legitimately carries less deep/REM, so the floor would false-positive there; we only flag the
    /// suspicious case — high efficiency (lots of measured sleep) but implausibly little restorative.
    public static let highEfficiencyThreshold: Double = 0.85

    /// Rest confidence WITH the H9 stage-quality check, the sparse-motion guard AND the hypnogram-coverage
    /// guard. Starts from `rest(hasSession:hasStagedSleep:)`, then DOWNGRADES a `.solid` tier to `.building`
    /// (low-confidence) when ANY of:
    ///  - the night was staged on SPARSE gravity (`gravitySparse`) — a WHOOP 4.0 synced/offload night banks
    ///    motion coarsely, too sparse to reliably stage sleep (#345), so a confident 85–100 Rest is unearned
    ///    however the engine filled the stages. This catches the case H9 MISSES: a sparse night whose staging
    ///    manufactures HIGH efficiency AND HIGH restorative reads SOLID under H9 alone (the #319 signature),
    ///    yet the underlying data can't support it; OR
    ///  - the night is high-efficiency yet its restorative (deep+REM) share is below
    ///    `restorativeLowConfidenceShare` — a likely staging miss (#H9); OR
    ///  - `stageCoverage` says the stage timeline accounts for less than `HypnogramCoverage.minCoverage` of
    ///    the span it claims. This is the case the other two structurally cannot see: a device-PROVIDED
    ///    hypnogram assembled from records that arrived incomplete has real stages over the part that DID
    ///    arrive, so its restorative share is ordinary and H9 stays quiet, while `gravitySparse` describes
    ///    the on-device motion stager and is false for a provided hypnogram (and inert for Oura outright,
    ///    which banks no gravity at all). Measured: a ring night covering 23% of its 601-minute span was
    ///    stored as 70 minutes of sleep and reported SOLID.
    /// `asleepSeconds`/`restorativeSeconds` are the night's totals; efficiency is asleep/in-bed in [0,1].
    /// `stageCoverage` is nil when coverage is unknown or not applicable — the guard fails OPEN there, so
    /// an unmeasurable payload keeps its previous tier rather than being downgraded on no evidence.
    /// `.calibrating`/`.building` from the base call are returned unchanged. Confidence-only — never changes
    /// the Rest score, invents stages, or claims the uncovered time was awake. Engine output only; the UI
    /// surfaces the tier later. (#H9, #345)
    /// `nightCoverage` is the FOURTH guard and the only one that measures the night rather than the
    /// session: the share of a clock-derived night window that carries heart rate at all. The other three
    /// are all computed from the detected span, so a night that synced two hours produces a two-hour
    /// session they all read as complete. nil = unmeasured, and the guard fails OPEN there.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool,
                            asleepSeconds: Double, restorativeSeconds: Double,
                            efficiency: Double, gravitySparse: Bool = false,
                            stageCoverage: Double? = nil,
                            nightCoverage: Double? = nil) -> ScoreConfidence {
        let base = rest(hasSession: hasSession, hasStagedSleep: hasStagedSleep)
        if base != .solid { return base }
        if gravitySparse { return .building }   // #345: sparse-motion staging can't earn a SOLID Rest
        if let c = stageCoverage, c < HypnogramCoverage.minCoverage {
            return .building   // the timeline covers only part of the night it claims
        }
        if coverageIsThin(nightCoverage) {
            return .building   // only part of the NIGHT was ever persisted (#NightCoverage)
        }
        if asleepSeconds <= 0 { return base }
        let restorativeShare = restorativeSeconds / asleepSeconds
        if efficiency >= highEfficiencyThreshold && restorativeShare < restorativeLowConfidenceShare {
            return .building   // high-efficiency night with near-zero deep+REM → low-confidence staging (#H9)
        }
        return base
    }
}
