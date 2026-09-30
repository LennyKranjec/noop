import Foundation

// StrapCueGate.swift — the system rules every strap cue passes before it may buzz a wrist, and the
// ledger that makes them hold across relaunches.
//
// THE RULES (DESIGN_V2 item 8 applied to the strap, plus the owner's Strap-cue brief):
//   1. The motor is never asked for two patterns at once: a cue waits until the previous pattern has
//      finished (`motorFreeAtMs`). Applies to every cue.
//   2. REQUESTED cues (the wearer started a pacer / focus block / meditation / a Lift rest timer) pass once
//      the motor is free. Nothing else holds them — they are the feature being used — except that the Lift
//      `restOver` cue still keeps the one-minute spacing (DESIGN_V2 decision 16).
//   3. UNREQUESTED cues (sitting break, wind-down, screens off, reward, penalty) are additionally held by:
//        a. the "Wrist alerts" master switch (`notif.masterEnabled`) — ONLY for the kinds whose
//           `heldByWristAlertsMaster` is true (wind-down, screens off). Coordinator decision: the sitting-break
//           nudge and the reward / penalty cues are governed by their own switches alone; the master stays
//           in charge of the HR / strain wrist alerts and the evening cues;
//        b. quiet hours (local clock window, may cross midnight);
//        c. the daily budget (default 8 per local day, counting only cues that actually reached the
//           wearer — a cue dropped on an unreachable strap interrupted nobody);
//        e. the sleep window from the sleep anchor (the caller passes `inSleepWindow`);
//        f. event dedupe: an event key already cued (a reward / penalty for one event id) is never cued again;
//        d. spacing: never within `minSpacingSeconds` (60 s) of the previous cue of ANY kind.
//      a–c HOLD (nothing will change in the next minute); d and rule 1 DEFER to a known instant.
//
// Pure: the caller passes `nowMs` and the tz offset; the ledger is a Codable value the app persists.

/// What the gate remembers between cues. Persist verbatim; start from `.empty`.
public struct StrapCueLedger: Equatable, Sendable, Codable {
    /// Local `yyyy-MM-dd` the `unrequestedToday` count belongs to.
    public var dayKey: String
    /// Unrequested cues that reached the wearer on `dayKey`.
    public var unrequestedToday: Int
    /// When the last delivered cue (of any kind) started, epoch ms.
    public var lastCueAtMs: Int?
    /// When the motor is free again, epoch ms.
    public var motorFreeAtMs: Int?
    /// Fire-once keys (e.g. "windDown:2026-09-30"), newest last, bounded to `maxFiredKeys`.
    public var firedKeys: [String]

    public init(dayKey: String = "", unrequestedToday: Int = 0, lastCueAtMs: Int? = nil,
                motorFreeAtMs: Int? = nil, firedKeys: [String] = []) {
        self.dayKey = dayKey
        self.unrequestedToday = unrequestedToday
        self.lastCueAtMs = lastCueAtMs
        self.motorFreeAtMs = motorFreeAtMs
        self.firedKeys = firedKeys
    }

    public static let empty = StrapCueLedger()
}

/// Why an unrequested cue is held (not merely deferred).
public enum StrapCueHold: String, Equatable, Sendable, Codable {
    /// The cue's own switch is off (decided by the caller from `StrapCueSettings.isEnabled`).
    case switchedOff
    /// This event (`eventKey`) was already cued.
    case duplicate
    /// Inside the sleep window from the sleep anchor.
    case sleepWindow
    case wristAlertsOff
    case quietHours
    case budgetSpent

    public var text: String {
        switch self {
        case .switchedOff: return "This cue is switched off."
        case .duplicate: return "This event was already cued once."
        case .sleepWindow: return "Sleep window."
        case .wristAlertsOff: return "Wrist alerts are off, so the strap stays quiet."
        case .quietHours: return "Quiet hours."
        case .budgetSpent: return "Today's cue budget is used up."
        }
    }
}

public enum StrapCueGateVerdict: Equatable, Sendable {
    case allow
    /// Try again at this epoch-ms instant (the motor is busy, or the one-minute spacing has not passed).
    case deferUntil(ms: Int)
    case hold(StrapCueHold)
}

public enum StrapCueGate {

