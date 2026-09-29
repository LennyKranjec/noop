import Foundation
import StrandAnalytics
import WhoopStore

// BreathSessionLog.swift — every completed breathing session, stored (HEALTH_V2 S4 §4.3).
//
// Before this file a session's result existed only as one display string in `breathe.lastOutcome`. Now
// each completed session is a record — its gated pre/post quiet readings, the change when both passed,
// the paced-phase swing, pace and minutes — in `breath-sessions.json` in the store directory.
//
// THE DAY'S MINUTES are banked as metricSeries `breath_session_min` under the `noop-habits` source, one
// row per local day, for the habit ledger (`HabitLedgerSource`, `auto:breathingSession`) and the
// `breathing10` trial's adherence. The day total is RE-DERIVED from the stored sessions on every write
// (never read-and-add), so a re-run can never double a day.
//
// It deliberately does NOT write `meditation_min`: the level's Focus part reads meditation, and whether a
// breathing session should count there is a level decision (flagged to the level-audit agent), not a
// side effect of storage.
//
// NOT ON THE `.noopbak` WHITELIST in 2.0 (Android codec parity, HEALTH_V2 §4.3). The metricSeries rows
// are in the database backup; the JSON is a known follow-up.

/// One stored session.
struct BreathSessionRecord: Codable, Equatable, Identifiable {
    /// The pre-reading's start, as a string (unique per device).
    let id: String
    /// Local day the session started on.
    let day: String
    let startTs: Int
    /// Minutes of the paced phase (the quiet readings are not counted as practice).
    let pacedMinutes: Double
    let outcome: BreathSessionOutcome.Result
}

@MainActor
final class BreathSessionLog: ObservableObject {

    static let shared = BreathSessionLog()

    static let fileName = "breath-sessions.json"
    static let key = "breath_session_min"
    static let source = "noop-habits"
    /// Bounded: a year of daily sessions and then some.
    static let maxSessions = 600

    @Published private(set) var sessions: [BreathSessionRecord]
    private let fileURL: URL?

    init(fileURL: URL? = BreathSessionLog.defaultFileURL()) {
        self.fileURL = fileURL
        self.sessions = Self.load(fileURL)
    }

    static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func load(_ url: URL?) -> [BreathSessionRecord] {
        guard let url, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([BreathSessionRecord].self, from: data) else { return [] }
        return list.sorted { $0.startTs < $1.startTs }
    }

    private func save() {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Pure helpers

    /// Minutes practised on `day`, from the stored sessions.
    nonisolated static func dayMinutes(_ sessions: [BreathSessionRecord], day: String) -> Double {
        sessions.filter { $0.day == day }.reduce(0) { $0 + $1.pacedMinutes }
    }

    /// Past changes (%) for the personal comparison: sessions before `beforeTs` whose change was computed.
    nonisolated static func pastDeltas(_ sessions: [BreathSessionRecord], beforeTs: Int) -> [Double] {
        sessions.filter { $0.startTs < beforeTs }.compactMap { $0.outcome.change?.deltaPct }
    }

    /// Weekly median of the PRE-session RMSSD (descriptive trend for the Focus tab; no target). Only gated
    /// readings count.
    nonisolated static func weeklyPreRmssd(_ sessions: [BreathSessionRecord]) -> [(weekStart: String, medianMs: Double, n: Int)] {
        var byWeek: [String: [Double]] = [:]
        for s in sessions {
            guard s.outcome.pre.passed, let r = s.outcome.pre.rmssd,
                  let wk = WeeklyDigestEngine.mondayOfWeek(containing: s.day) else { continue }
            byWeek[wk, default: []].append(r)
        }
        return byWeek.keys.sorted().compactMap { wk -> (weekStart: String, medianMs: Double, n: Int)? in
            let xs = (byWeek[wk] ?? []).sorted()
            guard !xs.isEmpty else { return nil }
            let mid = xs.count / 2
            let med = xs.count % 2 == 1 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2
            return (weekStart: wk, medianMs: med, n: xs.count)
        }
    }

    // MARK: - Writing

    /// Store a completed session and re-bank its day's minutes. Returns the personal comparison for this
    /// session (nil below 5 earlier sessions with a computed change).
    @discardableResult
    func append(_ record: BreathSessionRecord, repo: Repository?) async -> BreathSessionOutcome.PersonalComparison? {
        let past = Self.pastDeltas(sessions, beforeTs: record.startTs)
        sessions.removeAll { $0.id == record.id }
        sessions.append(record)
        sessions.sort { $0.startTs < $1.startTs }
        if sessions.count > Self.maxSessions { sessions.removeFirst(sessions.count - Self.maxSessions) }
        save()
        if let repo, let store = await repo.storeHandle() {
            let minutes = Self.dayMinutes(sessions, day: record.day)
            _ = try? await store.upsertMetricSeries([MetricPoint(day: record.day, key: Self.key, value: minutes)],
                                                    deviceId: Self.source)
        }
        guard let d = record.outcome.change?.deltaPct else { return nil }
        return BreathSessionOutcome.compare(deltaPct: d, past: past)
    }
}
