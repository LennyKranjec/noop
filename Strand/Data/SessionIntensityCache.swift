import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// SessionIntensityCache.swift — per-day aerobic minutes from recorded sessions (HEALTH_V2 S3 §3.7).
//
// Computes `SessionIntensity.day(...)` for the days whose sessions (or their heart rate) changed and
// banks the result as day-keyed metricSeries under the `noop-activity` source:
//
//     aerobic_mod_min · aerobic_vig_min · aerobic_hard_min · aerobic_hard_session (0/1)
//     strength_session (0/1) · aerobic_unmeasured_n · aerobic_approx (0/1) · aerobic_abstained (0/1)
//     wear_coverage (0–1)
//
// IDEMPOTENT. A day is recomputed only when its fingerprint changed: the session windows and sports, how
// much HR sits inside them (so a strap offload that lands after the workout was logged is picked up), the
// lift-log flag and (for the last 7 days only) the zone inputs. Re-running with nothing new writes nothing. Rows are upserts on the
// natural key (source, day, key), so a recompute replaces and never appends.
//
// CHUNKED HR READS. `Repository.hrSamples` caps a read at 8,000 rows, which silently truncates a 1 Hz
// session longer than ~2.2 h. Reads here are sliced in time (≤ 7,200 s per slice, fewer than 8,000 rows
// per device at 1 Hz) and a slice that still comes back full is halved and re-read, so nothing is dropped.
//
// ABSENT IS NOT ZERO. A day whose intensity abstained (no measured resting HR / HRmax) is written with
// `aerobic_abstained = 1`; readers treat its minutes as unknown. A 60-bpm placeholder resting HR is never
// used (`HRZones.RestingHRSource.fallback` ⇒ no zone inputs).
//
// WEAR COVERAGE is "hours of the local day holding at least one HR sample ÷ hours in that day" (DST-aware),
// from the indexed count query `Repository.hrFingerprint`. Coarse on purpose: it only has to separate "worn"
// from "not worn" for the baseline's ≥ 70 % rule, and it costs 24 index lookups a day, not a stream read.

@MainActor
enum SessionIntensityCache {

    static let source = "noop-activity"

    static let keyModerate = "aerobic_mod_min"
    static let keyVigorous = "aerobic_vig_min"
    static let keyHard = "aerobic_hard_min"
    static let keyHardSession = "aerobic_hard_session"
    static let keyStrength = "strength_session"
    static let keyUnmeasured = "aerobic_unmeasured_n"
    static let keyApprox = "aerobic_approx"
    static let keyAbstained = "aerobic_abstained"
    static let keyWear = "wear_coverage"

    /// The repository's per-read row cap.
    static let hrReadLimit = 8000
    /// Time slice per HR read: < 8,000 rows per device at 1 Hz.
    static let hrSliceSeconds = 7200
    /// Days whose wear is always re-measured (a strap offload can land a few days late).
    static let wearRecheckDays = 3
    /// Days within which a day still below 70 % wear keeps being re-measured.
    static let lowWearRecheckDays = 14
    /// Days whose intensity follows the current zone inputs.
    static let zoneRecheckDays = 7

    private static let fingerprintsKey = "sessionIntensity.fingerprints.v1"

    /// One cached day, as `WeekPlanSource` reads it back.
    struct CachedDay: Equatable {
        let moderate: Double
        let vigorous: Double
        let hard: Double
        let hardSession: Bool
        let strength: Bool
        let unmeasured: Int
        let approximate: Bool
        let abstained: Bool
        let wear: Double?

        /// nil when the day abstained — unknown, never 0.
        var mvpaEq: Double? { abstained ? nil : moderate + 2 * vigorous }
    }

    // MARK: - Chunked HR read (pure over `fetch`, so it is testable without a store)

    /// Every HR sample in `[from, to]`, read in time slices so no slice can hit the row cap. A slice that
    /// comes back with `limit` rows is halved and re-read.
    static func readChunked(from: Int, to: Int, limit: Int = 8000, sliceSeconds: Int = 7200,
                            fetch: (Int, Int, Int) async -> [HRSample]) async -> [HRSample] {
        guard to >= from, limit > 0 else { return [] }
        var out: [HRSample] = []
        var cursor = from
        var slice = max(1, sliceSeconds)
        while cursor <= to {
            let end = min(to, cursor + slice - 1)
            let chunk = await fetch(cursor, end, limit)
            if chunk.count >= limit && end > cursor {
                slice = max(1, slice / 2)
                continue
            }
            out.append(contentsOf: chunk)
            cursor = end + 1
        }
        return out
    }

