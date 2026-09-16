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
//     it happened before the day began.
//   · STRAIN spends it. Both the active strain of a session and the passive strain of moving about and
//     carrying an elevated heart rate outside one.
//   · STRESS spends it faster. High stress drains; low stress preserves. EXERCISE stress is excluded
//     from the stress figure itself — `DaytimeStress` masks ambulatory hours — but it is not free: it
//     is already counted, once, as strain.
//   · REST returns some. Calm hours, a nap, light activity: when stress is low the balance recovers
//     gradually rather than only ever falling.
//
// IT IS A MODEL AND SAYS SO. The weights below are a stated arrangement, not a measured physiology,
// and this file names them in one place so they can be argued with rather than being scattered through
// a view as literals. What it is NOT is a fabricated measurement: every input is a figure the app
// already computes from the wearer's own data, and a missing input makes the balance UNKNOWN rather
// than assumed.
//
// NOTHING IS COUNTED TWICE. A hard session raises strain AND would raise a naive stress figure; the
// stress input here is the non-activity one for exactly that reason.

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
    /// What is left, 0–100.
    public let balance: Double

    public init(opening: Double, strainSpend: Double, stressSpend: Double,
                restReturn: Double, balance: Double) {
        self.opening = opening
        self.strainSpend = strainSpend
        self.stressSpend = stressSpend
        self.restReturn = restReturn
        self.balance = balance
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
    // spread through a view.

    /// How much of the opening balance recovery decides, against sleep.
    ///
    /// Recovery leads because it is the overnight verdict on the whole autonomic picture; the sleep
    /// score is one input to that verdict and would otherwise be counted twice at full weight.
    public static let recoveryShare = 0.7
    public static let sleepShare = 0.3

    /// Points a full day of strain spends. A maximal WHOOP day (21) takes most of the balance, which is
    /// what a maximal day feels like; it does not take all of it, because a person at 21 strain is
    /// tired rather than incapable.
    public static let strainCost = 55.0

    /// Points a full waking day of non-activity high stress spends.
    public static let stressCost = 25.0

    /// Points a full waking day of calm returns. The smallest of the three on purpose: resting recovers
    /// some of a day, and a claim that it recovers all of one would make every quiet afternoon read as
    /// a second morning.
    public static let restReturnMax = 15.0

    /// The waking day the stress and rest figures are measured against, in minutes.
    public static let wakingMinutes = 16.0 * 60

    /// WHOOP's strain ceiling, which is the scale `strain` arrives on.
    public static let strainMax = 21.0

    /// The day's balance, or nil when there is not enough to say.
    ///
    /// NIL RATHER THAN A DEFAULT. With no recovery and no sleep score there is no opening balance, and
    /// a bank drawn from an assumed 50 would be a number about nobody. The spends are optional
    /// individually — a day with no stress read still has a strain figure worth spending — and an
    /// absent one simply spends nothing.
    ///
    /// - Parameters:
    ///   - recovery: the overnight recovery score, 0–100.
    ///   - sleepScore: the night's sleep performance, 0–100.
    ///   - strain: the day's strain so far, on WHOOP's 0–21 scale.
    ///   - stressMinutes: minutes of NON-ACTIVITY high stress so far — see the note at the top on why
    ///     the exercise kind is excluded here.
    ///   - calmMinutes: minutes the day has spent at low stress.
    public static func balance(
        recovery: Double?,
        sleepScore: Double?,
        strain: Double?,
        stressMinutes: Double?,
        calmMinutes: Double?
    ) -> EnergyBalance? {
        let opening: Double
        switch (recovery, sleepScore) {
        case let (r?, s?):
            opening = recoveryShare * r + sleepShare * s
        case let (r?, nil):
            opening = r
        case let (nil, s?):
            // Sleep alone is a weaker claim than recovery, and saying so is better than pretending the
            // two are interchangeable: a night scored well after a hard week is not a full tank.
            opening = s * 0.9
        default:
            return nil
        }

        let strainSpend = strain.map { Swift.min(Swift.max($0, 0), strainMax) / strainMax * strainCost } ?? 0
        let stressSpend = stressMinutes.map {
            Swift.min(Swift.max($0, 0), wakingMinutes) / wakingMinutes * stressCost
        } ?? 0
        let restReturn = calmMinutes.map {
            Swift.min(Swift.max($0, 0), wakingMinutes) / wakingMinutes * restReturnMax
        } ?? 0

        // THE RETURN CANNOT EXCEED WHAT WAS SPENT. Calm hours recover a day; they do not add energy the
        // day never had. Without this clamp a quiet day would end above the balance it woke with, which
        // would say that doing nothing is restorative beyond a night's sleep.
        let spent = strainSpend + stressSpend
        let credited = Swift.min(restReturn, spent)

        let balance = Swift.min(Swift.max(opening - spent + credited, 0), 100)
        return EnergyBalance(opening: Swift.min(Swift.max(opening, 0), 100),
                             strainSpend: strainSpend,
                             stressSpend: stressSpend,
                             restReturn: credited,
                             balance: balance)
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
}
