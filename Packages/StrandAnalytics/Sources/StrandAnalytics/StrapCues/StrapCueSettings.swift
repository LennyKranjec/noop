import Foundation

// StrapCueSettings.swift — the wearer's Strap-cue settings as ONE pure value, with the defaults and the
// allowed options in one place so the settings screen, the runtime and the tests cannot disagree.
//
// DEFAULTS. Every cue is OFF except the sitting-break nudge, which the owner asked for. That default does
// not make a fresh install buzz on its own: the nudge abstains until Motion & Fitness is granted (it has no
// honest live signal without it), and — like every ambient wrist buzz in the app — it is held while the
// "Wrist alerts" master switch (`notif.masterEnabled`) is off. Requested cues (pacer, focus block,
// meditation timer) are started by the wearer and are not held by that switch.
//
// Pure, Codable (the app persists it as one JSON blob), Swift-only in 2.0.

public struct StrapCueSettings: Equatable, Sendable, Codable {

    // MARK: Sitting-break nudge (the priority cue)
    public var sittingBreakEnabled: Bool
    /// Minutes with no movement break before the nudge. One of `sittingIntervalOptions`.
    public var sittingIntervalMinutes: Int

    // MARK: Breathing pacer
    public var breathingPacerEnabled: Bool
    /// Length of the PACED part (the quiet readings before and after are extra). One of `breathingOptions`.
    public var breathingMinutes: Int
    /// Breaths per minute. 6 is the slow-breathing pace the pacer is built around.
    public var breathingPaceBpm: Double

    // MARK: Evening
    public var windDownEnabled: Bool
    public var screensOffEnabled: Bool

    // MARK: Timers the wearer starts
    public var focusBlocksEnabled: Bool
    /// One of `focusOptions`.
    public var focusMinutes: Int
    public var meditationTimerEnabled: Bool
    /// One of `meditationOptions`; never below `meditationMinimumMinutes`.
    public var meditationMinutes: Int

    // MARK: System rules
    /// Unrequested cues per local day.
    public var dailyBudget: Int
    /// Quiet hours, local minute-of-day, may cross midnight. start == end means no quiet hours.
    public var quietStartMin: Int
    public var quietEndMin: Int
    /// Buzz the PHONE when the strap cannot be reached — only ever while NOOP is in the foreground.
    public var phoneFallbackEnabled: Bool

    public init(sittingBreakEnabled: Bool = true,
                sittingIntervalMinutes: Int = StrapCueSettings.defaultSittingIntervalMinutes,
                breathingPacerEnabled: Bool = false,
                breathingMinutes: Int = 5,
                breathingPaceBpm: Double = 6,
                windDownEnabled: Bool = false,
                screensOffEnabled: Bool = false,
                focusBlocksEnabled: Bool = false,
                focusMinutes: Int = 50,
                meditationTimerEnabled: Bool = false,
                meditationMinutes: Int = StrapCueSettings.meditationMinimumMinutes,
                dailyBudget: Int = StrapCueSettings.defaultDailyBudget,
                quietStartMin: Int = 22 * 60,
                quietEndMin: Int = 7 * 60,
                phoneFallbackEnabled: Bool = true) {
        self.sittingBreakEnabled = sittingBreakEnabled
        self.sittingIntervalMinutes = sittingIntervalMinutes
        self.breathingPacerEnabled = breathingPacerEnabled
        self.breathingMinutes = breathingMinutes
        self.breathingPaceBpm = breathingPaceBpm
        self.windDownEnabled = windDownEnabled
        self.screensOffEnabled = screensOffEnabled
        self.focusBlocksEnabled = focusBlocksEnabled
        self.focusMinutes = focusMinutes
        self.meditationTimerEnabled = meditationTimerEnabled
        self.meditationMinutes = meditationMinutes
        self.dailyBudget = dailyBudget
        self.quietStartMin = quietStartMin
        self.quietEndMin = quietEndMin
        self.phoneFallbackEnabled = phoneFallbackEnabled
    }

    public static let defaultSittingIntervalMinutes = 30
    public static let sittingIntervalOptions = [30, 45, 60]
    public static let breathingOptions = [3, 5, 10]
    public static let focusOptions = [25, 50, 90]
    /// The meditation minimum from 2026-09-29 (DESIGN_V2 item 12) is also the timer's floor.
    public static let meditationMinimumMinutes = 10
    public static let meditationOptions = [10, 15, 20, 30]
    public static let defaultDailyBudget = 8
    public static let budgetRange = 1...20

    /// The same settings with every value snapped onto something the screen can show — a corrupted or
    /// older blob can never schedule a 7-minute sitting interval or a 3-minute meditation.
    public func sanitized() -> StrapCueSettings {
        var s = self
        s.sittingIntervalMinutes = Self.nearest(sittingIntervalMinutes, in: Self.sittingIntervalOptions)
        s.breathingMinutes = Self.nearest(breathingMinutes, in: Self.breathingOptions)
        s.breathingPaceBpm = breathingPaceBpm.isFinite ? min(max(breathingPaceBpm, 4.5), 7) : 6
        s.focusMinutes = Self.nearest(focusMinutes, in: Self.focusOptions)
        s.meditationMinutes = Self.nearest(max(meditationMinutes, Self.meditationMinimumMinutes),
                                           in: Self.meditationOptions)
        s.dailyBudget = min(max(dailyBudget, Self.budgetRange.lowerBound), Self.budgetRange.upperBound)
        s.quietStartMin = SleepClock.wrap(quietStartMin)
        s.quietEndMin = SleepClock.wrap(quietEndMin)
        return s
    }

    /// Whether a cue kind's switch is on. The pacer's phase cues ride the pacer's switch.
    public func isEnabled(_ kind: StrapCueKind) -> Bool {
        switch kind {
        case .sittingBreak: return sittingBreakEnabled
        case .breathInhale, .breathExhale, .breathingDone: return breathingPacerEnabled
        case .windDown: return windDownEnabled
        case .screensOff: return screensOffEnabled
        case .focusEnd: return focusBlocksEnabled
        case .meditationEnd: return meditationTimerEnabled
        }
    }

    static func nearest(_ v: Int, in options: [Int]) -> Int {
        options.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
    }
}
