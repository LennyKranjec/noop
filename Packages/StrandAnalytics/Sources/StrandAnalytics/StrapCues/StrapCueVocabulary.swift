import Foundation

// StrapCueVocabulary.swift — THE ONE PLACE the strap-cue patterns are defined (Telos 2.0 "Strap cues").
//
// WHAT THE MOTOR CAN DO. A WHOOP buzz is one fixed-length motor run per loop (roughly 0.67 s per loop,
// `runHapticsPattern` patternId 2; on a 5/MG `send` remaps it to the maverick notify buzz, whose
// `overallLoop` repeats the waveform back to back). Nothing else is controllable from the app: not the
// intensity, not the waveform. So a pattern is a list of DISCRETE pulses, each `loops` long, walked from
// the app with a real silence between them — the same "walk" the zone-lock cue and the Haptic Clock use,
// because "2 loops" is one longer run, not two taps, and only a gap makes two pulses feel like two.
//
// THE VOCABULARY (each cue TYPE has exactly one pattern; `StrapCueVocabularyTests` pins that no two
// patterns are the same and that every gap is felt):
//
//   pattern      pulses (offset ms : loops)        felt as                 used by
//   ─────────    ─────────────────────────────     ────────────────────    ─────────────────────────────
//   move         0:1, 1000:1                       two short taps          sitting-break nudge
//   inhale       0:1                               one short               breathing pacer, inhale onset
//   exhale       0:2                               one long                breathing pacer, exhale onset
//   windDown     0:2, 2200:2                       two slow long pulses    wind-down cue
//   screensOff   0:1, 1000:1, 2000:1               three short taps        "screens off" cue
//   timesUp      0:3                               one extra-long          focus block / meditation / pacer end
//
// inhale = 1 loop and exhale = 2 loops are the SHIPPED Breathe language (`BreathPacer.inhaleLoops` /
// `exhaleLoops`), kept so existing users do not have to relearn it. "Two short taps" is also the zone-lock
// "speed up" cue (`AppModel.playZoneCue`); the two never meet because an active workout suppresses the
// sitting-break nudge. The three "time's up" cues share one pattern on purpose: they mean the same thing —
// a timer the wearer started has ended — and the wearer knows which timer they started.
//
// Pure, deterministic, no I/O. Swift-only in 2.0 (iOS feature; there is no Android twin of Strap cues).

/// One pulse of a strap-cue pattern: `loops` motor loops starting `offsetMs` after the pattern starts.
public struct StrapCuePulse: Equatable, Sendable, Codable {
    public let offsetMs: Int
    public let loops: Int

    public init(offsetMs: Int, loops: Int) {
        self.offsetMs = offsetMs
        self.loops = loops
    }
}

/// The distinct felt patterns. One per cue TYPE (see the table in the file header).
public enum StrapCuePattern: String, CaseIterable, Sendable, Codable {
    case move
    case inhale
    case exhale
    case windDown
    case screensOff
    case timesUp

    /// The pulses, in time order.
    public var pulses: [StrapCuePulse] {
        switch self {
        case .move:       return [StrapCuePulse(offsetMs: 0, loops: 1), StrapCuePulse(offsetMs: 1000, loops: 1)]
        case .inhale:     return [StrapCuePulse(offsetMs: 0, loops: 1)]
        case .exhale:     return [StrapCuePulse(offsetMs: 0, loops: 2)]
        case .windDown:   return [StrapCuePulse(offsetMs: 0, loops: 2), StrapCuePulse(offsetMs: 2200, loops: 2)]
        case .screensOff: return [StrapCuePulse(offsetMs: 0, loops: 1), StrapCuePulse(offsetMs: 1000, loops: 1),
                                  StrapCuePulse(offsetMs: 2000, loops: 1)]
        case .timesUp:    return [StrapCuePulse(offsetMs: 0, loops: 3)]
        }
    }

    /// How long the motor is busy with this pattern, start of the first pulse to the end of the last.
    public var durationMs: Int {
        pulses.map { $0.offsetMs + $0.loops * StrapCueVocabulary.motorMsPerLoop }.max() ?? 0
    }

    /// Plain words for the settings screen ("two short taps").
    public var feltAs: String {
        switch self {
        case .move:       return "two short taps"
        case .inhale:     return "one short"
        case .exhale:     return "one long"
        case .windDown:   return "two slow, long pulses"
        case .screensOff: return "three short taps"
        case .timesUp:    return "one extra-long"
        }
    }
}

/// Every cue the engine can send. Several kinds may share one pattern only when they MEAN the same thing
/// (the three "a timer you started has ended" kinds).
public enum StrapCueKind: String, CaseIterable, Sendable, Codable {
    case sittingBreak
    case breathInhale
    case breathExhale
    case breathingDone
    case windDown
    case screensOff
    case focusEnd
    case meditationEnd

    public var pattern: StrapCuePattern {
        switch self {
        case .sittingBreak:  return .move
        case .breathInhale:  return .inhale
        case .breathExhale:  return .exhale
        case .windDown:      return .windDown
        case .screensOff:    return .screensOff
        case .breathingDone, .focusEnd, .meditationEnd: return .timesUp
        }
    }

    /// True when the wearer ASKED for this cue by starting something (a pacer, a focus block, a meditation
    /// timer). Requested cues skip the daily budget, quiet hours and the one-minute spacing — they are the
    /// feature the wearer is using right now. Ambient cues (sitting break, wind-down, screens off) are
    /// unrequested and pay for every rule.
    public var isRequested: Bool {
        switch self {
        case .sittingBreak, .windDown, .screensOff: return false
        case .breathInhale, .breathExhale, .breathingDone, .focusEnd, .meditationEnd: return true
        }
    }

    /// Short English label for logs and the settings screen (localised at the view layer).
    public var label: String {
        switch self {
        case .sittingBreak:  return "Sitting break"
        case .breathInhale:  return "Breathe in"
        case .breathExhale:  return "Breathe out"
        case .breathingDone: return "Breathing done"
        case .windDown:      return "Wind-down"
        case .screensOff:    return "Screens off"
        case .focusEnd:      return "Focus block done"
        case .meditationEnd: return "Meditation done"
        }
    }
}

public enum StrapCueVocabulary {
    /// Approximate motor time of one loop (ms). The brief's "roughly 0.67 s per loop"; used only to know
    /// when the motor is free again and to check that gaps inside a pattern are real.
    public static let motorMsPerLoop = 670
    /// The smallest silence between two pulses of one pattern that still reads as two pulses. `HapticClock`
    /// uses 450 ms; 300 ms is the floor the vocabulary test enforces.
    public static let minFeltGapMs = 300
}
