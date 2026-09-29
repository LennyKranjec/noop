import Foundation
import WhoopStore

/// How much of a night NOOP actually holds, and whether that is enough for the night to mean anything.
///
/// Why this exists. Everything downstream of the offload reads a night's heart rate and R-R over the
/// sleep span and scores whatever it finds. Nothing asks how much of the span was actually persisted, so a
/// night that arrived one third complete - the phone out of range for hours, an offload that ended on the
/// idle watchdog, a firmware layout whose records were archived rather than decoded - produces a number
/// that looks exactly like a night that arrived whole. The strap log had the same blind spot from the
/// other side: it reported ROWS PERSISTED per session, which is a count with no time in it, so "persisted
/// 8,000 rows across 1 night(s)" reads identically whether those rows spread over eight hours or over
/// forty minutes.
///
/// This type is the missing measurement, and it is deliberately only a measurement: it reports, it never
/// suppresses a score. Suppression belongs to the analytics layer, which owns the honesty rules for its
/// own outputs; what was missing here was any way for a user or a maintainer to SEE that a night was
/// incomplete at all.
///
/// Everything is pure - no clock read of its own, no store, no I/O - so the arithmetic is pinned by
/// fixtures rather than by a device. The store half is `WhoopStore.hrCoverageSeconds` /
/// `rrCoverageSeconds`, which hand over the distinct capture seconds this reduces.
enum NightCoverage {

    // MARK: - The night window

    /// The local hour the night window opens on the PREVIOUS day.
    static let defaultStartHour = 22
    /// The local hour it closes on the current day.
    static let defaultEndHour = 9

