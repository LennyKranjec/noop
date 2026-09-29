import Foundation
import StrandAnalytics
import WhoopStore

// QuestGenerator.swift — naming a quest, and deciding when one is raised.
//
// Swift twin of the Android `com.noop.ai.QuestGenerator` plus the issuing half of `QuestTrigger`.
//
// The trigger already decided there is a problem and what the directive is. This asks the model for the
// two parts that should never be the same twice: a TITLE and a TAUNT.
//
// WHY THOSE TWO AND NOTHING ELSE. A generated target is a fabricated number, and a generated trigger is
// a model inventing a reason to nag. Both are things this app does not do. A generated NAME costs
// nothing if it is silly and is the difference between "Step goal" and something the wearer actually
// looks at. The parse is written so a model that ignores the format entirely still produces a usable
// quest: the target and the XP were never its to decide.
//
// IT NEVER FAILS TO ISSUE. If the model is unavailable — no provider, no consent, a dead network — the
// quest is still issued under a written fallback name. A system that stays silent because its writer
// was busy is a system that misses the day it was needed.

enum QuestGenerator {

    /// The model's answer, capped. Two short lines; anything longer is rambling.
    private static let maxAnswerChars = 260

    /// Turn one of the day's chosen-difficulty directives into a quest, naming it with the coach.
    ///
    /// ISSUED ALREADY ACCEPTED. The wearer picked the day's gear in the morning flow, which IS the
    /// choosing that makes a quest a quest — the same reasoning `QuestKind.custom` is issued active on.
    /// Offering four of them one at a time through the pop-up would dribble the day's plan out over the
    /// morning (`QuestStore.offered` shows one at a time) and ask the wearer to agree to a thing they
    /// had already agreed to.
    ///
    /// It is still kind `.side`: the stored wire shape is a parity contract with the Kotlin twin, so a
    /// mode quest is found by its id (`QuestDayPlan.isPlanQuest`) rather than by a new kind an older
    /// build would not understand. Not `.custom`, because that kind carries a "Mark it done" button —
    /// and a quest with a measured target must close on the data, never on the wearer's word.
    static func fromPlan(_ target: QuestPlanTarget, coach: AICoachEngine, dayKey: String) async -> Quest {
        let written = await write(coach: coach, reason: target.observation, directive: target.target)
        return Quest(
            id: target.id,
            kind: .side,
            title: written?.title ?? target.fallbackTitle,
            taunt: written?.taunt ?? target.fallbackTaunt,
            target: target.target,
            rewards: target.rewards,
            xp: target.xp,
            state: .active,
            dayKey: dayKey,
            createdAtMs: nowMs(),
            goal: target.goal)
    }

    /// Turn `trigger` into a quest, naming it with the coach.
    static func fromTrigger(_ trigger: QuestTrigger, coach: AICoachEngine, dayKey: String) async -> Quest {
        let written = await write(
            coach: coach,
            reason: trigger.observation,
            directive: trigger.target)
        return Quest(
            kind: .side,
            title: written?.title ?? QuestNaming.fallbackTitle(triggerId: trigger.id),
            taunt: written?.taunt ?? QuestNaming.fallbackTaunt(triggerId: trigger.id),
            target: trigger.target,
            rewards: trigger.rewards,
            xp: trigger.xp,
            dayKey: dayKey,
            createdAtMs: nowMs(),
            goal: trigger.goal)
    }

    /// The day's main quest, from the mission the coach already wrote.
    ///
    /// The mission IS the directive here — it was generated from the day's metrics and the wearer's
    /// goals — so this only needs a name for it. Its own sarcastic text becomes the taunt: a second one
    /// would be two jokes about the same thing.
    static func fromMission(_ mission: DailyMission, coach: AICoachEngine) async -> Quest {
        let written = await write(
            coach: coach,
            reason: "Today's directive for them is: \(mission.text)",
            directive: mission.text)
        return Quest(
            kind: .daily,
            title: written?.title ?? QuestNaming.fallbackTitle(triggerId: "daily"),
            taunt: String(mission.text.prefix(QuestNaming.maxTauntChars)),
            target: mission.text,
            rewards: QuestNaming.rewards(forDirective: mission.text),
            xp: dailyXp,
            dayKey: mission.dayKey,
            createdAtMs: nowMs(),
            goal: mission.goal ?? QuestGoal.parse(mission.text))
    }

