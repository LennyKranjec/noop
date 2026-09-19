//  StepCalibrationWalks.swift
//  NOOP
//
//  TEMPORARY step-calibration walks (iOS Today tile `StepCalibrationTile`). The wearer presses Start,
//  walks while counting steps in their head, presses Pause, and types the real count. NOOP measures the
//  SAME raw input its own step estimator uses over exactly that interval and derives the one calibration
//  parameter that estimator already has:
//
//  - `.counter` (WHOOP 5/MG): daily steps = @57 counter ticks ÷ `ProfileStore.stepTicksPerStep`
//    (AnalyticsEngine.analyzeDay). A walk implies ticksPerStep = ticks / counted.
//  - `.motion` (WHOOP 4.0): steps = motion volume × k (StepsEstimateEngine, manual k =
//    `ProfileStore.stepsManualCoefficient`). A walk implies k = counted / motion.
//
//  Nothing here re-scales steps itself: the combined value is written into the EXISTING parameter, which
//  each estimator already applies in exactly one place, so the Today tile, widgets, trends and the coach
//  all read the calibrated number and Apple Health / imported steps are never touched.
//
//  Pure value code (the persistence wrapper at the bottom is a thin UserDefaults JSON box) so the math is
//  unit-tested in `StepCalibrationWalksTests`. iOS-only feature; no Android twin by design (temporary).

import Foundation

/// Which step estimator a walk measured, and so which existing parameter it tunes.
enum StepCalibrationKind: String, Codable, Equatable {
    /// WHOOP 5/MG @57 motion counter; parameter = ticks per step (a divisor).
    case counter
    /// WHOOP 4.0 gravity motion volume; parameter = steps per unit of motion (a multiplier, `k`).
    case motion
}

/// One finished calibration walk.
struct StepCalibrationWalk: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var kind: StepCalibrationKind
    /// The estimator's raw input over the walk: counter ticks (`.counter`) or motion volume (`.motion`).
    var raw: Double
    /// NOOP's own count for the walk with the calibration in force at the time; nil when the estimator had
    /// no calibration to produce one (a WHOOP 4.0 that was never calibrated).
    var estimated: Int?
    /// What the wearer counted.
    var counted: Int
    /// The parameter this walk ALONE implies (ticks/step for `.counter`, k for `.motion`).
    var implied: Double

    /// counted ÷ estimated: how far NOOP was off on this walk (1.0 = spot on). nil without an estimate.
    var factor: Double? {
        guard let e = estimated, e > 0 else { return nil }
        return Double(counted) / Double(e)
    }
}

enum StepCalibrationMath {
    /// A walk shorter than this is too noisy to calibrate from (a few footfalls either way swamp it).
    static let minCountedSteps = 50
    /// Absolute range of the 5/MG divisor. Mirrors `ProfileStore.stepScaleRange` (asserted equal in tests;
    /// restated here because that one is main-actor isolated).
    static let ticksPerStepRange: ClosedRange<Double> = 0.5...30.0
    /// Absolute sanity range for the 4.0 coefficient k (steps per motion unit).
    static let motionCoefficientRange: ClosedRange<Double> = 0.5...5_000.0
    /// For the 4.0 coefficient, the walk-derived k may move at most this far from the phone-fitted k (when
    /// one exists). A walk is pure locomotion while a day also carries arm motion the phone never counts,
    /// so a walk-only k runs high; the bound stops one odd walk from doubling every estimated day.
    static let relativeBound: ClosedRange<Double> = 0.5...2.0

    /// NOOP's step count for `raw` under `parameter`, using the SAME arithmetic as the day totals:
    /// `.counter` = AnalyticsEngine's `Int((ticks / max(ticksPerStep, 0.5)).rounded())`;
    /// `.motion` = StepsEstimateEngine.estimate's `Int((motion * k).rounded())` (without the day-level
    /// `minMotionForFit` floor and 60k clamp, which describe a whole day, not a few minutes).
    /// nil when there is no usable parameter (k = 0: never calibrated).
    static func estimatedSteps(kind: StepCalibrationKind, raw: Double, parameter: Double) -> Int? {
        guard raw.isFinite, raw >= 0, parameter.isFinite, parameter > 0 else { return nil }
        switch kind {
        case .counter: return Int((raw / max(parameter, 0.5)).rounded())
        case .motion:  return Int((raw * parameter).rounded())
        }
    }

    /// The parameter one walk implies, or nil when the walk is unusable (too few counted steps, no raw
    /// movement measured).
    static func impliedParameter(kind: StepCalibrationKind, raw: Double, counted: Int) -> Double? {
        guard counted >= minCountedSteps, raw.isFinite, raw > 0 else { return nil }
        switch kind {
        case .counter: return raw / Double(counted)
        case .motion:  return Double(counted) / raw
        }
    }

