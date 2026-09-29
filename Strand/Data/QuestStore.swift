import Foundation
import StrandAnalytics

// QuestStore.swift — where the system's directives live between launches.
//
// Swift twin of the Android `com.noop.ai.QuestStore`. One defaults key holding the whole list as the
// JSON `QuestCodec` writes — the same bytes on both platforms, because the list crosses the `.noopbak`
// boundary and a quest exported on one has to read on the other.
//
// AN OBSERVABLE OBJECT, not a bag of statics. Today reads the strip while it renders, and accepting a
// quest has to move the strip immediately; a plain static would update the stored list and leave the
// screen showing the old one until something else happened to redraw.

@MainActor
final class QuestStore: ObservableObject {

    /// The app's store, wired to the game layer's books so a completion pays and an expiry is judged.
    static let shared = QuestStore(penalties: QuestPenaltyStore.shared)

    private static let key = "system.quests"

    /// Where the list lives. `.standard` for the app; a throwaway suite in tests.
    private let defaults: UserDefaults

    /// Everything kept, oldest first.
    @Published private(set) var quests: [Quest] = []

    /// The game layer's books: XP, streak, penalties, make-ups. Nil in a test that is not about them.
    ///
    /// NEVER THE LEVEL. A completion pays XP here and a miss costs XP here; the measured Level
    /// (`LevelLedger`) is not reachable from this store and must not become so.
    let penalties: QuestPenaltyStore?

    /// Internal rather than private so a test can run a store on its own suite; the app uses `shared`.
    init(defaults: UserDefaults = .standard, penalties: QuestPenaltyStore? = nil) {
        self.defaults = defaults
        self.penalties = penalties
        quests = QuestStore.read(defaults)
        // Completions from before the ledger existed are paid in once, so the first penalty does not
        // land on a balance that pretends nothing was ever earned.
        penalties?.seedIfNeeded(completed: quests)
    }

    /// The quest waiting to be answered, if any.
    ///
    /// ONE AT A TIME. Two pop-ups stacked on top of each other is a dialog fight, and a wearer who is
    /// shown three quests at once accepts none of them. The rest keep their turn.
    var offered: Quest? { quests.first { $0.state == .offered } }

