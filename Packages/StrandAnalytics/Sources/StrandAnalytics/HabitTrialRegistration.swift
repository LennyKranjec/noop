import Foundation

// HabitTrialRegistration.swift — the pre-registration of a habit trial, frozen before day 1.
//
// HEALTH_V2 §S1-B.2. Everything the analysis will do is decided HERE, before any trial outcome exists:
// the one primary outcome, its lag, the length, the minimal meaningful effect, the covariates, the
// permutation count, the seed, and the complete ON/OFF schedule drawn from that seed. The record is
// written once when the wearer taps Start and never mutated. Its canonical JSON (sorted keys, fixed number
// formatting) is hashed with FNV-1a 64 and the hash is stored beside it; `HabitTrialAnalysis` refuses to
// produce a verdict for a record whose hash no longer matches ("trial record altered — no verdict").
//
// `startDay` is always TOMORROW relative to registration, so behaviour already lived today cannot leak in.

/// How a day's assignment pairs with its outcome. Both lags pair assignment day D with the value keyed
/// D + 1: a night outcome is keyed by the wake day of the night that STARTS on D, and a next-day outcome is
/// D + 1's daytime value.
public enum HabitTrialLag: String, Codable, Sendable {
    case nightAfter
    case nextDay

    public static func lag(for outcome: HabitOutcome) -> HabitTrialLag {
        switch outcome {
        case .nightHrvLn, .nightRhr, .totalSleepMin, .onsetClockMin, .sleepEfficiency: return .nightAfter
        case .nextMorningCharge, .dayStressMean, .feltRested: return .nextDay
        }
    }

    /// The outcome key for assignment day `day`.
    public func outcomeKey(for day: String) -> String? { HabitDay.adding(1, to: day) }
}

/// The fixed covariates of the model.
public enum HabitTrialCovariate: String, Codable, Sendable {
    /// Day D's Effort.
    case effort
    /// Day D−1's Effort (interventions that themselves move Effort).
    case effortPreviousDay
    /// Linear day-index trend (slow drift).
    case trend
    /// Weekend-evening indicator (blocked designs only; weekday-balanced designs balance it by design).
    case weekend
    /// Previous day assigned ON (short carry-over only; rebuilt from every permuted schedule).
    case prevAssignedOn
}

/// Why a registration could not be made.
public enum HabitTrialRegistrationError: Error, Equatable, Sendable {
    case unknownIntervention
    case invalidLength(allowed: [Int])
    case invalidDay
    case tooFewBaselineNights(have: Int, need: Int)
    case noThreshold
}

/// The frozen pre-registration.
public struct HabitTrialRegistration: Equatable, Codable, Sendable {

    public static let defaultPermutations = 10_000
    public static let defaultAlpha = 0.05
    /// Baseline window before the start, in nights.
    public static let baselineWindow = 28
    /// Baseline nights needed to freeze the MCID and show a minimum detectable effect.
    public static let minBaselineNights = 14

    public let trialId: String
    public let interventionId: String
    /// The local day the wearer tapped Start.
    public let registeredOn: String
    /// Always `registeredOn + 1`.
    public let startDay: String
    public let lengthDays: Int
    public let design: HabitTrialDesign
    public let carryOver: HabitTrialCarryOver
    public let primaryOutcome: HabitOutcome
    public let direction: EffectDirection
    public let lag: HabitTrialLag
    /// Minimal meaningful effect, analysis units, frozen.
    public let mcid: Double
    /// Always exploratory.
    public let secondaryOutcomes: [HabitOutcome]
    public let covariates: [HabitTrialCovariate]
    public let affectsEffort: Bool
    /// < 2^53, so it survives any JSON number codec exactly.
    public let seed: UInt64
    /// ON/OFF for every day, generated from `seed` at registration.
    public let schedule: [Bool]
    public let alpha: Double
    public let permutations: Int
    public let baselineNights: Int
    public let baselineSD: Double?
    public let baselineRho: Double?
    public let baselineMedian: Double?
    /// Minimum detectable effect shown before Start (analysis units). Nil without a baseline SD.
    public let mde: Double?

