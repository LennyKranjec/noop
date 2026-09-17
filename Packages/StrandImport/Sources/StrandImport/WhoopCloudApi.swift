import Foundation

// WhoopCloudApi.swift — the WHOOP developer API, parsed.
//
// Swift twin of the Android `com.noop.ingest.WhoopCloudApi`. Three endpoints carry the three scores
// this app shows at the top of Today:
//
//   /developer/v2/recovery        → recovery score, resting HR, HRV
//   /developer/v2/cycle           → day strain
//   /developer/v2/activity/sleep  → sleep performance, the stage breakdown, respiratory rate
//
// PARSING ONLY, and pure, so the shape can be pinned by tests that need no network and no account —
// the same split the other importers use. The client and the token handling live in `WhoopCloudAuth`;
// what lands in the store is decided by `WhoopCloudSync`.
//
// A RECORD WITHOUT A SCORE IS SKIPPED, NOT ZEROED. WHOOP returns `score_state` as one of SCORED,
// PENDING_SCORE or UNSCORABLE, and only the first carries a `score` object at all. A pending night is
// a night WHOOP has not finished with — writing a zero for it would put a terrible recovery on a day
// that simply has not been graded yet, and it would then be overwritten hours later, so the wearer
// would watch their history change under them.
//
// THE DAY A RECORD BELONGS TO COMES FROM ITS OWN OFFSET. Every record carries `timezone_offset` as
// "+01:00", and a cycle that began at 23:40 belongs to the day it began ON, in the wearer's zone at
// the time — not in the phone's current zone. Bucketing by the phone's zone puts a flight's worth of
// days one off, which looks exactly like missing data.

public enum WhoopCloudApi {

    /// The API roots, newest first.
    ///
    /// TRIED IN ORDER, PER ENDPOINT, because which one answers is not something this app can know in
    /// advance: WHOOP runs both, an app registration is bound to one of them, and the first cut of the
    /// Android lane hard-coded v1 and got a 404 on recovery and on sleep while cycles answered
    /// perfectly. Guessing the other way would simply have moved which two endpoints were dead.
    ///
    /// The version that answered is reported in the sync note, so the next person reading this does not
    /// have to repeat the experiment.
    public static let bases = [
        "https://api.prod.whoop.com/developer/v2",
        "https://api.prod.whoop.com/developer/v1",
    ]

    /// One day's worth of what the cloud knows, already reduced to the fields this app stores.
    public struct CloudDay: Equatable, Sendable {
        public let day: String
        public var recovery: Double?
        public var restingHr: Int?
        public var hrv: Double?
        public var strain: Double?
        public var sleepPerformance: Double?
        public var totalSleepMin: Double?
        public var deepMin: Double?
        public var remMin: Double?
        public var lightMin: Double?
        public var efficiency: Double?
        public var respRateBpm: Double?
        /// When the night began and ended, as minutes past local midnight IN THE RECORD'S OWN ZONE.
        /// Clock times rather than instants because the regularity streak compares them across dates.
        public var sleepOnsetMin: Int?
        public var wakeMin: Int?
        /// WHOOP's own sleep debt going into the night, in minutes (`sleep_needed.need_from_sleep_debt_milli`).
        public var sleepDebtMin: Double?

        public init(
            day: String,
            recovery: Double? = nil,
            restingHr: Int? = nil,
            hrv: Double? = nil,
            strain: Double? = nil,
            sleepPerformance: Double? = nil,
            totalSleepMin: Double? = nil,
            deepMin: Double? = nil,
            remMin: Double? = nil,
            lightMin: Double? = nil,
            efficiency: Double? = nil,
            respRateBpm: Double? = nil,
            sleepOnsetMin: Int? = nil,
            wakeMin: Int? = nil,
            sleepDebtMin: Double? = nil
        ) {
            self.day = day
            self.recovery = recovery
            self.restingHr = restingHr
            self.hrv = hrv
            self.strain = strain
            self.sleepPerformance = sleepPerformance
            self.totalSleepMin = totalSleepMin
            self.deepMin = deepMin
            self.remMin = remMin
            self.lightMin = lightMin
            self.efficiency = efficiency
            self.respRateBpm = respRateBpm
            self.sleepOnsetMin = sleepOnsetMin
            self.wakeMin = wakeMin
            self.sleepDebtMin = sleepDebtMin
        }
    }

