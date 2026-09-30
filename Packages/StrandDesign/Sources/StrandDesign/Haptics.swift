import SwiftUI
#if os(watchOS)
import WatchKit
#elseif os(iOS)
import UIKit
#if canImport(CoreHaptics)
import CoreHaptics
#endif
#endif

// MARK: - Telos haptics — ONE vocabulary for the whole app (coordinator decision 8)
//
// The app is meant to be FELT, and that is exactly why the vocabulary is small: a phone that buzzes at
// everything gets silenced, and then the one buzz that mattered is gone with the rest. Every package
// maps its interactions onto these names and calls `TelosHaptics.play(_:)` — never a feedback
// generator directly.
//
// | pattern       | feel                                   | use for                                        |
// |---------------|----------------------------------------|------------------------------------------------|
// | `select`      | a light tick                           | a choice changed: segment, chip, toggle, tab   |
// | `settle`      | soft                                   | a value landed: score arrived, sheet snapped   |
// | `commit`      | rigid                                  | something committed: save, accept, log         |
// | `success`     | two rising taps                        | a real milestone: quest completed, debt cleared|
// | `warning`     | firm, then softer                      | not allowed / needs attention                  |
// | `failure`     | a heavier two-beat                     | a failed action, a refused input               |
// | `reward`      | a bright rising sparkle + swell        | a BIG reward: PR, quest / goal done, level up  |
// | `penalty`     | two heavy thuds over a low rumble      | a penalty landing, a broken streak             |
// | `levelSettle` | a slow three-step rise over a swell    | the day's Level settling (full-screen moment)  |
// | `heartbeat`   | one subtle lub-dub                     | RESERVED for full-screen moments about the heart|
// | `tick`        | a pinprick (≥ 75 ms apart)             | the typewriter, per letter (SystemHaptics)     |
// | `tap`         | barely-there                           | a control answered (SystemHaptics `tap`)       |
// | `summon`      | three quick rising pulses              | a quest arriving — nothing else                |
//
// `tick`, `tap` and `summon` are the app's existing `SystemHaptics` cues (Strand/Screens), carried here
// so that file can route through this one engine; the legacy `StrandHaptic` cases map onto the table
// (selection→select, light→tap, commit→commit, success→success, warning→warning).
//
// RULES the engine enforces (so a call site cannot get them wrong):
//   • The wearer's setting wins: `haptics.appWide` (the SystemHaptics key, default ON) — off means
//     silent everywhere.
//   • Reduce Motion, Low Power Mode and "Reduce motion in NOOP" (the `NoopMotionState` signals) keep the
//     information and drop the flourish: every multi-event pattern collapses to ONE transient.
//   • One action = one pattern. Two patterns closer than 80 ms are one action: the second is dropped.
//     The same pattern twice within 250 ms is a double-fire (a re-render) and is dropped. Pass
//     `action:` (e.g. a moment id) to dedupe an action for a full second.
//   • Never on scroll, never per list row appearing, never per frame. Haptics answer a touch or a state
//     change the wearer should notice.
//
// The STRAP buzz (decision 17: a reward pattern and a heavier penalty pattern on the wrist) is not this
// engine — it goes through the app's strap-cue system with its daily budget, never during sleep, never
// twice for one event. `TelosMoment.Kind.defaultStrapCue` names which one a moment wants
// (`TelosStrapCue.reward` / `.penalty`) so the moment presenter can request it alongside the phone
// pattern of the same name.
//
// Engine: ONE `CHHapticEngine`, created lazily on first use, auto-shutdown between cues, stopped when
// the app backgrounds and rebuilt on demand; the reset handler restarts it, the stopped handler drops
// it. Where Core Haptics is unavailable (older hardware, Simulator) each pattern falls back to the
// closest `UIFeedbackGenerator`. watchOS maps onto `WKHapticType` (the breathing / interval features
// rely on a real wrist cue); macOS is a no-op. Every call is best-effort and swallows failures.

// MARK: - The vocabulary

public enum TelosHaptic: String, CaseIterable, Sendable {
    case select
    case settle
    case commit
    case success
    case warning
    case failure
    case reward
    case penalty
    case levelSettle
    case heartbeat
    case tick
    case tap
    case summon

