import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// GoalStore.swift — the wearer's goals (DESIGN_V2 decision 14), kept in `goals.json` in the store directory
// like the other 2.0 stores (`week-plans.json`, `breath-sessions.json`).
//
// WHAT A GOAL IS: a target value for one metric on a target date (optional start date), with the reading
// it started from. It is an ASPIRATION: nothing here ever writes a measured value, touches the Level, the
// quest ledger or the penalty system. A passed date is reviewed honestly (`GoalFeasibility.review`), never
// charged.
//
// REACHING A GOAL is a full-screen moment (decision 7). This store never presents anything itself: it
// builds the `TelosMoment` and hands it to the ONE global presenter FRAME hosts at the app root, through
// `momentSink` (set once by FRAME). Until the sink exists the request waits in `pendingMoments`, so a goal
// reached before the presenter is wired is not lost. Fire-once: `reachedOn` is written the first time the
// goal is seen reached, and only a goal without it can raise the moment again — a re-evaluation later the
// same day, or a reading that dips and recovers, raises nothing.
//
// NOT ON THE `.noopbak` WHITELIST in 2.0 (Android codec parity, HEALTH_V2 §4.3) — a known follow-up, like
// the other 2.0 JSON stores. An unreadable file is set aside, never overwritten.

/// What `goals.json` holds.
struct GoalArchive: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = GoalArchive.currentVersion
    var goals: [Goal] = []

    init(goals: [Goal] = []) { self.goals = goals }

    /// Tolerant decoding: a key added later is absent from an older file, never a reason to drop it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? GoalArchive.currentVersion
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
    }
}

@MainActor
final class GoalStore: ObservableObject {

    static let shared = GoalStore()

    static let fileName = "goals.json"
    /// Bounded: archived goals beyond this are dropped oldest-first on save.
    static let maxGoals = 200

    @Published private(set) var goals: [Goal]
    /// Moments waiting for the presenter (FRAME wires `momentSink`).
    @Published private(set) var pendingMoments: [TelosMoment] = []

    /// FRAME hand-off: the global presenter's enqueue. Setting it flushes anything pending.
    var momentSink: ((TelosMoment) -> Void)? {
        didSet { flushMoments() }
    }

    private let fileURL: URL?

    init(fileURL: URL? = GoalStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.goals = Self.load(fileURL).goals
    }

    var activeGoals: [Goal] { goals.filter { !$0.archived }.sorted { ($0.targetDate, $0.id) < ($1.targetDate, $1.id) } }

    // MARK: - Storage

    static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func load(_ url: URL?) -> GoalArchive {
        guard let url, let data = try? Data(contentsOf: url) else { return GoalArchive() }
        if let a = try? JSONDecoder().decode(GoalArchive.self, from: data) { return a }
        // Unreadable: keep the bytes aside rather than overwrite the wearer's goals on the next save.
        let aside = url.deletingLastPathComponent().appendingPathComponent("goals.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return GoalArchive()
    }

    private func save() {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(GoalArchive(goals: Self.bounded(goals))) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Keep every active goal; drop the oldest archived ones beyond `maxGoals`. Pure, testable.
    static func bounded(_ goals: [Goal]) -> [Goal] {
        guard goals.count > maxGoals else { return goals }
        let active = goals.filter { !$0.archived }
        let archived = goals.filter { $0.archived }.sorted { $0.createdOn < $1.createdOn }
        let room = max(0, maxGoals - active.count)
        return active + Array(archived.suffix(room))
    }

    // MARK: - Editing

    /// Add a goal. `current` is the metric's latest reading (it sets the direction and the start value).
    @discardableResult
    func add(metric: ProjectionMetricID, target: Double, targetDate: String, startDate: String? = nil,
             current: Double?, today: String) -> Goal {
        let g = Goal(id: UUID().uuidString, metric: metric, target: target, targetDate: targetDate,
                     startDate: startDate, createdOn: today, startValue: current,
                     direction: Goal.direction(metric: metric, current: current, target: target))
        goals.append(g)
        save()
        return g
    }

    /// Change a goal's target, date or start. A new target resets the fire-once marks: it is a new goal.
    func update(id: String, target: Double, targetDate: String, startDate: String?, current: Double?) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        var g = goals[i]
        if g.target != target || g.targetDate != targetDate {
            g.reachedOn = nil
            g.reviewedOn = nil
        }
        g.target = target
        g.targetDate = targetDate
        g.startDate = startDate
        g.direction = Goal.direction(metric: g.metric, current: current ?? g.startValue, target: target)
        goals[i] = g
        save()
    }

    func archive(id: String) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[i].archived = true
        save()
    }

    /// Remove a goal from the file (the wearer's own action in the editor).
    func remove(id: String) {
        goals.removeAll { $0.id == id }
        save()
    }

    // MARK: - Evaluation

    /// Record what the latest assessments showed: reached goals get `reachedOn` once (and raise their
    /// moment once); passed dates get `reviewedOn` once. Never touches a measured value.
    func noteAssessments(_ assessments: [GoalAssessment], today: String) {
        var changed = false
        for a in assessments {
            guard let i = goals.firstIndex(where: { $0.id == a.goal.id }), !goals[i].archived else { continue }
            switch a.verdict {
            case .reached where goals[i].reachedOn == nil:
                goals[i].reachedOn = today
                changed = true
                enqueue(Self.reachedMoment(a, today: today))
            case .datePassed where goals[i].reviewedOn == nil:
                goals[i].reviewedOn = today
                changed = true
            default:
                break
            }
        }
        if changed { save() }
    }

    private func enqueue(_ m: TelosMoment) {
        if let sink = momentSink {
            sink(m)
        } else if !pendingMoments.contains(where: { $0.id == m.id }) {
            pendingMoments.append(m)
        }
    }

    private func flushMoments() {
        guard let sink = momentSink, !pendingMoments.isEmpty else { return }
        let queued = pendingMoments
        pendingMoments = []
        for m in queued { sink(m) }
    }

    /// The full-screen moment for a reached goal (`.goalCompleted`: celebration entrance, success haptic,
    /// positive tone). Pure (tested); the id is fire-once per goal.
    static func reachedMoment(_ a: GoalAssessment, today: String) -> TelosMoment {
        let m = a.goal.metric
        var figures: [TelosMoment.Figure] = [
            TelosMoment.Figure(label: "Target", value: m.format(a.goal.target), unit: m.unit.isEmpty ? nil : m.unit),
        ]
        if let c = a.current {
            figures.append(TelosMoment.Figure(label: "Now", value: m.format(c), unit: m.unit.isEmpty ? nil : m.unit))
        }
        if let s = a.goal.startValue {
            figures.append(TelosMoment.Figure(label: "Started at", value: m.format(s), unit: m.unit.isEmpty ? nil : m.unit))
        }
        // The fill encodes how far the wearer came: start → now over start → target. Above 1 is drawn honestly.
        var fill: Double? = nil
        if let s = a.goal.startValue, let c = a.current, a.goal.target != s {
            fill = (c - s) / (a.goal.target - s)
        }
        return TelosMoment(
            id: "goal.reached.\(a.goal.id)",
            kind: .goalCompleted,
            overline: "GOAL REACHED · \(today)",
            headline: m.displayName + " — " + m.formatWithUnit(a.goal.target),
            detail: "Set for \(a.goal.targetDate). A reading, not a promise: keep an eye on the trend in Look ahead.",
            figures: figures,
            fill: fill,
            primaryActionTitle: "Set the next goal")
    }
}
