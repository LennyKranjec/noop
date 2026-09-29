import Foundation

// HabitTrialSchedule.swift — the ON/OFF assignment of a habit trial, and its re-draws.
//
// HEALTH_V2 §S1-B.3. Two designs, chosen by the intervention's carry-over class, never by the wearer:
//
//   * weekdayBalanced — for each weekday position independently, exactly half its occurrences are ON,
//     chosen by a seeded Fisher–Yates shuffle. Weekday (the strongest routine confounder: weekend
//     bedtimes, alcohol, training) is balanced EXACTLY, and the two arms are exactly 50/50.
//   * blocked(4, 1) — for phase interventions (morning daylight), whose effect builds and decays over
//     days: 4-day blocks, exactly half ON by complete randomisation, and the first day of every block is a
//     washout day whose outcome is not analysed.
//
// `make` (the registered schedule) and `redraw` (every permutation of the randomisation test) go through
// ONE function, `assignments`, so the permutation null re-draws the assignment with exactly the procedure
// that produced it. That identity is what makes the test exact whatever the autocorrelation.

/// Which design a trial uses.
public enum HabitTrialDesign: Equatable, Codable, Sendable {
    case weekdayBalanced
    case blocked(blockDays: Int, washoutDays: Int)

    /// The phase design HEALTH_V2 specifies.
    public static let phaseBlocks = HabitTrialDesign.blocked(blockDays: 4, washoutDays: 1)

    /// The lengths a wearer may choose.
    public var allowedLengths: [Int] {
        switch self {
        case .weekdayBalanced: return [28, 42, 56]
        case .blocked(let blockDays, _):
            // 28-day phase trials are not offered: 7 blocks cannot be split evenly and the randomisation
            // distribution is too coarse to ever reach α.
            return blockDays == 4 ? [48, 56] : []
        }
    }

    /// A stable text tag for the canonical record.
    public var tag: String {
        switch self {
        case .weekdayBalanced: return "weekdayBalanced"
        case .blocked(let b, let w): return "blocked(\(b),\(w))"
        }
    }
}

/// One day of a trial.
public struct HabitTrialDay: Equatable, Codable, Sendable {
    /// 0-based index within the trial.
    public let index: Int
    /// The assignment day `D` (local `yyyy-MM-dd`).
    public let day: String
    public let on: Bool
    /// Instruction applies, outcome not analysed.
    public let washout: Bool

    public init(index: Int, day: String, on: Bool, washout: Bool) {
        self.index = index
        self.day = day
        self.on = on
        self.washout = washout
    }
}

public enum HabitTrialSchedule {

    /// Whether `lengthDays` is valid for `design`.
    public static func isValid(design: HabitTrialDesign, lengthDays: Int) -> Bool {
        guard design.allowedLengths.contains(lengthDays) else { return false }
        switch design {
        case .weekdayBalanced:
            return lengthDays % 7 == 0 && (lengthDays / 7) % 2 == 0
        case .blocked(let blockDays, let washoutDays):
            guard blockDays >= 2, washoutDays >= 0, washoutDays < blockDays,
                  lengthDays % blockDays == 0 else { return false }
            return (lengthDays / blockDays) % 2 == 0
        }
    }

    /// The ON/OFF vector for `design`, `lengthDays` and `seed`. Empty when the combination is invalid.
    ///
    /// THE CONTRACT (reproduced exactly by any twin): one `DeterministicRNG(seed:)`;
    /// weekdayBalanced — for position class w = 0…6 in order, the occurrences w, w+7, … are shuffled
    /// (Fisher–Yates, last index down) and the first half of the shuffled list is ON;
    /// blocked — the block indices 0…B−1 are shuffled once and the first half are ON blocks.
    public static func assignments(design: HabitTrialDesign, lengthDays: Int, seed: UInt64) -> [Bool] {
        guard isValid(design: design, lengthDays: lengthDays) else { return [] }
        var rng = DeterministicRNG(seed: seed)
        var on = [Bool](repeating: false, count: lengthDays)
        switch design {
        case .weekdayBalanced:
            let perClass = lengthDays / 7
            for w in 0..<7 {
                var positions = (0..<perClass).map { w + 7 * $0 }
                rng.shuffle(&positions)
                for k in 0..<(perClass / 2) { on[positions[k]] = true }
            }
        case .blocked(let blockDays, _):
            let blocks = lengthDays / blockDays
            var order = Array(0..<blocks)
            rng.shuffle(&order)
            for k in 0..<(blocks / 2) {
                let b = order[k]
                for i in (b * blockDays)..<((b + 1) * blockDays) { on[i] = true }
            }
        }
        return on
    }

    /// Which days are washout days (instruction applies, outcome not analysed).
    public static func washoutMask(design: HabitTrialDesign, lengthDays: Int) -> [Bool] {
        switch design {
        case .weekdayBalanced:
            return [Bool](repeating: false, count: Swift.max(0, lengthDays))
        case .blocked(let blockDays, let washoutDays):
            guard blockDays >= 1 else { return [Bool](repeating: false, count: Swift.max(0, lengthDays)) }
            return (0..<Swift.max(0, lengthDays)).map { $0 % blockDays < washoutDays }
        }
    }

    /// The registered schedule, day by day. Empty when the inputs are invalid.
    public static func make(design: HabitTrialDesign, lengthDays: Int, startDay: String,
                            seed: UInt64) -> [HabitTrialDay] {
        guard HabitDay.epochDay(startDay) != nil else { return [] }
        let on = assignments(design: design, lengthDays: lengthDays, seed: seed)
        guard !on.isEmpty else { return [] }
        let washout = washoutMask(design: design, lengthDays: lengthDays)
        var out: [HabitTrialDay] = []
        out.reserveCapacity(lengthDays)
        for i in 0..<lengthDays {
            guard let day = HabitDay.adding(i, to: startDay) else { return [] }
            out.append(HabitTrialDay(index: i, day: day, on: on[i], washout: washout[i]))
        }
        return out
    }

    /// One permutation of the randomisation test: the SAME procedure, a fresh seed.
    public static func redraw(design: HabitTrialDesign, days: Int, seed: UInt64) -> [Bool] {
        assignments(design: design, lengthDays: days, seed: seed)
    }

    /// The seed of permutation `index` for a trial registered with `registeredSeed`.
    public static func permutationSeed(registered: UInt64, index: Int) -> UInt64 {
        DeterministicRNG.derive(registered, stream: 0x7065_726D, index: UInt64(index))  // "perm"
    }

    /// Scheduled analysable (non-washout) days per arm.
    public static func analysableDaysPerArm(design: HabitTrialDesign, lengthDays: Int) -> Int {
        switch design {
        case .weekdayBalanced:
            return lengthDays / 2
        case .blocked(let blockDays, let washoutDays):
            guard blockDays > 0 else { return 0 }
            return (lengthDays / blockDays / 2) * (blockDays - washoutDays)
        }
    }
}
