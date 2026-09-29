import Foundation

// EnergyBank.swift — the energy available to a day, as a running balance.
//
// A BANK, NOT A SCORE. Recovery says how the body woke up; this says how much of that is still there
// at three in the afternoon. The difference is the whole point: two days that start at 70 % recovery
// end very differently if one of them held a hard session and six hours of high stress.
//
// WHAT FEEDS IT, and in which direction:
//
//   · RECOVERY sets the OPENING BALANCE. A strong overnight recovery — itself built from resting heart
//     rate, HRV, respiratory rate, SpO₂ and wrist temperature — is a higher starting point.
//   · SLEEP recharges. It is folded into the opening balance rather than added during the day, because
//     it happened before the day began. NOTE: the app's own Charge already carries a Rest-quality term
//     (`ChargeDrivers`), so the sleep share here counts part of the night a second time. That is why
//     the share is a FITTED parameter (`EnergyCalibration`) rather than a constant argued for in prose.
//   · STRAIN spends it. Both the active strain of a session and the passive strain of moving about and
//     carrying an elevated heart rate outside one.
//   · STRESS spends it faster. High stress drains; low stress preserves. EXERCISE stress is excluded
//     from the stress figure itself — `DaytimeStress` masks ambulatory hours — but it is not free: it
//     is already counted, once, as strain.
//   · REST returns some — but only MEASURED calm: minutes of scored, still hours that sat in the low
//     band (`calmMinutes(hours:)`). The Today wiring used to derive calm as "the 16-hour waking day
//     minus the high-stress minutes", which credited every unworn, unscored and NOT-YET-LIVED minute as
//     calm: at 08:00 the full rest return was already available to refund the morning's session.
//   · TIME AWAKE spends it (`Parameters.awakeCostPerHour`). Default 0 — the shipped model had no such
//     term — but it is the best-established driver of how tired a person feels by evening, so it is a
//     free parameter the wearer's own check-ins can switch on.
//
// IT IS A MODEL AND SAYS SO. The weights below are a stated arrangement, not a measured physiology.
// `EnergyCalibration` compares it with what the wearer REPORTS and refits the few free weights to them;
// until then the Today tile shows it as an estimate. What it is NOT is a fabricated measurement: every
// input is a figure the app already computes from the wearer's own data, and a missing or non-finite
// input makes the balance UNKNOWN rather than assumed.
//
// NOTHING IS COUNTED TWICE between strain and stress: the stress input is the non-activity one.

/// Everything the bank is computed from, kept with the result so a check-in can store exactly what the
/// model saw and the calibration can recompute it under other weights.
public struct EnergyInputs: Codable, Equatable, Sendable {
    /// The overnight recovery / Charge, 0–100.
    public var recovery: Double?
    /// The night's sleep performance / Rest, 0–100.
    public var sleepScore: Double?
    /// The day's strain so far ON WHOOP'S 0–21 AXIS. An Effort (0–100) must be mapped first
    /// (`StrainCalibration.strain21`); passed raw it would saturate the axis and spend a maximal day.
    public var strain21: Double?
    /// Minutes of NON-ACTIVITY high stress so far (covered minutes only — `DaytimeStress.highStressMinutes`).
    public var stressMinutes: Double?
    /// MEASURED calm minutes so far — `EnergyBank.calmMinutes(hours:)`. Never "waking day − stress".
    public var calmMinutes: Double?
    /// Hours since the night's wake, or nil when the wake time is unknown.
    public var hoursAwake: Double?

    public init(recovery: Double? = nil, sleepScore: Double? = nil, strain21: Double? = nil,
                stressMinutes: Double? = nil, calmMinutes: Double? = nil, hoursAwake: Double? = nil) {
        self.recovery = recovery
        self.sleepScore = sleepScore
        self.strain21 = strain21
        self.stressMinutes = stressMinutes
        self.calmMinutes = calmMinutes
        self.hoursAwake = hoursAwake
    }
}

