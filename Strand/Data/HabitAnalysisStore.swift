import Foundation
import StrandAnalytics
import WhoopStore

// HabitAnalysisStore.swift — the cached habit report, refreshed at most once per local day.
//
// HEALTH_V2 §S1-A.8. Runs `HabitAssociation.analyse` over the ledger `HabitLedgerSource` builds, after that
// morning's analysis has landed (today's row carries last night's sleep or HRV — or it is past noon, so a
// strap that did not sync does not hold the report back forever), and caches the report as JSON with its
// `computedAt` in the store directory (`habit-analysis.json`). It also keeps the trial proposals and the
// coach block derived from the same report, so every surface reads one set of numbers.
//
// Every displayed habit figure comes from here (HEALTH_V2 S1-A acceptance).

@MainActor
final class HabitAnalysisStore: ObservableObject {

    static let shared = HabitAnalysisStore()
    static let fileName = "habit-analysis.json"

    /// What is cached on disk.
    struct Cache: Codable, Equatable {
        var computedAt: Date
        /// The local day it was computed for.
        var day: String
        var report: HabitAssociationReport
        var proposals: [TrialProposal]
    }

    @Published private(set) var cache: Cache?
    /// Observed-night counts per habit source for the hub's "What gets logged" footer.
    var report: HabitAssociationReport? { cache?.report }
    var proposals: [TrialProposal] { cache?.proposals ?? [] }

    private let fileURL: URL?
    private var refreshing = false

    init(fileURL: URL? = HabitAnalysisStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let c = try? Self.decoder.decode(Cache.self, from: data) {
            cache = c
        }
    }

    nonisolated static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    /// Whether today's morning analysis has landed.
    static func morningLanded(repo: Repository, today: String, now: Date, calendar: Calendar = .current) -> Bool {
        if let row = repo.days.last(where: { $0.day == today }), row.totalSleepMin != nil || row.avgHrv != nil {
            return true
        }
        return (calendar.dateComponents([.hour], from: now).hour ?? 0) >= 12
    }

    /// Recompute when the cached report is not for today and the morning has landed. `force` for a pull.
    func refreshIfDue(repo: Repository, now: Date = Date(), force: Bool = false) async {
        let today = Repository.localDayKey(now)
        if !force {
            if cache?.day == today { return }
            guard Self.morningLanded(repo: repo, today: today, now: now) else { return }
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let snapshot = await HabitLedgerSource.build(repo: repo, asOf: today)
        let report = HabitAssociation.analyse(inputs: snapshot.inputs, asOf: today)
        let proposals = HabitTrialCatalog.proposals(
            report: report, context: HabitTrialStore.shared.eligibilityContext(inputs: snapshot.inputs, today: today))
        let next = Cache(computedAt: now, day: today, report: report, proposals: proposals)
        cache = next
        if let url = fileURL, let data = try? Self.encoder.encode(next) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Coach hand-off

    /// The coach's habit block (≤ 900 characters, dated). HEALTH_V2 §S1-A.6: register this with the coach
    /// context budget in place of the raw journal dump and the `EffectRanker` lines.
    func coachBlock(now: Date = Date(), maxChars: Int = HabitCoachSummary.defaultMaxChars) -> String {
        let today = Repository.localDayKey(now)
        let trials = HabitTrialStore.shared
        return HabitCoachSummary.render(
            report: report,
            trials: HabitCoachTrials(running: trials.runningProgress(today: today),
                                     finished: trials.finishedForCoach()),
            proposals: proposals, asOf: today, maxChars: maxChars)
    }
}