    /// Build a walk record, or nil when it can't calibrate anything.
    static func makeWalk(kind: StepCalibrationKind, raw: Double, estimated: Int?, counted: Int,
                         date: Date = Date(), id: UUID = UUID()) -> StepCalibrationWalk? {
        guard let implied = impliedParameter(kind: kind, raw: raw, counted: counted) else { return nil }
        return StepCalibrationWalk(id: id, date: date, kind: kind, raw: raw, estimated: estimated,
                                   counted: counted, implied: implied)
    }

    /// Combine every usable walk of `kind` into one parameter: the median of the walks' implied values,
    /// WEIGHTED by counted steps (a 1,000-step walk pins the ratio far better than a 60-step one), then
    /// clamped to the absolute range and, for `.motion` with a phone-fitted `referenceK`, to
    /// `relativeBound` × that reference. nil when no usable walk exists.
    static func combinedParameter(_ walks: [StepCalibrationWalk], kind: StepCalibrationKind,
                                  referenceK: Double? = nil) -> Double? {
        let usable = walks.filter {
            $0.kind == kind && $0.counted >= minCountedSteps && $0.implied.isFinite && $0.implied > 0
        }
        guard !usable.isEmpty else { return nil }
        var value = weightedMedian(usable.map(\.implied), weights: usable.map { Double($0.counted) })
        switch kind {
        case .counter:
            value = clamp(value, ticksPerStepRange)
        case .motion:
            if let ref = referenceK, ref.isFinite, ref > 0 {
                value = clamp(value, (ref * relativeBound.lowerBound)...(ref * relativeBound.upperBound))
            }
            value = clamp(value, motionCoefficientRange)
        }
        return value
    }

    /// Weighted median: sort by value, return the first value where the cumulative weight passes half the
    /// total; exactly on the half-mass boundary, the midpoint of the two straddling values (so equal weights
    /// reduce to the ordinary median). Same rule as `StepsEstimateEngine.weightedMedian` (internal there).
    static func weightedMedian(_ xs: [Double], weights: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        let ws = weights.count == xs.count ? weights.map { max(0, $0) } : Array(repeating: 1.0, count: xs.count)
        let total = ws.reduce(0, +)
        guard total > 0 else { return weightedMedian(xs, weights: Array(repeating: 1.0, count: xs.count)) }
        let half = total / 2
        var cum = 0.0
        for (pos, idx) in order.enumerated() {
            cum += ws[idx]
            if cum > half { return xs[idx] }
            if cum == half {
                let next = pos + 1 < order.count ? order[pos + 1] : idx
                return (xs[idx] + xs[next]) / 2
            }
        }
        return xs[order[order.count - 1]]
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

// MARK: - Persistence

/// The walk history plus what the parameters were BEFORE the first walk was applied, so Reset can put the
/// estimator back exactly as it was. JSON in UserDefaults; deliberately NOT in the `.noopbak` whitelist
/// (temporary, device-local).
struct StepCalibrationState: Codable, Equatable {
    var walks: [StepCalibrationWalk] = []
    /// `stepTicksPerStep` before the first applied `.counter` walk; nil = no counter walk applied yet.
    var originalTicksPerStep: Double?
    /// `stepsManualCoefficient` before the first applied `.motion` walk (0 = auto-fit); nil = none applied.
    var originalManualK: Double?
    /// The phone-fitted (non-manual) k captured before the first `.motion` walk, for the relative bound.
    var referenceK: Double?

    static let defaultsKey = "stepCalibration.state"

    static func load(_ d: UserDefaults = .standard) -> StepCalibrationState {
        guard let data = d.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(StepCalibrationState.self, from: data) else { return .init() }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}

/// A running / paused calibration session: one or more `[start, end]` segments (unix seconds). Persisted so
/// a walk survives the app being suspended in a pocket or killed — every figure is re-read from the store.
struct StepCalibrationSession: Codable, Equatable {
    struct Segment: Codable, Equatable { var start: Int; var end: Int }
    /// Closed segments.
    var segments: [Segment] = []
    /// Start of the open (running) segment; nil when paused.
    var runningSince: Int?

    var isRunning: Bool { runningSince != nil }
    var isEmpty: Bool { segments.isEmpty && runningSince == nil }

    /// Every segment, the open one closed at `now`.
    func allSegments(now: Int) -> [Segment] {
        if let s = runningSince { return segments + [Segment(start: s, end: max(s, now))] }
        return segments
    }

    /// Total walked seconds across segments.
    func elapsed(now: Int) -> Int { allSegments(now: now).reduce(0) { $0 + ($1.end - $1.start) } }

    mutating func start(now: Int) { if runningSince == nil { runningSince = now } }

    mutating func pause(now: Int) {
        guard let s = runningSince else { return }
        if now > s { segments.append(Segment(start: s, end: now)) }
        runningSince = nil
    }

    static let defaultsKey = "stepCalibration.session"

    static func load(_ d: UserDefaults = .standard) -> StepCalibrationSession {
        guard let data = d.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(StepCalibrationSession.self, from: data) else { return .init() }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if isEmpty { d.removeObject(forKey: Self.defaultsKey); return }
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}