    public init(trialId: String, interventionId: String, registeredOn: String, startDay: String,
                lengthDays: Int, design: HabitTrialDesign, carryOver: HabitTrialCarryOver,
                primaryOutcome: HabitOutcome, direction: EffectDirection, lag: HabitTrialLag, mcid: Double,
                secondaryOutcomes: [HabitOutcome], covariates: [HabitTrialCovariate], affectsEffort: Bool,
                seed: UInt64, schedule: [Bool], alpha: Double = HabitTrialRegistration.defaultAlpha,
                permutations: Int = HabitTrialRegistration.defaultPermutations, baselineNights: Int,
                baselineSD: Double?, baselineRho: Double?, baselineMedian: Double?, mde: Double?) {
        self.trialId = trialId
        self.interventionId = interventionId
        self.registeredOn = registeredOn
        self.startDay = startDay
        self.lengthDays = lengthDays
        self.design = design
        self.carryOver = carryOver
        self.primaryOutcome = primaryOutcome
        self.direction = direction
        self.lag = lag
        self.mcid = mcid
        self.secondaryOutcomes = secondaryOutcomes
        self.covariates = covariates
        self.affectsEffort = affectsEffort
        self.seed = seed
        self.schedule = schedule
        self.alpha = alpha
        self.permutations = permutations
        self.baselineNights = baselineNights
        self.baselineSD = baselineSD
        self.baselineRho = baselineRho
        self.baselineMedian = baselineMedian
        self.mde = mde
    }

    /// The last assignment day.
    public var endDay: String { HabitDay.adding(lengthDays - 1, to: startDay) ?? startDay }

    /// The key of the last outcome (the night after the last day). Results unseal once it is scored.
    public var lastOutcomeKey: String { lag.outcomeKey(for: endDay) ?? endDay }

    /// The fixed covariate list for a design and carry-over.
    public static func covariates(design: HabitTrialDesign, carryOver: HabitTrialCarryOver,
                                  affectsEffort: Bool) -> [HabitTrialCovariate] {
        var out: [HabitTrialCovariate] = [affectsEffort ? .effortPreviousDay : .effort, .trend]
        if case .blocked = design { out.append(.weekend) }
        if carryOver == .short { out.append(.prevAssignedOn) }
        return out
    }

    // MARK: Registering

    /// Freeze a trial of `entry` starting TOMORROW (`registeredOn + 1`).
    ///
    /// - `baseline`: primary-outcome values in analysis units keyed by outcome key, from which the 28 keys
    ///   ending on `registeredOn` are used (the last pre-trial nights the app can have seen).
    /// - `seed`: a registration seed (`DeterministicRNG.registrationSeed`); masked to 53 bits.
    public static func register(entry: HabitTrialEntry, registeredOn: String, lengthDays: Int, seed: UInt64,
                                baseline: [String: Double],
                                permutations: Int = defaultPermutations) -> Result<HabitTrialRegistration, HabitTrialRegistrationError> {
        guard let start = HabitDay.adding(1, to: registeredOn) else { return .failure(.invalidDay) }
        let design = entry.design
        guard HabitTrialSchedule.isValid(design: design, lengthDays: lengthDays) else {
            return .failure(.invalidLength(allowed: design.allowedLengths))
        }
        var values: [Double] = []
        var positions: [Int] = []
        for back in 0..<baselineWindow {
            guard let key = HabitDay.adding(-back, to: registeredOn) else { continue }
            if let v = baseline[key], v.isFinite {
                values.append(v)
                positions.append(-back)
            }
        }
        guard values.count >= minBaselineNights else {
            return .failure(.tooFewBaselineNights(have: values.count, need: minBaselineNights))
        }
        let sd = HabitStats.sampleSD(values)
        let rho = HabitStats.lag1Autocorrelation(values: values, positions: positions)
        guard let mcid = entry.primaryOutcome.mcid(baselineSD: sd) else { return .failure(.noThreshold) }
        let perArm = HabitTrialSchedule.analysableDaysPerArm(design: design, lengthDays: lengthDays)
        let mde = sd.flatMap {
            HabitTrialAnalysis.minimumDetectableEffect(sd: $0, rho: rho ?? 0, nOn: perArm, nOff: perArm)
        }
        let seed53 = seed & ((1 << 53) - 1)
        let schedule = HabitTrialSchedule.assignments(design: design, lengthDays: lengthDays, seed: seed53)
        let reg = HabitTrialRegistration(
            trialId: "\(entry.id).\(start)", interventionId: entry.id, registeredOn: registeredOn,
            startDay: start, lengthDays: lengthDays, design: design, carryOver: entry.carryOver,
            primaryOutcome: entry.primaryOutcome, direction: entry.direction,
            lag: HabitTrialLag.lag(for: entry.primaryOutcome), mcid: mcid,
            secondaryOutcomes: entry.secondaryOutcomes,
            covariates: covariates(design: design, carryOver: entry.carryOver, affectsEffort: entry.affectsEffort),
            affectsEffort: entry.affectsEffort, seed: seed53, schedule: schedule,
            permutations: permutations, baselineNights: values.count, baselineSD: sd, baselineRho: rho,
            baselineMedian: HabitStats.median(values), mde: mde)
        return .success(reg)
    }