    /// What the day's own quest is worth. Fixed, because the daily is always the same commitment.
    private static let dailyXp = 60

    private static func write(coach: AICoachEngine, reason: String, directive: String) async -> QuestNaming.Written? {
        let answer = await coach.generateOneShot(
            systemPrompt: systemPrompt(),
            question: "Situation: \(reason)\nDirective: \(directive)\nName it.",
            budget: .naming)
        guard let answer else { return nil }
        return QuestNaming.parse(String(answer.prefix(maxAnswerChars)))
    }

    static func systemPrompt(_ defaults: UserDefaults = .standard) -> String {
        var s = ""
        s += "You are THE SYSTEM naming a quest for the Player. Cold, theatrical, savagely funny. "
        s += "You are given a situation and a directive. You do NOT change the directive and you do "
        s += "NOT invent numbers.\n\n"
        s += "Answer in EXACTLY two lines and nothing else:\n"
        s += "TITLE: <a quest name, 2-5 words, no quotation marks>\n"
        s += "TAUNT: <one sentence, at most 25 words, mocking the SITUATION and never the person>\n\n"
        s += "Example:\n"
        s += "TITLE: The Horizontal Hours\n"
        s += "TAUNT: Eleven hundred steps. Impressive — most furniture manages that only when moved.\n\n"
        s += "Never mock their body or their weight. If the situation involves pain, injury or "
        s += "illness, drop the theatre and write both lines plainly."
        if let routines = CoachRoutines.promptSection(defaults) { s += "\n\n" + routines }
        return s
    }
}

// MARK: - Issuing
//
// The half that decides whether today should be interrupted at all.
//
// ONE OFFERED AT A TIME. `QuestStore.offered` is what the pop-up reads, and two stacked pop-ups is a
// dialog fight — so nothing new is raised while one is still waiting to be answered.
//
// THE DAILY FIRST, THEN AT MOST ONE SIDE QUEST. The daily is the mission promoted; a side quest is the
// data noticing something. Raising both at once means the second is answered without being read.

@MainActor
enum QuestIssuer {

    /// Raise whatever today has earned, if anything. Safe to call on every appearance of Today.
    static func issueIfDue(repo: Repository, coach: AICoachEngine) async {
        // A PAST DAY'S PLAN IS CLOSED BEFORE A NEW ONE IS RAISED. Its directives were already cancelled
        // by `QuestStore.sweepExpired` without cards of their own; this is where the day gets its one
        // summary. Harmless on every other call — it returns at once when there is nothing to close.
        await QuestPlanReporter.reportIfDue(repo: repo)
        let store = QuestStore.shared
        // Something is already waiting to be answered. Anything raised now would stack behind it and be
        // dismissed unread.
        guard store.offered == nil else { return }

        let dayKey = DailyMissionStore.dayKey()
        let existingToday = store.forDay(dayKey)

        // 1 · The day's own quest, from the mission, once per day.
        if !existingToday.contains(where: { $0.kind == .daily }),
           let mission = await coach.ensureDailyMission() {
            store.upsert(await QuestGenerator.fromMission(mission, coach: coach))
            return
        }

        // 2 · At most one side quest, and only for a condition not already on today's list.
        //
        // THE CHOSEN DIFFICULTY'S QUESTS DO NOT SPEND THE SIDE BUDGET. They are the day's plan, not the
        // data noticing something, and a Relentless morning would otherwise fill `maxSidePerDay` before
        // breakfast and silence the one trigger that matters — overreaching on an empty tank. So the
        // budget is counted over the triggered quests only, while the CONDITION check below still sees
        // the whole day: a trigger that asks for a metric the day's plan already asks for is not news.
        //
        // MAKE-UP QUESTS DO NOT SPEND IT EITHER. A make-up (`QuestDebt`) is the price of an earlier miss,
        // not the data noticing something today; counting it would let one missed directive silence the
        // day's only trigger. And a metric a make-up is still open on is TAKEN: a side quest asking for
        // the same steps the make-up already asks for is the same demand twice.
        let days = repo.days
        guard let trigger = QuestTriggers.next(
            today: days.last,
            recent: Array(days.suffix(14)),
            existingToday: sideBudgetQuests(existingToday))
        else { return }
        let taken = takenMetrics(existingToday: existingToday, all: store.quests)
        if let metric = trigger.goal?.metric, taken.contains(metric) { return }
        store.upsert(await QuestGenerator.fromTrigger(trigger, coach: coach, dayKey: dayKey))
    }