    /// What the wearer has taken on and not yet finished, newest first.
    var active: [Quest] {
        quests.filter { $0.state == .active }.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    /// Today's quests in every state, for deciding whether a trigger has already fired.
    func forDay(_ dayKey: String) -> [Quest] { quests.filter { $0.dayKey == dayKey } }

    @discardableResult
    func upsert(_ quest: Quest) -> [Quest] {
        var next = quests
        if let i = next.firstIndex(where: { $0.id == quest.id }) {
            next[i] = quest
        } else {
            next.append(quest)
        }
        // Oldest fall off the end. A quest from three weeks ago is history nobody reads, and this list
        // is parsed on every Today render.
        next.sort { $0.createdAtMs < $1.createdAtMs }
        if next.count > QuestCodec.maxKept { next = Array(next.suffix(QuestCodec.maxKept)) }
        write(next)
        return next
    }

    @discardableResult
    func setState(id: String, state: QuestState) -> Quest? {
        guard let existing = quests.first(where: { $0.id == id }) else { return nil }
        // Through `with(state:)`, which carries EVERY field. Rebuilding the quest here field by field is
        // how the goal would have been silently dropped the first time a quest was accepted.
        let updated = existing.with(state: state)
        upsert(updated)
        return updated
    }

    /// A quest the data just closed, and what the data said. What the completion pop-up reads.
    struct Completion: Identifiable, Equatable {
        let quest: Quest
        let summary: String
        var id: String { quest.id }
    }

    /// Completions waiting to be shown, oldest first. A queue, because two quests can close in the same
    /// refresh and each deserves its own moment.
    @Published private(set) var completions: [Completion] = []

    /// Close `quest` because its goal was met, and queue the pop-up that says so.
    ///
    /// PAID HERE, ONCE. The XP goes on the books the moment the quest closes (`QuestPenaltyStore.credit`,
    /// keyed by the quest's id), and a completed quest always keeps it — no later judgement takes it back.
    func complete(_ quest: Quest, summary: String) {
        guard quests.contains(where: { $0.id == quest.id && $0.state != .completed }) else { return }
        setState(id: quest.id, state: .completed)
        penalties?.credit(quest)
        completions.append(Completion(quest: quest.with(state: .completed), summary: summary))
    }

    /// Close a quest whose window had already shut, because data that arrived late shows it met.
    ///
    /// JUDGED ON THE DATA, NOT THE CLOCK. A strap that synced the morning after is not the wearer failing;
    /// the quest completes, pays, and its completion card says what was read. Returns false when the quest
    /// is no longer in the list, so the caller can pay it from the judgement's own record.
    @discardableResult
    func completeLate(id: String, summary: String) -> Bool {
        guard let quest = quests.first(where: { $0.id == id }) else { return false }
        guard quest.state != .completed else { return true }
        complete(quest, summary: summary + " The data arrived after the window closed; it counts.")
        return true
    }

    /// Issue a make-up quest. Issued ACTIVE: it is an obligation that follows from a miss, not an offer.
    func issueDebt(_ quest: Quest) {
        guard !quests.contains(where: { $0.id == quest.id }) else { return }
        upsert(quest.state == .active ? quest : quest.with(state: .active))
    }

    /// Take a make-up quest off the strip because the miss it was owed for turned out not to be one.
    func withdraw(id: String) {
        guard quests.contains(where: { $0.id == id && $0.state != .completed }) else { return }
        write(quests.filter { $0.id != id })
    }

    /// Give up on a quest.
    ///
    /// One only OFFERED is simply declined: nothing was promised. One ACCEPTED is conceded, not escaped —
    /// it is declined now and still judged on its data at the deadline it would have had, so abandoning
    /// a quest can never be a way round its penalty. A make-up abandoned simply lapses.
    func abandon(id: String) {
        guard let quest = quests.first(where: { $0.id == id }),
              quest.state == .active || quest.state == .offered else { return }
        setState(id: id, state: .declined)
        guard quest.state == .active, quest.kind != .custom else { return }
        if QuestDebt.isDebtQuest(id) {
            penalties?.lapseDebt(id)
        } else {
            penalties?.enqueue(quest, judgeAfterMs: quest.checkableUntilMs())
        }
    }

    /// The front completion has been seen.
    func dismissCompletion() {
        if !completions.isEmpty { completions.removeFirst() }
    }

    /// Quests whose window closed with the goal unmet, waiting to be shown in red.
    ///
    /// HEALTH_V2 H3 — ONE RED CARD A DAY, NEVER A STACK. A sweep that closes several quests queues ONE
    /// card naming all of them (`failureSummary`), and the card shares one slot per local day with the
    /// day's plan card (`presentPlanReport`): whichever comes first that day is shown, and anything after
    /// it folds into the pinned penalty board instead of stacking a second modal. The misses themselves are
    /// still judged and priced on their data (`QuestPenaltyAssessor`); only the interruption is bounded.
    ///
    /// NEVER A FAILURE: a physiology quest (sleep hours) or an effort quest — reported with its reading by
    /// the assessor, "no cost" unless no training happened at all — and a trial quest (`trial-`), which is
    /// an experiment arm and never a miss. See `showsAsFailure`.
    @Published private(set) var failures: [Completion] = []

    /// The local day the day's one red card (a failure card or the plan card) was last shown.
    private static let dayCardKey = "system.questDayCard.v1"

    /// Whether the day's one card is still free on `now`'s local day.
    func dayCardAvailable(now: Date = Date()) -> Bool {
        defaults.string(forKey: Self.dayCardKey) != DailyMissionStore.dayKey(now)
    }

    private func spendDayCard(now: Date) {
        defaults.set(DailyMissionStore.dayKey(now), forKey: Self.dayCardKey)
    }

    /// Whether a closed, accepted quest may appear on a red card at all (H3c). Pure.
    ///
    /// The wearer's own task (no goal) is their own deadline and does. A quest the DATA judges does only
    /// when its metric is BEHAVIOUR: a physiology or effort metric is reported with its reading, never as a
    /// failure, and a quest with no metric at all is unmeasured, never a miss. A trial arm never does.
    static func showsAsFailure(_ quest: Quest) -> Bool {
        if quest.id.hasPrefix(QuestPenaltyRules.trialIdPrefix) { return false }
        guard let goal = quest.effectiveGoal else { return quest.kind == .custom }
        return goal.metric.penaltyClass == .behaviour
    }

    /// The one card's words for everything a sweep closed. One quest keeps the wording it always had.
    static func failureSummary(_ missed: [Quest]) -> String {
        guard missed.count > 1 else {
            return missed.first?.kind == .custom
                ? "The deadline passed before it was done, so your task has been closed."
                : "The window closed before the data showed it done, so the quest has been cancelled."
        }
        let lines = missed.map { "· \($0.title) — \($0.target)" }
        return (["\(missed.count) closed before the data showed them done. Each is judged on its data:"] + lines)
            .joined(separator: "\n")
    }

    /// CANCEL EVERY QUEST WHOSE WINDOW HAS CLOSED. An accepted quest that runs out is cancelled and its
    /// failure queued for the red pop-up — a commitment that quietly vanished from the strip would be the
    /// system pretending it never asked. One only ever offered and never accepted is withdrawn silently:
    /// nothing was promised, so there is nothing to fail.
    ///
    /// Runs after the completion check, so a goal met in the last minute closes as done, not as failed.
    func sweepExpired(now: Date = Date()) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var missed: [Quest] = []
        for quest in quests where quest.state == .active || quest.state == .offered {
            guard nowMs >= quest.checkableUntilMs() else { continue }
            setState(id: quest.id, state: .declined)
            // THE PENALTY IS DECIDED BY THE DATA, NOT HERE. An accepted quest that ran out is queued to be
            // judged (`QuestPenaltyAssessor`), which needs the day's evidence this clock-driven sweep does
            // not have. A make-up that runs out simply lapses: the miss it was for is already charged, and
            // charging again would be two penalties for one miss.
            if quest.state == .active {
                if QuestDebt.isDebtQuest(quest.id) {
                    penalties?.lapseDebt(quest.id)
                    continue
                }
                penalties?.enqueue(quest)
            }
            // THE DAY'S PLAN IS ONE OUTCOME, NOT N FAILURES. A wearer who picked Relentless and took two
            // of its four directives would otherwise be handed four red cards the next morning, one at a
            // time — four punishments for aiming high, which is the opposite of what the choice is for.
            // A plan directive is still cancelled here exactly like any other; what it does NOT do is
            // queue its own card. The day is summarised once instead, by `QuestPlanReporter`, in the
            // three honest categories (met / short / not measured). Everything else keeps its own card.
            //
            // Only a window that closed in the last day is news. A quest that ran out weeks ago — from
            // before quests could fail — is cancelled quietly rather than joining a queue of red cards.
            if quest.state == .active, !QuestDayPlan.isPlanQuest(quest),
               nowMs - quest.checkableUntilMs() < 24 * 3_600_000, Self.showsAsFailure(quest) {
                missed.append(quest)
            }
        }
        // H3a: ONE card for the whole sweep, and only if the day's card is still free and none is waiting.
        guard let first = missed.first, failures.isEmpty, planReport == nil, dayCardAvailable(now: now) else { return }
        spendDayCard(now: now)
        failures.append(Completion(quest: first.with(state: .declined), summary: Self.failureSummary(missed)))
    }