    /// Last night as a unix-second interval, in LOCAL time: previous day `startHour` through today
    /// `endHour`, with the end clamped to `now` so a window that has not finished yet is never reported as
    /// having a hole at its end that is simply the future.
    ///
    /// Built through `Calendar` date components rather than by subtracting 86,400, so the two DST days a
    /// year produce a 10 h or 12 h window instead of an 11 h window shifted by an hour. The whole point of
    /// this type is to say how much of a span is missing, and on those two mornings an 86,400-based window
    /// would invent or hide exactly one hour of it.
    ///
    /// A fixed, stated window rather than the detected sleep span on purpose: the detected span is DERIVED
    /// from the data whose completeness is in question, so a night that synced only two hours would report
    /// a two-hour span fully covered. The window has to come from the clock, not from the rows.
    ///
    /// nil when the calendar cannot form the boundaries, or when `now` is so early that the window would
    /// be empty (before the start hour with nothing yet elapsed).
    static func lastNightWindow(now: Date,
                                calendar: Calendar,
                                startHour: Int = defaultStartHour,
                                endHour: Int = defaultEndHour) -> (start: Int, end: Int)? {
        var endComps = calendar.dateComponents([.year, .month, .day], from: now)
        endComps.hour = endHour
        endComps.minute = 0
        endComps.second = 0
        guard let endToday = calendar.date(from: endComps),
              let previousDay = calendar.date(byAdding: .day, value: -1, to: endToday) else { return nil }
        var startComps = calendar.dateComponents([.year, .month, .day], from: previousDay)
        startComps.hour = startHour
        startComps.minute = 0
        startComps.second = 0
        guard let start = calendar.date(from: startComps) else { return nil }
        // A window still in progress ends NOW. Reporting it to the nominal end hour would count the hours
        // that have not happened yet as missing data, which is the one direction a coverage figure must
        // never err in.
        let end = min(endToday, now)
        guard end > start else { return nil }
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    // MARK: - Coverage arithmetic

    /// One stream's coverage of one window.
    struct Stats: Equatable {
        /// Distinct seconds in the window that carry at least one sample.
        let coveredSeconds: Int
        /// Underlying rows. Larger than `coveredSeconds` for R-R, equal for heart rate.
        let samples: Int
        /// First and last covered second, or nil when nothing landed.
        let firstTs: Int?
        let lastTs: Int?
        /// The longest run of window seconds carrying NO sample, INCLUDING the runs at the window's own
        /// edges. A night whose heart rate starts three hours in is missing three hours, and a gap measure
        /// that only looked between samples would call that night gapless.
        let largestGapSeconds: Int
        /// Where that run begins, or nil when there is no gap at all.
        let largestGapStartTs: Int?
        /// The read that produced this hit its row cap, so the figures describe a prefix of the window
        /// rather than the window. Never reported as a coverage verdict - see `verdict`.
        let truncated: Bool
    }

    /// Reduce a stream's distinct capture seconds to `Stats` over the HALF-OPEN window
    /// `[windowStart, windowEnd)`.
    ///
    /// Half-open so that `coveredSeconds` and `windowEnd - windowStart` are the same quantity and a
    /// completely covered night reports exactly 100%. An inclusive window would make full coverage read as
    /// one second more than the window is long, which is a small arithmetic point with a large consequence:
    /// this whole type exists to be believed about completeness.
    ///
    /// `seconds` is expected ascending and de-duplicated (both coverage reads guarantee it via
    /// `ORDER BY ts ASC` over a `UNION` / `DISTINCT`), and out-of-order input is clamped rather than
    /// trusted, so a malformed list can only ever shrink a reported gap, never invent one.
    static func stats(seconds: [Int], samples: Int,
                      windowStart: Int, windowEnd: Int,
                      truncated: Bool = false) -> Stats {
        var largest = 0
        var largestStart: Int?
        // The last second we hold, initialised one before the window so the run BEFORE the first sample is
        // measured the same way as every run between samples.
        var cursor = windowStart - 1
        var covered = 0
        for s in seconds {
            guard s >= windowStart, s < windowEnd else { continue }
            covered += 1
            let gap = max(0, s - cursor - 1)
            if gap > largest {
                largest = gap
                largestStart = cursor + 1
            }
            cursor = max(cursor, s)
        }
        let tailGap = max(0, (windowEnd - 1) - cursor)
        if tailGap > largest {
            largest = tailGap
            largestStart = cursor + 1
        }
        let inWindow = seconds.filter { $0 >= windowStart && $0 < windowEnd }
        return Stats(coveredSeconds: covered,
                     samples: samples,
                     firstTs: inWindow.first,
                     lastTs: inWindow.last,
                     largestGapSeconds: largest,
                     largestGapStartTs: largest > 0 ? largestStart : nil,
                     truncated: truncated)
    }

    /// Adapter for the store's read result, so the caller does not restate the field mapping.
    static func stats(_ s: StreamSeconds, windowStart: Int, windowEnd: Int) -> Stats {
        stats(seconds: s.seconds, samples: s.samples,
              windowStart: windowStart, windowEnd: windowEnd, truncated: s.truncated)
    }

    /// What the coverage means for anything scored off this night.
    enum Verdict: String, Equatable {
        /// Nothing at all was persisted for the window. Named `empty` rather than `none` so it can never be
        /// confused with `Optional.none` at a call site that also handles an optional verdict.
        case empty
        /// Less than `sparseFraction` of the window's seconds carry a sample.
        case sparse
        /// Enough overall, but with one continuous blind stretch of at least `holeSeconds`.
        case holed
        /// Covered end to end within both thresholds.
        case covered
        /// The read was truncated, so completeness is unknown rather than good or bad.
        case unknown
    }

    /// Below this share of the window's seconds the night is reported sparse. Half, because at that point
    /// the majority of the night is absent and any duration, efficiency or HRV figure taken from it
    /// describes the minority that happened to arrive.
    static let sparseFraction = 0.5

    /// The continuous blind stretch that makes a night holed. Thirty minutes: sleep staging works in
    /// epochs of tens of seconds to a few minutes, so a half-hour hole is several whole stages that were
    /// never observed, whatever the total coverage looks like.
    static let holeSeconds = 30 * 60

    static func verdict(_ s: Stats, windowSeconds: Int) -> Verdict {
        if s.truncated { return .unknown }
        guard windowSeconds > 0 else { return .unknown }
        guard s.coveredSeconds > 0 else { return .empty }
        if Double(s.coveredSeconds) / Double(windowSeconds) < sparseFraction { return .sparse }
        if s.largestGapSeconds >= holeSeconds { return .holed }
        return .covered
    }

    // MARK: - The log line

    /// The one line the strap log carries after every offload session, and the thing a user can read back.
    ///
    /// It names the window it measured, both streams' coverage IN TIME rather than only in rows, the
    /// largest blind stretch and when it starts, and then says in plain words what that means for a score.
    /// The verdict sentence is the point of the whole line: a night that is missing half its heart rate has
    /// to SAY so, because every surface downstream will render its number exactly as it renders a whole
    /// night's.
    ///
    /// Pure, so a fixture pins the wording. No em-dash (project rule). Local wall time, because the reader
    /// is the person who slept through it.
    static func line(windowStart: Int, windowEnd: Int,
                     hr: Stats, rr: Stats,
                     timeZone: TimeZone) -> String {
        let windowSeconds = max(0, windowEnd - windowStart)
        let v = verdict(hr, windowSeconds: windowSeconds)
        var line = "Night coverage \(dayStamp(windowStart, timeZone)) "
            + "\(clock(windowStart, timeZone)) to \(clock(windowEnd, timeZone)) local "
            + "(window \(duration(windowSeconds))): "
            + "HR \(hr.samples) sample(s) covering \(duration(hr.coveredSeconds)) "
            + "(\(percent(hr.coveredSeconds, of: windowSeconds)))"
        line += gapClause(hr, timeZone)
        line += "; R-R \(rr.samples) interval(s) across \(duration(rr.coveredSeconds)) "
            + "(\(percent(rr.coveredSeconds, of: windowSeconds)))"
        line += gapClause(rr, timeZone)
        line += ". " + sentence(v, hr: hr)
        return line
    }

    private static func gapClause(_ s: Stats, _ tz: TimeZone) -> String {
        guard s.largestGapSeconds > 0, let start = s.largestGapStartTs else { return ", no gaps" }
        return ", largest gap \(duration(s.largestGapSeconds)) from \(clock(start, tz))"
    }

    /// The plain-words verdict. Every branch states what it means for a SCORE, because that is the thing
    /// the reader is actually trying to trust or distrust.
    static func sentence(_ v: Verdict, hr: Stats) -> String {
        switch v {
        case .empty:
            return "NO DATA: no heart rate was persisted for this night at all, "
                + "so there is nothing here for sleep or recovery to be computed from."
        case .sparse:
            return "INCOMPLETE: more than half of this night's seconds carry no heart rate, "
                + "so any sleep, HRV or recovery figure shown for it describes the part that arrived, "
                + "not the night."
        case .holed:
            return "INCOMPLETE: this night holds a continuous \(duration(hr.largestGapSeconds)) stretch "
                + "with no heart rate, so its staging covers less than the night and the stages inside "
                + "that stretch were never observed."
        case .covered:
            return "Covered: this night arrived whole."
        case .unknown:
            return "UNKNOWN: the coverage read was capped before the end of the window, "
                + "so completeness could not be measured. This is a NOOP limit, not a finding about the night."
        }
    }

    // MARK: - Formatting

    /// "5h31m" / "48m" / "0m". Seconds are dropped above a minute because nothing here is that precise.
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(seconds)s"
    }

    /// Integer percent, rounded half-up, "0%" for an empty window. Never rounds a non-empty coverage up to
    /// 100% - a night one second short is not a whole night, and the verdict line is read as a claim.
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let raw = (part * 200 + whole) / (whole * 2)
        let clamped = part < whole ? min(raw, 99) : raw
        return "\(min(clamped, 100))%"
    }

    static func clock(_ unix: Int, _ tz: TimeZone) -> String { formatted(unix, tz, "HH:mm") }
    static func dayStamp(_ unix: Int, _ tz: TimeZone) -> String { formatted(unix, tz, "yyyy-MM-dd") }

    private static func formatted(_ unix: Int, _ tz: TimeZone, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed Gregorian - not the device calendar
        f.timeZone = tz
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