    /// WHOOP's own scoring state. Only this one carries a `score` object.
    private static let scored_ = "SCORED"

    /// `GET /recovery` — the recovery score and the two markers under it.
    ///
    /// Keyed by the CYCLE's day, which the caller supplies from the cycle response: a recovery record
    /// carries `cycle_id` but not the cycle's own start, so keying it by `created_at` would file a
    /// recovery computed at 07:00 on the day it was calculated rather than the day it describes.
    public static func parseRecovery(_ body: String, cycleDayById: [String: String]) -> [String: CloudDay] {
        var out: [String: CloudDay] = [:]
        for rec in records(body) {
            guard str(rec, "score_state") == scored_ else { continue }
            // READ AS A STRING, deliberately. v1 numbers its cycles and v2 moved several ids to UUIDs;
            // reading this as an integer means every recovery whose id is not numeric silently fails to
            // place and the whole endpoint looks empty. A string key is correct for both.
            guard let cycleId = idString(rec["cycle_id"]), let day = cycleDayById[cycleId] else { continue }
            guard let score = rec["score"] as? [String: Any] else { continue }
            // `user_calibrating` means WHOOP itself says the figure is not yet meaningful. Storing it
            // would show a number the source does not stand behind.
            if (score["user_calibrating"] as? Bool) == true { continue }
            out[day] = CloudDay(
                day: day,
                recovery: num(score, "recovery_score"),
                restingHr: num(score, "resting_heart_rate").map { Int($0) },
                hrv: num(score, "hrv_rmssd_milli").flatMap { hrvMilliseconds($0) })
        }
        return out
    }

    /// `GET /cycle` — day strain, and the day key every other endpoint is filed against.
    ///
    /// Returns the day per cycle id as well, because the recovery endpoint can only be placed through
    /// it.
    ///
    /// A WHOOP CYCLE STARTS WHEN YOU FALL ASLEEP, not when you wake. The cycle that carries today's
    /// strain and this morning's recovery began at last night's sleep onset — 23:40 on the 15th for a
    /// day that is the 16th in every sense the wearer means. Filing it under the day it STARTED put
    /// today's strain and recovery on YESTERDAY's row, left today's row holding only the sleep (which
    /// is filed by the day it ends), and sent the hero to its fallbacks: the app's own strain on the
    /// Strain ring, and a "repeating yesterday" banner over what was in fact today's recovery.
    ///
    /// So a cycle is filed under the day it is mostly ABOUT — see `cycleDay`.
    public static func parseCycles(_ body: String) -> (byDay: [String: CloudDay], dayById: [String: String]) {
        var byDay: [String: CloudDay] = [:]
        var dayById: [String: String] = [:]
        for rec in records(body) {
            guard let id = idString(rec["id"]),
                  let day = cycleDay(start: str(rec, "start"), offset: str(rec, "timezone_offset"))
            else { continue }
            dayById[id] = day
            guard str(rec, "score_state") == scored_, let score = rec["score"] as? [String: Any] else { continue }
            byDay[day] = CloudDay(day: day, strain: num(score, "strain"))
        }
        return (byDay, dayById)
    }