    /// The fingerprint that decides whether a day is recomputed. Pure.
    nonisolated static func fingerprint(sessions: [SessionIntensity.Window], hrCount: Int, liftSession: Bool,
                                        restingHR: Double?, hrMax: Double?) -> String {
        let s = sessions.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map { "\($0.start)-\($0.end)-\($0.sport)-\($0.zonePercents?.map { Int($0.rounded()) } ?? [])" }
            .joined(separator: ",")
        let r = restingHR.map { String(Int($0.rounded())) } ?? "-"
        let m = hrMax.map { String(Int($0.rounded())) } ?? "-"
        return "v1|\(s)|hr\(hrCount)|lift\(liftSession ? 1 : 0)|z\(r)/\(m)"
    }

    // MARK: - Refresh

    /// Recompute changed days in the last `days` local days and return every day's cached values.
    static func refresh(repo: Repository, profile: ProfileStore, days: Int = 49,
                        now: Date = Date(), calendar: Calendar = .current) async -> [String: CachedDay] {
        guard let store = await repo.storeHandle() else { return [:] }
        let todayStart = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return [:] }

        // Zone inputs: a measured resting HR only — never the 60 bpm placeholder.
        let rhrInput = profile.zoneRestingHR
        let restingHR: Double? = rhrInput.source == .fallback ? nil : rhrInput.bpm
        let hrMax: Double? = profile.zoneHRmaxResolved.bpm

        // Sessions by the local day they started on.
        let fromTs = Int(windowStart.timeIntervalSince1970)
        let rows = await repo.workoutRows(days: days + 2)
        var byDay: [String: [SessionIntensity.Window]] = [:]
        for w in rows where w.startTs >= fromTs && w.endTs > w.startTs {
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            byDay[key, default: []].append(SessionIntensity.Window(start: w.startTs, end: w.endTs, sport: w.sport,
                                                                   zonePercents: WorkoutZones.percents(w.zonesJSON)))
        }