    /// The quests that count against the side-quest budget: everything on the day except the chosen
    /// gear's plan directives and make-up quests. Pure.
    nonisolated static func sideBudgetQuests(_ existingToday: [Quest]) -> [Quest] {
        existingToday.filter { !QuestDayPlan.isPlanQuest($0) && !QuestDebt.isDebtQuest($0.id) }
    }

    /// Metrics a new side quest may not ask for: the day's live plan directives, and every make-up that
    /// is still open (offered or active, whichever day it was issued for). Pure.
    nonisolated static func takenMetrics(existingToday: [Quest], all: [Quest]) -> Set<QuestMetric> {
        let planned = existingToday.filter { QuestDayPlan.isPlanQuest($0) && $0.state != .declined }
        let openMakeUps = all.filter {
            QuestDebt.isDebtQuest($0.id) && ($0.state == .active || $0.state == .offered)
        }
        return Set((planned + openMakeUps).compactMap { $0.effectiveGoal?.metric })
    }

    /// Issue the day's quests for a freshly picked difficulty, replacing whatever the last pick left.
    ///
    /// ORDER MATTERS: CHOOSE, THEN GENERATE. The morning flow runs before the day has any quests, so the
    /// plan is written first and `issueIfDue` finds it already there. A pick made LATER in the day
    /// replaces the plan quests it issued before — except the ones already completed, because that XP is
    /// paid and a finished commitment is not something a new choice gets to un-finish.
    ///
    /// Each quest is named by the coach one at a time, exactly as `issueIfDue` names one, and appears as
    /// it is named. A coach that cannot be reached returns at once and the written fallbacks are used, so
    /// the day's plan is never delayed by its writer.
    ///
    /// ONLY UPWARD ONCE ISSUED. A day whose plan has gone out at a gear can be re-picked HIGHER (Steady ->
    /// Push -> Relentless) but not lower: otherwise picking Relentless at breakfast and Steady at nine in
    /// the evening would swap four directives the wearer is about to miss for two they already met, and be
    /// judged on the easy set. A downward re-pick leaves the higher gear's quests untouched, puts the
    /// higher gear back on the day (`QuestModeStore`, which Today's chip and the penalty judge read), and
    /// returns the note that says so.
    @discardableResult
    static func issuePlan(_ difficulty: QuestDifficulty, repo: Repository, coach: AICoachEngine,
                          focus: LevelPart?, dayKey: String = DailyMissionStore.dayKey()) async -> QuestPlanIssue {
        let store = QuestStore.shared
        let gear = QuestGearFloor.effective(picked: difficulty, issued: QuestGearFloor.issued(for: dayKey))
        if gear != difficulty {
            // A downward re-pick: nothing is re-issued, and the day keeps the gear it was issued at.
            QuestModeStore.shared.set(gear, for: dayKey)
            return QuestPlanIssue(gear: gear, note: QuestGearFloor.downgradeNote(picked: difficulty, held: gear))
        }
        QuestGearFloor.note(gear, for: dayKey)
        let baseline = await QuestBaselineReader.read(repo: repo, day: dayKey)
        let targets = QuestPlanComposer.targets(baseline: baseline, difficulty: gear, focus: focus,
                                                day: dayKey, repo: repo)

        // Withdraw the previous pick's unfinished quests. `.declined` rather than deleted, so the store's
        // own history rules apply and nothing re-raises them.
        let keep = Set(targets.map(\.id))
        let stale = store.forDay(dayKey).filter {
            QuestDayPlan.isPlanQuest($0) && $0.state != .completed && !keep.contains($0.id)
        }
        for quest in stale {
            store.setState(id: quest.id, state: .declined)
        }

        for target in targets {
            // A quest this wearer already finished today keeps its completion; the new pick does not
            // re-issue it under a fresh clock.
            if store.forDay(dayKey).contains(where: { $0.id == target.id && $0.state == .completed }) {
                continue
            }
            store.upsert(await QuestGenerator.fromPlan(target, coach: coach, dayKey: dayKey))
        }
        return QuestPlanIssue(gear: gear, note: nil)
    }
}