/// What the day spent and what it has left.
public struct EnergyBalance: Equatable, Sendable {
    /// Where the day started, 0–100.
    public let opening: Double
    /// Points spent on strain.
    public let strainSpend: Double
    /// Points spent on non-activity stress.
    public let stressSpend: Double
    /// Points returned by calm hours.
    public let restReturn: Double
    /// Points spent simply by being awake (0 under the default weights).
    public let awakeSpend: Double
    /// What is left, 0–100.
    public let balance: Double
    /// What it was computed from. Nil only for a balance built through the five-figure memberwise init.
    public let inputs: EnergyInputs?

    public init(opening: Double, strainSpend: Double, stressSpend: Double,
                restReturn: Double, balance: Double) {
        self.init(opening: opening, strainSpend: strainSpend, stressSpend: stressSpend,
                  restReturn: restReturn, awakeSpend: 0, balance: balance, inputs: nil)
    }

    public init(opening: Double, strainSpend: Double, stressSpend: Double,
                restReturn: Double, awakeSpend: Double, balance: Double, inputs: EnergyInputs?) {
        self.opening = opening
        self.strainSpend = strainSpend
        self.stressSpend = stressSpend
        self.restReturn = restReturn
        self.awakeSpend = awakeSpend
        self.balance = balance
        self.inputs = inputs
    }

    /// The share of the opening balance still available, 0–1. What a bar fills to.
    public var fraction: Double {
        opening > 0 ? Swift.min(Swift.max(balance / opening, 0), 1) : 0
    }
}

public enum EnergyBank {

    // MARK: - The weights
    //
    // Stated here rather than inline, so the model is one readable paragraph instead of six literals
    // spread through a view. These are the DEFAULTS; `Parameters` carries a wearer's fitted set.

    /// How much of the opening balance recovery decides, against sleep.
    public static let recoveryShare = 0.7
    public static let sleepShare = 0.3

    /// Sleep alone is a weaker claim than recovery: a night scored well after a hard week is not a full
    /// tank. The opening with no recovery is the sleep score times this.
    public static let sleepOnlyFactor = 0.9

    /// Points a full day of strain spends. A maximal WHOOP day (21) takes most of the balance; it does
    /// not take all of it, because a person at 21 strain is tired rather than incapable.
    public static let strainCost = 55.0

    /// Points a full waking day of non-activity high stress spends.
    public static let stressCost = 25.0

    /// Points a full waking day of MEASURED calm returns. The smallest of the three on purpose.
    public static let restReturnMax = 15.0

    /// The waking day the stress and rest figures are measured against, in minutes.
    public static let wakingMinutes = 16.0 * 60

    /// WHOOP's strain ceiling, which is the scale `strain` arrives on.
    public static let strainMax = 21.0

    /// Stress level below which a scored hour counts as calm: the LOW band of the shared 0–3 scale
    /// (`StressBand.low` is `..<1.0`). Medium hours neither spend nor return.
    public static let calmCeiling = 1.0

    /// The model's free weights. `defaults` is the shipped arrangement; `EnergyCalibration.fit` moves
    /// them toward what the wearer reports, regularised back toward these.
    public struct Parameters: Codable, Equatable, Sendable {
        /// Offset added to the opening, in points — the gap between the model's scale and the wearer's
        /// own sense of "full". 0 by default.
        public var bias: Double
        /// Recovery's share of the opening against sleep, 0–1.
        public var recoveryShare: Double
        public var strainCost: Double
        public var stressCost: Double
        public var restReturnMax: Double
        /// Points per hour awake. 0 by default (the shipped model had no such term).
        public var awakeCostPerHour: Double

        public init(bias: Double, recoveryShare: Double, strainCost: Double, stressCost: Double,
                    restReturnMax: Double, awakeCostPerHour: Double) {
            self.bias = bias
            self.recoveryShare = recoveryShare
            self.strainCost = strainCost
            self.stressCost = stressCost
            self.restReturnMax = restReturnMax
            self.awakeCostPerHour = awakeCostPerHour
        }

        public static let defaults = Parameters(
            bias: 0, recoveryShare: EnergyBank.recoveryShare, strainCost: EnergyBank.strainCost,
            stressCost: EnergyBank.stressCost, restReturnMax: EnergyBank.restReturnMax,
            awakeCostPerHour: 0)

