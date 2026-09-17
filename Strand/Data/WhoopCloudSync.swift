import Foundation
import StrandImport
import WhoopStore

// WhoopCloudSync.swift — pulling the three scores from WHOOP's cloud.
//
// Swift twin of the Android `com.noop.ingest.WhoopCloudSync`. The strap gives this app raw signal over
// Bluetooth and the app scores it itself. The cloud gives WHOOP'S OWN scores — the recovery percentage,
// the day strain and the sleep performance the wearer sees in WHOOP's app. Those are the figures the
// Today rings are meant to show, and nothing on the phone can reproduce them: they are proprietary.
//
// SO THEY GET THEIR OWN SOURCE. `sourceId` is distinct from the strap's own "my-whoop", and from the
// computed "-noop" lane, so a cloud recovery of 71 % never silently overwrites a locally derived figure
// and the app can always say which of the two a number came from. The day resolver picks a winner per
// day exactly as it does for every other source.
//
// PAGED, AND BOUNDED. WHOOP returns a `next_token` per page; this follows it up to `maxPages`, which at
// 25 records a page covers well over a year. An unbounded follow would let a server decide how long
// this runs for.
//
// FAILURE IS A COUNT, NOT AN EXCEPTION. Every step returns what it managed; a dead network syncs
// nothing and leaves everything that was already stored exactly as it was.

enum WhoopCloudSync {

    /// The device/source id everything from the cloud is written under.
    static let sourceId = "whoop-cloud"

    /// WHOOP's own sleep-performance percentage, banked per day on the generic series seam.
    ///
    /// `DailyMetric` has no column for it, and an earlier cut of the Android lane therefore re-scored
    /// the night with this app's own scorer — which produces a different number from the one the wearer
    /// sees in WHOOP's app, for a ring that is explicitly labelled as WHOOP's. Two definitions of "sleep
    /// score" on one tile is exactly the kind of quiet disagreement this project treats as a bug, so the
    /// real figure is banked rather than approximated.
    static let sleepPerformanceKey = "sleep_performance"

    /// When WHOOP says each night began and ended, as minutes past local midnight. Banked on the same
    /// generic series seam as the sleep score, for the same reason: `DailyMetric` has no column for it,
    /// and the regularity streak needs the clock time of a night, not just its length.
    static let sleepOnsetKey = "sleep_onset_min"
    static let sleepWakeKey = "sleep_wake_min"
    /// WHOOP's own sleep debt per day, under the same key the export importer uses for its figure.
    static let sleepDebtKey = "sleep_debt_min"

    /// How far back a full sync reaches.
    ///
    /// A YEAR, not a month. The level timeline offers 1y and All, and the muscle and streak surfaces
    /// read whatever history exists — a thirty-day sync silently capped every one of them at thirty days
    /// while looking like a complete account. Paging is what makes this affordable: the window is walked
    /// in pages, and a wearer with three months of data pays for three months.
    static let defaultDays = 365

    /// Page ceiling per endpoint, so a paging bug cannot run forever.
    ///
    /// At 25 records a page this covers three years of daily records, which is past anything the app
    /// asks for. It is a runaway guard, not a history limit.
    private static let maxPages = 60

    /// The two spellings of the paging parameter, tried in order.
    ///
    /// WHOOP returns `next_token` in the body and documents `nextToken` on the request. One of them is
    /// what their v2 accepts and the other is a 400; rather than guess, the walk tries the documented
    /// one and falls back once.
    private static let tokenParams = ["nextToken", "next_token"]

    /// How long the RECENT window stays fresh.
    ///
    /// Five minutes, not thirty. The open cycle's strain climbs all day, and the hero's Strain ring is
    /// labelled as WHOOP's own figure — half an hour behind WHOOP's app is a number that visibly
    /// disagrees with the app it is credited to. What makes a short interval affordable is that it
    /// only walks the last few days; see `recentDays` and `fullSyncAfter`.
    private static let staleAfter: TimeInterval = 5 * 60

    /// The window a routine refresh reads: today, yesterday, and the day before, which is everything a
    /// score can still change on.
    private static let recentDays = 3

    /// How often the whole year is walked again. Old cycles do not change; this is for the wearer who
    /// connected yesterday, or whose account was re-scored.
    private static let fullSyncAfter: TimeInterval = 6 * 3600

    private static let lastNoteKey = "whoop.cloud.lastNote"
    // v2: bumped when cycles moved to the day they cover (see `WhoopCloudApi.cycleDay`), so the first
    // launch of that build rewrites every stored day immediately instead of waiting out the interval
    // with strain filed a day early.
    private static let lastSyncAtKey = "whoop.cloud.lastSyncAt.v2"
    private static let lastFullSyncAtKey = "whoop.cloud.lastFullSyncAt.v2"