/// What `QuestIssuer.issuePlan` did with a pick: the gear the day now runs at, and, when that is not the
/// gear that was picked, the sentence that says why.
struct QuestPlanIssue: Equatable {
    let gear: QuestDifficulty
    let note: String?
}

// MARK: - The gear a day was issued at
//
// Why a day's plan cannot be re-picked downward. `QuestModeStore` holds the LAST pick (the morning flow
// writes it before issuing), so it cannot say what went out before; this keeps the highest gear each
// day's plan was actually issued at.

enum QuestGearFloor {

    /// One key, a `[day: rawValue]` dictionary, like `QuestModeStore.key`.
    static let key = "system.questGearIssued.v1"
    /// Days kept, like `QuestModeStore.kept`: only the current day is ever read.
    static let kept = 14

    /// Steady < Push < Relentless.
    static func rank(_ gear: QuestDifficulty) -> Int {
        switch gear {
        case .steady: return 0
        case .push: return 1
        case .relentless: return 2
        }
    }

    /// The gear a pick runs at: the pick itself, unless the day was already issued at a higher one.
    static func effective(picked: QuestDifficulty, issued: QuestDifficulty?) -> QuestDifficulty {
        guard let issued, rank(issued) > rank(picked) else { return picked }
        return issued
    }

    /// The UI copy for a downward re-pick; nil when the pick stands.
    static func downgradeNote(picked: QuestDifficulty, held: QuestDifficulty) -> String? {
        guard rank(held) > rank(picked) else { return nil }
        return "Today's quests already went out at \(held.title). The gear can go up once the day is "
            + "issued, not down, so \(held.title)'s targets stand."
    }

    /// The highest gear `day`'s plan was issued at, or nil when none was.
    static func issued(for day: String, _ d: UserDefaults = .standard) -> QuestDifficulty? {
        read(d)[day]
    }

    /// Record that `day`'s plan went out at `gear`. Only ever raises the stored gear.
    static func note(_ gear: QuestDifficulty, for day: String, _ d: UserDefaults = .standard) {
        var next = read(d)
        next[day] = effective(picked: gear, issued: next[day])
        if next.count > kept {
            for old in next.keys.sorted().prefix(next.count - kept) { next[old] = nil }
        }
        d.set(next.mapValues(\.rawValue), forKey: key)
    }

    private static func read(_ d: UserDefaults) -> [String: QuestDifficulty] {
        let raw = d.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(QuestDifficulty.init(rawValue:))
    }
}

// MARK: - The day's plan, bounded by the day
//
// ONE PLACE the gear's targets meet the day's state and the week plan, read both by issuing and by the
// morning flow's preview, so the card shows exactly what will be issued.

enum QuestPlanComposer {

    /// The gear's plan for `day`, bounded by what the day allows. Pure.
    ///
    /// THE BRIDGE UNDOES THE GEAR'S TRAINING FACTOR (`threshold / scale.training`), so it must be handed
    /// the plan at the gear's own factors, an `asPlanned` plan, or the day's state would be applied twice
    /// and a recovery day's minutes would be cut a second time. So:
    ///   - When the week plan (or, with no plan, a known Charge at or under `QuestTriggers.chargeLow`)
    ///     constrains the day, the bridge is the authority: `asPlanned` plan in, bridge applied.
    ///   - An illness heads-up (`baseline.dayState == .rest`, from `QuestDayState.standIn`) makes the day a
    ///     rest day whatever the week plan said: the heads-up can be newer than the plan.
    ///   - Otherwise the plan runs with the stand-in state `QuestBaselineReader` put on the baseline.
    static func targets(baseline: QuestBaseline, difficulty: QuestDifficulty, focus: LevelPart?,
                        day: String, guidance: DayGuidance?, charge: Double?) -> [QuestPlanTarget] {
        var dayGuidance = guidance
        if baseline.dayState == .rest, guidance?.kind != .rest {
            dayGuidance = DayGuidance(day: day, kind: .rest, notes: [.illness],
                                      hrvNights: guidance?.hrvNights ?? 0, charge: charge)
        }
        let bridgeActs: Bool
        if let g = dayGuidance {
            bridgeActs = g.kind != .asPlanned
        } else if let c = charge {
            bridgeActs = c <= QuestTriggers.chargeLow
        } else {
            bridgeActs = false
        }
        guard bridgeActs else {
            return QuestDayPlan.plan(baseline: baseline, difficulty: difficulty, focus: focus, day: day)
        }
        let raw = QuestDayPlan.plan(baseline: baseline, difficulty: difficulty, focus: focus, day: day,
                                    dayState: .asPlanned)
        return WeekPlanQuestBridge.apply(raw, guidance: dayGuidance, difficulty: difficulty, charge: charge)
    }

