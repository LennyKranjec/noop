import Foundation
#if canImport(CoreHaptics)
import CoreHaptics
#endif
#if canImport(UIKit)
import UIKit
#endif

// SystemHaptics.swift — the app you can feel.
//
// Swift twin of the Android `com.noop.ui.SystemHaptics`. The wearer asked for the whole app to be
// haptic, so the bond between human and system is something the hand notices and not just the eye.
// That is a real design goal and also a real hazard: a phone that buzzes at everything becomes a phone
// people silence, and then the ONE buzz that mattered — a quest arriving — is gone with the rest.
//
// So this is a small, deliberate vocabulary rather than a feedback generator scattered through the UI:
//
//   · tick    — a letter landing as the system types. Barely there, and there are hundreds of them.
//   · tap     — a control answered. The everyday one.
//   · select  — a choice changed: a tab, a segment, a model.
//   · confirm — something committed: a quest accepted, XP claimed.
//   · summon  — the system wants attention. Reserved for a quest arriving, and nothing else.
//
// INTENSITY IS THE POINT, not duration — the same rule the Android lane states in amplitude terms. A
// full-strength jolt is a jolt; the same event at a quarter is a tick you feel in the fingertip and not
// in the room. CoreHaptics expresses that directly as `hapticIntensity`, so the five cues are one
// transient event each at five intensities, and the summon is the one real pattern.
//
// CORE HAPTICS, WITH UIKit BEHIND IT. `CHHapticEngine` is the only way to play the rising three-pulse
// summon and the only way to make a tick quiet enough to fire per letter. Where it is unavailable — an
// older device, an engine that refuses to start, the Simulator, macOS — every cue falls back to the
// UIKit generator that is closest in feel, so the app is never silent for a reason the wearer cares
// about. On macOS the whole thing is a no-op.
//
// THE ENGINE IS STARTED LAZILY AND KEPT. Starting one costs tens of milliseconds, which is fine once
// and catastrophic per letter of a typewriter running at 25 Hz. It is also restarted on the system's
// reset and stopped handlers, because iOS tears the engine down when the app backgrounds and a dead
// engine otherwise means the haptics never come back for the rest of the session.
//
// Every call is best-effort and swallows its failures: haptics are a garnish, and a missing engine, a
// revoked capability or a device quirk must never be able to take down the screen using it.

enum SystemHaptics {

    /// One of the five gestures above. Named for what it MEANS, not for how hard it buzzes.
    enum Cue: CaseIterable {
        /// Per-letter typewriter tick. Must be cheap: a 200-character line fires this 200 times.
        case tick
        case tap
        case select
        case confirm
        /// A quest arriving. A pattern, not a single event — see `summonPattern`.
        case summon

        /// 0–1, matching the Android amplitudes (0–255) divided through.
        var intensity: Float {
            switch self {
            // 120, not the 40 the Android amplitude scale uses. Android's amplitude and CoreHaptics'
            // `hapticIntensity` are not the same scale and do not share a perceptual floor: 40/255 is
            // 0.16 here, which on the Taptic Engine is below the threshold at which a transient is
            // felt at all. The typewriter was firing every letter and the hand felt nothing.
            case .tick: return 120.0 / 255
            case .tap: return 90.0 / 255
            case .select: return 130.0 / 255
            case .confirm: return 200.0 / 255
            case .summon: return 1
            }
        }

        /// How sharp the transient reads. A tick is a pinprick; a confirm is a thud.
        var sharpness: Float {
            switch self {
            case .tick: return 0.9
            case .tap: return 0.7
            case .select: return 0.6
            case .confirm: return 0.4
            case .summon: return 0.5
            }
        }
    }