    /// What one sync managed, and what each endpoint actually said.
    struct Result {
        let days: Int
        let connected: Bool
        /// One short line per endpoint: the HTTP status and how many records it returned.
        ///
        /// THIS EXISTS BECAUSE SILENCE WAS INDISTINGUISHABLE FROM EMPTINESS. The first cut of the
        /// Android lane swallowed a failed request and returned no records, so a 403 from a scope the
        /// wearer had not granted looked exactly like an account with no data — and the only thing on
        /// screen was three dashes. A sync that cannot get something has to be able to say which thing
        /// and why.
        var note: String = ""
    }

    /// What the last sync reported, or nil when one has never run.
    static var lastNote: String? {
        let note = UserDefaults.standard.string(forKey: lastNoteKey) ?? ""
        return note.isEmpty ? nil : note
    }

    /// Sync only if the last one is older than `staleAfter`.
    ///
    /// WHAT THIS IS FOR. Nothing else calls the sync except a manual pull, so a wearer who connected
    /// their account and then opened the app saw nothing and had no way to know whether the connection
    /// had worked. This makes opening Today enough.
    ///
    /// The guard is a STORED timestamp rather than a process flag, so backgrounding and reopening the
    /// app ten times in a minute does not make ten round trips to WHOOP.
    @discardableResult
    static func syncIfStale(repo: Repository) async -> Result? {
        guard WhoopCloudAuth.isConfigured, WhoopCloudAuth.isConnected else { return nil }
        let last = UserDefaults.standard.double(forKey: lastSyncAtKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= staleAfter else { return nil }
        UserDefaults.standard.set(now, forKey: lastSyncAtKey)
        let lastFull = UserDefaults.standard.double(forKey: lastFullSyncAtKey)
        if now - lastFull >= fullSyncAfter {
            UserDefaults.standard.set(now, forKey: lastFullSyncAtKey)
            return await sync(repo: repo)
        }
        return await sync(repo: repo, days: recentDays)
    }

    /// Pull the last `days` days and store them.
    ///
    /// Returns `connected = false` when the wearer has never signed in or the token could not be
    /// refreshed — the caller shows the sign-in rather than an error, because that is the fix.
    @discardableResult
    static func sync(repo: Repository, days: Int = defaultDays) async -> Result {
        guard WhoopCloudAuth.isConfigured else {
            return Result(days: 0, connected: false, note: "no credentials in this build")
        }
        guard let token = await WhoopCloudAuth.accessToken() else {
            return Result(days: 0, connected: false, note: "not signed in")
        }

        let end = Date()
        let start = end.addingTimeInterval(-Double(days) * 86_400)

        // CYCLES FIRST, and not only for strain: a recovery record identifies its day only through
        // `cycle_id`, so without the cycle map built from every page, a recovery whose cycle landed on a
        // later page would be unplaceable and silently dropped.
        var cycleDaysPerPage: [[String: WhoopCloudApi.CloudDay]] = []
        var dayByCycleId: [String: String] = [:]
        let cyclesFetched = await fetchAll(token: token, path: "cycle", start: start, end: end)
        for page in cyclesFetched.pages {
            let parsed = WhoopCloudApi.parseCycles(page)
            cycleDaysPerPage.append(parsed.byDay)
            for (id, day) in parsed.dayById { dayByCycleId[id] = day }
        }

        let recoveryFetched = await fetchAll(token: token, path: "recovery", start: start, end: end)
        let recovery = recoveryFetched.pages.map { WhoopCloudApi.parseRecovery($0, cycleDayById: dayByCycleId) }
        let sleepFetched = await fetchAll(token: token, path: "activity/sleep", start: start, end: end)
        let sleep = sleepFetched.pages.map { WhoopCloudApi.parseSleep($0) }

        // THE SESSIONS, not just the day totals. A cycle's strain says the day was hard; a workout says
        // WHAT was hard, when, and for how long — which is the difference between the coach saying "your
        // strain is high" and it saying "that 74-minute run this morning is why". They are also the only
        // cloud records the wearer recognises by name.
        let workoutsFetched = await fetchAll(token: token, path: "activity/workout", start: start, end: end)
        let workouts = workoutsFetched.pages.flatMap { WhoopCloudApi.parseWorkouts($0) }

        // Records READ versus days STORED are different numbers, and the gap is the interesting part: a
        // hundred records that all come back PENDING_SCORE store nothing, and without both figures that
        // is indistinguishable from a request that failed.
        let note = [cyclesFetched.note, recoveryFetched.note, sleepFetched.note, workoutsFetched.note]
            .joined(separator: " · ")
        UserDefaults.standard.set(note, forKey: lastNoteKey)

        // WRITTEN BEFORE THE EARLY RETURN BELOW. An account whose daily endpoints are all pending but
        // whose workouts came back fine is a real state — dropping the sessions because no DAY scored
        // would be losing the half that did arrive.
        let workoutRows = workouts.map { w in
            WorkoutRow(
                startTs: Int(w.start.timeIntervalSince1970),
                endTs: Int(w.end.timeIntervalSince1970),
                sport: WhoopCloudApi.displaySport(name: w.sportName, id: w.sportId),
                source: sourceId,
                durationS: w.end.timeIntervalSince(w.start),
                energyKcal: w.energyKcal,
                avgHr: w.averageHeartRate,
                maxHr: w.maxHeartRate,
                // ONTO THE APP'S OWN 0–100 SCALE, which is what a workout row's strain is everywhere
                // else — the export importer stores WHOOP's figure ×100/21 and every read-out converts
                // back. Written raw, WHOOP's 11.4 read as an effort of 11.4 out of 100, and on the WHOOP
                // display scale as 2.4. The same factor the importer uses, so the round trip is exact.
                strain: w.strain.map { $0 * WhoopExportImporter.dayStrainToEffortScale },
                distanceM: w.distanceMetre,
                // Zones in the export's own shape ("z1"…"z5", percent), so the zone readers treat a
                // cloud session exactly like an imported one.
                zonesJSON: w.zonePercents.flatMap { p in
                    let dict = Dictionary(uniqueKeysWithValues: p.enumerated().map { ("z\($0.offset + 1)", $0.element) })
                    return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
                },
                notes: nil,
                steps: nil)
        }
        // ONLY ON A READ THAT ANSWERED. `pages` is empty when every request failed, and replacing the
        // window with nothing on a dead network would delete every session the cloud had given us.
        if !workoutsFetched.pages.isEmpty {
            await writeWorkouts(repo: repo, rows: workoutRows, from: start, to: end)
        }

        let all = WhoopCloudApi.merge(cycleDaysPerPage + recovery + sleep)
        guard !all.isEmpty else { return Result(days: 0, connected: true, note: note) }

        let rows = all.map { d in
            DailyMetric(
                day: d.day,
                totalSleepMin: d.totalSleepMin,
                efficiency: d.efficiency,
                deepMin: d.deepMin,
                remMin: d.remMin,
                lightMin: d.lightMin,
                disturbances: nil,
                restingHr: d.restingHr,
                avgHrv: d.hrv,
                recovery: d.recovery,
                strain: d.strain,
                exerciseCount: nil,
                respRateBpm: d.respRateBpm)
        }
        var sleepScoreRows = all.compactMap { d in
            d.sleepPerformance.map { MetricPoint(day: d.day, key: sleepPerformanceKey, value: $0) }
        }
        sleepScoreRows += all.compactMap { d in
            d.sleepOnsetMin.map { MetricPoint(day: d.day, key: sleepOnsetKey, value: Double($0)) }
        }
        sleepScoreRows += all.compactMap { d in
            d.wakeMin.map { MetricPoint(day: d.day, key: sleepWakeKey, value: Double($0)) }
        }
        sleepScoreRows += all.compactMap { d in
            d.sleepDebtMin.map { MetricPoint(day: d.day, key: sleepDebtKey, value: $0) }
        }

        let stored = await write(repo: repo, rows: rows, sleepScores: sleepScoreRows)
        // A failed write is reported as zero days rather than as the count it TRIED to store — the
        // caller's message goes on screen, and "synced 30 days" over an empty table is the worst of both.
        return Result(days: stored ? rows.count : 0, connected: true, note: note)
    }

    /// Store the sessions under the cloud's own source.
    ///
    /// Separate from `write` because it has to be able to run when the daily write does not — see the
    /// call site. The natural key is (device, start, sport), so re-syncing the same window updates the
    /// rows in place instead of stacking duplicates every half hour.
    ///
    /// THE CLOUD'S OWN WINDOW IS REPLACED, not merged into. The natural key includes the sport, so a
    /// session whose NAME changes — which is exactly what correcting the sport table does to every
    /// session synced before it — would upsert as a second row beside the first rather than over it,
    /// and every workout would appear twice. The cloud is the only writer of its own source, so its
    /// window is cleared and rewritten from what it just said; no other source is touched.
    private static func writeWorkouts(repo: Repository, rows: [WorkoutRow], from: Date, to: Date) async {
        guard let store = await repo.storeHandle() else { return }
        let lo = Int(from.timeIntervalSince1970), hi = Int(to.timeIntervalSince1970)
        do {
            try await store.upsertDevice(id: sourceId, mac: nil, name: "WHOOP (cloud)")
            // `deleteWorkouts` is keyed by sport, so the stale rows are cleared one stored sport at a
            // time — every sport this source holds in the window, whatever it was named when written.
            let existing = try await store.workouts(deviceId: sourceId, from: lo, to: hi, limit: 100_000)
            for sport in Set(existing.map(\.sport)) {
                _ = try await store.deleteWorkouts(deviceId: sourceId, sport: sport, from: lo, to: hi)
            }
            if !rows.isEmpty {
                _ = try await store.upsertWorkouts(rows, deviceId: sourceId)
            }
            await MainActor.run { repo.noteWhoopCloudChanged(); repo.noteWorkoutsChanged() }
        } catch {
            // Reported through the note, not thrown: a sync that got the days but not the sessions is
            // still a sync that got the days.
        }
    }

    private static func write(repo: Repository, rows: [DailyMetric], sleepScores: [MetricPoint]) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        do {
            try await store.upsertDevice(id: sourceId, mac: nil, name: "WHOOP (cloud)")
            _ = try await store.upsertDailyMetrics(rows, deviceId: sourceId)
            if !sleepScores.isEmpty {
                _ = try await store.upsertMetricSeries(sleepScores, deviceId: sourceId)
            }
            // The hero reads its cloud row on this counter. Without it a sync lands in the store and the
            // rings keep showing dashes until something unrelated reloads the screen.
            await MainActor.run { repo.noteWhoopCloudChanged(); repo.noteWorkoutsChanged() }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Fetching

    /// Pages, plus a one-line account of what the endpoint did.
    private struct Fetched {
        let pages: [String]
        let note: String
    }

    /// Every page of one endpoint, as raw bodies.
    ///
    /// Bodies rather than parsed maps because each endpoint parses differently, and the caller already
    /// knows which parser it wants — this half only has to know how to follow a `next_token`.
    ///
    /// Each base is tried until one ANSWERS. A 404 means this version does not serve this endpoint,
    /// which is information, not a failure — so it moves on rather than giving up. Anything else (a 401,
    /// a 429, a dead socket) is the endpoint's real answer and is reported as it stands.
    private static func fetchAll(token: String, path: String, start: Date, end: Date) async -> Fetched {
        var last = Fetched(pages: [], note: "\(path): no response")
        for base in WhoopCloudApi.bases {
            let attempt = await fetchFrom(token: token, base: base, path: path, start: start, end: end)
            if !attempt.pages.isEmpty || !attempt.note.contains("HTTP 404") { return attempt }
            last = attempt
        }
        return last
    }

    private static func fetchFrom(
        token: String, base: String, path: String, start: Date, end: Date
    ) async -> Fetched {
        var out: [String] = []
        var status = 0
        var pagingStatus = 0
        var pagingBody: String?
        var stalled = false
        var failure: String?
        var next: String?
        var page = 0
        var tokenParam = tokenParams[0]
        var triedBothParams = false

        while page < maxPages {
            page += 1
            var url = base + "/" + path
                + "?start=" + encode(WhoopCloudApi.rfc3339(start))
                + "&end=" + encode(WhoopCloudApi.rfc3339(end))
                + "&limit=25"
            // ENCODED. A `next_token` is base64-ish and carries `=` and `+`; appended raw it makes a
            // malformed query. Encoding alone did not fix the 400 on the Android lane, so the PARAMETER
            // NAME is tried both ways — WHOOP's response field is `next_token` and its documented request
            // parameter is `nextToken`, and only the server knows which its v2 accepts. Whichever works
            // is remembered for the rest of the walk.
            if let next { url += "&\(tokenParam)=" + encode(next) }

            var body: String?
            if let requestURL = URL(string: url) {
                var request = URLRequest(url: requestURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 30
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(code) {
                        // Recorded separately: a failed page AFTER good ones is a paging problem, not
                        // the endpoint's verdict. Letting it overwrite `status` reported "HTTP 400" for a
                        // call that had in fact returned twenty-nine records, which reads as total failure.
                        status = code
                        body = String(data: data, encoding: .utf8)
                    } else {
                        pagingStatus = code
                        // THE SERVER'S OWN WORDS. Two rounds of guessing at this 400 from the status code
                        // alone got nowhere; WHOOP returns a JSON error that names the offending
                        // parameter, and reading it is the difference between fixing this and guessing
                        // again. Truncated because it goes into a preference and onto a card.
                        if pagingBody == nil {
                            pagingBody = String(data: data, encoding: .utf8)
                                .map { String($0.prefix(180)).replacingOccurrences(of: "\"", with: "'") }
                        }
                    }
                } catch {
                    failure = "\(type(of: error))"
                }
            }

            guard let body else {
                // A rejected PAGE is retried once under the other parameter name before giving up. The
                // first page never takes this path (it sends no token), so this cannot mask a real
                // authorisation or availability failure.
                if next != nil, !triedBothParams {
                    triedBothParams = true
                    tokenParam = tokenParams.last { $0 != tokenParam } ?? tokenParam
                    pagingStatus = 0
                    page -= 1
                    continue
                }
                break
            }
            out.append(body)

            let advanced = WhoopCloudApi.nextToken(body)
            // A TOKEN THAT DOES NOT MOVE IS NOT A PAGE. Sending a parameter the server ignores gets a
            // 200 and the SAME page back, forever — which is what produced 1,488 "records" for a year
            // that holds a few hundred, and then a 429 for hammering the endpoint sixty times. Stopping
            // on a repeat turns a silent infinite loop into a clean, reportable end of data.
            guard let advanced, advanced != next else {
                if advanced != nil { stalled = true }
                break
            }
            next = advanced
        }

        let version = base.split(separator: "/").last.map(String.init) ?? base
        let records = out.reduce(0) { $0 + WhoopCloudApi.recordCount($1) }
        let what = failure ?? (status == 0 ? "HTTP \(pagingStatus)" : "HTTP \(status)")
        // The paging note is appended rather than substituted, so a partial read says so plainly instead
        // of presenting itself as a complete one.
        let partial: String
        if stalled {
            partial = " (paging stalled: token did not advance)"
        } else if !out.isEmpty, pagingStatus != 0 {
            partial = " (paging stopped at HTTP \(pagingStatus): \(pagingBody ?? "no body"))"
        } else {
            partial = ""
        }
        return Fetched(pages: out, note: "\(path)(\(version)): \(what), \(records) records\(partial)")
    }

    /// Percent-encoding for a query VALUE. `+` is a space in a query string, so it must not survive.
    private static func encode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

// MARK: - Reading it back

extension Repository {

    /// WHOOP's sleep score for `day`, or nil when that night was never scored.
    func whoopCloudSleepScore(day: String) async -> Double? {
        guard let store = await storeHandle() else { return nil }
        let pts = (try? await store.metricSeries(deviceId: WhoopCloudSync.sourceId,
                                                 key: WhoopCloudSync.sleepPerformanceKey,
                                                 from: day, to: day)) ?? []
        return pts.last?.value
    }

    /// The cloud's own row for `day`, read straight from its source rather than from the merged day.
    ///
    /// DIRECT, on purpose. The merged view picks one winner per field across every source, so a locally
    /// derived recovery can legitimately outrank the cloud's — which is right for the rest of the app
    /// and wrong for a tile that is explicitly labelled WHOOP. This asks the one source the tile credits.
    func whoopCloudDay(_ day: String) async -> DailyMetric? {
        guard let store = await storeHandle() else { return nil }
        let rows = (try? await store.dailyMetrics(deviceId: WhoopCloudSync.sourceId,
                                                  from: day, to: day)) ?? []
        return rows.last
    }

    /// The newest cloud row at or before `day`, for the carry.
    ///
    /// A day WHOOP has not scored yet is common in the morning, and showing three dashes over a strap
    /// that is working is worse than showing last night's real numbers with the date they belong to —
    /// which is what the hero's footer says. Requires at least one of recovery or strain, so a row that
    /// carries only an unscored shell is not mistaken for a scored day.
    func whoopCloudCarriedDay(upTo day: String, lookbackDays: Int = 7) async -> DailyMetric? {
        guard let store = await storeHandle() else { return nil }
        let calendar = Calendar.current
        guard let end = WhoopCloudApi.localDayDate(day),
              let from = calendar.date(byAdding: .day, value: -lookbackDays, to: end)
        else { return nil }
        let rows = (try? await store.dailyMetrics(deviceId: WhoopCloudSync.sourceId,
                                                  from: Repository.localDayKey(from), to: day)) ?? []
        return rows.last { $0.recovery != nil || $0.strain != nil }
    }
}
