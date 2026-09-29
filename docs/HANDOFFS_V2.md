# Telos 2.0 — hand-off ledger (coordinator)

Each item: target file → change → from which package. Tick when applied.

## Strand/AI (token agent finished; now free — an AI-integration agent applies these)
- [ ] QuestGenerator.swift `QuestPlanReporter.reportIfDue`: real bug — early return when the oldest plan day is already reported. Fix: `guard let day = Set(plan.map(\.dayKey)).filter({ !store.planDayReported($0) }).min() else { return }` (penalty agent)
- [ ] QuestGenerator.swift `QuestIssuer.issueIfDue`: exclude make-up quests (`QuestDebt.isDebtQuest`) from the side-quest budget; treat an open make-up's metric as taken (penalty agent)
- [ ] QuestGenerator.swift `issuePlan`: gear re-pick loophole — allow only upward re-picks once issued, or judge at the highest gear picked that day (penalty agent)
- [ ] QuestGenerator.swift `issuePlan` + MorningFlowView `targets(_:)`: wrap targets in `WeekPlanQuestBridge.apply(QuestDayPlan.plan(...), guidance: WeekPlanSource.shared.guidance(for: dayKey), difficulty: difficulty, charge: repo.days.first { $0.day == dayKey }?.recovery)` (HD)
- [ ] AICoach.swift context blocks: week plan block `WeekPlanSource.shared.coachBlock(maxChars: 700)` / short 250, value 60; "Review my week" preset uses `WeekPlanSource.shared.lastReview?.coachBlock(maxChars: 500)` (HD)
- [ ] Coach objective text (H5), habit summary block (HB, ~900 chars, replaces raw journal dump), EffectRanker lines dropped (H12), DayGuidance passing (H9) — from HA/HB reports (pending)
- [ ] Goals block + goals coach panel (HF, pending)
- [ ] DayRituals energy hooks (energy agent, pending)

## Penalty system (SA/QuestPenalty.swift, QuestPenaltyAssessor)
- [ ] `QuestDebtContext.trainingChargeableByDay: [String: Bool]` (default [:]); in `QuestLedger.judge` after the penaltyClass switch: if metric is workoutMinutes/strain and `trainingChargeableByDay[s.dayKey] != true` → reportNote "The week plan made this an easy day: reported, not charged."; `QuestPenaltyAssessor.debtContext` passes `WeekPlanSource.shared.trainingChargeableByDay` (HD)

## HealthV2Refresh (HB creates it)
- [ ] `await WeekPlanSource.shared.refresh(model: model)` (HD)

## Cross-health providers
- [ ] SleepScheduleProvider sets `WeekPlanSource.shared.sleepInputsProvider = { (wakeSd, usualWakeMinute, bedtimeTargetMinute) }` (HD → HA)
- [ ] HabitTrialStore sets `WeekPlanSource.shared.trialStatusProvider` (HD → HB)
- [ ] HabitLedgerSource reads `breath_session_min` from source `noop-habits` (HD → HB)

## Design packages (view hooks)
- [ ] BreathingView (BODY P6): `@StateObject recorder = BreathSessionRecorder()`; start via `recorder.begin(paceBpm:repo:)`; `.onRRPackets` → `recorder.ingest(rr)`; stop → `recorder.finish()`; onDisappear/mode change → `recorder.cancel()`; replace outcomeCard with `BreathSessionPhaseBanner` + `BreathSessionResultCard`; Focus trend `BreathSessionLog.weeklyPreRmssd(...)` (HD)
- [ ] Health tab top: `WeekPlanCardView(source: WeekPlanSource.shared)` (HD → BODY)
- [ ] Today State card: `WeekPlanSource.shared.guidance(for: Repository.localDayKey(Date()))?.line` (HD → TODAY)
- [ ] StrengthProgressionCardView: "Easy week — hold loads" when `currentPlan?.strength.holdLoads == true` (HD → BODY)
- [ ] Optimum trigger: `WeekPlanSource.shared.optimumNoticeDue(todayEffort:)` replaces `optimalStrainRange` in LiquidTodayView.checkOptimum / DayAlerts (HD → TODAY/HA)
- [ ] FrostedCardSurface `\.telosCardOpacity` root hook (P1 → FRAME)

## Audit notes
- breathing minutes are NOT written to meditation_min (level decision)
- level step penalty should use `WeekPlanEngine.stepGate`
- VO2max in review is per-session, not the mixed `vo2max_est` series