        // Lift-log sessions by local day.
        let lifts = (try? await store.liftSetsWithSessionStart(deviceId: ImportedLiftSets.deviceId, fromTs: fromTs,
                                                                toTs: Int(now.timeIntervalSince1970))) ?? []
        let liftDays = Set(lifts.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.sessionStartTs))) })

        var prints = UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
        let existingWear = await repo.series(key: keyWear, source: source,
                                             from: Repository.localDayKey(windowStart),
                                             to: Repository.localDayKey(todayStart))
        var wearByDay: [String: Double] = [:]
        for p in existingWear { wearByDay[p.day] = p.value }

        var points: [MetricPoint] = []
        var validKeys = Set<String>()
        for offset in 0..<days {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let nextStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let key = Repository.localDayKey(dayStart)
            validKeys.insert(key)
            let sessions = byDay[key] ?? []
            let lift = liftDays.contains(key)

            // Wear: measured once per day, re-measured for the last few days (late offloads) and, within the
            // low-wear window, while still below the baseline line — bounded, so a rarely-worn history does
            // not re-query 24 hours × 49 days on every refresh.
            let known = wearByDay[key]
            if known == nil || offset < wearRecheckDays
                || (offset < lowWearRecheckDays && (known ?? 0) < WeekPlanEngine.minWearCoverage) {
                if let wear = await wearCoverage(repo: repo, dayStart: dayStart, nextStart: nextStart,
                                                 now: now, calendar: calendar) {
                    if wearByDay[key] != wear { points.append(MetricPoint(day: key, key: keyWear, value: wear)) }
                    wearByDay[key] = wear
                }
            }

            // Intensity: only when the fingerprint moved.
            var hrCount = 0
            if let lo = sessions.map(\.start).min(), let hi = sessions.map(\.end).max() {
                hrCount = await repo.hrFingerprint(from: lo, to: hi)?.count ?? 0
            }
            // Zone inputs move a little every night (the resting HR is a 7-night median). Only the last
            // week follows them; older days are frozen at the inputs they were computed with, and recompute
            // only when their sessions or HR change or when zone inputs first become known.
            let recentZones = offset < zoneRecheckDays
            let fp = fingerprint(sessions: sessions, hrCount: hrCount, liftSession: lift,
                                 restingHR: recentZones ? restingHR : restingHR.map { _ in 0 },
                                 hrMax: recentZones ? hrMax : hrMax.map { _ in 0 })
            guard prints[key] != fp else { continue }

            var hr: [HRSample] = []
            if let lo = sessions.map(\.start).min(), let hi = sessions.map(\.end).max() {
                hr = await readChunked(from: lo, to: hi, limit: hrReadLimit, sliceSeconds: hrSliceSeconds) { a, b, n in
                    await repo.hrSamples(from: a, to: b, limit: n)
                }
            }
            let summary = SessionIntensity.day(sessions: sessions, hr: hr, restingHR: restingHR, hrMax: hrMax,
                                               liftSession: lift)
            points.append(contentsOf: Self.points(day: key, summary))
            prints[key] = fp
        }

        if !points.isEmpty {
            do {
                _ = try await store.upsertMetricSeries(points, deviceId: source)
            } catch {
                // The write failed: forget the fingerprints of the days in this batch so the next refresh
                // recomputes them instead of believing they were banked.
                for p in points { prints[p.day] = nil }
            }
        }
        prints = prints.filter { validKeys.contains($0.key) }
        UserDefaults.standard.set(prints, forKey: fingerprintsKey)

        return await read(repo: repo, from: Repository.localDayKey(windowStart), to: Repository.localDayKey(todayStart))
    }

    /// The rows one summary banks.
    nonisolated static func points(day: String, _ s: SessionIntensity.DaySummary) -> [MetricPoint] {
        [
            MetricPoint(day: day, key: keyModerate, value: s.moderateMin),
            MetricPoint(day: day, key: keyVigorous, value: s.vigorousMin),
            MetricPoint(day: day, key: keyHard, value: s.hardMin),
            MetricPoint(day: day, key: keyHardSession, value: s.hardSession ? 1 : 0),
            MetricPoint(day: day, key: keyStrength, value: s.strengthSession ? 1 : 0),
            MetricPoint(day: day, key: keyUnmeasured, value: Double(s.unmeasuredCount)),
            MetricPoint(day: day, key: keyApprox, value: s.approximate ? 1 : 0),
            MetricPoint(day: day, key: keyAbstained, value: s.abstained == nil ? 0 : 1),
        ]
    }

    /// Hours of the local day with any HR sample ÷ hours in the day (only the elapsed part of today).
    private static func wearCoverage(repo: Repository, dayStart: Date, nextStart: Date, now: Date,
                                     calendar: Calendar) async -> Double? {
        let end = min(nextStart, now)
        guard end > dayStart else { return nil }
        var hours = 0
        var worn = 0
        var cursor = dayStart
        while cursor < end {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            let sliceEnd = min(next, end)
            hours += 1
            let from = Int(cursor.timeIntervalSince1970)
            let to = Int(sliceEnd.timeIntervalSince1970) - 1
            if to >= from, let fp = await repo.hrFingerprint(from: from, to: to), fp.count > 0 { worn += 1 }
            cursor = next
        }
        guard hours > 0 else { return nil }
        return Double(worn) / Double(hours)
    }

    /// Every cached day in `[from, to]`. A day with no intensity rows is absent from the map.
    static func read(repo: Repository, from: String, to: String) async -> [String: CachedDay] {
        func map(_ key: String) async -> [String: Double] {
            var out: [String: Double] = [:]
            for p in await repo.series(key: key, source: source, from: from, to: to) { out[p.day] = p.value }
            return out
        }
        let mod = await map(keyModerate)
        let vig = await map(keyVigorous)
        let hard = await map(keyHard)
        let hardS = await map(keyHardSession)
        let str = await map(keyStrength)
        let unm = await map(keyUnmeasured)
        let apx = await map(keyApprox)
        let abs_ = await map(keyAbstained)
        let wear = await map(keyWear)
        var out: [String: CachedDay] = [:]
        for day in Set(mod.keys).union(wear.keys) {
            out[day] = CachedDay(moderate: mod[day] ?? 0, vigorous: vig[day] ?? 0, hard: hard[day] ?? 0,
                                 hardSession: (hardS[day] ?? 0) > 0, strength: (str[day] ?? 0) > 0,
                                 unmeasured: Int(unm[day] ?? 0), approximate: (apx[day] ?? 0) > 0,
                                 abstained: mod[day] == nil || (abs_[day] ?? 0) > 0, wear: wear[day])
        }
        return out
    }
}