    /// The front failure has been seen.
    func dismissFailure() {
        if !failures.isEmpty { failures.removeFirst() }
    }

    // MARK: - The day's plan, as it ended
    //
    // The one summary that replaces the N red cards a chosen-difficulty day would otherwise produce.
    // Built by `QuestPlanReporter`, which is the only thing with the day's evidence to hand; this half
    // owns showing it at most once and remembering that it did.

    /// The summary waiting to be shown, or nil. One at a time, like every other card here.
    @Published private(set) var planReport: QuestPlanDayReport?

    /// Days whose plan has already been summarised — the persistent fire-once guard, so a relaunch does
    /// not re-show the card. A LIST rather than a single day (the shape `DayAlerts` uses for its
    /// once-a-day notice): a wearer who did not open the app for a week has several days to close, and
    /// each of them must be closed exactly once.
    private static let reportedKey = "system.questPlanReported.v1"

    /// How many closed days are remembered. Well past the point a summary would still be news, and
    /// bounded so the key cannot grow forever.
    static let reportedKept = 30

    /// Whether `day`'s plan has already been summarised.
    func planDayReported(_ day: String) -> Bool { reportedDays().contains(day) }

    /// Record `day` as closed WITHOUT showing anything. For a day the wearer was never asked about, and
    /// for a day whose every directive was met — each of those already had its own completion card with
    /// its XP on it, and a summary repeating them would be a second notice about the same good news.
    func notePlanDayReported(_ day: String) {
        var days = reportedDays()
        guard !days.contains(day) else { return }
        days.append(day)
        days.sort()
        if days.count > Self.reportedKept { days = Array(days.suffix(Self.reportedKept)) }
        defaults.set(days, forKey: Self.reportedKey)
    }