    /// The full pattern.
    public var events: [TelosHapticEvent] {
        switch self {
        case .select:
            return [.transient(0, intensity: 0.50, sharpness: 0.60)]
        case .settle:
            return [.transient(0, intensity: 0.35, sharpness: 0.20)]
        case .commit:
            return [.transient(0, intensity: 0.80, sharpness: 0.55)]
        case .success:
            return [.transient(0, intensity: 0.55, sharpness: 0.40),
                    .transient(0.09, intensity: 0.85, sharpness: 0.50)]
        case .warning:
            return [.transient(0, intensity: 0.75, sharpness: 0.35),
                    .transient(0.12, intensity: 0.50, sharpness: 0.25)]
        case .failure:
            return [.transient(0, intensity: 1.00, sharpness: 0.30),
                    .transient(0.16, intensity: 0.85, sharpness: 0.20)]
        case .reward:
            // Three quick rising sparkles over a short bright swell — vivid, but done in half a second.
            return [.continuous(0.05, duration: 0.40, intensity: 0.30, sharpness: 0.60),
                    .transient(0, intensity: 0.55, sharpness: 0.70),
                    .transient(0.09, intensity: 0.75, sharpness: 0.80),
                    .transient(0.18, intensity: 1.00, sharpness: 0.90)]
        case .penalty:
            // Heavier than `failure`: two full-strength dull thuds over a low rumble.
            return [.continuous(0, duration: 0.45, intensity: 0.45, sharpness: 0.05),
                    .transient(0, intensity: 1.00, sharpness: 0.15),
                    .transient(0.22, intensity: 1.00, sharpness: 0.10)]
        case .levelSettle:
            return [.continuous(0, duration: 0.55, intensity: 0.22, sharpness: 0.10),
                    .transient(0, intensity: 0.35, sharpness: 0.30),
                    .transient(0.22, intensity: 0.60, sharpness: 0.40),
                    .transient(0.44, intensity: 0.90, sharpness: 0.50)]
        case .heartbeat:
            return [.transient(0, intensity: 0.55, sharpness: 0.15),
                    .transient(0.14, intensity: 0.38, sharpness: 0.10)]
        case .tick:
            return [.transient(0, intensity: 120.0 / 255, sharpness: 0.90)]
        case .tap:
            return [.transient(0, intensity: 90.0 / 255, sharpness: 0.70)]
        case .summon:
            return [.transient(0, intensity: 110.0 / 255, sharpness: 0.35),
                    .transient(0.10, intensity: 170.0 / 255, sharpness: 0.45),
                    .transient(0.20, intensity: 1.0, sharpness: 0.60)]
        }
    }

    /// The pattern with the flourish removed: the single strongest transient of the full pattern
    /// (fired immediately). Used under Reduce Motion / Low Power / "Reduce motion in NOOP".
    public var reducedEvents: [TelosHapticEvent] {
        let transients = events.filter { $0.duration == 0 }
        guard var strongest = transients.first else { return [] }
        for event in transients where event.intensity > strongest.intensity {
            strongest = event
        }
        return [.transient(0, intensity: strongest.intensity, sharpness: strongest.sharpness)]
    }

    public func pattern(reduced: Bool) -> [TelosHapticEvent] {
        reduced ? reducedEvents : events
    }
}

/// One event of a pattern, in plain numbers (so patterns are testable without Core Haptics).
/// `duration == 0` is a transient; `> 0` a continuous swell.
public struct TelosHapticEvent: Equatable, Sendable {
    public let offset: Double
    public let intensity: Float
    public let sharpness: Float
    public let duration: Double

    public static func transient(_ offset: Double, intensity: Float, sharpness: Float) -> TelosHapticEvent {
        TelosHapticEvent(offset: offset, intensity: intensity, sharpness: sharpness, duration: 0)
    }

    public static func continuous(_ offset: Double, duration: Double, intensity: Float,
                                  sharpness: Float) -> TelosHapticEvent {
        TelosHapticEvent(offset: offset, intensity: intensity, sharpness: sharpness, duration: duration)
    }
}

