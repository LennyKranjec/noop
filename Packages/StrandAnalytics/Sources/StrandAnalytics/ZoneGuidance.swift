import Foundation

// ZoneGuidance.swift — the pure decision half of the live-workout ZONE LOCK.
//
// The wearer locks one target HR zone for the session; the strap then tells them, without a screen,
// which way to go: TWO buzzes while they are BELOW the zone ("speed up"), ONE buzz while they are ABOVE
// it ("ease off"), silence while inside. This type decides WHEN to cue; it knows nothing about BLE,
// haptic prefs or the workout's paused state — the owner (`AppModel`) feeds it samples, resets it on
// pause / unlock / end, and turns a returned `Cue` into a strap buzz.
//
// HYSTERESIS, BOTH WAYS ROUND. Starting is slow and stopping is instant, on purpose:
//   - A cue run STARTS only after the smoothed bpm has sat outside the zone by at least `marginBPM` for
//     at least `settleSeconds`. A heartbeat grazing the edge — or the median wobbling a beat across a
//     boundary — must not buzz the wrist; that is noise the wearer cannot act on.
//   - A cue run STOPS the moment a sample lands back inside the zone. Buzzing someone who has already
//     corrected is worse than a slow start: it reads as "still wrong" and makes them over-correct.
//   - Outside but within the margin is a dead band: it neither starts a run (the settle timer resets)
//     nor stops one already going (the wearer is not back inside yet).
//   - Crossing straight from one side to the other (a sprint from below to above) is a NEW side, so it
//     earns its own settle period rather than inheriting the old run.
//
// CADENCE. Within a run the first cue fires as the run starts, then every `cueInterval` seconds. The
// clock is the sample timestamps, so the schedule is only as fine as the HR feed (≈1 Hz with the
// realtime stream armed, which the workout screen does).

/// Where a bpm reading sits relative to the locked zone.
public enum ZonePosition: Equatable, Sendable {
    case inside
    case below
    case above
}

public struct ZoneGuidance: Equatable, Sendable {

    /// A cue the owner should play on the strap now.
    public enum Cue: Equatable, Sendable {
        /// Below the zone — speed up. Two buzzes.
        case below
        /// Above the zone — ease off. One buzz.
        case above

        /// How many strap buzzes this cue is (the `loops` of the haptic pattern).
        public var buzzCount: Int {
            switch self {
            case .below: return 2
            case .above: return 1
            }
        }
    }

    /// How far outside the zone (bpm) a reading must be before it counts toward starting a cue run.
    public static let defaultMarginBPM: Double = 2
    /// How long (s) the reading must stay beyond the margin before the first cue.
    public static let defaultSettleSeconds: TimeInterval = 10
    /// Seconds between repeated cues while the wearer stays out of the zone.
    public static let defaultCueInterval: TimeInterval = 8

    /// The locked zone's bounds (bpm), inclusive at both ends — a reading exactly on the edge is IN.
    public let lower: Double
    public let upper: Double
    public let marginBPM: Double
    public let settleSeconds: TimeInterval
    public let cueInterval: TimeInterval

    /// The side currently being cued, or `.inside` when silent.
    public private(set) var cueing: ZonePosition = .inside
    /// The side a settle run is building toward, and when it began (nil when none is building).
    public private(set) var pendingSide: ZonePosition?
    public private(set) var pendingSince: Date?
    /// When the last cue was issued in the current run.
    public private(set) var lastCueAt: Date?

    public init(lower: Double, upper: Double,
                marginBPM: Double = ZoneGuidance.defaultMarginBPM,
                settleSeconds: TimeInterval = ZoneGuidance.defaultSettleSeconds,
                cueInterval: TimeInterval = ZoneGuidance.defaultCueInterval) {
        self.lower = Swift.min(lower, upper)
        self.upper = Swift.max(lower, upper)
        self.marginBPM = Swift.max(0, marginBPM)
        self.settleSeconds = Swift.max(0, settleSeconds)
        self.cueInterval = Swift.max(1, cueInterval)
    }