    /// Show the day's summary, once. Returns whether it fired.
    ///
    /// CHECKED AND RECORDED IN ONE STEP, with nothing awaited between them, so two passes arriving
    /// together cannot both present it — the shape the notification centre's check-then-record race was
    /// fixed into. The guard is spent only on a card that is actually shown: a refused present leaves the
    /// day open for the next pass.
    ///
    /// NOT BEFORE THE DAY IS JUDGED. The card prints each miss with its penalty, so while any of the day's
    /// plan quests is still waiting on its data the present is refused — the guard stays unspent, and the
    /// next pass (the assessor calls the reporter as soon as it has judged) shows the card with its numbers.
    ///
    /// ONE RED CARD A DAY (H3a): refused, with the guard unspent, while today's card slot is taken — the
    /// next day's pass shows it. Never over a failure card that is still up.
    @discardableResult
    func presentPlanReport(_ report: QuestPlanDayReport, now: Date = Date()) -> Bool {
        guard planReport == nil, failures.isEmpty, !planDayReported(report.day) else { return false }
        if penalties?.hasPendingPlanJudgement(day: report.day) == true { return false }
        guard dayCardAvailable(now: now) else { return false }
        notePlanDayReported(report.day)
        spendDayCard(now: now)
        planReport = report
        return true
    }

    /// The summary has been seen.
    func dismissPlanReport() { planReport = nil }

    private func reportedDays() -> [String] { defaults.stringArray(forKey: Self.reportedKey) ?? [] }

    // MARK: - The wearer's own tasks
    //
    // Asked for in the coach's task sheet (`CustomTaskSheet`), stored in this same list as quests of kind
    // `.custom`: the strip, the countdown, auto-completion by goal and the red failure pop-up all apply
    // to them unchanged.

    /// The wearer's own tasks, newest first, in every state.
    var customTasks: [Quest] {
        quests.filter { $0.kind == .custom }.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    /// Add a confirmed custom task. It is issued ACTIVE: the wearer asked for it, so there is nothing to
    /// accept and no pop-up.
    @discardableResult
    func addCustom(_ quest: Quest) -> Quest {
        let task = quest.state == .active ? quest : quest.with(state: .active)
        upsert(task)
        return task
    }

    /// Tick off a custom task by hand. Only custom tasks — a system quest closes on its data, never on
    /// the wearer's word (see `QuestReviewSheet`).
    ///
    /// HB INSERTION POINT (S1-B): a trial quest (`QuestPenaltyRules.trialIdPrefix`) is answered through the
    /// trial store, not completed here — its hook goes at the top of this function and returns.
    func checkOff(id: String) {
        guard let quest = quests.first(where: { $0.id == id }), quest.kind == .custom,
              quest.state == .active || quest.state == .offered else { return }
        complete(quest, summary: "Checked off by you.")
    }

    /// Remove a custom task outright. A system quest is abandoned (`.declined`) instead, so the issuer
    /// does not raise the same one again at once; the wearer's own task has no such history to keep.
    func removeCustom(id: String) {
        guard quests.contains(where: { $0.id == id && $0.kind == .custom }) else { return }
        write(quests.filter { $0.id != id })
    }

    /// Re-read from storage. For a screen that has been away while a background pass wrote one.
    func reload() { quests = QuestStore.read(defaults) }

    private func write(_ list: [Quest]) {
        defaults.set(QuestCodec.encode(list), forKey: QuestStore.key)
        quests = list
    }

    private static func read(_ defaults: UserDefaults) -> [Quest] {
        guard let raw = defaults.string(forKey: key) else { return [] }
        return QuestCodec.decode(
            raw,
            fallbackDay: DailyMissionStore.dayKey(),
            now: Int64(Date().timeIntervalSince1970 * 1000))
    }
}