    /// `GET /activity/sleep` — the night, filed against the day it is credited to.
    ///
    /// NAPS ARE SKIPPED. WHOOP flags them, and folding a nap into the night's totals would inflate the
    /// duration and wreck the stage breakdown. The day a night belongs to is the day it ENDS on, which
    /// is what the rest of this app means by a night — a sleep that starts at 23:40 on Tuesday is
    /// Wednesday's row everywhere else, and a cloud import that disagreed would just look broken.
    public static func parseSleep(_ body: String) -> [String: CloudDay] {
        var out: [String: CloudDay] = [:]
        for rec in records(body) {
            if (rec["nap"] as? Bool) == true { continue }
            guard str(rec, "score_state") == scored_,
                  let day = localDay(str(rec, "end"), offset: str(rec, "timezone_offset")),
                  let score = rec["score"] as? [String: Any]
            else { continue }
            let stages = score["stage_summary"] as? [String: Any]
            let deep = stages.flatMap { num($0, "total_slow_wave_sleep_time_milli") }.map { $0 / 60_000 }
            let rem = stages.flatMap { num($0, "total_rem_sleep_time_milli") }.map { $0 / 60_000 }
            let light = stages.flatMap { num($0, "total_light_sleep_time_milli") }.map { $0 / 60_000 }
            // The total is the three ASLEEP stages, not in-bed time: awake time is reported separately
            // and adding it would turn "you slept" into "you lay there", which is a different figure.
            let parts = [deep, rem, light].compactMap { $0 }
            out[day] = CloudDay(
                day: day,
                sleepPerformance: num(score, "sleep_performance_percentage"),
                totalSleepMin: parts.isEmpty ? nil : parts.reduce(0, +),
                deepMin: deep,
                remMin: rem,
                lightMin: light,
                efficiency: num(score, "sleep_efficiency_percentage"),
                respRateBpm: num(score, "respiratory_rate"),
                sleepOnsetMin: minuteOfDay(str(rec, "start"), offset: str(rec, "timezone_offset")),
                wakeMin: minuteOfDay(str(rec, "end"), offset: str(rec, "timezone_offset")),
                sleepDebtMin: (score["sleep_needed"] as? [String: Any])
                    .flatMap { num($0, "need_from_sleep_debt_milli") }
                    .map { $0 / 60_000 })
        }
        return out
    }

    /// One workout, as the cloud reports it.
    ///
    /// Its own type rather than a `CloudDay` field: a day holds ONE of every score and any number of
    /// workouts, and folding them into the daily row would either lose all but one or turn every field on
    /// that row into an array for the sake of a sport name.
    public struct CloudWorkout: Equatable, Sendable {
        public let id: String
        public let start: Date
        public let end: Date
        /// WHOOP's numeric sport id, kept raw. NOT used to name the session when `sportName` is there.
        public let sportId: Int?
        /// WHOOP's OWN name for the sport, as v2 sends it (`sport_name`). The authority on what this
        /// session was — see `displaySport`.
        public let sportName: String?
        public let strain: Double?
        public let averageHeartRate: Int?
        public let maxHeartRate: Int?
        public let kilojoule: Double?
        public let distanceMetre: Double?

        /// Kilojoules as kilocalories, which is the unit every other workout row in this app carries.
        public var energyKcal: Double? {
            kilojoule.map { $0 / 4.184 }
        }
    }

    /// `GET /activity/workout` — the sessions WHOOP scored.
    ///
    /// UNSCORED SESSIONS ARE STILL RETURNED, unlike the daily endpoints. A workout that WHOOP has not
    /// finished grading still HAPPENED — it has a start, an end and a sport — and dropping it would take
    /// a real session off the list to avoid showing one missing number. The strain is simply nil, which
    /// every consumer of a workout row already handles.
    public static func parseWorkouts(_ body: String) -> [CloudWorkout] {
        records(body).compactMap { rec -> CloudWorkout? in
            guard let id = idString(rec["id"]),
                  let start = parseInstant(str(rec, "start")),
                  let end = parseInstant(str(rec, "end")),
                  end > start
            else { return nil }
            let score = rec["score"] as? [String: Any]
            let scored = str(rec, "score_state") == scored_
            return CloudWorkout(
                id: id,
                start: start,
                end: end,
                sportId: num(rec, "sport_id").map { Int($0) },
                sportName: {
                    let raw = str(rec, "sport_name").trimmingCharacters(in: .whitespaces)
                    return raw.isEmpty ? nil : raw
                }(),
                strain: scored ? score.flatMap { num($0, "strain") } : nil,
                averageHeartRate: score.flatMap { num($0, "average_heart_rate") }.map { Int($0) },
                maxHeartRate: score.flatMap { num($0, "max_heart_rate") }.map { Int($0) },
                kilojoule: score.flatMap { num($0, "kilojoule") },
                distanceMetre: score.flatMap { num($0, "distance_meter") })
        }
    }