// MARK: - The gate (pure, testable)

/// Admission rules: one action = one pattern; no double-fire; ticks rate-limited to what the actuator
/// can render as separate events. Time is injected so the rules are deterministic in tests.
public struct TelosHapticGate {
    /// Two different patterns closer than this are one action; the later one is dropped.
    public static let minimumPatternGap: Double = 0.08
    /// The same pattern again within this window is a double-fire.
    public static let repeatWindow: Double = 0.25
    /// An `action:` key is honoured once per this window.
    public static let actionWindow: Double = 1.0
    /// Ticks faster than this smear into one hum on the Taptic Engine (SystemHaptics' measurement).
    public static let tickInterval: Double = 0.075

    private var lastPatternAt: Double = -Double.infinity
    private var lastTickAt: Double = -Double.infinity
    private var lastByHaptic: [TelosHaptic: Double] = [:]
    private var lastByAction: [String: Double] = [:]

    public init() {}

    /// Whether `haptic` may fire at `now` (seconds, monotonic). Records it when admitted.
    public mutating func admit(_ haptic: TelosHaptic, action: String? = nil, at now: Double) -> Bool {
        if let action {
            if let last = lastByAction[action], now - last < TelosHapticGate.actionWindow { return false }
        }
        if haptic == .tick {
            guard now - lastTickAt >= TelosHapticGate.tickInterval else { return false }
            lastTickAt = now
        } else {
            if let last = lastByHaptic[haptic], now - last < TelosHapticGate.repeatWindow { return false }
            guard now - lastPatternAt >= TelosHapticGate.minimumPatternGap else { return false }
            lastPatternAt = now
            lastByHaptic[haptic] = now
        }
        if let action {
            if lastByAction.count > 64 { lastByAction.removeAll(keepingCapacity: true) }
            lastByAction[action] = now
        }
        return true
    }
}

// MARK: - The one entry point

public enum TelosHaptics {
    /// The app-wide haptics switch — the SAME key `SystemHaptics.prefKey` uses (Strand/Screens), so the
    /// existing Settings toggle governs this engine too. Default ON.
    public static let preferenceKey = "haptics.appWide"