    /// The same, reading the day's week-plan guidance and Charge from the app.
    @MainActor
    static func targets(baseline: QuestBaseline, difficulty: QuestDifficulty, focus: LevelPart?,
                        day: String, repo: Repository) -> [QuestPlanTarget] {
        targets(baseline: baseline, difficulty: difficulty, focus: focus, day: day,
                guidance: WeekPlanSource.shared.guidance(for: day),
                charge: repo.days.first { $0.day == day }?.recovery)
    }
}

// MARK: - Closing a day's plan
//
// The chosen-difficulty directives do not each get a red card when they run out (see
// `QuestStore.sweepExpired`). This is what replaces them: one summary per day, built from the day's own
// evidence, shown once.
//
// IT NEEDS THE EVIDENCE, which is why it lives here and not in the store: `sweepExpired` runs off a
// clock with no repository to hand, and a summary that said "not met" without saying how close would be
// the same scolding in fewer words.

@MainActor
enum QuestPlanReporter {

    /// Summarise the oldest past day whose plan has finished, if it has not been summarised already.
    static func reportIfDue(repo: Repository, now: Date = Date()) async {
        let store = QuestStore.shared
        // NOT ON TOP OF ANOTHER CARD. A completion, a failure or an offer already owns that space, and
        // this is not urgent — it waits for the next pass rather than stacking. Nothing is spent by
        // waiting: the fire-once guard is only taken when a card is actually shown.
        guard store.planReport == nil, store.offered == nil,
              store.completions.isEmpty, store.failures.isEmpty else { return }

        let today = DailyMissionStore.dayKey(now)
        let plan = store.quests.filter { QuestDayPlan.isPlanQuest($0) && $0.dayKey < today }
        // Oldest UNREPORTED first, so a wearer who was away for a week closes those days in order. Not
        // the oldest day outright: that one is usually reported already, and returning on it meant no
        // later day's card was ever shown.
        guard let day = nextDayToReport(planDays: plan.map(\.dayKey),
                                        isReported: { store.planDayReported($0) }) else { return }

        let quests = plan.filter { $0.dayKey == day }.sorted { $0.createdAtMs < $1.createdAtMs }
        // STILL RUNNING IS NOT AN OUTCOME. A sleep or bedtime directive stays checkable until noon the
        // next day (`Quest.checkableUntilMs`), and summarising the day before that would call a night
        // that has not been read yet a miss.
        guard !quests.contains(where: { $0.state == .active || $0.state == .offered }) else { return }

        // NO CHOICE, NO PLAN. A day the wearer was never asked about has nothing to summarise — closed
        // silently so it is not looked at again.
        guard let difficulty = QuestModeStore.shared.mode(for: day) else {
            store.notePlanDayReported(day)
            return
        }

        // ONE GATHER FOR THE DAY, the same read `QuestAutoComplete` closes quests with — so a line in the
        // summary can never quote a different number from the one that decided the quest.
        let evidence = await QuestAutoComplete.gather(repo: repo, day: day)
        let report = QuestPlanDayReport(
            day: day,
            difficulty: difficulty,
            lines: quests.map {
                QuestPlanDayReport.line(target: $0.target, goal: $0.effectiveGoal,
                                        completed: $0.state == .completed, evidence: evidence)
            })
        guard report.isWorthShowing else {
            store.notePlanDayReported(day)
            return
        }
        store.presentPlanReport(report)
    }

    /// The earliest plan day not yet reported, or nil. Pure.
    nonisolated static func nextDayToReport(planDays: [String], isReported: (String) -> Bool) -> String? {
        Set(planDays).filter { !isReported($0) }.min()
    }
}