        /// The same weights, forced into the ranges the model means: a share in 0–1, costs and the
        /// return never negative (a spend is never credited), the offset within ±50.
        public var projected: Parameters {
            let d = Parameters.defaults
            func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
            return Parameters(
                bias: Swift.min(Swift.max(finite(bias, d.bias), -50), 50),
                recoveryShare: Swift.min(Swift.max(finite(recoveryShare, d.recoveryShare), 0), 1),
                strainCost: Swift.max(finite(strainCost, d.strainCost), 0),
                stressCost: Swift.max(finite(stressCost, d.stressCost), 0),
                restReturnMax: Swift.max(finite(restReturnMax, d.restReturnMax), 0),
                awakeCostPerHour: Swift.max(finite(awakeCostPerHour, d.awakeCostPerHour), 0))
        }
    }

    /// The day's balance under the default weights, or nil when there is not enough to say.
    ///
    /// The original entry point, kept source-compatible. `strain` is on WHOOP's 0–21 axis.
    public static func balance(
        recovery: Double?,
        sleepScore: Double?,
        strain: Double?,
        stressMinutes: Double?,
        calmMinutes: Double?
    ) -> EnergyBalance? {
        balance(EnergyInputs(recovery: recovery, sleepScore: sleepScore, strain21: strain,
                             stressMinutes: stressMinutes, calmMinutes: calmMinutes),
                params: .defaults)
    }

    /// The day's balance under `params`, or nil when there is not enough to say.
    ///
    /// NIL RATHER THAN A DEFAULT. With no recovery and no sleep score there is no opening balance, and
    /// a bank drawn from an assumed 50 would be a number about nobody. A NON-FINITE input is treated as
    /// absent: a NaN used to flow straight through `min`/`max` into the balance, which the tile then
    /// passed to `Int(_:)` — a trap, not a dash. The spends are optional individually and an absent one
    /// simply spends nothing.
    public static func balance(_ inputs: EnergyInputs, params: Parameters = .defaults) -> EnergyBalance? {
        let p = params.projected
        guard let f = features(inputs) else { return nil }

        // THE OPENING IS CLAMPED BEFORE ANYTHING IS SPENT. It used to be clamped only on the way out,
        // so an out-of-range opening (a 130 from a bad import) absorbed the first 30 points of spend
        // invisibly — the bar did not move for a whole session.
        let opening = clamp(f.base + p.recoveryShare * f.shareSpread + p.bias, 0, 100)

        let strainSpend = f.strainFraction * p.strainCost
        let stressSpend = f.stressFraction * p.stressCost
        let awakeSpend = f.hoursAwake * p.awakeCostPerHour
        let restReturn = f.calmFraction * p.restReturnMax

        // THE RETURN CANNOT EXCEED WHAT WAS SPENT. Calm hours recover a day; they do not add energy the
        // day never had.
        let spent = strainSpend + stressSpend + awakeSpend
        let credited = Swift.min(restReturn, spent)

        let balance = clamp(opening - spent + credited, 0, 100)
        return EnergyBalance(opening: opening, strainSpend: strainSpend, stressSpend: stressSpend,
                             restReturn: credited, awakeSpend: awakeSpend, balance: balance,
                             inputs: inputs)
    }

    // MARK: - The model as features (shared with the fit)

    /// The inputs reduced to what the weights multiply. `base + recoveryShare × shareSpread` is the
    /// opening before the offset; each fraction is its input clamped to its own scale.
    public struct Features: Equatable, Sendable {
        public let base: Double
        public let shareSpread: Double
        public let strainFraction: Double
        public let stressFraction: Double
        public let calmFraction: Double
        public let hoursAwake: Double
    }

    /// Nil when there is no opening (no finite recovery and no finite sleep score).
    public static func features(_ inputs: EnergyInputs) -> Features? {
        let r = finite(inputs.recovery).map { clamp($0, 0, 100) }
        let s = finite(inputs.sleepScore).map { clamp($0, 0, 100) }
        let base: Double
        let spread: Double
        switch (r, s) {
        case let (r?, s?):
            base = s            // share·r + (1 − share)·s  ==  s + share·(r − s)
            spread = r - s
        case let (r?, nil):
            base = r
            spread = 0
        case let (nil, s?):
            base = s * sleepOnlyFactor
            spread = 0
        default:
            return nil
        }
        return Features(base: base, shareSpread: spread,
                        strainFraction: fraction(inputs.strain21, strainMax),
                        stressFraction: fraction(inputs.stressMinutes, wakingMinutes),
                        calmFraction: fraction(inputs.calmMinutes, wakingMinutes),
                        hoursAwake: finite(inputs.hoursAwake).map { clamp($0, 0, 24) } ?? 0)
    }