    /// The name a session is stored and shown under.
    ///
    /// WHOOP'S OWN `sport_name` FIRST, and the numeric table only where it is absent. The first cut
    /// named every session from a sport-id table transcribed from memory, and that table was off by one
    /// across most of its range — 45 is Weightlifting, not Yoga; 44 is Yoga; 63 is Walking, not 66 — so
    /// a strength session arrived labelled as yoga. That is precisely the failure the table's own note
    /// said it existed to avoid, and it did a second piece of damage: the cross-source dedup only
    /// collapses two rows of the SAME sport, so a strap-logged "Weightlifting" and the cloud's
    /// mis-named copy of it both stayed on the list.
    ///
    /// v2 sends the name. The name is WHOOP's own, needs no table, and cannot go stale.
    ///
    /// The fallback covers only the three ids that have never moved. Anything else without a name is
    /// "Workout", which is true, rather than a guess at which sport a number stands for.
    public static func displaySport(name: String?, id: Int?) -> String {
        if let name, !name.isEmpty { return prettySport(name) }
        switch id {
        case -1: return "Activity"
        case 0: return "Running"
        case 1: return "Cycling"
        default: return "Workout"
        }
    }

    /// "functional-fitness" / "functional_fitness" / "FUNCTIONAL FITNESS" -> "Functional Fitness".
    ///
    /// Title-cased with SPACES, because that is the spelling the rest of the app stores a sport under,
    /// and the cross-source dedup compares sports with whitespace removed and case folded. A hyphen
    /// survives that fold, so "functional-fitness" and a strap-logged "Functional Fitness" would never
    /// be recognised as the same session.
    public static func prettySport(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Fold the reads into one row per day.
    ///
    /// Later sources fill only the gaps the earlier ones left, so no endpoint can blank a field another
    /// one measured — the three carry disjoint fields in practice, and this keeps that true if WHOOP
    /// ever starts returning one of them in two places.
    public static func merge(_ parts: [[String: CloudDay]]) -> [CloudDay] {
        var out: [String: CloudDay] = [:]
        for part in parts {
            for (day, d) in part {
                guard var cur = out[day] else {
                    out[day] = d
                    continue
                }
                cur.recovery = cur.recovery ?? d.recovery
                cur.restingHr = cur.restingHr ?? d.restingHr
                cur.hrv = cur.hrv ?? d.hrv
                cur.strain = cur.strain ?? d.strain
                cur.sleepPerformance = cur.sleepPerformance ?? d.sleepPerformance
                cur.totalSleepMin = cur.totalSleepMin ?? d.totalSleepMin
                cur.deepMin = cur.deepMin ?? d.deepMin
                cur.remMin = cur.remMin ?? d.remMin
                cur.lightMin = cur.lightMin ?? d.lightMin
                cur.efficiency = cur.efficiency ?? d.efficiency
                cur.respRateBpm = cur.respRateBpm ?? d.respRateBpm
                cur.sleepOnsetMin = cur.sleepOnsetMin ?? d.sleepOnsetMin
                cur.wakeMin = cur.wakeMin ?? d.wakeMin
                cur.sleepDebtMin = cur.sleepDebtMin ?? d.sleepDebtMin
                out[day] = cur
            }
        }
        return out.values.sorted { $0.day < $1.day }
    }

    /// How many records a page carried, whatever they turned out to be.
    public static func recordCount(_ body: String) -> Int { records(body).count }

    /// The `next_token` for a paged response, or nil on the last page.
    public static func nextToken(_ body: String) -> String? {
        guard let root = object(body), let token = root["next_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// RFC 3339, which is what the range parameters take.
    public static func rfc3339(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// The local calendar day of an RFC-3339 instant, in the offset the RECORD carries.
    ///
    /// Not the phone's current zone: a cycle recorded in Tokyo belongs to the Tokyo day it happened on,
    /// and re-bucketing it when the wearer flies home would silently shift a week of history by one.
    /// The day a cycle belongs to: the local day of its start PLUS TWELVE HOURS.
    ///
    /// A cycle runs from one sleep onset to the next, so almost all of it is the waking day that
    /// follows its start. Twelve hours lands inside that day for every ordinary pattern — asleep at
    /// 23:40 files under the next day, asleep at 01:30 under the same one, and a start in the small
    /// hours or the morning stays where it is — and it agrees with the sleep endpoint, which files a
    /// night under the day it ENDS on, so a day's row gets its own night, its own recovery and its own
    /// strain rather than three different days' worth.
    ///
    /// THE OFFSET IS THE RECORD'S OWN, for the same reason as everywhere else here: a travelled week
    /// bucketed by the phone's current zone shifts by a day and looks exactly like missing data.
    public static func cycleDay(start: String, offset: String) -> String? {
        guard let date = parseInstant(start) else { return nil }
        let midday = date.addingTimeInterval(12 * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(from: offset) ?? TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: midday)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Minutes past local midnight for an instant, in the record's own zone.
    public static func minuteOfDay(_ instant: String, offset: String) -> Int? {
        guard let date = parseInstant(instant) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(from: offset) ?? TimeZone.current
        let c = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return nil }
        return h * 60 + m
    }

    public static func localDay(_ instant: String, offset: String) -> String? {
        guard let date = parseInstant(instant) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(from: offset) ?? TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// A `yyyy-MM-dd` day key back as a date at local midnight, for walking a window of days.
    ///
    /// Here rather than on the repository because the day keys this lane produces are the ones it has
    /// to read back, and a second spelling of the same format elsewhere is how the two drift.
    public static func localDayDate(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        return calendar.date(from: c)
    }

    /// `hrv_rmssd_milli`, in milliseconds, whichever unit it actually arrives in.
    ///
    /// THE FIELD NAME IS NOT RELIABLE. WHOOP documents it as milliseconds, and it has been observed
    /// arriving as SECONDS (0.0654 for a 65 ms RMSSD). Picking one and hoping would either divide this
    /// app's HRV by a thousand or multiply it by one — both of which produce a number that is wrong by
    /// three orders of magnitude while still looking like a reading.
    ///
    /// So the value decides. A resting RMSSD below 1 ms is not something a living person produces; a
    /// value under that threshold is therefore seconds, and is converted. Everything at or above it is
    /// taken as the milliseconds it says it is. The rule is crude, but it is checkable against a real
    /// response and it cannot silently mangle a plausible figure into another plausible figure.
    public static func hrvMilliseconds(_ raw: Double) -> Double? {
        guard raw.isFinite, raw > 0 else { return nil }
        return raw < 1 ? raw * 1000 : raw
    }

    // MARK: - JSON, defensively

    private static func object(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func records(_ body: String) -> [[String: Any]] {
        guard let root = object(body), let array = root["records"] as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    private static func str(_ o: [String: Any], _ key: String) -> String {
        (o[key] as? String) ?? ""
    }

    /// An id that may arrive as a JSON number or a JSON string, as one string.
    private static func idString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber {
            // `%.0f` rather than description, so a cycle id that decodes as a Double does not become
            // "1.234567891e+09" and fail to match the recovery record that quotes it as an integer.
            return String(format: "%.0f", n.doubleValue)
        }
        return nil
    }

    private static func num(_ o: [String: Any], _ key: String) -> Double? {
        guard let n = o[key] as? NSNumber else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    /// `+01:00`, `-05:30`, `Z`. Anything else is nil and the caller falls back to the phone's zone.
    private static func zone(from offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed == "Z" || trimmed == "z" { return TimeZone(secondsFromGMT: 0) }
        let sign: Int
        switch trimmed.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let digits = trimmed.dropFirst().split(separator: ":")
        guard digits.count == 2, let h = Int(digits[0]), let m = Int(digits[1]) else { return nil }
        return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
    }

    /// RFC 3339, with or without fractional seconds — WHOOP sends both.
    private static func parseInstant(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