    /// The smallest allowed length whose minimum detectable effect is at most twice the MCID, or nil.
    /// The Start screen recommends it when the chosen length's MDE is above 2 × MCID.
    public func recommendedLength() -> Int? {
        guard let sd = baselineSD else { return nil }
        for length in design.allowedLengths {
            let perArm = HabitTrialSchedule.analysableDaysPerArm(design: design, lengthDays: length)
            if let m = HabitTrialAnalysis.minimumDetectableEffect(sd: sd, rho: baselineRho ?? 0,
                                                                  nOn: perArm, nOff: perArm),
               m <= 2 * mcid { return length }
        }
        return nil
    }

    /// Whether the chosen length is underpowered (MDE > 2 × MCID) — said plainly before Start.
    public var isUnderpowered: Bool {
        guard let mde else { return true }
        return mde > 2 * mcid
    }

    // MARK: Canonical form and hash

    /// Canonical JSON: keys sorted, numbers in fixed `%.9f`, integers in decimal, the schedule as a
    /// string of 1/0. Byte-stable across runs and reproducible by a twin.
    public func canonicalJSON() -> String {
        func num(_ v: Double?) -> String {
            guard let v, v.isFinite else { return "null" }
            return String(format: "%.9f", v)
        }
        func str(_ s: String) -> String {
            var out = "\""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                default:
                    if ch.value < 0x20 {
                        let hex = String(ch.value, radix: 16)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    } else {
                        out.unicodeScalars.append(ch)
                    }
                }
            }
            return out + "\""
        }
        func list(_ items: [String]) -> String { "[" + items.map(str).joined(separator: ",") + "]" }
        let fields: [(String, String)] = [
            ("affectsEffort", affectsEffort ? "true" : "false"),
            ("alpha", num(alpha)),
            ("baselineMedian", num(baselineMedian)),
            ("baselineNights", String(baselineNights)),
            ("baselineRho", num(baselineRho)),
            ("baselineSD", num(baselineSD)),
            ("carryOver", str(carryOver.rawValue)),
            ("covariates", list(covariates.map { $0.rawValue })),
            ("design", str(design.tag)),
            ("direction", str(direction.rawValue)),
            ("interventionId", str(interventionId)),
            ("lag", str(lag.rawValue)),
            ("lengthDays", String(lengthDays)),
            ("mcid", num(mcid)),
            ("mde", num(mde)),
            ("permutations", String(permutations)),
            ("primaryOutcome", str(primaryOutcome.rawValue)),
            ("registeredOn", str(registeredOn)),
            ("schedule", str(schedule.map { $0 ? "1" : "0" }.joined())),
            ("secondaryOutcomes", list(secondaryOutcomes.map { $0.rawValue })),
            ("seed", String(seed)),
            ("startDay", str(startDay)),
            ("trialId", str(trialId)),
        ]
        return "{" + fields.map { str($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    /// FNV-1a 64 over the canonical JSON's UTF-16 code units, 16 lowercase hex digits.
    public var hash: String { HabitTrialRegistration.fnv1a64Hex(canonicalJSON()) }

    /// Whether `storedHash` still matches this record.
    public func verify(storedHash: String) -> Bool { storedHash == hash }

    public static func fnv1a64Hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for u in s.utf16 {
            h = (h ^ UInt64(u)) &* 0x0000_0100_0000_01b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

// MARK: - Life cycle and the sealed view

/// Where a trial is in its life.
public enum HabitTrialState: String, Codable, Sendable {
    case draft, running, completed, stoppedEarly
}

/// Did the wearer do the ON behaviour on a day (ON day: followed; OFF day: contamination)?
public enum HabitTrialBehaviour: String, Codable, Sendable {
    case did, didNot, unknown
}

/// Everything a RUNNING trial may expose: counts only. There is no estimate, interval, mean or p-value
/// field on this type, by construction — results stay sealed until the trial ends.
public struct HabitTrialProgress: Equatable, Codable, Sendable {
    public let trialId: String
    public let interventionId: String
    /// 1-based day number today (0 before the start, `lengthDays` after the end).
    public let dayNumber: Int
    public let lengthDays: Int
    /// Today's arm, revealed on the day itself only. Nil outside the trial window.
    public let todayOn: Bool?
    /// Share of elapsed ON days answered "did it". Nil before the first ON day has passed.
    public let adherence: Double?
    /// Days whose answer is still unknown, among elapsed days.
    public let unanswered: Int
    /// Scored (valid) nights so far, per arm, and the planned analysable nights per arm.
    public let validOn: Int
    public let validOff: Int
    public let plannedPerArm: Int
    /// Results stay sealed until this day (the morning the last night is scored).
    public let sealedUntil: String

    /// Builds the sealed view from the registration, today, the per-day answers and the set of outcome
    /// keys that have a value. Reads NO outcome value.
    public static func make(registration r: HabitTrialRegistration, today: String,
                            behaviour: [String: HabitTrialBehaviour],
                            scoredOutcomeKeys: Set<String>) -> HabitTrialProgress {
        let idx = HabitDay.days(from: r.startDay, to: today) ?? -1
        let dayNumber = Swift.max(0, Swift.min(r.lengthDays, idx + 1))
        let todayOn: Bool? = (idx >= 0 && idx < r.schedule.count) ? r.schedule[idx] : nil
        let washout = HabitTrialSchedule.washoutMask(design: r.design, lengthDays: r.lengthDays)
        var onElapsed = 0, onFollowed = 0, unanswered = 0, validOn = 0, validOff = 0
        // Elapsed = strictly before today (today can still be answered).
        let elapsed = Swift.max(0, Swift.min(r.lengthDays, idx, r.schedule.count, washout.count))
        for i in 0..<elapsed {
            guard let day = HabitDay.adding(i, to: r.startDay) else { continue }
            let b = behaviour[day] ?? .unknown
            if b == .unknown { unanswered += 1 }
            if r.schedule[i] {
                onElapsed += 1
                if b == .did { onFollowed += 1 }
            }
            if !washout[i], let key = r.lag.outcomeKey(for: day), scoredOutcomeKeys.contains(key) {
                if r.schedule[i] { validOn += 1 } else { validOff += 1 }
            }
        }
        return HabitTrialProgress(
            trialId: r.trialId, interventionId: r.interventionId, dayNumber: dayNumber,
            lengthDays: r.lengthDays, todayOn: todayOn,
            adherence: onElapsed > 0 ? Double(onFollowed) / Double(onElapsed) : nil,
            unanswered: unanswered, validOn: validOn, validOff: validOff,
            plannedPerArm: HabitTrialSchedule.analysableDaysPerArm(design: r.design, lengthDays: r.lengthDays),
            sealedUntil: r.lastOutcomeKey)
    }
}