    // MARK: - Resolving today's inputs

    /// A figure with the day it belongs to.
    public struct DayFigure: Equatable, Sendable {
        public let value: Double
        public let day: String
        public init(value: Double, day: String) {
            self.value = value
            self.day = day
        }
    }

    /// `value` stamped with `day`, or nil when either is missing.
    public static func stamp(_ value: Double?, _ day: String?) -> DayFigure? {
        guard let value, let day else { return nil }
        return DayFigure(value: value, day: day)
    }

    /// Today's inputs, taking ONLY figures that belong to `dayKey`. Each figure is a list of candidates
    /// in preference order (the same order the Today rings resolve them in); the first finite one
    /// stamped with `dayKey` wins.
    ///
    /// ONE DAY, ONE KEY. The Today wiring opened the bank from `repo.days.last` when today had no row
    /// yet and from a CARRIED cloud recovery — both yesterday's after the 04:00 rollover — and spent a
    /// carried cloud strain (yesterday's whole-day total) against it. It also looked stress up under
    /// the calendar-midnight key while every other figure followed the logical day. A figure stamped
    /// with any other day is dropped here, so the bank abstains until today's night is scored instead
    /// of presenting yesterday as today. Stress and calm are read under `dayKey` only, and calm is NEVER
    /// derived from stress: absent a measured calm figure, nothing is returned for resting.
    public static func inputs(dayKey: String,
                              recovery: [DayFigure?],
                              sleepScore: [DayFigure?],
                              strain21: [DayFigure?],
                              stressMinutesByDay: [String: Double],
                              calmMinutesByDay: [String: Double],
                              hoursAwake: Double?) -> EnergyInputs {
        func today(_ candidates: [DayFigure?]) -> Double? {
            for case let figure? in candidates where figure.day == dayKey && figure.value.isFinite {
                return figure.value
            }
            return nil
        }
        var awake: Double?
        if let h = finite(hoursAwake), h >= 0 { awake = h }
        return EnergyInputs(recovery: today(recovery),
                            sleepScore: today(sleepScore),
                            strain21: today(strain21),
                            stressMinutes: stressMinutesByDay[dayKey],
                            calmMinutes: calmMinutesByDay[dayKey],
                            hoursAwake: awake)
    }

    /// Minutes of MEASURED calm in a day's stress timeline: for each scored, non-masked hour in the low
    /// band, the minutes that hour was actually covered by heart rate. Nil when no hour was scored — an
    /// unmeasured day is not a calm one.
    public static func calmMinutes(hours: [DaytimeStress.HourPoint]) -> Int? {
        let scored = hours.filter { $0.level != nil && !$0.maskedForActivity }
        guard !scored.isEmpty else { return nil }
        var total = 0
        for h in scored {
            guard let level = h.level, level < calmCeiling else { continue }
            total += Swift.min(Swift.max(h.coveredMinutes, 0), 60)
        }
        return total
    }

    /// Hours since the wake, by the wall clock, or nil when the wake is unknown or still ahead.
    public static func hoursAwake(wakeMinute: Int?, nowMinute: Int) -> Double? {
        guard let wakeMinute, nowMinute >= wakeMinute else { return nil }
        return Double(nowMinute - wakeMinute) / 60
    }

    /// The plain-words state of a balance, for a caption and for the coach's grounding.
    ///
    /// Bands rather than a sentence per point: the figure is a model, and language finer than this
    /// would dress it up as a measurement.
    public static func state(_ balance: Double) -> String {
        switch balance {
        case ..<20: return "spent"
        case ..<40: return "low"
        case ..<65: return "steady"
        case ..<85: return "good"
        default: return "full"
        }
    }

    // MARK: - Helpers

    static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), hi)
    }

    static func fraction(_ v: Double?, _ scale: Double) -> Double {
        guard let v = finite(v) else { return 0 }
        return clamp(v, 0, scale) / scale
    }
}