## Energy (agent afabbd — full exact code is in its report; summary)
- [ ] A LiquidTodayView `loadStateAndEnergy`: replace from `let todayKey = …` through `energy = EnergyBank.balance(…)` with the `EnergyBank.inputs(dayKey: selectedDayKey, recovery:[stamp(whoopChargeToday,cloudKey), stamp(noopCharge,todayKey), stamp(displayDay?.recovery, displayDay?.day)], sleepScore:[stamp(whoopRestToday,cloudKey), stamp(noopRest,todayKey)], strain21:[stamp(heroOwnEffort→strain21 min whoopStrainMax, todayKey), stamp(cloudDay?.strain, cloudKey)], stressMinutesByDay, calmMinutesByDay: await repo.bankedCalmMinutes(), hoursAwake: EnergyBank.hoursAwake(wakeMinute: sleepTimingsByDay(days:2)[todayKey]?.wakeMinute, nowMinute:…))` then `energy = EnergyCheckInStore.shared.balance(inputs)`; cloudKey = cloudIsCarried ? nil : cloudDay?.day; NO fallback to repo.days.last (TODAY package)
- [ ] B StressDayCurve.swift ~:155 inside `if !scored.scored.isEmpty {` after bankStressMinutes: `if let calm = EnergyBank.calmMinutes(hours: scored.hours) { await repo.bankCalmMinutes(day: Repository.localDayKey(now), minutes: calm) }`
- [ ] C DayRituals.swift: `@MainActor var text: String`; replace `if let energy {…}` (:180-186) with `if let line = EnergyCheckInStore.shared.coachLine(energy) { lines.append("- " + line) }` (AI)
- [ ] D CoachExtraContext.swift :181-184 → `if let line = EnergyCheckInStore.shared.coachLine(CoachDaySnapshot.energy) { day.append("  For \(today): " + line + " It resets at the 04:00 day rollover and does not carry to another day.") }` (AI)
- [ ] E MorningFlowView DailyBriefView after REST/CHARGE HStack: `EnergyCheckInPrompt(slot: .morning, question: "How much energy do you have this morning?")` (SYS package)
- [ ] F Settings: toggle bound to `@AppStorage(EnergyCheckInStore.hiddenKey)` + optional "Reset energy calibration" → `EnergyCheckInStore.shared.clear()` (SYS package)
- [ ] G strings: 11 new in EnergyTileView (integration pass)

## HA (S0 + S2 + Level recipe epoch 4) — exact code in its report
AI:
- [ ] CoachLevelContext.promptSection(): H5 opening line "The level is one lens on long-term trends. Your objective is the wearer's health. Never advise more training load, less sleep or skipping recovery to raise the level."; update sleep/focus formula lines to new recipe (Sleep 30%: duration-vs-need .50 uncapped, wake regularity .30, deep+REM .20; Heart 23%: HRV .5 RHR .5; Muscle 24%: strength .6 load .4 uncapped; Lungs 12%: VO2max .75 resp .25; Focus 11%: daytime calm only); remove meditation from "28-day share"/"previous full day" lines; add "meditation only deducts 1 point per missed day in its era; min 5 min before 2026-09-29, 10 min from it"; add b.meditationPenalty to "Before steps" line; update prompt test
- [ ] QuestGenerator.QuestBaselineReader.read (H9): out.bedtimeTargetMin = SleepScheduleProvider.shared.plan(wakingOn: <quest day + 1>)?.asleepByMin; out.dayState = .standIn(charge: repo.days.first{$0.day==day}?.recovery, illnessRaised: resolvedAppModel(nil)?.healthAlert != nil)  (and HD's WeekPlanQuestBridge wrap)
- [ ] AICoach.onDeviceSignalsBlock (H12): switch to HB habit summary
- [ ] DayRituals/DayRitualScheduler (H4): per-slot keys rituals.enabled.{morning,midday,evening} default T/F/F, migrate legacy rituals.enabled==false → all off; morning time = SleepScheduleProvider.shared.morningRitualMinute(on:) ?? DayRitual.morning.minutes in schedule() and dueRituals(); per-slot register/cancel; setEnabled(_:slot:)
Views:
- [ ] RootTabView: stress subtitle LiveStressMonitor.alertSubtitle(level:); presentStressScreenIfDue final guard LiveStressMonitor.shared.claimScreenSlot(); overlay also when stressMonitor.diagnosticRequested, close via closeDiagnostic(); Optimum overlay message: optimum.message (FRAME)
- [ ] Today stress tile tap → openDiagnostic() (TODAY)
- [ ] Settings: stress alert toggle (setAlertScreenEnabled), 3 ritual slot toggles, target wake + weekend offset (SleepScheduleProvider.shared; alarm time as anchor), WiZ follow toggle (SYS)
- [ ] QuestFailedPopupView (H3b/d): no per-letter ticks/countdown; multi-line summary (PROGRESS B)
- [ ] HealthAlertBanner title "Body off baseline" (TODAY/BODY)
- [ ] CaffeineLogCard: CaffeineBedtime.bedtimeMinutes(fallback: bedtimeMinutes) for cutoff+label
- [ ] MeditationCardView circles + 28-day count: isDayDone(minutes:day:) per circle day (PROGRESS A)
- [ ] LevelBarModel.LevelMissingInput regularity hint "Needs 7 of the last 14 nights with a wake time" (logic file — coordinator)
- [ ] Level breakdown: "−N meditation" line when meditationPenalty > 0; stop showing meditation as a focus contributor (FRAME)
- [ ] TonightCardView (new, SLEEP): reads current, abstention.reason, needLine, paybackLine, insomniaLine
- [ ] H10, H11, H13, H15 view-only items open (BODY/PROGRESS)
Findings for owner: load term = training done not adaptation (uncapped by decision); sleep duration uncapped; one sleep need applied to whole history; meditation era from log (≥180 d read)