// MARK: - The wearer's own numbers
//
// What every scaled target is measured from. One reader, so "their usual" means the same thing in every
// directive the day issues.

@MainActor
enum QuestBaselineReader {

    /// Read this wearer's own baselines for `day`.
    ///
    /// EVERY FIELD ABSTAINS ON ITS OWN. A metric without `QuestDayPlan.minBaselineDays` of this
    /// wearer's own days stays nil and produces no directive — see `QuestBaseline`. Nothing here
    /// substitutes a population default, and nothing here invents a day.
    static func read(repo: Repository, day: String) async -> QuestBaseline {
        var out = QuestBaseline()
        let window = QuestDayPlan.baselineWindowDays
        let days = repo.days.suffix(window + 1).filter { $0.day < day }

        // STEPS — the median of the days that actually have a count. A nil step count is a day the
        // sensor was not read, not a day with no steps, so it is left out rather than counted as zero.
        out.medianSteps = QuestDayPlan.median(days.compactMap { $0.steps.map(Double.init) })

        // SLEEP NEED — what the last analysis pass scored Rest with. Nil before any pass has run.
        out.sleepNeedHours = AnalyticsEngine.Rest.engineNeedHours()

        // BEDTIME — their own median onset, on the evening clock. Only the fallback now: the sleep
        // anchor's asleep-by for the night that ends the morning after `day` is THE bedtime when there is
        // one (HEALTH_V2 H9b), the same for every gear. Nil while the anchor abstains.
        let timings = await repo.sleepTimingsByDay(days: window + 1)
        out.medianSleepOnsetMinute = QuestDayPlan.medianOnsetMinute(
            timings.filter { $0.key < day }.values.map(\.onsetMinute))
        if let date = LevelWiring.date(from: day),
           let wake = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            out.bedtimeTargetMin = SleepScheduleProvider.shared.plan(wakingOn: wake)?.asleepByMin
        }

        // THE DAY'S STATE (H9a): the stand-in `QuestPlanComposer` falls back to when the week plan does
        // not constrain the day. An illness heads-up is a rest day, a Charge under the low line an easy
        // one, and an unmeasured morning is never invented as low.
        out.dayState = QuestDayState.standIn(charge: repo.days.first { $0.day == day }?.recovery,
                                             illnessRaised: resolvedAppModel(nil)?.healthAlert != nil)

        // TRAINING — the median length of the days they train on. Days with no session are excluded:
        // the question is how long a session of theirs runs, not how often they have one.
        let workouts = await repo.workoutRows(days: window + 1)
        var trainingByDay: [String: Double] = [:]
        for w in workouts {
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            guard key < day else { continue }
            trainingByDay[key, default: 0] += (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60
        }
        out.medianTrainingMinutes = QuestDayPlan.median(trainingByDay.values.filter { $0 > 0 })

        // MEDITATION — the median length of their sessions, over the days that have one.
        let meditation = await repo.meditationMinutesByDay(days: window + 1)
        out.medianMeditationMinutes = QuestDayPlan.median(
            meditation.filter { $0.key < day && $0.value > 0 }.values.map { $0 })

        // WATER — the day's own goal, and only while the wearer tracks water at all. Tracking off means
        // there is nothing to check a water directive against, and an uncheckable quest is not issued.
        if HydrationStore.isEnabled {
            let own = await repo.noopScores(day: day).effort
            let merged = repo.days.first { $0.day == day }?.strain
            let effort = own ?? merged
            let sex = resolvedAppModel(nil)?.profile.sex ?? ""
            out.hydrationGoalMl = Double(HydrationGoal.dailyGoalML(sex: sex, effort: effort))
        }

        // EFFORT — the day's recommended band, and ONLY when the day's strain is a figure this wearer's
        // data actually produces. `QuestMetric.strain` is checked against WHOOP's own cloud strain and
        // nothing stands in for it, so a band with no strain behind it would be a quest that can never
        // close. Evidence: a cloud strain on any of the last few days.
        if let band = await repo.todayEffortTarget()?.band {
            var measurable = false
            for recent in days.suffix(3) {
                if await repo.whoopCloudDay(recent.day)?.strain != nil {
                    measurable = true
                    break
                }
            }
            if measurable { out.effortBand21 = band }
        }
        return out
    }
}
