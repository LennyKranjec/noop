import Foundation
import WhoopProtocol

// MARK: - Live workout HR trace

/// Pure shaping for the live-workout heart-rate chart: the whole session's captured HR, bucketed down to a
/// bounded number of points, and the y-range that frames it against the zone boundaries. Kept here, beside
/// `ZoneSliderGeometry`, so the view does no maths that a test cannot see.
public enum WorkoutHRTrace {

    /// One plotted point. `offset` is wall-clock seconds since the workout started; `segment` increments
    /// across a capture gap (a pause, or a dropped strap) so the chart breaks the line there instead of
    /// drawing a straight bridge across time with no data.
    public struct Point: Equatable, Sendable {
        public let offset: Double
        public let bpm: Double
        public let segment: Int

        public init(offset: Double, bpm: Double, segment: Int) {
            self.offset = offset
            self.bpm = bpm
            self.segment = segment
        }
    }

    /// Default ceiling on plotted points — far more than the chart has horizontal pixels to show, and a
    /// constant cost per render however long the session runs.
    public static let defaultMaxPoints = 600

    /// A gap between consecutive samples longer than this (seconds) starts a new line segment.
    public static let defaultGapBreak = 30

    /// Bucket the session's samples (ascending `ts`, as `captureWorkoutSample` appends them) into fixed-
    /// width time buckets and average each. The bucket width is the smallest whole number of seconds that
    /// keeps the session span within `maxPoints` buckets, so a short session plots every sample as-is.
    /// A bucket never straddles a gap, so the count can exceed `maxPoints` by at most the number of gaps.
    public static func downsample(_ samples: [HRSample],
                                  startSec: Int,
                                  maxPoints: Int = defaultMaxPoints,
                                  gapBreak: Int = defaultGapBreak) -> [Point] {
        guard let first = samples.first, let last = samples.last else { return [] }
        let span = max(0, last.ts - first.ts)
        let cap = max(1, maxPoints)
        let width = max(1, Int((Double(span + 1) / Double(cap)).rounded(.up)))

        var out: [Point] = []
        out.reserveCapacity(min(samples.count, cap + 8))
        var segment = 0
        var bucket = -1
        var sumTs = 0
        var sumBpm = 0
        var count = 0
        var prevTs: Int?

        func flush() {
            guard count > 0 else { return }
            let meanTs = Double(sumTs) / Double(count)
            out.append(Point(offset: max(0, meanTs - Double(startSec)),
                             bpm: Double(sumBpm) / Double(count),
                             segment: segment))
            sumTs = 0; sumBpm = 0; count = 0
        }

        for s in samples {
            let b = (s.ts - first.ts) / width
            if let p = prevTs, s.ts - p > gapBreak {
                flush()
                segment += 1
                bucket = b
            } else if b != bucket {
                flush()
                bucket = b
            }
            sumTs += s.ts
            sumBpm += s.bpm
            count += 1
            prevTs = s.ts
        }
        flush()
        return out
    }

    /// Elapsed-time axis ticks (seconds from start) on whole-minute steps — 1, 2, 5, 10, 15, 30, 60 or
    /// 120 min, the smallest that gives at most `maxTicks` ticks across 0…`maxOffset` — so the labels read
    /// "10:00", "20:00" rather than whatever round numbers of SECONDS an automatic axis would pick.
    public static func xTicks(maxOffset: Double, maxTicks: Int = 4) -> [Double] {
        guard maxOffset.isFinite, maxOffset > 0 else { return [0] }
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200]
        let limit = Double(max(1, maxTicks))
        let step = steps.first { (maxOffset / $0).rounded(.down) + 1 <= limit }
            ?? (maxOffset / max(1, limit - 1) / 3600).rounded(.up) * 3600
        return Array(stride(from: 0, through: maxOffset, by: step))
    }

    /// The zone boundary lines (bpm): each zone's lower edge plus the top zone's upper edge (HRmax), in
    /// ascending order. Non-finite edges are dropped.
    public static func boundaries(_ set: HRZoneSet) -> [Double] {
        var edges = set.zones.map(\.lower)
        if let top = set.zones.last?.upper { edges.append(top) }
        return edges.filter(\.isFinite).sorted()
    }

    /// Y-range for the chart: the data, widened to the nearest zone boundary below and above it (so the
    /// trace always sits between zone lines it can be read against), plus the locked zone's whole band when
    /// one is set, padded by `padding` bpm and snapped outward to multiples of 5. Never the whole 0…220:
    /// with no data yet it frames zone 1 … HRmax. A floor of `minSpan` keeps a flat trace from filling the
    /// plot edge to edge.
    public static func yDomain(bpms: [Double],
                               zones: HRZoneSet,
                               lockedZone: Int? = nil,
                               padding: Double = 5,
                               minSpan: Double = 20) -> ClosedRange<Double> {
        let edges = boundaries(zones)
        let data = bpms.filter(\.isFinite)
        var lo: Double
        var hi: Double
        if let dMin = data.min(), let dMax = data.max() {
            lo = dMin
            hi = dMax
            if let below = edges.last(where: { $0 <= dMin }) { lo = below }
            if let above = edges.first(where: { $0 >= dMax }) { hi = above }
        } else if let eMin = edges.first, let eMax = edges.last {
            lo = eMin
            hi = eMax
        } else {
            return 40...200
        }
        if let n = lockedZone, let z = zones.zones.first(where: { $0.number == n }),
           z.lower.isFinite, z.upper.isFinite {
            lo = min(lo, z.lower)
            hi = max(hi, z.upper)
        }
        lo -= padding
        hi += padding
        if hi - lo < minSpan {
            let mid = (lo + hi) / 2
            lo = mid - minSpan / 2
            hi = mid + minSpan / 2
        }
        lo = max(0, (lo / 5).rounded(.down) * 5)
        hi = max(lo + 5, (hi / 5).rounded(.up) * 5)
        return lo...hi
    }
}