    /// Raw placement of one reading against the bounds, no hysteresis.
    public static func position(bpm: Double, lower: Double, upper: Double) -> ZonePosition {
        if bpm < lower { return .below }
        if bpm > upper { return .above }
        return .inside
    }

    /// True when the reading is outside the zone by at least the margin — far enough to start a run.
    public func isBeyondMargin(_ bpm: Double) -> Bool {
        bpm <= lower - marginBPM || bpm >= upper + marginBPM
    }

    /// Back to silent with nothing building — for pause, unlock, a lost HR signal.
    public mutating func reset() {
        cueing = .inside
        pendingSide = nil
        pendingSince = nil
        lastCueAt = nil
    }

    /// Fold one smoothed-bpm sample in at `now`; returns the cue to play, or nil for silence.
    /// A nil / non-finite bpm (signal lost) resets: never cue on a heart rate we no longer have.
    public mutating func update(bpm: Double?, now: Date) -> Cue? {
        guard let bpm, bpm.isFinite, bpm > 0 else { reset(); return nil }
        let side = Self.position(bpm: bpm, lower: lower, upper: upper)

        // BACK INSIDE: stop immediately, forget any run that was building.
        guard side != .inside else { reset(); return nil }

        // STILL ON THE SIDE BEING CUED (dead band included): keep the cadence going.
        if cueing == side {
            if let last = lastCueAt, now.timeIntervalSince(last) < cueInterval { return nil }
            lastCueAt = now
            return Self.cue(for: side)
        }

        // Crossed over to the OTHER side mid-run: that run is over; this side must settle on its own.
        if cueing != .inside { cueing = .inside; lastCueAt = nil }

        // Within the margin: not far enough out to count, so any settle run starts over.
        guard isBeyondMargin(bpm) else { pendingSide = nil; pendingSince = nil; return nil }

        if pendingSide != side {
            pendingSide = side
            pendingSince = now
        }
        guard let since = pendingSince, now.timeIntervalSince(since) >= settleSeconds else { return nil }
        // Settled: start the run and cue right away.
        cueing = side
        pendingSide = nil
        pendingSince = nil
        lastCueAt = now
        return Self.cue(for: side)
    }

    private static func cue(for side: ZonePosition) -> Cue? {
        switch side {
        case .below: return .below
        case .above: return .above
        case .inside: return nil
        }
    }
}

// MARK: - Zone slider geometry

/// Pure placement for the live-workout zone slider: one continuous bar from zone 1's lower bound to
/// HRmax, split into the five zone segments. Kept here, beside the guidance, so the view does no maths
/// that a test cannot see.
public enum ZoneSliderGeometry {

    /// The bar's span (bpm): zone 1's lower bound … the top zone's upper bound (HRmax). nil when the
    /// zone set is empty or degenerate.
    public static func span(_ set: HRZoneSet) -> ClosedRange<Double>? {
        guard let lo = set.zones.map(\.lower).min(),
              let hi = set.zones.map(\.upper).max(),
              lo.isFinite, hi.isFinite, hi > lo else { return nil }
        return lo...hi
    }

    /// Where `bpm` sits along the bar, 0…1 (clamped: below zone 1 pins to the left end, above HRmax to
    /// the right).
    public static func fraction(bpm: Double, in span: ClosedRange<Double>) -> Double {
        let width = span.upperBound - span.lowerBound
        guard width > 0, bpm.isFinite else { return 0 }
        return Swift.min(Swift.max((bpm - span.lowerBound) / width, 0), 1)
    }

    /// Where `bpm` sits WITHIN its own zone, 0 (the zone's floor) … 1 (its ceiling); nil below zone 1.
    public static func withinZone(bpm: Double, set: HRZoneSet) -> Double? {
        let n = set.zoneNumber(forBPM: bpm)
        guard n >= 1, let z = set.zones.first(where: { $0.number == n }), z.upper > z.lower else { return nil }
        return Swift.min(Swift.max((bpm - z.lower) / (z.upper - z.lower), 0), 1)
    }
}