    /// Whether the app-wide haptics fire. DEFAULT ON — the wearer asked for a phone they can feel — but
    /// switchable, because this is exactly the kind of thing that is delightful for a week and then is
    /// not. Same key as the Android lane so an exported settings blob reads the same on both.
    static let prefKey = "haptics.appWide"

    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: prefKey) as? Bool) ?? true
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: prefKey)
    }

    /// Fire `cue`. Silent no-op when haptics are off, unsupported, or the device refuses.
    @MainActor
    static func play(_ cue: Cue) {
        guard enabled else { return }
        #if os(iOS)
        if cue == .summon {
            if !Engine.shared.playSummon() { fallback(cue) }
        } else if !Engine.shared.playTransient(cue) {
            fallback(cue)
        }
        #endif
    }

    /// The shortest gap between two ticks that the hardware can still render as two.
    ///
    /// THIS IS THE OTHER HALF OF WHY THE TYPEWRITER FELT LIKE NOTHING. The line types at ~26 Hz, and
    /// the Taptic Engine's actuator cannot strike, settle and strike again in 38 ms — the requests
    /// arrive faster than it can reset, so they smear into one indistinct hum or are dropped outright.
    /// At ~13 Hz each letter lands as its own event and the line reads through the fingertip as a run
    /// of taps, which is the thing that was asked for.
    ///
    /// Every OTHER letter, in other words. That is not a compromise: two events the hand cannot tell
    /// apart are one event that cost twice as much.
    private static let minimumTickInterval: TimeInterval = 0.075
    @MainActor private static var lastTickAt: TimeInterval = 0

    /// A tick that does NOT re-read preferences.
    ///
    /// The typewriter fires one per letter, and a defaults read per letter is both wasteful and — on a
    /// slow device — enough to make the animation stutter. The caller reads `enabled` once, holds it,
    /// and calls this.
    @MainActor
    static func tick() {
        #if os(iOS)
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastTickAt >= minimumTickInterval else { return }
        lastTickAt = now
        if !Engine.shared.playTransient(.tick) {
            // No fallback here on purpose: `UIImpactFeedbackGenerator` at .light is far heavier than a
            // tick, and firing it per letter is the "phone people silence" failure mode. A device
            // without CoreHaptics simply types silently.
        }
        #endif
    }

    /// Warm the engine so the first cue of a screen is not the one that pays for the start.
    @MainActor
    static func prepare() {
        #if os(iOS)
        guard enabled else { return }
        Engine.shared.prepare()
        #endif
    }

    /// Hold the engine open across a burst of ticks, then let it go. See `Engine.holdOpen`.
    ///
    /// ALWAYS PAIRED. The typewriter opens it when a line starts and closes it when the line finishes
    /// or is cancelled, so a screen that is dismissed mid-type cannot leave the hardware awake.
    @MainActor
    static func holdTickEngine(_ hold: Bool) {
        #if os(iOS)
        guard enabled else { return }
        Engine.shared.holdOpen(hold)
        #endif
    }

    #if os(iOS)
    /// The closest UIKit generator, for devices and builds where CoreHaptics will not run.
    @MainActor
    private static func fallback(_ cue: Cue) {
        switch cue {
        case .tick: break
        case .tap: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .select: UISelectionFeedbackGenerator().selectionChanged()
        case .confirm: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .summon: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
    #endif
}

#if os(iOS) && canImport(CoreHaptics)

/// The one long-lived `CHHapticEngine`, and everything that can go wrong with it.
///
/// `final class`, not an actor: a haptic is fired from the main thread at the moment of a tap or a
/// letter, and hopping actors to buzz would put the feel of the app behind a scheduling boundary. All
/// mutation is confined to the main actor instead, which is where every call site already is.
@MainActor
private final class Engine {

    static let shared = Engine()

    private var engine: CHHapticEngine?
    /// Set once the hardware has told us it cannot do this, so we stop trying on every tap.
    private var unsupported = false

    /// The summon pattern: three rising pulses, because a quest arriving should not feel like a
    /// notification. The Android lane spells the same shape as a waveform of timings and amplitudes;
    /// these are the same three pulses at the same rising strengths, with the gaps between them
    /// expressed as event offsets rather than as silent waveform segments.
    private static let summonPattern: [(offset: TimeInterval, intensity: Float, sharpness: Float)] = [
        (0.00, 110.0 / 255, 0.35),
        (0.10, 170.0 / 255, 0.45),
        (0.20, 255.0 / 255, 0.60),
    ]

    func prepare() {
        _ = ensureEngine()
    }

    /// Keep the hardware awake for the length of a typed line.
    ///
    /// `isAutoShutdownEnabled` is right for an app that ticks once a minute and wrong for one that is
    /// about to tick forty times in three seconds: the engine idles out between letters and every
    /// restart costs tens of milliseconds, during which the ticks are simply lost. The typewriter
    /// holds it open and lets go at the end of the line.
    func holdOpen(_ hold: Bool) {
        guard let engine = ensureEngine() else { return }
        engine.isAutoShutdownEnabled = !hold
        if hold { try? engine.start() }
    }

    /// Play one transient. False when CoreHaptics could not, so the caller can fall back.
    func playTransient(_ cue: SystemHaptics.Cue) -> Bool {
        guard let engine = ensureEngine() else { return false }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: cue.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: cue.sharpness),
            ],
            relativeTime: 0)
        return play(events: [event], on: engine)
    }

    /// Play the summon. False when CoreHaptics could not.
    func playSummon() -> Bool {
        guard let engine = ensureEngine() else { return false }
        let events = Self.summonPattern.map { pulse in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
                ],
                relativeTime: pulse.offset)
        }
        return play(events: events, on: engine)
    }

    private func play(events: [CHHapticEvent], on engine: CHHapticEngine) -> Bool {
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            // One failure is usually a torn-down engine rather than a broken device, so drop it and let
            // the next call build a fresh one. Two in a row on a device that cannot do this at all are
            // caught by `unsupported` above, which is set from the hardware capabilities, not from here.
            self.engine = nil
            return false
        }
    }

    private func ensureEngine() -> CHHapticEngine? {
        guard !unsupported else { return nil }
        if let engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            unsupported = true
            return nil
        }
        do {
            let created = try CHHapticEngine()
            // iOS tears the engine down when the app backgrounds or the audio session is interrupted. A
            // dead engine that is never restarted means the haptics silently stop for the rest of the
            // session — which is exactly the kind of "it worked yesterday" bug nobody can reproduce.
            created.resetHandler = { [weak created] in try? created?.start() }
            created.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            // Let the engine idle out between cues rather than holding the hardware awake for a tick
            // that may not come again for minutes.
            created.isAutoShutdownEnabled = true
            try created.start()
            engine = created
            return created
        } catch {
            engine = nil
            return nil
        }
    }
}

#elseif os(iOS)

/// CoreHaptics is unavailable in this build: every cue takes the UIKit path.
@MainActor
private final class Engine {
    static let shared = Engine()
    func prepare() {}
    func holdOpen(_ hold: Bool) {}
    func playTransient(_ cue: SystemHaptics.Cue) -> Bool { false }
    func playSummon() -> Bool { false }
}

#endif