    /// Never two cues within this many seconds (unrequested cues only; see the file header).
    public static let minSpacingSeconds = 60
    /// Bounded so the ledger stays small; generous enough that one-per-event dedupe keys (a day of rewards
    /// and penalties at most `budgetRange.upperBound`) and the evening keys survive several days.
    public static let maxFiredKeys = 64

    /// May `kind` buzz now? `eventKey` (see `eventKey(_:eventId:)`) makes the cue once-per-event.
    public static func check(_ kind: StrapCueKind, ledger: StrapCueLedger, settings: StrapCueSettings,
                             wristAlertsOn: Bool, nowMs: Int, tzOffsetSec: Int,
                             inSleepWindow: Bool = false, eventKey: String? = nil) -> StrapCueGateVerdict {
        if let key = eventKey, hasFired(key, ledger: ledger) { return .hold(.duplicate) }
        let motorFree = ledger.motorFreeAtMs ?? Int.min
        var earliest = motorFree
        if kind.respectsSpacing, let last = ledger.lastCueAtMs {
            earliest = max(earliest, last + minSpacingSeconds * 1000)
        }
        if kind.isRequested {
            return nowMs < earliest ? .deferUntil(ms: earliest) : .allow
        }
        if kind.heldByWristAlertsMaster && !wristAlertsOn { return .hold(.wristAlertsOff) }
        if inSleepWindow { return .hold(.sleepWindow) }
        if inQuietHours(settings, nowSec: nowMs / 1000, tzOffsetSec: tzOffsetSec) { return .hold(.quietHours) }
        let today = rolled(ledger, nowMs: nowMs, tzOffsetSec: tzOffsetSec)
        if today.unrequestedToday >= settings.dailyBudget { return .hold(.budgetSpent) }
        return nowMs < earliest ? .deferUntil(ms: earliest) : .allow
    }

    /// The once-per-event dedupe key for a cue fired for an app event (e.g. `reward:pr.bench.2026-09-30`).
    /// Callers should make `eventId` unique per event, not per kind of event.
    public static func eventKey(_ kind: StrapCueKind, eventId: String) -> String {
        "event.\(kind.rawValue):\(eventId)"
    }

    /// The ledger after a cue of `kind` REACHED the wearer (strap write issued, or the phone fallback
    /// buzzed). Never call this for a cue that was not delivered.
    public static func recordDelivered(_ kind: StrapCueKind, ledger: StrapCueLedger, nowMs: Int,
                                       tzOffsetSec: Int) -> StrapCueLedger {
        var next = rolled(ledger, nowMs: nowMs, tzOffsetSec: tzOffsetSec)
        next.lastCueAtMs = nowMs
        next.motorFreeAtMs = nowMs + kind.pattern.durationMs
        if !kind.isRequested { next.unrequestedToday += 1 }
        return next
    }

    /// The ledger with its day count reset if the local day has changed since it was written.
    public static func rolled(_ ledger: StrapCueLedger, nowMs: Int, tzOffsetSec: Int) -> StrapCueLedger {
        let key = StrapCueClock.dayKey(epochSec: nowMs / 1000, tzOffsetSec: tzOffsetSec)
        guard key != ledger.dayKey else { return ledger }
        var next = ledger
        next.dayKey = key
        next.unrequestedToday = 0
        return next
    }

    /// Unrequested cues left today.
    public static func remainingBudget(_ ledger: StrapCueLedger, settings: StrapCueSettings, nowMs: Int,
                                       tzOffsetSec: Int) -> Int {
        max(0, settings.dailyBudget - rolled(ledger, nowMs: nowMs, tzOffsetSec: tzOffsetSec).unrequestedToday)
    }

    public static func inQuietHours(_ settings: StrapCueSettings, nowSec: Int, tzOffsetSec: Int) -> Bool {
        let m = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
        return SedentaryDetector.windowContains(m, startMin: settings.quietStartMin, endMin: settings.quietEndMin)
    }

    public static func hasFired(_ key: String, ledger: StrapCueLedger) -> Bool { ledger.firedKeys.contains(key) }