    public static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: preferenceKey) as? Bool) ?? true
    }

    private static var gate = TelosHapticGate()
    private static let gateLock = NSLock()

    /// Play `haptic` — one call, one pattern. Silent when the setting is off, when the gate drops it
    /// (double-fire / second pattern of one action / repeated `action`), or when the device cannot.
    /// - Parameter action: an optional key naming the ACTION (e.g. "moment.quest.done.<id>"); the same
    ///   action is honoured once per second no matter how many views react to it.
    public static func play(_ haptic: TelosHaptic, action: String? = nil) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        gateLock.lock()
        let admitted = gate.admit(haptic, action: action, at: now)
        gateLock.unlock()
        guard admitted else { return }
        render(haptic)
    }

    /// Warm the engine so the first cue of a screen is not the one that pays for the start.
    public static func prepare() {
        #if os(iOS) && canImport(CoreHaptics)
        guard isEnabled else { return }
        TelosHapticEngine.shared.prepare()
        #endif
    }

    /// Whether patterns are currently reduced to one transient (Reduce Motion ‖ Low Power ‖ "Reduce
    /// motion in NOOP").
    public static var isReduced: Bool {
        #if os(iOS)
        return UIAccessibility.isReduceMotionEnabled || NoopMotionState.shared.poseStillIgnoringReduceMotion
        #else
        return NoopMotionState.shared.poseStillIgnoringReduceMotion
        #endif
    }

    private static func render(_ haptic: TelosHaptic) {
        #if os(iOS)
        let events = haptic.pattern(reduced: isReduced)
        #if canImport(CoreHaptics)
        if TelosHapticEngine.shared.play(events) { return }
        #endif
        fallback(haptic)
        #elseif os(watchOS)
        watchFallback(haptic)
        #endif
    }

    #if os(iOS)
    /// The closest UIKit generator where Core Haptics will not run.
    private static func fallback(_ haptic: TelosHaptic) {
        switch haptic {
        case .select:      UISelectionFeedbackGenerator().selectionChanged()
        case .settle:      UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .commit:      UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:     UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:     UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .failure:     UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .reward:      UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .penalty:     UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .levelSettle: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .heartbeat:   UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .tick:        break   // a UIKit impact is far heavier than a tick; type silently instead
        case .tap:         UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .summon:      UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
    #endif

    #if os(watchOS)
    private static func watchFallback(_ haptic: TelosHaptic) {
        let device = WKInterfaceDevice.current()
        switch haptic {
        case .select, .tap, .tick: device.play(.click)
        case .settle:              device.play(.click)
        case .commit, .success, .levelSettle, .summon, .reward: device.play(.success)
        case .warning:             device.play(.retry)
        case .failure, .penalty:   device.play(.failure)
        case .heartbeat:           device.play(.directionUp)
        }
    }
    #endif
}

#if os(iOS) && canImport(CoreHaptics)

/// The one long-lived `CHHapticEngine`. Confined to the main thread by use (every call site is a tap
/// or a state change on the main thread); the system handlers hop back to main before touching state.
final class TelosHapticEngine {
    static let shared = TelosHapticEngine()

    private var engine: CHHapticEngine?
    /// Set once the hardware says it cannot, so we stop trying on every tap.
    private var unsupported = false
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    func prepare() {
        _ = ensureEngine()
    }

    /// Play a pattern. False when Core Haptics could not, so the caller can fall back.
    func play(_ pattern: [TelosHapticEvent]) -> Bool {
        guard !pattern.isEmpty, let engine = ensureEngine() else { return false }
        var events: [CHHapticEvent] = []
        events.reserveCapacity(pattern.count)
        for item in pattern {
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: item.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: item.sharpness),
            ]
            if item.duration > 0 {
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: parameters,
                                            relativeTime: item.offset, duration: item.duration))
            } else {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: parameters,
                                            relativeTime: item.offset))
            }
        }
        do {
            let hapticPattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: hapticPattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            // Usually a torn-down engine rather than a broken device: drop it, rebuild on the next call.
            self.engine = nil
            return false
        }
    }

    /// Stop and release the engine (app backgrounded). It is rebuilt lazily on the next cue.
    func stop() {
        guard let engine else { return }
        engine.stop(completionHandler: nil)
        self.engine = nil
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
            created.isAutoShutdownEnabled = true
            created.resetHandler = { [weak created] in
                DispatchQueue.main.async { try? created?.start() }
            }
            created.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.engine = nil }
            }
            try created.start()
            engine = created
            return created
        } catch {
            engine = nil
            return nil
        }
    }
}

#endif

// MARK: - Legacy entry point (kept; routes through the vocabulary)

/// The 1.x haptic names. Kept for every existing call site; each now plays through `TelosHaptics`, so
/// it honours the app-wide setting, the reduce signals and the one-action-one-pattern gate.
public enum StrandHaptic {
    case selection   // → select
    case light       // → tap
    case commit      // → commit
    case success     // → success
    case warning     // → warning

    /// The vocabulary entry this legacy name plays.
    public var telos: TelosHaptic {
        switch self {
        case .selection: return .select
        case .light:     return .tap
        case .commit:    return .commit
        case .success:   return .success
        case .warning:   return .warning
        }
    }

    /// Fire this haptic now (through `TelosHaptics.play`). No-op on macOS.
    public func play() {
        TelosHaptics.play(telos)
    }
}

public extension View {
    /// Fire `haptic` when `trigger` changes — for value-driven landings (score reveal, bond success,
    /// refresh done). Routes through `TelosHaptics`, so the app-wide setting and the gate apply (the
    /// 1.x version used `.sensoryFeedback`, which ignored the setting).
    func strandHaptic<V: Equatable>(_ haptic: StrandHaptic, trigger: V) -> some View {
        onChangeCompat(of: trigger) { _ in haptic.play() }
    }

    /// Fire a vocabulary pattern when `trigger` changes.
    func telosHaptic<V: Equatable>(_ haptic: TelosHaptic, trigger: V) -> some View {
        onChangeCompat(of: trigger) { _ in TelosHaptics.play(haptic) }
    }
}