    public static func markFired(_ key: String, ledger: StrapCueLedger) -> StrapCueLedger {
        var next = ledger
        guard !next.firedKeys.contains(key) else { return next }
        next.firedKeys.append(key)
        if next.firedKeys.count > maxFiredKeys { next.firedKeys.removeFirst(next.firedKeys.count - maxFiredKeys) }
        return next
    }
}

/// Clock helpers on epoch seconds + a fixed tz offset (seconds east of UTC). Integer math, no calendars,
/// so the tests are deterministic. The offset is the one in force at `now`; across a DST change an instant
/// a day away can be an hour off, which none of the callers can notice (they look back hours, not days).
public enum StrapCueClock {

    /// Local `yyyy-MM-dd` of an instant.
    public static func dayKey(epochSec: Int, tzOffsetSec: Int) -> String {
        let local = epochSec + tzOffsetSec
        let days = local >= 0 ? local / 86_400 : -((-local - 1) / 86_400 + 1)
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The most recent instant at or before `nowSec` whose local clock reads `minuteOfDay`:00.
    public static func lastClockInstant(atOrBefore nowSec: Int, minuteOfDay: Int, tzOffsetSec: Int) -> Int {
        let local = nowSec + tzOffsetSec
        let intoDay = ((local % 86_400) + 86_400) % 86_400
        var candidate = local - intoDay + SleepClock.wrap(minuteOfDay) * 60
        if candidate > local { candidate -= 86_400 }
        return candidate - tzOffsetSec
    }
}

// MARK: - Honest delivery

/// What ONE cue will do on the wire, decided before it is written — the Strap-cue twin of
/// `WakeBuzzAlarm.Delivery` (same cases, same precedence, same reasons; see that type for the field
/// reports behind it). `.sent` means the write left the phone for a connected strap that is accepting
/// writes; it is not a promise the motor turned.
public enum StrapCueDelivery: String, Equatable, Sendable, Codable {
    case sent
    case noStrap
    case strapRefused
    case noSink

    /// Precedence: a wiring bug, then a refused bond, then reachability. A refused bond also reads as "not
    /// ready", so checking reachability first would tell a connected-but-refusing strap's owner that it is
    /// not connected — the one wrong instruction.
    public static func verdict(hasSink: Bool, strapReachable: Bool, bondRefused: Bool) -> StrapCueDelivery {
        if !hasSink { return .noSink }
        if bondRefused { return .strapRefused }
        if !strapReachable { return .noStrap }
        return .sent
    }
}

/// Where a cue ended up.
public enum StrapCueOutcome: Equatable, Sendable, Codable {
    /// Written to the strap.
    case strap
    /// The strap could not be reached (`reason`), NOOP was in the foreground and the phone buzzed instead.
    case phone(reason: StrapCueDelivery)
    /// Nobody felt anything. Logged as not delivered.
    case notDelivered(reason: StrapCueDelivery)

    /// Whether the wearer was actually cued (strap or phone) — what the budget and the backoff count.
    public var reachedWearer: Bool {
        if case .notDelivered = self { return false }
        return true
    }

    public static func resolve(_ delivery: StrapCueDelivery, appInForeground: Bool,
                               phoneFallbackEnabled: Bool) -> StrapCueOutcome {
        if delivery == .sent { return .strap }
        if phoneFallbackEnabled && appInForeground { return .phone(reason: delivery) }
        return .notDelivered(reason: delivery)
    }

    /// The strap-log line. Pure, so what the log claims is pinned by a test.
    public func logLine(_ kind: StrapCueKind) -> String {
        let name = "Strap cue \(kind.label) (\(kind.pattern.feltAs))"
        switch self {
        case .strap:
            return "\(name): sent to the strap (write issued; the motor itself cannot be confirmed from the phone)"
        case .phone(let r):
            return "\(name): NOT sent to the strap (\(Self.reasonText(r))) — buzzed the phone instead, NOOP was in front"
        case .notDelivered(let r):
            return "\(name): NOT delivered (\(Self.reasonText(r)))"
        }
    }

    public static func reasonText(_ d: StrapCueDelivery) -> String {
        switch d {
        case .sent: return "sent"
        case .noStrap: return "strap not connected"
        case .strapRefused: return "the strap is connected but refusing NOOP's writes - it needs re-pairing"
        case .noSink: return "no strap buzz is wired in this build - app bug, not your strap"
        }
    }
}
