# Telos 2.0 — health-impact plan

Status: planning document for implementation agents. Written 2026-09-29 against `main` at `bd2a062d`.
Scope: the iOS app (`NOOPiOS`, sharing `Strand/` and `Packages/`). Nothing here is a medical claim; every
feature below stays inside the project's wellness-only framing (see `docs/SAFEGUARDS.md`,
`DISCLAIMER.md`).

The owner's brief for 2.0 is to "improve the improvement of my health and body as far as possible". This
document answers one question: given what this app can actually measure, and how reliably, which product
changes are most likely to change a real wearer's health, and how to build them without breaking the
project's honesty rules (absent ⇒ "—" plus a reason, no fabricated values, `calibrating / building / solid`
confidence, level coverage).

Two ground rules run through every spec:

1. **Behaviour change beats more numbers.** The app already computes far more than it acts on. Most of the
   health upside is in closing loops that exist in pieces: a week-level plan instead of day-level
   scores, one sleep schedule instead of six, and a way to test habits properly instead of listing
   correlations.
2. **Harm removal comes first.** Several current surfaces can raise arousal, reward overtraining, or
   present a population prior as the wearer's own data. Fixing these is cheaper than any feature and helps
   everyone.

---

## 0. Summary

### Ranking (expected health impact × feasibility × honesty)

| # | Change | Why it ranks here | Spec |
|---|---|---|---|
| 0 | **Harm-removal pack**: honesty fixes inside the stress screen, the "Optimum reached" screen and the daily failure card (these stay by coordinator decision), 3×/day ritual pushes with no UI toggle, the coach's "raise this score" objective, unbounded training-load reward in the level, the illness skin-temp bug, dishonest breathing before/after, a mislabelled dose-response card | Cheap, certain, and helps every wearer. Several items are real bugs. | [S0](#s0-harm-removal-pack) |
| 1 | **Weekly movement plan and review**: aerobic minutes toward the WHO range, 2 strength sessions/week with the existing progression, step targets from the wearer's own baseline, HRV-guided day moves, ramp guard, easy weeks triggered by data | Physical activity has the largest and best-evidenced dose-response of anything this app can influence. The app has the pieces (zones, TRIMP, CTL/ATL, HRV SWC tier, lift sets) and no plan. | [S3](#s3-weekly-movement-plan-and-review) |
| 2 | **Sleep anchor**: one wake anchor → one bedtime target → wind-down, lights, room, caffeine cutoff and bedtime quests all read it; a real regularity metric | Sleep timing is measured well even where staging is not. Six independent schedules exist today, and the gear system actively varies bedtime day to day. | [S2](#s2-sleep-anchor) |
| 3 | **Central habit model and N-of-1 habit trials** (owner's top priority) | It turns loose journal correlations into answers the wearer can trust, and it is the most honest way to personalise. Its health impact depends on which habits turn out to matter, so it ranks below activity and sleep on expected impact, but it is **in the 2.0 build set by owner priority** and has the fullest spec. | [S1](#s1-central-habit-model-and-n-of-1-habit-trials) |
| 4 | **Honest breathing sessions**: pre/post quiet readings with cleaned R-R, stored, trended | Slow breathing has moderate evidence for stress and anxiety. The current before/after number is not honest. Small build. | [S4](#s4-honest-breathing-sessions) |
| 5 | Illness heads-up | Keep opt-in; fix the bugs (S0). Do not expand: retrospective evidence, low positive predictive value, can only say "rest". | S0 items H7–H8 |
| 6 | VO₂max trend feedback | Shown as a monthly trend with its error band inside the weekly review. Not a target: the estimate's error (±5 ml/kg/min) is larger than a year of realistic change. | S3 §3.6 |
| 7 | "Zone 2" volume | Folded into aerobic minutes (moderate + vigorous by %HRR). The zone-2-specific evidence is weaker than its marketing; total volume carries the benefit. | S3 |
| — | Things not to build | See [§5](#5-what-not-to-build). |

### Build set for 2.0

S0 (all of it), S1 (A and B), S2, S3, S4. Order: S0 first (small, unblocks the rest). Then S1, S2 and S3
in parallel; they touch different files. S4 last. Section [§4](#4-coordination-and-file-ownership) lists
every existing file each spec touches so the design packages and the other agents (token budget in
`Strand/AI/**`, `docs/DESIGN_V2.md`, level-audit, steps-vo2-audit, nightly-stress-audit) can see conflicts
before they happen.

### Binding coordinator decisions (`docs/DESIGN_V2.md`, top block) and how this plan applies them

The coordinator recorded owner decisions that override this document where the two disagree:
1. The stress full-screen diagnostic, the "Optimum reached" full-screen and the gear choice **stay** and may
   only be restyled, not removed or put behind an opt-in.
2. The daily failure card **stays red and consequential**, with exact numbers, one card per day.
3. Penalties apply to behaviour only, never physiology, and never to trial quests.
4. The Focus tab stays; the Habits hub is reached from Today, the Coach and More.

S0 items H1–H3 are therefore rewritten below as honesty fixes *inside* those surfaces rather than removals.
Where the health evidence still points the other way, the item says so plainly for the owner to weigh; it
does not override the decision.

### Platform note

The owner has scoped 2.0 to iOS. `CLAUDE.md` requires Swift/Kotlin parity for analytics and stored data.
Every **new** engine in this plan is Swift-only and uses platform-neutral primitives (FNV-1a hashes,
SplitMix64 RNG, `yyyy-MM-dd` strings, integer calendar math) so a Kotlin twin can be added later without
changing results. Every change to an **existing shared** engine (`QuestDifficulty`, `LevelEngine`,
`AppModel.applyIllnessSignal`'s inputs) breaks parity with Android and must say so in its PR. No new key is
added to the `.noopbak` whitelist (`BackupSettings.swift`) in 2.0, because that whitelist is a byte-identical
contract with the Android codec. New stores live in their own files and are listed as a backup follow-up.

**Test reality check.** `swift-packages.yml` runs `Packages/**` tests on every push. `StrandTests` run only
when `app-build.yml` is dispatched by hand. So every decision rule in this plan lives in a pure
`Packages/StrandAnalytics` type with package tests. App-side tests are written as well, but are not relied on
as the guard.

---

## 1. Ground truth: data and engine inventory

Verdicts: **solid** = computed correctly, gated, tested, and valid enough for decisions; **thin** = works but
has a validity gap, a wiring gap, or is untested; **unused** = collected or computed but read by nothing that
matters; **unsound** = claims more than it computes.

### 1.1 Sensors and data sources

| Source | What arrives | Reliability here | Verdict |
|---|---|---|---|
| WHOOP 5/MG strap | HR 1 Hz, R-R (optical), gravity, step counter (@57), skin temp (`raw/100`, proven), SpO₂ candidate byte (unvalidated) | HR solid. R-R optical, good at rest, coverage drops when co-bonded with the WHOOP app (`docs/RR-OPTIMIZATION.md`: 3 of 8 nights adequate). Steps are a raw pass-through until the wearer calibrates (`stepTicksPerStep` defaults to 1.0; overcounts up to ~24×). | HR solid; R-R thin; steps thin until calibrated; SpO₂ unused (default-off display) |
| WHOOP 4.0 strap | HR, R-R, sparse gravity, skin temp (affine map, provisional slope #938), no steps over BLE | Motion too sparse to stage sleep reliably (#345). Skin temp: direction trustworthy, absolute approximate. Steps only as `k × motion`, fitted to phone steps. | HR solid; staging thin; skin temp thin; steps thin |
| Apple Health import | Daily steps/energy/VO₂/HR, workouts, water, caffeine | Phone steps are the calibration reference for 4.0. | solid |
| WHOOP cloud (`WhoopCloudSync`) | Recovery, strain 0–21, sleep performance | Used as the reference for effort calibration. Only cloud users get an Effort quest and an Effort→WHOOP calibration. | solid, but creates a two-tier experience |
| WHOOP CSV (`WhoopImporter`) | History; daily `hr_zone1..5_min` | Only source of stored daily zone minutes. | solid (import-only) |
| Govee (`BedroomClimate`) | Temperature, humidity every 10 min while the app runs; 14-day `ClimateHistory` | Accurate sensor; history not keyed to nights; never related to sleep. No CO₂. | thin (unused for outcomes) |
| WiZ (`WizLights`) | Scenes 6500 K / 4600 K / 2700 K / 2200 K; two fixed-time automations | Works; not tied to the sleep window; no usage history. | thin |
| Weather (`WeatherNow`) | Open-Meteo, **hard-coded to Frankfurt**, today only | Wrong for anyone elsewhere. | thin |
| Lift imports (`ImportedLiftSets`) | Alphaprog, Hevy CSV, Liftosaur JSON → per-set rows (store v46); Hevy API parser has no app caller | Accurate per set; manual file re-import only; no RPE; lifting never enters Effort/ACWR/CTL. | solid data, thin freshness |
| Hydration (`HydrationStore`) | ml per day plus timestamped entries | Absent reads as 0; the enable date is not stored. | thin |
| Meditation (`MeditationLog`) | Minutes per day from named workouts and the legacy timer | Absent reads as 0. | thin |
| Dream journal | 7 four-option answers per wake day incl. `Screen before bed`, `Last meal before bed` | Stored as numeric journal rows with `answeredYes = true` only, so they never reach any statistic. | **unused** |
| Journal (`journal` table) | Yes/no and numeric items; custom items keyed by their text | Only store with a real "logged no". Numeric items have no "no" state and feed no statistic. | solid (bool) / unused (numeric) |
| Caffeine (`CaffeineLog`) | Intakes with timestamps, **48-hour retention** | No history exists to analyse. | **unused** |
| Mood (`MoodStore`) | 1–5 check-ins | Only `MindSection` Pearson. | thin |
| Cycle (`CycleTrackingStore`) | Period starts | Only `CycleAwarenessCard`; not an illness confounder. | thin |

### 1.2 Scores and engines

Paths abbreviated: `SA/` = `Packages/StrandAnalytics/Sources/StrandAnalytics/`.

| Engine | What it does | Verdict and the reason |
|---|---|---|
| Charge — `SA/RecoveryScorer.swift` | HRV 0.55 (ln z), RHR 0.20, sleep 0.15, resp/skin/recovery-index/activity-balance 0.05 each; logistic to 0–100 | **solid.** But `priorDayEffort` and `recoveryIndexSlope` are never supplied by a production caller, so Charge ignores yesterday's load. |
| Nightly RHR/HRV/resp — `SleepStager.swift`, `AnalyticsEngine.swift` | RHR/HRV from the last deep run, else fallbacks; resp from RSA | **solid on 5/MG; thin on 4.0**, because the "deep run" anchor inherits staging error. |
| Rest — `AnalyticsEngine.Rest` | duration vs need 0.50, efficiency 0.20, restorative 0.20, consistency 0.10 | **thin.** Consistency is `1 − CV` of *durations* and ignores timing. Restorative share rests on staging (V2 kappa 0.356 on PSG replay; no 4.0 ground truth). |
| Sleep need — `Rest.personalizedNeedHours` | p75 of nightly hours, floored 8.0 h, capped 9.5 h | **thin.** Three definitions exist: engine p75, `HoursVsNeededCard` `max(7.5 h, mean)`, `WindDownNudge` user setting 8 h. |
| Sleep debt — `SA/SleepDebt.swift` | 55 % carry of unmet need over 14 nights | **solid.** |
| Regularity | four definitions: Rest `1−CV` of duration; `SleepModel.consistencySeries` onset SD; `Streaks` ±30 min; `LevelWiring.regularity` night-to-night drift | **thin.** No Sleep Regularity Index anywhere. |
| Effort — `SA/StrainScorer.swift` | Edwards zone TRIMP on %HRmax, log-mapped to 0–100; Banister option | **solid.** The log map compresses hard days, so every model fed with Effort under-weights them (see load). |
| Load — `ReadinessEngine` ACWR/monotony, `SA/TrainingLoadEngine.swift` CTL/ATL/TSB | Both on log-compressed Effort. ACWR skips missing days and includes today's partial value. CTL/ATL is shown only on Trends. | **thin.** `StrainCombine.strainToTRIMP` exists and could linearise the input. |
| `SA/HRVReadiness.swift` | Plews/Altini 7-night ln RMSSD vs a ±0.5 SD band → primed / normal / suppressed | **solid engine, unused**: behind an off-by-default Test Centre flag. |
| `SA/RecoveryForecast.swift` | Tomorrow's Charge heuristic | **thin**: always `.building` in the app (`needNights` never passed). |
| Effort target band — `CoupledView.optimalStrainRange` | Population lookup: green 14–18, yellow 10–14, red 4–10 on 0–21 | **thin**: not personal. For a beginner who never exceeds 10, "green = 14–18" is a push toward a spike. |
| HR zones — `SA/HRZones.swift` | Karvonen zones; learned HRmax | **solid per session.** No weekly strap-derived zone minutes (detected bouts compute `zoneTimePct` and discard it). |
| VO₂max — `SA/VO2MaxEstimator.swift`, `FitnessAgeEngine.swift` | ACSM run/walk, Nes/HUNT, Uth fallback; blended | **thin**: SEE ≈ 5–6 ml/kg/min. Two writers use different day keys and methods under one key (`vo2max_est`). |
| Strength — `Packages/StrandImport/.../StrengthProgression.swift` | Per-exercise Epley e1RM, stall detection, double-progression suggestion | **solid** (39 tests). Import-only freshness. |
| Level — `SA/LevelEngine.swift` + `Strand/Screens/LevelWiring.swift` | Sleep 0.30, Muscle 0.24, Heart 0.23, Lungs 0.12, Focus 0.11 against own baselines; coverage floor 0.40; frozen ledger | **solid honesty plumbing; flawed incentives**: chronic load is "higher is better" with no cap (≈ 9.6 % of the level); HRV counted twice (sleep part and heart part, ≈ 19 %); restorative (deep+REM minutes) is 18 % of the level and rests on staging. |
| Quests and gears — `SA/QuestDifficulty.swift` | Steady/Push/Relentless multipliers on own medians | **thin on safety**: not gated by Charge or HRV except for the strain band. Relentless asks 1.30× training and 1.35× steps on a red day. `bedtimeEarlierMin` 20/40 varies bedtime by the gear chosen that morning. |
| Stress — `SA/DaytimeStress.swift`, `Strand/Data/LiveStressMonitor.swift` | HR-only day-relative index (daytime RMSSD scoring is off); live monitor every 5 min in the foreground | **thin validity.** HR also rises with standing, caffeine and heat. "At rest" is asserted even when gravity has not synced. |
| Illness — `SA/IllnessSignalEngine.swift` + `AppModel.applyIllnessSignal` | ≥2 of RHR↑/skin↑/HRV↓/resp↑ beyond z 2, confounder dampening | **solid engine, buggy caller**: skin z = `recentSkin / 0.3` with no filter for absolute imported °C (~33 °C ⇒ z ≈ 110). Confounders from substring matching ("ill" matches "pill"); stress and sauna never set. |
| Breathing — `SA/ResonanceEngine.swift`, `BreathPacer`, `Strand/Screens/BreathingView.swift` | Resonance sweep on live R-R (solid); session outcome from an uncleaned 30-beat RMSSD vs whatever value existed at start; "+X % vs start · peak Y ms"; stored only as a string | **engine solid, outcome unsound.** |
| Circadian — `SA/CircadianEngine.swift` | HR cosinor, anchored on one night's wake | **thin** (partly circular: sleep masks HR). `planShift` has no production caller. |
| Habit correlations — `BehaviorInsights`, `EffectRanker`, `CorrelationEngine`, `DoseResponseEngine`, Personal Experiment | See §S1-A.1 for the full audit. | **flawed to unsound.** |
| Coach — `Strand/AI/*` | Rich, dated context; token budget being added by another agent | **solid dating discipline**, but the level context opens with "YOUR PRIMARY OBJECTIVE IS TO RAISE THIS SCORE", which combines badly with the level's load reward. `CoachSuggestions.highStrain = 14` is compared with the 0–100 axis, so its "done enough?" chip fires almost daily. |
| Unwired but built | `PreSleepHeartRateFeedback`, `SleepHeartRateContrast`, `PrimarySessionRestingHR` (shadow), `CircadianEngine.planShift`, `AdaptiveExpenditureEngine`, `ReadinessEngine.evaluateWithTrainingLoad`, `HevyAPI` | **unused.** Only `HRVReadiness` and a linear-load `TrainingLoadEngine` are pulled into 2.0 (S3). The rest stay unwired; they do not change behaviour. |

### 1.3 Honesty infrastructure that 2.0 reuses

- `ScoreConfidence` tiers (`calibrating / building / solid`), persisted per day as `charge_/effort_/rest_confidence`
  ordinals, currently **read by nothing**. S3 reads them.
- `LevelMissingInput`, `QuestPlanOutcome.notMeasured`, `StrengthProgression.Abstention`: the patterns for
  "not measured" to copy.
- There is no shared absent-value helper (≈ 270 literal dashes). New screens use one helper introduced in
  S1 (`HealthAbsence` in `SA/`, see §S1-A.5) so the reason text is consistent. Existing screens are not
  migrated in 2.0.

---

## 2. Candidate evaluation

Each candidate: the behaviour it changes; the evidence and its honest size; the data it needs and whether
that data is good enough here; what the wearer sees; what could go wrong.

### 2.1 Weekly plan periodised from Charge and chronic/acute load, with deloads

- **Behaviour:** trains in a sustainable pattern over weeks instead of reacting to one morning's number.
- **Evidence:**
  - Activity volume has the strongest dose-response of anything here (WHO 2020 guideline: 150–300 min moderate
    or 75–150 min vigorous per week plus ≥ 2 muscle-strengthening days).
  - Periodised programmes beat non-periodised ones for 1RM strength with a moderate effect (Williams 2017
    meta-analysis), but not clearly for hypertrophy.
  - **Deload weeks as a rule have little direct evidence.** A 2024 trial of a one-week deload in trained lifters
    found no benefit for strength or hypertrophy (Coleman 2024). They remain a reasonable coaching convention
    against accumulated fatigue.
  - The acute:chronic "sweet spot 0.8–1.3" is contested (mathematical coupling, poor prediction; Impellizzeri
    2020, Lolli 2019) and must not be presented as injury prediction.
  - A week-over-week spike above ~30 % in running distance was associated with more injuries in novice runners
    (Nielsen 2014). The "10 % rule" itself was not protective in a trial (Buist 2008).
- **Data:** session HR (solid), lift sets (solid but import-lagged), Effort (solid but log-compressed; use
  linear TRIMP via `strainToTRIMP`), Charge (solid), HRV tier (solid engine).
- **Wearer sees:** a week card: the aerobic minutes target and progress, strength sessions, a step target
  when steps are reliable, a note of whether this is a build, hold or easy week, and why.
- **Risks:** over-prescription for a beginner (mitigated by baseline-relative ramps and a cap at the top of the
  WHO range); false authority from load models (mitigated by stating targets as health ranges, not
  performance promises); import lag for lifting (the card says "last import …").
- **Verdict: build (S3)**, with easy weeks *triggered by data*, not calendar-fixed, and no ACWR language.

### 2.2 Sleep regularity coaching (wake anchor, wind-down, light, room temperature)

- **Behaviour:** gets up at a consistent time, gives themselves a sleep opportunity that matches their need,
  starts winding down at a fixed offset.
- **Evidence:**
  - Sleep regularity (SRI) was a stronger predictor of all-cause mortality than duration in ~60 k UK Biobank
    accelerometer wearers (Windred 2024). This is observational; causal trials of regularity alone are lacking.
  - A fixed wake time is a core element of CBT-I, the first-line insomnia treatment (ACP guideline, Qaseem 2016).
  - Sleep extension in habitual short sleepers improves outcomes in randomised trials: e.g. ≈ 270 kcal/day
    lower intake in overweight adults (Tasali 2022), and performance in athletes (Mah 2011).
  - Evening light suppresses melatonin even at room levels (Gooley 2011). Light-emitting screens before bed
    delayed circadian timing (Chang 2015).
  - Bedroom temperature matters, but the optimum is individual (Okamoto-Mizuno 2012 review; 20–25 °C was
    best for sleep efficiency in older adults, Baniassadi 2023), which makes it a good trial candidate rather
    than a universal rule.
- **Data:** onset and wake times (solid on both families; timing is far more reliable than staging), engine
  sleep need (thin but usable as a planning number), debt (solid), Govee (solid sensor), WiZ (works).
- **Wearer sees:** a "Tonight" card: bedtime target, wind-down time, lights and room status, caffeine cutoff;
  a weekly regularity line ("your wake time varied by ±42 min").
- **Risks:** orthosomnia (Baron 2017), where chasing sleep numbers raises anxiety. Mitigation: timing targets,
  not stage targets; no score shaming. Shift workers: abstain when timing is too irregular to anchor.
  Indoor bulbs are dim compared with daylight, so the copy must not overclaim morning-light effects of bulbs.
- **Verdict: build (S2).**

### 2.3 HRV-guided training decisions

- **Behaviour:** moves hard sessions away from days when the 7-day HRV trend is suppressed.
- **Evidence:**
  - Individual RCTs found HRV-guided endurance training equal or better than predefined plans, often with fewer
    hard sessions (Kiviniemi 2007; Vesterinen 2016; Javaloyes 2019).
  - Meta-analyses find small or unclear advantages for VO₂max and performance, possibly more for submaximal
    markers (Granero-Gallegos 2020; Düking 2021). Samples are small and mostly endurance-trained.
  - Rolling 7-day ln RMSSD is the recommended signal, not single nights (Plews 2013).
- **Data:** `HRVReadiness` already implements exactly this and returns nil below 14 valid nights. On 4.0,
  nightly HRV inherits staging error, but a 7-day log mean is robust to single-night noise.
- **Wearer sees:** "Your 7-day HRV is below your normal band — today's hard session moves to Thursday."
- **Risks:** nocebo from a "bad" morning (mitigated by using the 7-day tier, not a single night, and by
  moving sessions rather than cancelling them); over-trust on thin nights (tier abstains).
- **Verdict: build inside S3** as the day-level modulator. Promote `HRVReadiness` from the Test Centre flag to
  a decision input (not a displayed score).

### 2.4 Resonant-breathing biofeedback with an honest before/after

- **Behaviour:** does short slow-breathing sessions, especially in the evening or when stressed.
- **Evidence:**
  - HRV biofeedback reduced self-reported stress and anxiety in a meta-analysis (Goessl 2017; large pooled effect,
    with study-quality caveats). A broader meta-analysis found small-to-moderate effects across outcomes
    (Lehrer 2020).
  - Slow breathing raises vagally mediated HRV during and shortly after sessions (Laborde 2022), with no
    clear advantage of an individually found resonance pace over ~6/min.
  - The in-session RMSSD rise is largely the breathing pattern itself (RSA amplitude), so it is not a training effect.
- **Data:** live R-R on both families (optical on 5/MG, variable coverage). `HRVAnalyzer` cleaning exists.
- **Wearer sees:** pre and post quiet-sitting readings, each with its own minimum-beat gate; during-session
  RSA shown separately and labelled as expected to be higher.
- **Risks:** the current "+18 % vs start · peak 64 ms" invites belief in an effect that is mostly mechanical.
- **Verdict: build (S4)**, small.

### 2.5 Zone-2 volume toward a weekly target, and VO₂max trend feedback

- **Evidence:**
  - Cardiorespiratory fitness is one of the strongest mortality predictors (each 1 MET ≈ 13 % lower all-cause
    mortality, Kodama 2009; Mandsager 2018).
  - Both continuous moderate training and HIIT raise VO₂max; HIIT slightly more per minute (Milanović 2015).
  - "Zone 2" as a distinct target has weak specific evidence; what matters for health is total
    moderate-to-vigorous volume.
- **Data:** per-session HR zones (solid); VO₂max estimate (thin: SEE ≈ 5 ml/kg/min, mixed methods under one key).
- **Verdict:**
  - Fold into S3 as **aerobic minutes** by ACSM intensity (%HRR), counting vigorous double as WHO does.
  - Show VO₂max only as a monthly median with its error band. Never set VO₂max as a target, because random
    error would read as success or failure.

### 2.6 Strength: progressive overload from per-set data, tied into the week

- **Evidence:**
  - Muscle-strengthening activity is associated with 10–20 % lower all-cause mortality at 30–60 min/week
    (Momma 2022 meta-analysis, J-shaped).
  - Hypertrophy shows a dose-response with weekly sets (Schoenfeld 2017).
  - Progressive overload is the core principle (ACSM 2009 position stand).
- **Data:** `StrengthProgression` is solid. Freshness depends on re-imports.
- **Verdict: build inside S3**: ≥ 2 sessions/week target, the existing suggestions, "hold" during easy weeks.

### 2.7 Step dose-response targets from the wearer's baseline

- **Evidence:**
  - All-cause mortality falls with daily steps and plateaus at ~6–8 k/day for ≥ 60 y and ~8–10 k/day for < 60 y
    (Paluch 2022, 15 cohorts).
  - The largest gains are at the low end (Saint-Maurice 2020; Ding 2025 meta-analysis). All of this is observational.
- **Data:** reliable only for 4.0 with phone calibration, 5/MG after calibration, or phone steps. Otherwise
  thin to wrong.
- **Verdict: build inside S3**, strictly gated on step reliability; +1000/day increments from the wearer's
  median toward the age-appropriate plateau, then hold.

### 2.8 Illness/overreach early warning from respiration, skin temperature and RHR

- **Evidence:**
  - Retrospective studies show RHR, respiration and skin-temperature deviations before symptoms (Mishra 2020;
    Miller 2020 on WHOOP respiration; Smarr 2020).
  - Prospective real-time alerting flagged most infections but with many alerts unrelated to illness (Alavi 2022).
  - The only useful action is "rest", which the plan already does via the HRV tier.
- **Verdict: do not expand.** Keep opt-in and fix the bugs (S0 H7). The overreach part is covered by S3's
  7-day tier rule.

### 2.9 A weekly review that closes the loop

- **Evidence:** self-monitoring combined with goal review is one of the more consistent active ingredients in
  physical-activity behaviour-change interventions (Michie 2009 meta-regression), stronger than monitoring alone.
- **Screen or coach?** Both, on one pure struct. The **screen** shows deterministic content: plan vs done,
  one suggested change, trial status. The **coach** narrates the same struct on demand within its budget, so it
  never invents figures and works without an API key.
- **Verdict: build inside S3.** The existing `WeeklyDigest` stays as its descriptive input.

### 2.10 Harm removal

The evidence for nocebo from sleep feedback is direct: people given falsely bad sleep feedback reported worse
daytime function (Gavriloff 2018), and tracker-driven sleep anxiety is a recognised clinical presentation
(Baron 2017).

**Verdict: build first (S0).** It covers:
- full-screen arousal-raising alarms: they stay by coordinator decision, so S0 fixes their claims and triggers;
- punitive failure cards: they stay red by coordinator decision, so S0 constrains what they may charge;
- directive pushes with no off switch;
- false precision ("2.3 of 3");
- a population prior labelled as the wearer's own data;
- an incentive (the level plus a coach told to maximise it) that rewards more load without limit.

### 2.11 Owner's addition: central habit analysis and N-of-1 trials

- **Evidence for the method:**
  - Randomised N-of-1 designs with pre-registered outcomes are the recognised way to estimate an individual
    treatment effect (AHRQ N-of-1 user's guide, Kravitz & Duan 2014; CENT reporting guideline, Vohra 2015).
  - Randomisation tests give exact inference for exactly the assignment used, whatever the autocorrelation
    (Edgington & Onghena).
- **Evidence for the candidate habits:**
  - Caffeine 6 h before bed measurably reduced sleep (Drake 2013).
  - Alcohol dose-dependently lowers nocturnal HRV (Pietilä 2018).
  - Evening light and screens delay circadian timing (Chang 2015).
  - Bedroom temperature affects sleep with an individual optimum (see 2.2).
- **Data:** journal bools (solid), auto-derived behaviours (sleep timing, workouts, caffeine and climate once
  retained per night), outcomes on HRV/RHR/onset/duration (solid to thin by family).
- **Risks:**
  - Underpowered trials: most 4-week trials can only detect large effects, and the plan says so before Start.
  - Adherence bias: handled by intention-to-treat.
  - Expectation effects: unblindable; physiological outcomes only.
- **Verdict: build (S1), top priority by owner.**

---

## 3. Specs

Conventions for every spec:
- **Pure logic** lives in `Packages/StrandAnalytics/Sources/StrandAnalytics/` (`SA/`), is DB-free and
  deterministic, takes `yyyy-MM-dd` strings and plain numbers, and is tested in
  `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/` (`SAT/`).
- **App wiring** lives in new `Strand/Data/*Source.swift` / `*Store.swift` files.
- **Screens** are new files; the design packages decide placement and styling (design tokens only).
- **Hooks** into existing files are listed exactly, and kept to a few lines each.
- **Regenerate the project** with `xcodegen generate` after adding files; never commit `Strand.xcodeproj/`.
- **Abstention** is always nil plus a typed reason, rendered as "—" plus one line of reason.

---

### S0. Harm-removal pack

Each item below gives the harm, the change, the files and the acceptance check. Items are independent, and
each is its own PR ("one concern per PR"). The changes are grouped by what they protect.

#### Alarms and punitive screens

**H1. Full-screen red "STRESS ALERT"**
- **Harm:**
  - A summon haptic, no setting to turn it off, and "x.x of 3, at rest".
  - The reading is heart-rate only, and it claims "at rest" even when the motion data for that window has not synced yet.
  - Alarming someone about stress raises arousal.
- **Change (per coordinator decision 1 the screen stays on; only its honesty is fixed):**
  - (a) `LiveStressMonitor` abstains when the 10-minute window has less than 50 % gravity coverage: level nil, reason `noMotionEvidence`. Today it scores such a window as if the wearer were still. No reading means no screen, so the "at rest" claim is only ever made when it was observed.
  - (b) Subtitle in words (low / moderate / high) plus "heart-rate based", not "2.3 of 3".
  - (c) At most 2 presentations per day, on top of the existing 60-minute cooldown.
  - (d) Health note for the owner: the evidence favours a quiet cue over a full-screen alarm. A user-facing "quieter stress cue" setting would honour both, if the owner wants it later.
- **Files:**
  - `Strand/Data/LiveStressMonitor.swift`: the gate and the daily cap.
  - The subtitle string at `StrandiOS/App/RootTabView.swift` about L455. The shell is design-owned; this is a 1-line hook.
- **Accept when:** a window without motion data never raises the screen, and `StrandTests/LiveStressMonitorTests` covers both the coverage gate and the daily cap.

**H2. "Optimum reached" full-screen alarm (`DayAlerts`)**
- **Harm:** it tells the wearer "anything more now is paid for tomorrow", based on a population band (`optimalStrainRange`) that is not personal.
- **Change (per coordinator decision 1 the screen stays; its claim is corrected):**
  - (a) Replace the message with: "Today's effort has reached the top of the range suggested for this morning's Charge. More is your call — keep it easy if you want tomorrow fresh." This drops the "paid for tomorrow" certainty.
  - (b) Once S3 lands, raise the notice from the week plan: when `DayGuidance` is `easy` / `moveHard` and today's load already exceeds the plan's easy-day share. The population band is then no longer used as the trigger.
  - (c) Do not raise the notice while an illness heads-up is up. On those days the day is already `rest`, and the heads-up banner carries the message.
- **Files:**
  - `Strand/Data/DayAlerts.swift`: copy and trigger input.
  - `Strand/Liquid/LiquidTodayView.swift`: the `checkOptimum` call (design package; the trigger moves to the week plan in S3).
- **Accept when:** the notice copy contains no claim of certain cost, and after S3 the trigger reads `DayGuidance`, not `optimalStrainRange`.

**H3. "DIRECTIVE FAILED" red card (`QuestFailedPopupView`)**
- **Harm:** a struck-through target, a 00:00:00 countdown and a tick per letter. Punitive framing drives disengagement and self-blame.
- **Change (per coordinator decision 2 the card stays red, one per day, with exact numbers):**
  - (a) One card per day. This is already the direction of the penalty work in `QuestStore`.
  - (b) Each missed line shows the reading behind it.
  - (c) Physiology quests (sleep hours) and unmeasured quests appear as "reported, no cost", never as failures. This matches `QuestMetric.penaltyClass` in `SA/QuestPenalty.swift`.
  - (d) No per-letter ticks and no countdown. The consequence is carried by the numbers, not by alarm effects.
  - (e) Health note for the owner: shame-framed feedback tends to reduce engagement over time. The escalation rule (see *Rules for the penalty system* below) matters more than the colour.
- **Files:** `Strand/Screens/QuestPopupView.swift` (design package) and the penalty agent's `Strand/Data/QuestPenaltyAssessor.swift`.
- **Accept when:** at most one failure card is shown per day, and a physiology or unmeasured quest never appears as a cost.

**H4. Three ritual pushes a day, on by default (`DayRitualScheduler`)**
- **Harm:**
  - Slots at 06:40, 13:30 and 19:00, at fixed clock times.
  - `setEnabled` has **no UI caller**, so there is no way to turn them off in the app.
  - Directive tone ("One correction still fits").
- **Change:** default to **one** morning slot, timed at the S2 wake anchor + 15 min. Midday and evening are off by default. Add a Settings toggle per slot.
- **Files:** `Strand/System/DayRitualScheduler.swift`; Settings (design package).
- **Accept when:** a fresh install schedules at most one ritual push, and each slot can be switched off in the UI.

#### Incentives that push volume

**H5. Coach objective "YOUR PRIMARY OBJECTIVE IS TO RAISE THIS SCORE" (`CoachLevelContext.promptSection`)**
- **Harm:** combined with the level's uncapped load reward (H6) and the gears (H9), it gives the model an incentive to push training volume.
- **Change:** reword to: "The level is one lens on long-term trends. Your objective is the wearer's health. Never advise more training load, less sleep or skipping recovery to raise the level."
- **Files:** `Strand/AI/CoachLevelContext.swift`. This file is **owned by the token-budget agent this cycle: hand over the text rather than editing it at the same time.**
- **Accept when:** the prompt test in `StrandTests` asserts the new sentence and the absence of "PRIMARY OBJECTIVE IS TO RAISE".

**H6. The level rewards chronic load without limit, counts HRV twice, and leans on stage minutes**
- **Change:**
  - (a) Cap the `trainingLoad` term at the wearer's own "best" (`scored(...)` ≤ 100 for that term). Load above their 95th percentile earns nothing more.
  - (b) Remove `hrv` from the Sleep part and keep it in Heart. The Sleep shares become:
    - duration-vs-need 0.50 (a new input: the last-7-night mean of `asleep / engineNeed`, capped at 1.0);
    - regularity 0.30, taken from S2's `SleepRegularity.wakeSdMin`;
    - restorative 0.20.
  - (c) Bump the ledger epoch (`LevelLedger.currentEpoch` 3 → 4) so the old and new formulas never mix.
- **Files:**
  - `SA/LevelEngine.swift`.
  - `SA/LevelBaselines.swift`: new `sleepDurationRatio` metric, population prior 0.95 ± 0.08.
  - `Strand/Screens/LevelWiring.swift`: the new inputs.
  - `Strand/Screens/LevelLedger.swift`: the epoch.
  - **Coordinate with the level-audit agent.** This breaks Android parity; say so in the PR.
- **Accept when:** `SAT/LevelEngineTests` pins that load above best adds 0, that HRV appears in exactly one part, and that a short night lowers Sleep through duration even when staging is absent.

**H9. Gears ignore the body's state**
- **Harm:**
  - Relentless on a red day still asks for 1.30× training minutes and 1.35× steps.
  - `bedtimeEarlierMin` (20 or 40 min) moves bedtime according to that morning's gear choice, which **makes bedtimes less regular**.
- **Change:**
  - (a) `QuestDifficulty.targets` takes a `DayGuidance` (S3). When guidance is `.easy` or `.rest`:
    - training and strain directives use Steady's factors;
    - the training directive becomes "easy movement ≤ 30 min";
    - steps are unaffected, since walking is compatible with recovery.
  - (b) The bedtime directive uses S2's bedtime target for every gear. The gear only decides whether a bedtime directive is issued:
    - Steady: no.
    - Push: yes.
    - Relentless: yes, plus a wind-down directive.
- **Files:**
  - `SA/QuestDifficulty.swift`.
  - Caller `Strand/AI/QuestGenerator.swift` (`QuestBaselineReader`). **Coordinate with the Strand/AI agent**: this adds one argument.
- **Accept when:** `SAT/QuestDifficultyTests` shows that suppressed guidance gives no training factor above 1.0, and that the bedtime threshold equals the anchor for Push and Relentless.

#### Illness heads-up

**H7. Illness heads-up false positives**
- **Harm:**
  - Skin z is computed as `recentSkin / 0.3`. Imported values are absolute °C (about 33), which gives z ≈ 110.
  - The substring "ill" matches "pill".
  - Users on the `alreadyUnwell` path get a "rest up" push.
  - The stress, sauna and workout confounders are never set.
- **Change:**
  - (a) Drop values where `VitalBands.isAbsoluteSkinTemp(v)` from both skin paths (`AppModel.swift` about L2332 and about L2510). A night without a deviation counts as absent.
  - (b) Match confounders on exact starter-question identity (the `JournalCatalog` canonical strings), not substrings. Set `hardOrLateWorkout` from the `workout` table: a session with Effort in the top quartile, or one ending less than 3 h before sleep onset.
  - (c) No push notification on the `alreadyUnwell` path. The banner may still show.
- **Files:** `Strand/App/AppModel.swift` (`applyIllnessSignal`, `evaluateIllness`); `Strand/System/IllnessNotifier.swift`.
- **Accept when:** a new `StrandTests/IllnessSkinTempFilterTests` shows that absolute °C never produces a skin signal. The engine tests stay unchanged.

**H8. Illness copy "Early warning"**
- **Harm:** the title implies a prediction.
- **Change:** title the alert "Body off baseline". Keep "not a diagnosis" in the body, and show which signals fired and which confounders were present.
- **Files:** `Strand/System/IllnessNotifier.swift`; `Strand/Screens/HealthAlertBanner.swift` (layout is the design package's).
- **Accept when:** a copy test passes.

#### Numbers that claim more than they know

**H10. Breathing outcome "+X % vs start · peak Y ms"**
- **Harm:**
  - RMSSD comes from 30 uncleaned beats.
  - The "start" value can be just 2 beats.
  - The peak is cherry-picked.
  - The result is stored only as a string.
- **Change:** replaced by S4. Until S4 lands, show "—" instead of the percentage.
- **Files:** `Strand/Screens/BreathingView.swift` `captureOutcome` (design package; a one-line interim change).
- **Accept when:** no percentage or peak is shown.

**H11. The dose-response card says "your data" and "solid" while showing 100 % population prior**
- **Harm:**
  - Nothing ever writes the dose rows it reads (`dose_alcohol` / `dose_caffeine`), so every dose is 1 and the personal slope is never fitted.
  - Its "damage forecast" adds a number derived from the prior to the wearer's Charge.
- **Change:** hide the dose-response cards and the damage forecast in `InsightsHubView` until a dose writer exists (not in 2.0). The habit model (S1-A) replaces them.
- **Files:** `Strand/Screens/InsightsHubView.swift` (design package; remove the section).
- **Accept when:** no UI shows `DoseResponseEngine` output.

**H12. `EffectRanker` keeps the lag with the biggest effect, and labels lags wrongly**
- **Harm:**
  - Picking the largest of 3 uncorrected lags inflates the reported effect by chance.
  - Days are keyed to the wake day, so lag 0 already means "the next morning", but the labels treat it as the same day.
  - Its top 3 are what the coach sees.
- **Change:** the coach's `onDeviceSignalsBlock` switches to the S1 habit summary, and the hub switches to `HabitAssociation`. `EffectRanker` stays in the code for parity but is no longer displayed.
- **Files:** `Strand/AI/AICoach.swift` (`onDeviceSignalsBlock`; **coordinate**); `Strand/Screens/InsightsHubView.swift` (design package).
- **Accept when:** no displayed figure comes from choosing the best of several lags.

**H13. Personal Experiment (`InsightsView.experimentSection`)**
- **Harm:**
  - Unlogged days count as the baseline.
  - It is a before/after design.
  - Its lag is the same day, so it pairs a behaviour with the morning before it.
  - There is no statistical test.
- **Change:** retire the section, and point its entry at Habit Trials (S1-B). Keep the AppStorage keys readable for one release so an experiment already in progress can still show its start date as history.
- **Files:** `Strand/Screens/InsightsView.swift` (design package).
- **Accept when:** no new Personal Experiment can be started.

**H14. Stale coach chip threshold**
- **Harm:** `CoachSuggestions.highStrain = 14` is compared against Effort on 0–100, so the "done enough?" chip fires almost every day.
- **Change:** compare on the 0–21 axis via `StrainCalibration`, or use 67 on 0–100 (the green-band floor mapped to 0–100).
- **Files:** `SA/CoachSuggestions.swift`.
- **Accept when:** a test shows an Effort of 40/100 does not trigger the chip.

**H15. False precision on imprecise numbers**
- **Harm:**
  - VO₂max is shown to one decimal with no band.
  - Fitness Age's "±5" is sometimes dropped.
  - Stage minutes on sparse WHOOP 4.0 nights are shown to the minute.
- **Change:**
  - Show VO₂max as a rounded integer with a "±5" band and its method.
  - Show stage minutes on `stagingSparse` nights as an approximate figure, e.g. "~1 h 10 m".
- **Files:** display helpers in `Strand/Screens/HostedCards.swift` and `VitalSignsSummary.swift` (design package).
- **Accept when:** unit tests on the formatter functions pass (no snapshots needed).

#### Rules for the penalty system

Another agent is building penalties in the working tree: `SA/QuestPenalty.swift`,
`Strand/Data/QuestPenaltyStore.swift` and `QuestPenaltyAssessor.swift`. These are the health constraints on
it, checked against that code on 2026-09-29:

1. **No penalty on outcomes the wearer cannot choose directly** (sleep hours, HRV, RHR, Charge, stress level).
   Penalise behaviour, never physiology.
   *Status: met.* `QuestMetric.penaltyClass` makes `.sleepHours` physiology, and strain is charged only for
   "no training at all".
2. **No penalty for training shortfall** on a day whose `DayGuidance` is `.easy` or `.rest`, or while an
   illness heads-up is raised.
   *Status: partly met.* Make-up training quests are already withheld when Charge is low or unknown. The miss
   itself is still charged.
   *Change:* `QuestPenaltyRules` should take the day's `DayGuidance` (S3). Missed `workoutMinutes`/`strain`
   quests on `easy`/`rest` days are reported, not charged. Until S3 lands, use `charge < QuestTriggers.chargeLow`
   as the stand-in.
3. **No penalty on trial quests**, in either arm, for any answer or no answer (see S1-B §B.7).
   *Status: met.* `QuestPenaltyRules.trialIdPrefix = "trial-"`, and `isPenalisable` returns false for it.
   S1-B uses exactly that prefix.
4. **Keep repeated misses from compounding.**
   *Status: conflict.* The current `escalationStep = 0.5` / `escalationCap = 2.0` doubles the cost of the same
   metric missed repeatedly within 7 days. `DESIGN_V2.md` §5.14 already specifies "at most one day's cost
   per miss" on the card.
   *Recommendation (health):* set `escalationStep = 0`, so one miss costs one day's reward at most. Escalating
   costs after a run of misses is the pattern most associated with all-or-nothing abandonment. The make-up
   quest already carries the "you owe this" signal.
   Because the owner asked for real penalties, this is a recommendation for the coordinator to decide, not a
   blocker.

---

### S1. Central habit model and N-of-1 habit trials

**Owner priority.** Two linked parts:
- **A. One habit model.** It unifies every behaviour the app records and every place that relates behaviour to
  outcomes, and it feeds the coach a compact, dated summary.
- **B. Randomised personal trials** of one harmless habit at a time, issued as quests.

A proposes, B tests. Only B can ever say a habit *helped*.

#### S1-A. Central habit analysis

##### A.1 What exists today (audit)

**Where behaviour is recorded:**

| Record | Store | Absent ≠ "no"? | Reaches any statistic today? |
|---|---|---|---|
| Journal yes/no items (10 starters: alcohol, late caffeine, screen in bed, eating close to bedtime, stressed, sauna, shared bed, sick/ill, magnesium, reading before bed; plus custom items) | `journal` table (WhoopStore v8), `JournalCatalog` `journal.catalog.v2`; identity = question text | **Yes**: a "no" tap writes `answeredYes = 0`; absent = no row | Yes: `BehaviorInsights`, `EffectRanker`, coach |
| Journal numeric items | same table, `numericValue`, always `answeredYes = true` | **No** "no" state; 0 is written as "yes" | **No**: `numericJournalByKey` is never read |
| Dream journal (7 answers incl. `Screen before bed`, `Last meal before bed`) | `dreamJournal.entries.v1`, mirrored as numeric journal rows | No "no" state | **No** (never has a control group) |
| Caffeine intakes | `caffeine.intakes`, **48 h retention** | n/a | **No history exists** |
| Alcohol dose | `noop-journal-dose` / `dose_alcohol` | n/a | **Nothing writes it** |
| Meditation minutes | metricSeries `meditation_min` | **No**: absent reads as 0 | Level Focus, quests |
| Hydration | metricSeries `hydration` (+ entries) | **No**: absent reads as 0; enable date not stored | quests, coach |
| Mood (1–5) | metricSeries `noop-mood` | absent = not checked in | `MindSection` Pearson only |
| Bed/wake times | derived: `Repository.sleepTimingsByDay` | derived | Level regularity, Streaks |
| Workouts and their timing | `workout` table (`startTs`, `endTs`, `avgHr`, `strain`) | derived | Effort; timing used nowhere |
| Steps | `DailyMetric.steps` (nil = unmeasured) | yes | Level penalty, quests |
| Room climate | `climate.history.v1`, 14 days, not keyed to nights | n/a | coach "last night min–max" only |
| WiZ use | settings plus last-ran day strings only | n/a | coach sees state only |
| Quest completions | `system.quests`, max 40, "declined" conflates declined, expired and ignored | no | coach only |

**Where behaviour is related to outcomes, with the statistical verdict:**
- **`BehaviorInsights`** (the "Behaviour Effects" feed). Flawed:
  - Welch t with a *normal* tail at n = 5 per group;
  - days treated as independent although HRV and recovery are autocorrelated;
  - no multiplicity control across ~10–25 behaviours × 4 outcomes;
  - no confounder adjustment; no confidence interval.
- **`EffectRanker`** (the "What Moves You" hub and the coach's top 3). Flawed:
  - picks the lag with the largest |d| out of {0, 1, 2} (winner's curse, uncorrected);
  - lag labels are off by one under wake-day keying.
- **`CorrelationEngine` callers** (`InsightsView` relationships, `MindSection`, `MetricExplorerView`, `CompareView`). Flawed:
  - Pearson on trending, autocorrelated series, with a normal-tail p;
  - catalog-wide screening with no correction;
  - some pairs are circular: Charge is computed from HRV.
- **`DoseResponseEngine`**. Unsound as shipped: see S0 H11.
- **`ActivityCostEngine`**. Descriptive only, with a strongly selected baseline.
- **`LabBookProjection`**. Pearson at n = 4.
- **Personal Experiment**. Pre/post, unlogged days counted as baseline, same-day mis-lag: see S0 H13.

The model below replaces the display role of all of these (they stay in the package for Android parity).

##### A.2 One model

All in `SA/HabitModel.swift`.

```swift
public struct HabitId: Hashable, Codable, Sendable { public let raw: String }
// "journal:<canonical>", "dream:screen", "dream:meal", "auto:lateWorkout", "auto:lateCaffeine",
// "auto:warmBedroom", "auto:breathingSession", "auto:lightsDimmed", "auto:bedtimeOnTarget"

public enum HabitKind: String, Codable, Sendable { case behaviour, context, supplement }
// context   = a state, not a choice (stressed, sick, shared bed): reported, never tested, never trialled.
// supplement = recorded (magnesium) and shown descriptively, never tested, never proposed as a trial.

public struct HabitDefinition: Sendable {
    public let id: HabitId
    public let label: String
    public let kind: HabitKind
    public let primaryOutcome: HabitOutcome          // fixed per habit, never searched
    public let secondaryOutcomes: [HabitOutcome]     // ≤ 2, always "exploratory"
    public let direction: EffectDirection            // which way "better" is for the primary
    public let trialId: String?                      // the HabitTrialCatalog entry that tests it, if any
}

public enum ObservationState: String, Codable, Sendable { case yes, no }   // absent = no observation at all

public struct HabitObservation: Equatable, Codable, Sendable {
    public let nightKey: String      // wake-day key of the night this behaviour precedes
    public let habit: HabitId
    public let state: ObservationState
    public let source: HabitSource   // .journal, .dream, .caffeineLog, .workouts, .climate, .breathLog, .wiz, .sleepTiming
    public let recalled: Bool        // true when reported the next morning (dream answers)
}

public enum HabitOutcome: String, Codable, CaseIterable, Sendable {
    case nightHrvLn, nightRhr, totalSleepMin, onsetClockMin, sleepEfficiency   // may be primary
    case nextMorningCharge, dayStressMean, feltRested                          // secondary / exploratory only
}
```

**The one keying rule: everything is keyed to the night.**
- Every observation is normalised to `nightKey`, the wake-day key of the night the behaviour precedes.
- Outcomes use the same key:
  - `night*`, `totalSleepMin`, `onsetClockMin` and `sleepEfficiency` belong to the night ending on that wake day;
  - `nextMorningCharge` is that morning's Charge;
  - `dayStressMean` is the daytime after that night.
- There is **no lag search**: the timing of each habit fixes its pairing.

How each source maps to a night:
- **Journal rows.** The existing convention says an answer describes "the night and day leading into this
  morning", so the row's day key *is* the `nightKey`.
  - The journal table has no write timestamp, so a wearer who logs tonight's drinks under "Today" attaches
    them to the wrong night. The Habits hub (A.7) logs evening behaviours with an explicit "tonight" key to
    remove the ambiguity for new entries. Old rows keep the convention.
- **Dream answers** are keyed by wake day, which is already the night key. `recalled = true`.
- **Caffeine, workouts, breath sessions, WiZ** carry absolute timestamps. Anything on local calendar day D
  before that night's onset maps to the night keyed D+1 (or to the night whose onset follows it, when a
  sleep session exists).
- **Climate** is measured over the first 90 min after onset of the night itself.

**Absence is never "no".** Each source gets explicit rules:
- Journal bool: yes/no only from a row. A numeric item gives yes when the value > 0 and **no when the value is
  exactly 0 and was entered** (the stepper writes the row).
- Dream `screen`: options 1–2 (screen within 30 min of sleep) ⇒ yes; 3–4 ⇒ no; unanswered ⇒ absent.
  Dream `meal`: options 1–2 (meal within 2 h) ⇒ yes; 3–4 ⇒ no. **Cut points are fixed here, never chosen from data.**
- `auto:lateCaffeine`: observed only on local days with ≥ 1 logged intake. Yes if the last intake is after 14:00.
  A day with no intake logged is **absent**: the app cannot tell "no coffee" from "didn't log".
- `auto:lateWorkout`: observed on every night with a sleep onset and workout-table coverage. Yes if any session
  ends < 3 h before onset.
- `auto:warmBedroom`: observed when a Govee sensor covered ≥ 60 % of the 5-min slots in the first 90 min after
  onset. Yes if the mean is > 19.5 °C (the top of `ClimateAdvice`'s sleep band).
- `auto:breathingSession`: observed only while the wearer is "active": ≥ 1 session in the previous 14 days.
  Yes if a ≥ 5-min session ended between 17:00 and onset.
- `auto:lightsDimmed`: observed only on days the WiZ wind-down automation was enabled. Yes if it ran.
- `auto:bedtimeOnTarget`: observed when S2 has a bedtime target. Yes if onset is within ±30 min of it.
- **Outcome-like self-reports are outcomes, not habits:** `Felt rested`, `Night wakings (felt)`, `Dream tone`,
  `Dream recall`, `Wake-up`.

**Primary outcome per habit.** This fixed table lives in `HabitCatalog.definitions` in `SA/HabitModel.swift`.

| Habit | Primary outcome (better direction) | Secondaries (exploratory) |
|---|---|---|
| alcohol (journal) | nightHrvLn (up when absent) | nightRhr, totalSleepMin |
| late caffeine (journal / auto) | totalSleepMin (down when present) | onsetClockMin, nightHrvLn |
| screen in bed (journal) / dream:screen | onsetClockMin (later when present) | totalSleepMin |
| eating close to bedtime (journal) / dream:meal | nightRhr (up when present) | nightHrvLn |
| reading before bed | onsetClockMin | totalSleepMin |
| sauna | nightRhr | nightHrvLn |
| auto:lateWorkout | nightHrvLn | onsetClockMin |
| auto:warmBedroom | nightHrvLn | sleepEfficiency |
| auto:breathingSession | nightHrvLn | nightRhr |
| auto:lightsDimmed | onsetClockMin | totalSleepMin |
| auto:bedtimeOnTarget | totalSleepMin | nightHrvLn |
| custom journal items | wearer picks one primary when creating the item; default nightHrvLn | none |

##### A.3 Association analysis (observational; never "caused")

In `SA/HabitAssociation.swift`, recomputed at most once per day, after the morning analysis.

For each `behaviour`-kind habit and its **primary** outcome, over the last 90 nights:
1. **Rows:** nights where the habit is observed (yes or no), the outcome is present, and the previous day's
   Effort is present.
2. **Gate:** ≥ 8 yes **and** ≥ 8 no rows. Otherwise the result is `notEnoughData(yes:no:)`.
3. **Model:** `y = β0 + β·yes + γ1·effortPrevDay(0–21) + γ2·weekend + γ3·dayIndex`, fitted by OLS. HRV is analysed
   as ln RMSSD and reported as a percentage.
4. **Uncertainty:** Newey–West (HAC) standard error for β with a Bartlett kernel. The lag is counted in calendar
   days, `L = 3` (for n ≈ 90, `⌊4(n/100)^{2/9}⌋ = 3`); residual pairs further apart than L calendar days get
   weight 0. The 95 % interval uses Student-t with df = n − 5.
   - Why HAC rather than permutation: the data are not randomised, so there is no assignment to permute. HAC
     keeps the interval from being too narrow on autocorrelated nights.
5. **Multiplicity:** Benjamini–Hochberg at q = 0.10 across all primary tests in the run (typically 8–20).
   Secondary outcomes never enter BH and never receive a label; they show "exploratory".
6. **Label**, using the same MCID table as the trials (§B.2):

   | Label | Condition |
   |---|---|
   | `possibleLink` | BH-significant **and** \|β\| ≥ MCID |
   | `smallOrNone` | the whole interval lies within ±MCID |
   | `unclear` | everything else with enough data |
   | `notEnoughData` | the gate failed |

7. **Co-occurrence honesty:** for every pair of habits, the Jaccard overlap of their yes-nights. If > 0.6, both
   rows say "often happens together with X — this data can't separate them". This catches alcohol, late meals
   and weekend nights clustering together.
8. **Copy is always associational:** "On nights after X, your HRV was about 8 % lower (range 3–13 %, 11 vs 64
   nights). This is a pattern, not proof — a trial can test it."

What is adjusted and what is not: prior-day Effort, weekend and drift are adjusted. Sleep duration is not
(it is often a mediator). Other habits are not (they are reported via co-occurrence). This mirrors §B.5 so the
two parts speak the same language.

##### A.4 Proposing trials from the analysis

`HabitTrialCatalog.proposals(report:history:sensors:) -> [TrialProposal]` in `SA/HabitTrialCatalog.swift`.

**Eligible entries:**
- catalogue entries whose behaviour the wearer can do;
- `bedroom18` only if a Govee sensor is paired *and* a way to reach 18 °C is plausible, which the wearer confirms;
- `alcoholFree` only with ≥ 8 drinking evenings in the last 28;
- not trialled in the last 90 days.

**Ranking:**
1. The linked habit is `possibleLink`, or `unclear` with the estimate pointing the harmful way.
2. Lowest effort; the catalogue carries an `effort` rank of 1–3.
3. Untested habits with strong population evidence (caffeine cutoff, screens off, alcohol-free).

At most 2 proposals are shown. A proposal carries its reason ("your data suggests …" or "commonly effective;
untested for you").

##### A.5 Absence helper

`SA/HealthAbsence.swift` holds one enum of reasons with fixed short texts, used by every new 2.0 surface:
`notLogged`, `tooFewNights(n, need)`, `sensorNotPaired`, `stepsUncalibrated`, `stagingSparse`, `noMotionEvidence`,
`sealedUntil(day)`, `calibrating(days, need)`, `illnessFlagged`. Existing screens are not migrated in 2.0.

##### A.6 The coach receives a compact, dated block

`SA/HabitCoachSummary.swift`, with the signature
`render(report:trials:proposals:asOf:maxChars: = 900) -> String`.

- **Fixed layout, dated, priority-truncated** (whole lines dropped from the bottom, never cut mid-line).
- **Line priority:**
  1. running trial (always);
  2. finished trials in the last 90 days (≤ 2);
  3. `possibleLink` habits (≤ 3, largest |β|/MCID first);
  4. proposals (≤ 2).
- Example:
  ```
  HABITS (as of 2026-09-29; nights 2026-07-01..2026-09-28; associations, not causes)
  - alcohol evening: next-night HRV -8% [-13,-3] (11 yes / 64 no) possible link; often with late meal
  - screen <30 min before sleep: onset +21 min [+8,+34] (40/22) possible link
  TRIAL RUNNING screensOff60: day 12/28, adherence 83%, results sealed until 2026-10-18. Do not advise on evening screens.
  TRIAL DONE 2026-09-10 breathing10 -> night HRV: no meaningful effect (+1% [-4,+6]).
  CANDIDATE TRIALS: caffeineCutoff14 (untested), dinner3h (possible link on RHR)
  ```
- **Budget:** ≤ 900 characters (~225 tokens). It **replaces** the raw 7-day journal dump in
  `CoachExtraContext.block` (≈ 3–4 k characters, ~0.8–1 k tokens), and the `EffectRanker` lines in
  `AICoach.onDeviceSignalsBlock`. The net context gets *smaller*.
- **Integration** is one registration in the budgeted context assembly owned by the token-budget agent
  (`Strand/AI/CoachContextBudget.swift`). Hand the function over; do not edit `Strand/AI/**` concurrently.
- **Coach rules added with the block** (one sentence each, in the same string):
  - never describe a `possibleLink` as a cause;
  - never give advice on a running trial's behaviour;
  - report trial verdicts verbatim.

##### A.7 What the wearer sees: the Habits hub (new screen)

Four sections, top to bottom:
1. **Today's trial.** The assignment card (B.7) when a trial runs; otherwise one line: "No trial running —
   try one".
2. **What your data suggests.** One row per habit:
   - label, the estimate with its interval as a bar with the MCID band shaded, yes/no counts, co-occurrence note;
   - rows sorted `possibleLink` → `unclear` → `smallOrNone` → `notEnoughData`;
   - context and supplement habits in a collapsed "Also logged" group with counts only.
3. **Try one.** Up to 2 proposals, each opening the trial setup.
4. **Finished trials.** Verdict cards (B.6).

Also:
- A small "What gets logged" footer lists each source with its counts over 90 nights and why some nights are
  absent (`HealthAbsence`).
- **Evening logging:** a "Tonight" sheet reachable from the hub and the trial card logs any journal habit under
  the explicit night key (tomorrow's wake-day key). This fixes the ambiguity in A.2 for new entries.

##### A.8 File plan (S1-A)

**New, package** (`Packages/StrandAnalytics/Sources/StrandAnalytics/`):
- `HabitModel.swift`: types, `HabitCatalog.definitions`, night-key normalisation, dichotomisation rules.
- `HabitStats.swift`: shared numerics, also used by S1-B:
  - dense OLS via normal equations and Cholesky (≤ 7 regressors; abstain `singularDesign` when the
    condition estimate exceeds 1e10);
  - Frisch–Waugh–Lovell residualiser;
  - Newey–West SE;
  - Student-t quantile (Hill 1970 algorithm; |error| < 1e-4 for df ≥ 3);
  - Benjamini–Hochberg; Jaccard.
- `HabitAssociation.swift`: the A.3 report.
- `HabitCoachSummary.swift`, `HealthAbsence.swift`.

**New, app** (`Strand/Data/`):
- `HabitLedgerSource.swift`: builds `HabitLedgerInputs` from the repo (merged journal), `DreamJournalStore`,
  `sleepTimingsByDay`, workouts, the new caffeine/climate/WiZ series, the S4 breath log, and outcomes from
  `repo.days` plus the stress daily log.
- `HabitAnalysisStore.swift`: caches the last report as JSON with `computedAt`; `refreshIfDue()` at most once
  per local day, after that morning's analysis has landed.
- `CaffeineDailySummary.swift`: writes metricSeries source `noop-habits`, keys `caffeine_last_min` (minutes
  after local midnight of the last intake that day) and `caffeine_mg_day` (only when every intake had mg). It
  is written whenever intakes change, so history survives the 48 h pruning.
- `BedroomNightSummary.swift`: after a night is scored, writes `bedroom_temp_sleep90` / `bedroom_rh_sleep90`
  (wake-day key) from `ClimateHistory`; nil below 60 % slot coverage.
- `WizDailyRecord.swift`: `wiz_winddown_ran` = 1 when the automation fired that day, 0 when enabled and not
  fired by onset, no row when disabled.
- `HealthV2Refresh.swift`: one coordinator, `daysChanged(_:)`. It throttles and calls
  `HabitAnalysisStore.refreshIfDue`, `BedroomNightSummary.writeIfDue`, `SleepScheduleProvider.refresh` (S2),
  `WeekPlanSource.refresh` (S3) and `HabitTrialStore.tick` (S1-B).

**New, screens** (`Strand/Screens/`; the design packages style them): `HabitsHubView.swift`,
`TonightLogSheet.swift`.

**Hooks in existing files (each ≤ 3 lines):**
- `Strand/App/AppModel.swift`: in the `repo.$days.sink` block (~L448), call `HealthV2Refresh.shared.daysChanged(days)`.
- `Strand/Data/CaffeineLog.swift`: after `log(at:mg:)` and `replaceImported(_:)`, call `CaffeineDailySummary.record(...)`.
- `Strand/Data/WizLights.swift`: where `K.windRan` is set (~L378), call `WizDailyRecord.markRan(day:)`.
- Entry points (per coordinator decision 4 the Focus tab stays; there is no Habits tab). The Habits hub is
  reached from:
  - a primary entry on Today, next to the quest strip / the running trial's card;
  - the Coach;
  - the More list in `StrandiOS/App/RootTabView.swift`.

  `InsightsHubView`'s and `InsightsView`'s experiment entry points route here too. All of these belong to the
  design packages; `DESIGN_V2.md` §5.15 defines the trial and result cards. Where names differ, the model
  names in this document win.
- Coach: register `HabitCoachSummary` with the context budget (token-budget agent).

**Tests** (`SAT/`):
- `HabitModelTests`: absent vs "no" for each source; numeric 0 entered is "no"; dream cut points fixed;
  night-key mapping incl. DST days and after-midnight caffeine; outcome-like answers never become habits.
- `HabitStatsTests`: OLS against a hand-solved system; singular-design abstention; Newey–West against a
  hand-computed 12-point example; t quantiles against a table (df 3, 5, 10, 30, 120; p 0.975); BH on a
  textbook example.
- `HabitAssociationTests`:
  - synthetic effect 1.0 MCID·2 detected as `possibleLink` with n = 40/40;
  - null data over 20 habits yields BH-controlled false labels (≤ 10 % of runs with any `possibleLink` over
    200 seeded runs);
  - AR(1) ρ = 0.5 null gives interval coverage ≥ 90 %;
  - co-occurrence flag at Jaccard > 0.6;
  - gate at 7 vs 8.
- `HabitCoachSummaryTests`: never exceeds `maxChars`; priority order; dates present; a running trial line never
  contains an estimate.

**Acceptance (S1-A):**
- Every displayed habit figure comes from `HabitAssociation`.
- Dream screen and meal answers appear as habits.
- Caffeine timing appears as a habit after 8 + 8 logged days.
- The coach context is smaller than before.
- No surface says a habit "causes" or "improves" anything outside a completed trial.

#### S1-B. Habit trials (N-of-1 experiments)

**Purpose.** Turn "your data suggests late caffeine lines up with lower HRV" into a question the wearer
can actually answer for themselves, with a design whose false-positive rate is known and whose "no
effect" answer is as legitimate as "helped". This is the one place in the app where a causal statement
about *this wearer* can be earned; everywhere else stays associational.

##### B.1 Eligible interventions (closed catalogue, no free text)

Only behaviours that are harmless, reversible within a day, and that a healthy adult already varies
without supervision. The catalogue is a fixed Swift table (`HabitTrialCatalog`), not model output; the
coach can *propose* an entry, never invent one.

| id | ON-day instruction | OFF-day instruction | carry-over class | default primary outcome (direction) | auto-adherence source |
|---|---|---|---|---|---|
| `caffeineCutoff14` | No caffeine after 14:00 | Caffeine as usual | none (half-life ~5 h; one night) | that night's total sleep time (up) | `caffeine_last_min` (S1-A `CaffeineDailySummary`) on days with a logged intake; else tap |
| `screensOff60` | Screens off 60 min before your planned bedtime | Evening as usual | none | sleep-onset clock time (earlier) | tap (dream-journal "Screen before bed" is recall, used as secondary check only) |
| `bedroom18` | Bedroom at ~18 °C at lights-out | Bedroom as usual | none | that night's HRV, ln RMSSD (up) | Govee sensor mean over the first 90 min of the sleep window, if a sensor is paired; else tap |
| `walkAfterDinner10` | 10-min walk within 60 min after dinner | No planned walk | none | that night's RHR (down) | step count in the evening window (≥ 800 steps in any 15-min span) **only when steps are reliable** (S3 §3.4 gate); else tap |
| `morningDaylight` | ≥ 10 min outdoors within 30 min of waking | No deliberate outdoor time before 10:00 | phase (multi-day) | sleep-onset clock time (earlier) | tap (weather daylight/cloud shown for context only) |
| `dinner3h` | Last meal ≥ 3 h before bed | Dinner as usual | none | that night's RHR (down) | tap (dream-journal "Last meal" as secondary check) |
| `breathing10` | One 10-min paced-breathing session in the evening | No breathing session | none | that night's HRV, ln RMSSD (up) | `MeditationLog` / biofeedback session record (auto) |
| `alcoholFree` | No alcohol this evening | Evening as usual (no instruction to drink) | short (1 night) | that night's HRV, ln RMSSD (up) | tap |

**A contrast must exist.** A trial only makes sense if the wearer's usual evening differs from the ON
instruction. Setup asks "On how many evenings a week do you usually <do the thing>?" and, where data exists
(journal, caffeine summary, Govee, workouts), shows the observed rate beside it. Below 3 evenings a week the
trial is not offered ("you already mostly do this — there is nothing to compare").

`alcoholFree` is special: the OFF instruction is "as usual", never "drink". If the wearer's history shows
fewer than 8 drinking evenings in the last 28 days (the general 3-a-week contrast rule is relaxed to 2 a week here, because the app must not wait for more drinking), the catalogue marks it *ineligible* (there is no
contrast to test, and the app must never nudge anyone toward drinking to make a trial work).

**Explicitly excluded, by rule, with the reason shown in the catalogue screen:** supplements (including
melatonin, magnesium, creatine), any medication or change to one, caffeine *increases*, fasting or
time-restricted eating protocols, calorie restriction, sleep restriction or deliberately shortened
nights, cold/heat exposure (ice baths, sauna — cardiovascular risk for some), breath-holds or
hyperventilation protocols, training-intensity increases, and anything a free-text field could smuggle
in. A trial may only ever *remove* a plausible disruptor or *add* a low-dose, everyday behaviour.

##### B.2 Pre-registration (frozen before day 1)

A trial is created in a `draft` state and becomes `running` only when the wearer taps **Start**, at which
point this record is written once and never mutated (`HabitTrialRegistration`, Codable, with an FNV-1a
hash over its canonical JSON stored beside it so any later edit is detectable):

- `interventionId`, `startDay` (local `yyyy-MM-dd`, always *tomorrow* — never today, so today's already-lived
  behaviour cannot leak in), `lengthDays` (28, 42 or 56 for `weekdayBalanced`; 48 or 56 for `blocked`;
  chosen before start, cannot be changed after),
- `primaryOutcome` (exactly one `HabitOutcome`), `direction` (`.increase` / `.decrease`), `lag` (fixed by
  the outcome: night outcomes pair day D's assignment with the night that *starts* on D and is keyed to
  wake day D+1; next-day outcomes pair with D+1's daytime value),
- `mcid` — the minimal meaningful effect in the outcome's units, frozen from the pre-trial baseline
  (table below),
- `schedule` — the full ON/OFF assignment for every day, generated at registration from `seed`,
- `seed` (UInt64, stored), `design` (`.weekdayBalanced` or `.blocked(blockDays:washoutDays:)`),
- `covariates` — fixed list (below), `alpha = 0.05` (two-sided CI, i.e. 2.5 % one-sided in the
  pre-registered direction), `permutations = 10_000`,
- `baselineSD` of the outcome over the 28 nights before `startDay` and the resulting minimum detectable
  effect (`mde`) — shown to the wearer before Start.

Secondary outcomes are listed at registration too, and every secondary result is rendered with the word
**Exploratory** and never produces a verdict.

**Minimal meaningful effect (MCID) per outcome** — judgement calls, each with its reason, frozen per trial:

| outcome | unit | MCID | rationale |
|---|---|---|---|
| night HRV (ln RMSSD) | ln ms | `max(0.5 × baselineSD, 0.04)` | the Plews/Altini "smallest worthwhile change" convention for ln RMSSD; the 0.04 floor (~4 %) stops a very stable wearer's MCID shrinking into measurement noise |
| night RHR | bpm | `max(0.5 × baselineSD, 1.0)` | below 1 bpm is within night-to-night measurement wobble of a PPG strap |
| total sleep time | min | 15 | a quarter hour is the smallest change sleep-extension studies treat as practically relevant; less is within staging-boundary error |
| sleep-onset clock time | min | 15 | same reasoning; onset from the strap is detected to roughly ±10 min |
| sleep efficiency | %-points | 2 | wearable efficiency is noisy; 2 points is the smallest change worth a behaviour |
| next-day Charge | points | 5 | secondary only (a composite of HRV/RHR — never primary, see B.6) |
| daytime stress (mean, 0–3) | scale units | exploratory only | the stress index is thinly validated here; never primary |

Sleep latency is **not** an outcome: the strap cannot see the moment of lights-out, so "latency" would be
fabricated from a guessed bedtime. Onset clock time is used instead.

##### B.3 Assignment schedule

Two designs, chosen by the intervention's carry-over class, never by the wearer:

1. **`weekdayBalanced` (carry-over `none` / `short`).** Length L ∈ {28, 42, 56} = 4, 6 or 8 occurrences of
   each weekday. For each weekday independently, exactly half its occurrences are ON, chosen uniformly at
   random from `seed` (SplitMix64 → Fisher–Yates; deterministic, so the schedule and the permutation null
   are reproducible and testable). This gives exact weekday balance (weekday is the strongest routine
   confounder: weekend bedtimes, alcohol, training) and exact 50/50 arms.
   For `short` carry-over (`alcoholFree`), a day whose *previous* day was ON and which is itself OFF is
   still analysed, but `prevAssignedOn` enters the model as a covariate (B.5), which absorbs a one-night
   spill-over rather than letting it contaminate the OFF mean.
2. **`blocked(blockDays: 4, washoutDays: 1)` (carry-over `phase`, i.e. `morningDaylight`).** Circadian
   phase shifts accumulate over days and decay over days, so alternating single days would measure
   nothing. The trial is cut into 4-day blocks; blocks are assigned ON/OFF by complete randomisation with
   exactly half ON (L = 48 → 12 blocks, 6 ON: C(12,6) = 924 possible schedules; L = 56 → 14 blocks, 7 ON:
   3,432). The first day of every block is a **washout day**: the instruction applies, but its outcome is
   not analysed. 28-day phase trials are not offered: 7 blocks cannot be split evenly and the
   randomisation distribution is too coarse to ever reach α.

Assignments are revealed **one day at a time** (the quest for day D appears at the start of day D). The
wearer never sees the schedule ahead, so they cannot pre-arrange "good" days for ON.

##### B.4 Adherence, missing data, and what gets analysed

- **Adherence** is recorded per day as `followed` / `notFollowed` / `unknown` (no tap and no auto-evidence).
  Auto-evidence (table B.1) sets it where the app can see the behaviour; the tap overrides only toward
  honesty (a wearer can say "I didn't" on an auto-`followed` day). OFF days record whether the wearer did
  the behaviour anyway (contamination), with the same single tap.
- **Primary analysis is intention-to-treat (ITT): every day with an observed outcome is analysed in the
  arm it was *assigned* to, whatever the adherence.** Why ITT and not per-protocol: (a) the permutation
  test below is only exact when the analysed assignment is the randomised one — dropping non-adherent days
  breaks exchangeability; (b) adherence is not random: people skip "screens off" on stressful evenings,
  which are also low-HRV evenings, so per-protocol would *manufacture* a benefit; (c) non-adherence
  dilutes ITT toward zero, which can only cost power, never create a false "helped". **Per-protocol**
  (followed-ON vs not-contaminated-OFF) is computed as a secondary, labelled Exploratory, and shown only
  beside the ITT result.
- **Adherence gate:** if fewer than 70 % of ON days are `followed`, or more than 30 % of OFF days are
  contaminated, the verdict is forced to *Inconclusive — the plan wasn't followed closely enough to test
  it*. (Below that the ITT contrast is mostly measuring the schedule, not the habit.)
- **Missing outcomes:** a night with no measurement (strap off, no sleep detected, `ScoreConfidence` =
  `calibrating` for that night's input, or an HRV night outside the `Baselines.hrvCfg` plausibility bounds)
  is **missing** — excluded from both the observed statistic and every permuted statistic, never zero,
  never carried forward, never imputed. Missing days are counted per arm and shown.
- **Minimum valid data (otherwise Inconclusive):** in each arm, ≥ 70 % of that arm's scheduled analysable
  days must be analysable (10 of 14 for L = 28; 15 of 21 for L = 42; 13 of 18 for the 48-day blocked design),
  and the missing counts in the two
  arms differ by no more than max(3, 15 % of arm size) — a lopsided loss suggests missingness is related to
  the assignment, and then no estimate is trustworthy.
- **Illness:** if `IllnessSignalEngine` raised (≥ `raiseThreshold`) on 3 or more trial days, the trial is
  marked *Inconclusive — you were likely unwell during part of it* and the wearer is offered a fresh
  trial. Illness-flagged days are **not** individually excluded: the flag is itself computed from HRV/RHR,
  so excluding on it would be selecting on the outcome.

##### B.5 Confounders: what is designed out, adjusted, or only reported

| factor | handling | why |
|---|---|---|
| weekday / weekend | **designed out** by weekday-balanced randomisation; plus a `weekend` indicator in the model for blocked designs | strongest routine confounder |
| training load | **adjusted**: day D's Effort (0–21 scale) as a covariate, **except** for interventions flagged `affectsEffort` (`walkAfterDinner10`), which use day D−1's Effort instead, because a covariate the intervention itself moves is a mediator and adjusting for it would subtract the effect. Missing Effort ⇒ the day is dropped *from both observed and permuted statistics* (a model cannot run on an absent covariate; dropping on a pre-assignment covariate keeps the test valid) | hard days depress next-night HRV and raise RHR; adjusting removes variance, raising power |
| slow drift (fitness, season, a cold coming on) | **adjusted**: linear day-index trend | 4–8 weeks is long enough for the baseline to move |
| one-night spill-over (short carry-over) | **adjusted**: `prevAssignedOn` indicator (only for `short`) | see B.3 |
| sleep duration | **not adjusted — reported** as a secondary | for most interventions sleep duration is a *mediator* (screens off → more sleep → higher HRV); adjusting would subtract part of the real effect |
| alcohol (when it is not the intervention) | **not adjusted — reported** per arm, plus an exploratory sensitivity analysis excluding alcohol nights | alcohol could itself respond to the assignment (e.g. a screens-off evening changes the evening), so adjusting would be adjusting for a possible consequence |
| illness | **gated** (B.4), not adjusted | the flag is outcome-derived |

Randomisation makes all of these independent of the assignment *in expectation*; the covariates exist for
precision, and the permutation test stays exact with them because the same model is refitted under every
permuted assignment.

##### B.6 Analysis (pure, deterministic)

For the analysable days (outcome present, covariates present, not washout):

1. Fit ordinary least squares `y = β0 + τ·ON + β1·effort + β2·t + [β3·weekend] + [β4·prevAssignedOn] + ε`.
   `τ̂` (the ON coefficient) is the effect estimate, in outcome units. HRV is analysed as ln RMSSD and
   reported back as a percentage (`exp(τ̂) − 1`) plus ms at the baseline median.
2. **Inference = a randomisation (permutation) test that re-draws the assignment with the exact
   procedure used at registration** (same design, same weekday/block constraints, fresh sub-seeds derived
   from the registered seed), refits the same model, and records `τ̂*`. 10,000 draws; the one-sided p in the
   pre-registered direction is `(1 + #{τ̂* ≥ τ̂}) / (1 + 10,000)` (sign-adjusted for `.decrease`).
   **Why this and not a t-test:** nightly HRV/RHR are autocorrelated (a lag-1 correlation of 0.3–0.5 is
   typical), which makes t-test and Welch p-values too small. Under the sharp null (the habit does nothing
   on any day) the outcome series is fixed and only the assignment is random, so the permutation
   distribution is exact *whatever the autocorrelation* — autocorrelation costs power, it cannot inflate
   the false-positive rate. It also needs no normality assumption and matches the small n.
3. **95 % interval by test inversion** under the constant-additive-effect model: the interval is every
   `δ` for which "the effect is δ" is not rejected at 2.5 % in either tail, found by bisection on
   `y − δ·ON` (each probe reuses the same 10,000 stored permuted assignments, so the interval is
   deterministic and consistent with the p-value). Reported in outcome units.
   *Computation:* by Frisch–Waugh–Lovell, `τ̂ = (M d)·(M y) / (M d)·(M d)` where `M` is the residual-maker
   of the fixed covariates (effort, trend, weekend) and `d` the assignment vector. `M y` is computed once;
   each permutation costs one `M d*` (n ≤ 56, so O(n²) ≈ 3 k operations). `prevAssignedOn`, when present,
   is assignment-derived and is rebuilt from each permuted schedule, so for `short` designs `M` is refitted
   per permutation (still ≤ 6 regressors). Under the shift `y − δ·d_obs` every permuted statistic is linear
   in δ (`a* − δ·b*`), so the interval search below needs no refits.
4. **Autocorrelation is reported, not modelled away:** the lag-1 autocorrelation of the model residuals
   is computed and shown in the detail view ("your nights are strongly linked day-to-day — this trial
   needed more days"). It feeds the next trial's recommended length via the MDE formula with an AR(1)
   variance inflation `(1+ρ)/(1−ρ)`.
5. **Minimum detectable effect shown before Start:** `mde ≈ 2.8 · σ · sqrt(1/nOn + 1/nOff) · sqrt((1+ρ)/(1−ρ))`
   with σ and ρ from the 28 pre-trial nights (ρ clamped to [0, 0.6]). If `mde > 2 × mcid`, the Start screen
   says so plainly and recommends the next longer length; the wearer still decides, and the choice is
   frozen.

**Verdicts — exactly three, decided mechanically from the registered rule:**

- **Helped** — the 95 % interval excludes zero on the pre-registered side *and* the point estimate is at
  least the MCID. Copy: "Over N days, <habit> was followed by <outcome> about X better (range A to B).
  That's big enough to matter and unlikely to be chance for you."
- **No meaningful effect detected** — enough valid data, and either the whole interval lies below the MCID
  on the beneficial side (confidently small or absent), or the interval excludes zero on the *harmful*
  side (then the copy says the estimate pointed the other way). Copy never implies failure: "For you,
  <habit> didn't move <outcome> by a meaningful amount. That's a real result — you can drop it without
  losing anything we can measure."
- **Inconclusive** — too few valid days, adherence/contamination gate failed, missing data lopsided,
  illness gate, stopped early, *or* the interval is so wide that it contains both zero and the MCID (the
  data cannot tell a meaningful effect from none). Copy says which, and whether a longer trial would help.

A statistically clear effect smaller than the MCID is deliberately reported as *No meaningful effect*, not
as a small win: the app is not in the business of turning 0.8 ms into a habit.

**No p-hacking, enforced in code, not policy:**
- one primary outcome, frozen; secondaries always labelled Exploratory and excluded from the verdict;
- **sealed results**: while `running`, the store exposes only day count, adherence and missing counts —
  the analysis function is not called, and no interim estimate exists anywhere (not on screen, not in the
  coach context, not in logs);
- **fixed stopping rule**: the trial ends on `startDay + lengthDays − 1` (plus one day for the last night
  to be scored). Ending early is allowed (it is the wearer's life) but yields *Inconclusive — stopped
  early*, never an analysis; extending is impossible;
- a completed trial of the same intervention can be repeated only as a *new* registration; the two are
  never pooled after the fact.

**Blinding** is impossible; the doc and the result screen say so. Physiological outcomes (HRV, RHR,
onset time) are less exposed to expectation effects than self-report, which is one more reason
self-reported outcomes ("felt rested") are never primary.

##### B.7 Quest integration and the penalty rule

- A running trial issues **one trial quest per day**, created at local day start (or first foreground):
  ON → the instruction with the S2 times filled in ("Tonight: screens off by 21:45"), OFF → "Normal
  evening — nothing to change". Both arms get a card; the OFF card is not a rest-from-duty, it is half the
  experiment.
- **Mechanics, chosen to avoid a codec change:** the quest is a `Quest` with `kind: .custom`, **id prefix
  `trial-<trialId>-<day>`** (the same pattern plan quests use with `plan-`), no `QuestGoal`, so
  `QuestAutoComplete` never touches it and `QuestCodec` / the Android decoder need no new case. The trial
  store (`HabitTrialStore`), not the quest list, is the source of truth for adherence — `QuestStore` keeps
  at most 40 quests, which would drop a long trial's history. `QuestStore.sweepExpired` skips `trial-`
  ids entirely (no failure card, not in the day report); an unanswered day simply stays `unknown`.
- The card has a single tap: **Did it / Didn't** (ON) or **Kept to normal / Did it anyway** (OFF). Auto
  evidence pre-fills where available.
- **XP is awarded for logging, identically in both arms** (same XP for any answer, including "Didn't"),
  so XP cannot reward a false "Did it" and cannot make ON days more attractive to *report*. The trial
  quest does not count toward streaks.
- **Penalty rule (binding on the penalty system another agent is building): trial quests are never
  penalised — no XP loss, no red/failed card, no streak break, no level effect, in either arm, for any
  answer or for no answer.** Reason: a penalty that attaches to non-adherence on ON days turns the
  outcome into "the habit + the stress of being penalised", and any penalty or directive on OFF days
  changes OFF-day behaviour — both bias τ̂. For the same reason, **while a trial runs the day plan must not
  issue any other directive that targets the trial's behaviour or its primary outcome's obvious lever**
  (e.g. no "Asleep by 22:30" bedtime quest during `screensOff60`, no evening-breathing directive during
  `breathing10`); other quests and their penalties are allowed only because they are independent of the
  day's assignment and so equal across arms in expectation.
- The coach does not give advice on the trial behaviour while the trial runs (the context line says a
  trial is running and results are sealed).

##### B.8 The coach's role

- **Proposes** trials from the habit model (S1-A): candidates are catalogue entries ranked by
  (1) the habit analysis showing a *possible link* (see A.4) on the default primary outcome, (2) lowest
  effort, (3) not already tested in the last 90 days. The coach may only name catalogue ids; the app
  renders the pre-registration screen, not the model.
- **Explains** the design in plain words from a fixed template ("For 4 weeks, each evening the app will
  tell you whether tonight is a screens-off night or a normal night. Half are each, balanced across
  weekdays. We'll compare your onset time on the two kinds of nights. You won't see results until the
  end, so you can't accidentally steer it.").
- **Reports** the verdict verbatim from the engine, including *No meaningful effect* and *Inconclusive*;
  it may add what to try next, but never re-interpret an Inconclusive as a trend.

##### B.9 Verification (pure functions and required tests)

Pure API (all in `Packages/StrandAnalytics`, no store, no dates beyond `yyyy-MM-dd` strings):

- `HabitTrialSchedule.make(design:lengthDays:startDay:seed:) -> [HabitTrialDay]`
- `HabitTrialSchedule.redraw(design:days:seed:) -> [Bool]` (the permutation generator — same code path)
- `HabitTrialAnalysis.analyse(registration:observations:) -> HabitTrialResult`
- `HabitTrialAnalysis.fitOLS(...)` (small dense solver, ≤ 6 regressors, via normal equations + Cholesky
  with a condition check → abstain on singular design)
- `HabitTrialAnalysis.minimumDetectableEffect(sd:rho:nOn:nOff:)`
- `HabitTrialVerdict.decide(result:registration:) -> HabitTrialVerdict`
- `SplitMix64` (deterministic RNG; platform-neutral)

Tests (`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/HabitTrial*Tests.swift`; synthetic tests inject `mcid` and `permutations` so they do not depend on the real outcome tables):

1. *Schedule*: every weekday exactly half ON for L = 28/42/56; blocked design has exactly half ON blocks
   and washout on each block's first day; same seed ⇒ identical schedule; different seeds differ.
2. *Known effect detected*: i.i.d. noise σ = 1, true effect 1.5σ, L = 28 ⇒ verdict Helped in ≥ 80 % of
   200 seeded replications; estimate's 95 % interval covers the truth in ≥ 92 % of them.
3. *Known effect under autocorrelation*: AR(1) ρ = 0.5 noise, effect 2σ, L = 56 ⇒ Helped ≥ 80 %.
4. *Null is not an effect*: effect 0, i.i.d. and AR(1) ρ = 0.5, with a linear drift and weekday
   seasonality ⇒ Helped in ≤ 2.5 % (+ binomial tolerance: ≤ 4.5 % over 1,000 replications).
5. *Empirical false-positive simulation*: 2,000 null trials mixing ρ ∈ {0, 0.3, 0.6}, 15 % MCAR missing
   nights, 20 % non-adherence, drift — assert Helped rate ≤ 3.5 % and the rate of "interval excludes zero
   in the beneficial direction" ≤ 3.5 %. (Kept under ~10 s by using 1,000 permutations in the test build
   via an injected `permutations` parameter; one slow-tagged test runs the full 10,000.)
6. *Confounded adherence does not manufacture an effect*: null effect, but non-adherence on ON days is
   concentrated on low-outcome days ⇒ ITT verdict is not Helped (per-protocol exploratory is allowed to
   look better — the test asserts that the verdict ignores it).
7. *Missing nights are missing*: dropping nights reduces n and never changes the estimate as a zero would;
   a trial with 9 valid ON days ⇒ Inconclusive(tooFewDays).
8. *Lopsided missingness* ⇒ Inconclusive(missingImbalance).
9. *Adherence gate*: 65 % ON adherence ⇒ Inconclusive(adherence) even with a large effect.
10. *Effect below MCID*: L = 56 with noise small relative to the MCID (σ = 0.25 × MCID), true effect 0.3 × MCID ⇒ No meaningful effect (not Helped).
11. *Harmful direction*: effect of −1.5σ ⇒ No meaningful effect with `pointedOtherWay = true`.
12. *Wide interval*: n at the minimum, small effect ⇒ Inconclusive(imprecise).
13. *Stopped early* ⇒ Inconclusive(stoppedEarly), and `analyse` is never invoked on a running trial
    (store-level test in `StrandTests`).
14. *Covariate absorbs confounding*: effort simulated to differ by chance between arms and to depress
    the outcome ⇒ adjusted estimate within tolerance of truth where the raw difference is not.
15. *Determinism*: same inputs ⇒ byte-identical result struct (so a re-render never flips a verdict).
16. *Registration immutability*: a mutated registration fails its hash check and the result renders
    "trial record altered — no verdict".

##### B.10 File plan (S1-B)

**New, package** (`Packages/StrandAnalytics/Sources/StrandAnalytics/`):
- `HabitTrialCatalog.swift`: the B.1 table, which includes for each entry:
  - carry-over class, `affectsEffort`, effort rank;
  - the default primary outcome and direction;
  - the conflicting quest metrics (e.g. `screensOff60` → `.bedtimeBy`, `.bedtimeEarlier`; `breathing10` →
    `.meditationMinutes`);
  - the exclusion list with reasons;
  - `proposals(...)` (A.4).
- `HabitTrialRegistration.swift`: the frozen record, its canonical JSON (sorted keys, fixed number formatting)
  and an FNV-1a 64 hash.
- `HabitTrialSchedule.swift`: `make` / `redraw` for both designs.
- `DeterministicRNG.swift`: `SplitMix64`; platform-neutral, so a Kotlin twin can reproduce any schedule.
- `HabitTrialAnalysis.swift`: B.4–B.6, using `HabitStats` from S1-A.
- `HabitTrialVerdict.swift`: the three verdicts, the typed reasons for Inconclusive, and fixed copy templates.

**New, app** (`Strand/Data/`):
- `HabitTrialStore.swift`: one JSON file `habit-trials.json` in the store directory (the directory of
  `StorePaths.defaultDatabasePath()`), written atomically. It holds:
  - registrations and their hashes;
  - per-day records `{day, assigned, adherence, contamination, answeredAt, source}`;
  - state `draft → running → completed | stoppedEarly`.

  Rules:
  - The analysis is callable only in `completed`.
  - `tick(now:)` completes a trial the morning after its last night has been scored, then runs the analysis
    once and stores the result.
- `HabitTrialQuestBridge.swift`: upserts today's `trial-` quest and routes a tap to
  `HabitTrialStore.recordAdherence`. It also exposes `conflictingMetrics(for:)` so the day plan can drop
  conflicting directives.

**New, screens** (`Strand/Screens/`):
- `HabitTrialSetupView.swift`, which shows:
  - the catalogue entry, its evidence line and the plain-words design (B.8);
  - the contrast question (B.1);
  - the MDE with a warning;
  - the length choice and Start.
- `HabitTrialTodayCard.swift`: the two-answer card, hosted by Today's quest area and the Habits hub.
- `HabitTrialResultView.swift`: the verdict, estimate with interval, the arms' means, adherence, missing
  counts, residual autocorrelation, exploratory secondaries and per-protocol result in a separate section,
  and "blinding was not possible".

**Hooks in existing files:**
- `Strand/Data/QuestStore.swift`:
  - `sweepExpired`: skip ids with prefix `trial-` (1 line).
  - `checkOff`: for `trial-` ids, delegate to the bridge (2 lines).
- `SA/QuestDifficulty.swift` and `Strand/AI/QuestGenerator.swift`: a `excluding: Set<QuestMetric>` argument,
  filled from `HabitTrialQuestBridge.conflictingMetrics`. This shares the S0 H9 signature change, so it is
  one coordinated edit with the Strand/AI agent.
- Coach: the trial lines ride in `HabitCoachSummary` (A.6). The coach needs no other hook.

**Acceptance (S1-B):**
1. All 16 package tests above pass in `swift-packages.yml`. The simulation test's observed false-positive
   rate is printed in the test log.
2. A running trial exposes no estimate anywhere: store API, UI, coach string or logs. A `StrandTests` test
   asserts that `HabitTrialStore` has no read path to the analysis before `completed`.
3. On a fresh 28-day trial, the schedule is weekday-balanced and revealed one day at a time.
4. A trial day never produces a failure card, XP loss or streak change, whatever the answer.
5. While `screensOff60` runs, no bedtime directive is issued.
6. Stopping early yields "Inconclusive — stopped early" with no numbers.

---

### S2. Sleep anchor

**Goal.** One schedule instead of six. Today six things each keep their own idea of bedtime:
- detected sleep;
- `WindDownNudge` (user-set 07:00 wake, 8 h need, 30 min lead);
- `RoomClimatePlan`;
- WiZ (fixed 06:30 / 21:30);
- rituals (06:40 / 13:30 / 19:00);
- the caffeine bedtime setting (23:00).

The gears also shift bedtime by 20–40 min depending on the morning's choice. S2 derives one plan from a wake
anchor and the wearer's own sleep need, and every consumer reads it.

#### 2.1 What the wearer sees

**A "Tonight" card** (new screen file; the design packages place it in the Sleep tab and optionally on Today):

```
Bedtime 22:45   to wake at 07:00 with your ~8 h 15 m need
                (15 min earlier this week to pay back 45 min of sleep debt)
Wind down 21:45 · Lights dim 20:45 · Bedroom 19.2 °C (aim 16–19.5) · Last caffeine by 11:45
```

**One weekly line** in the review (S3):
- "Wake time this week varied ±42 min (your usual ±55)";
- in the detail view, the Sleep Regularity Index as a 4-week trend.

**What it never shows:**
- No score and no red.
- No message when a night misses the target. The week's review summarises.
- **No stage targets.** Staging is not reliable enough to coach on (V2 kappa 0.356; no 4.0 ground truth).

#### 2.2 Pure logic: `SA/SleepAnchor.swift`

**Inputs:**
- `nights: [SleepTimingNight]`: `{wakeDay, onsetMin, wakeMin, asleepMin?, efficiency?}`, main sleep only, from
  `Repository.sleepTimingsByDay` plus `repo.days`.
- `needHours: Double?`: `AnalyticsEngine.Rest.engineNeedHours()`.
- `debtMin: Double?`: `SleepDebt` balance.
- `targetWakeMin: Int?`: user-set, optional.
- `weekendOffsetMin: Int`: 0–60, default 0.
- `weekday` of the coming wake day.

**Anchor:**
1. The user's target wake if set.
2. Otherwise the median wake time of the last 14 main sleeps, as a circular median rounded to 5 min. This
   needs ≥ 7 nights.
3. Otherwise **abstain** with `calibrating(n, 7)` and prompt "set the time you want to wake".

On Saturday and Sunday wake days the anchor moves later by `weekendOffsetMin`. The cap of 60 min keeps
social jet lag small (Wittmann 2006).

**Abstain `scheduleTooIrregular`** when there is no user target and the circular SD of wake times over 14
nights exceeds 120 min (shift work or very irregular schedules). The card offers "set a target wake if you
want an anchor". Offering a bedtime off a median that describes nobody's actual night would be fabrication.

**Need:**
- The engine's recorded need. Its p75-of-own-nights rule is already floored at 8.0 h and capped at 9.5 h.
- Below 7 nights the engine need is the population default. The card then says "8 h — adult recommendation;
  yours after 7 nights". This is a labelled planning target, not a measurement, so it does not violate the
  no-fabrication rule.

**Bedtime target** = `anchor − need − 15 min (sleep-onset buffer) − payback`:
- `payback = min(30, round5(debtMin / 3))` when `debtMin ≥ 60`, else 0. The wake anchor never moves for debt.
  Paying back by getting up later would trade regularity for duration.
- **Insomnia guard:** if sleep efficiency was < 80 % on ≥ 4 of the last 7 nights, `payback = 0` and the card
  shows one line: "If you often lie awake, more time in bed can make it worse. CBT-I is the recommended
  approach — consider talking to a professional." This matters because extending time in bed is the opposite
  of what insomnia treatment prescribes.

**Derived times:**
- `windDownStart = bedtime − 60`;
- `lightsDim = bedtime − 120`, roughly when melatonin starts to rise before habitual sleep;
- `lightsWindDown = windDownStart`;
- `morningLight = anchor`;
- `roomSleepWindow = windDownStart … anchor`;
- `caffeineCutoff = CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes:)`. This reuses the existing decay model,
  so only its bedtime input changes; there is no second caffeine rule.

**Confidence:** `calibrating` below 7 nights without a user target; `building` at 7–13 nights; `solid` at ≥ 14.

#### 2.3 Pure logic: `SA/SleepRegularity.swift`

This is one canonical regularity. It replaces the display role of the four current definitions; the Rest
formula is untouched in 2.0 (see §4).

- **`wakeSdMin`, `onsetSdMin`:** circular SD over the last 14 main sleeps; needs ≥ 7. This is the headline
  number because it is directly actionable.
- **`sri`:** Sleep Regularity Index (Phillips 2017) over the last 14 days.
  - Formula: `SRI = −100 + 200 × P(same sleep/wake state at t and t + 24 h)` over minutes.
  - Only 24-h pairs where both days have ≥ 80 % wear coverage count; coverage comes from HR-sample coverage,
    already computed for `NightCoverage`. Needs ≥ 7 valid pairs, otherwise nil with `tooFewNights`.
  - Shown as a trend. **No population cut-points are shown**: published thresholds come from different
    devices and populations.
- **`socialJetlagMin`:** |midsleep on Saturday/Sunday wake days − midsleep on weekday wake days|. Needs ≥ 2
  free and ≥ 4 work nights.

#### 2.4 Consumers switched to the plan (one provider)

`Strand/Data/SleepScheduleProvider.swift` is new: `@MainActor final class`, with `current: SleepSchedulePlan?`.
- It is refreshed by `HealthV2Refresh` and whenever the target-wake prefs change.
- New prefs: `sleepAnchor.targetWakeMinutes` (Int, optional) and `sleepAnchor.weekendOffsetMinutes`.

| Consumer | Change | File (hook size) |
|---|---|---|
| Wind-down notification | When enabled, schedule at `windDownStart` per weekday. Its own need and wake settings become the fallback used only when the plan is nil. | `Strand/System/WindDownNudge.swift` (new `reschedule(plan:)`, ~15 lines) |
| Room climate windows | `RoomClimatePlan.schedule` prefers the plan's sleep window, then the existing fallbacks. | `Strand/Data/RoomClimateContext.swift` (~5 lines) |
| WiZ | New pref `wiz.followSleepAnchor` (default on when a plan exists). Evening scene at `lightsDim`, windDown scene at `windDownStart`, daylight at `morningLight`. Fixed-time settings stay as the fallback. Copy on the morning scene: "Indoor light is far dimmer than daylight — a few minutes outside does more." | `Strand/Data/WizLights.swift` (~10 lines in the automation `due` check) |
| Caffeine cutoff | Bedtime input comes from the plan; the separate `noop.caffeine.bedtimeMinutes` becomes the fallback. | `Strand/Data/CaffeineLog.swift` (~3 lines) |
| Bedtime quests | Threshold = `bedtime` for every gear (S0 H9). | `SA/QuestDifficulty.swift` (via `QuestBaseline.bedtimeTargetMin`) |
| Morning ritual push | Anchor + 15 min (S0 H4). | `Strand/System/DayRitualScheduler.swift` |

WiZ sunrise fades and Android's stage-aware smart wake are out of scope. The iOS alarm stays fixed-time; its
default time is offered as the anchor.

#### 2.5 Tests (`SAT/SleepAnchorTests.swift`, `SAT/SleepRegularityTests.swift`)

**SleepAnchor:**
- A user target overrides the median.
- Circular median across midnight: wakes at 23:50 and 00:10 give about 00:00, not 12:00.
- An onset after midnight is handled.
- Payback is capped at 30 min and is 0 below 60 min of debt.
- The insomnia guard zeroes payback.
- A wake SD over 120 min with no target abstains.
- A DST night: minute arithmetic uses clock minutes, never 86 400 s days.
- The need-below-7-nights label is present.

**SleepRegularity:**
- Identical days give SRI = 100.
- Independent random sleep gives SRI ≈ 0 (±10 over seeded runs).
- Low-coverage days are excluded from pairs.
- Wake SD is circular.
- Social jet lag abstains without enough weekend nights.

**App (`StrandTests`):**
- `SleepScheduleProviderTests`: with a plan present, `WindDownNudge`, `RoomClimatePlan`, WiZ due-times and the
  caffeine cutoff all read the same bedtime.

#### 2.6 Acceptance

1. With ≥ 7 nights, every consumer in 2.4 uses one bedtime. A grep-level review finds no remaining hard-coded
   bedtime default reached while a plan exists.
2. Gear choice no longer changes the bedtime threshold.
3. The card shows "—" plus a reason in each abstention case.
4. No stage-minute target exists anywhere in quests or the plan.

---

### S3. Weekly movement plan and review

**Goal.** Replace the day-by-day prescription with a week-level plan. The day-by-day version is a
population strain band (which also triggers the "Optimum reached" screen) and gears scaled daily on
medians. The Optimum screen itself stays, by coordinator decision, but is re-triggered from S3's day guidance
(H2). The week plan:
- moves the wearer toward the ranges with the strongest health evidence: WHO aerobic minutes, 2 strength
  days, and steps to the plateau of the dose-response;
- ramps from their own baseline;
- lets the 7-day HRV trend move hard days;
- inserts easy weeks when the data calls for them;
- is reviewed every Monday.

#### 3.1 What the wearer sees

**Week card** (new screen file; placement is the design packages' choice, e.g. Today's first card on Mondays,
otherwise the Health tab):

```
BUILD WEEK · Mon 29 Sep – Sun 5 Oct
Aerobic   95 / 130 min   (vigorous counts double)    ▓▓▓▓▓▓▓░░
Strength   1 / 2 sessions  — last import Sat; bench: add a rep (82.5 × 7)
Steps      7,900 / day target 8,000 (your median 7,100)
Today      As planned. A harder session fits today.
```

**Changes to that card:**
- **Easy week:** the header reads "EASY WEEK — your 7-day HRV has been below your normal range for 5 days"
  (or whichever reason applied). Targets shrink, and strength suggestions show "hold loads".
- **Day line:** says one of "As planned", "Move today's hard session — HRV below your range", "Easy movement
  only today", or "Rest — body off baseline".
- **No precise "calories to burn" or strain targets.** Effort still shows on its own ring, with its
  typical-range notch.

**Monday review** (same card, expanded; and `WeekReviewView`):
- last week's plan vs done;
- trends;
- one suggested change;
- trial status.

The coach can narrate it from the same struct.

#### 3.2 Pure logic: `SA/SessionIntensity.swift`

Per-session aerobic minutes by ACSM relative intensity (Garber 2011 position stand).

**For each HR sample inside a session window:**
- HRR fraction `f = (hr − rhrZone) / (hrMax − rhrZone)`;
- `rhrZone` and `hrMax` come from `HRZones`' existing resolution: zone RHR as the median of 7 sleep RHRs;
  HRmax learned as `max(Tanaka, second-highest peak)`.

**Classes:**

| Class | Range |
|---|---|
| moderate | 0.40 ≤ f < 0.60 |
| vigorous | f ≥ 0.60 |
| hard | f ≥ 0.80, reported separately |

- **Sample duration** is the gap to the next sample, capped at 2 min (the `StrainScorer` convention).
- **Sessions** are rows in the `workout` table: manual, imported and detected. Overlapping windows are unioned
  so a detected bout inside a logged workout is counted once.
- **Outputs:**
  - `moderateMin`, `vigorousMin`, `hardMin`, and `mvpaEq = moderate + 2 × vigorous` (WHO equivalence);
  - `hardSession = hardMin ≥ 10`;
  - `strengthSession`: a lift session that day, or a workout ≥ 20 min in a strength category of `WorkoutCatalog`.
- **Imported-only sessions** (no strap HR, but `zonesJSON`): z2–z3 count as moderate, z4–z5 as vigorous. They
  carry `source = importedZones`, and the card marks them "≈".
- **Abstention:** a session with < 50 % HR coverage of its window is `unmeasured`. It is counted as a session
  but adds no minutes, and the card says "1 session without heart rate". It is never scored as 0.
- **Honest limit, shown in the detail view:** "Only minutes inside recorded sessions count. Brisk walking
  outside a session is not counted, and very fit people may walk below the moderate threshold."

#### 3.3 Pure logic: `SA/WeekPlanEngine.swift`

**Inputs (`WeekPlanInputs`):**
- the last 42 days of `DayActivity {day, mvpaEq?, moderateMin?, vigorousMin?, hardSession?, strengthSession?,
  steps?, stepsReliable, trimp?, wearCoverage?}`;
- `hrvTier: ReadinessTier?` from `HRVReadiness.evaluate` over nightly `avgHrv`. This promotes the engine from
  the Test Centre flag to an input. It is not displayed as a score.
- `charge`, `illnessRaised`, `sleepDebtMin`, `age?`, and the previous weeks' `WeekPlan`s (for the build-streak rule).

**Baselines:**
- `b` = mean `mvpaEq` over the last 4 complete Monday–Sunday weeks that each have ≥ 5 days with wear coverage
  ≥ 0.7.
- Needs ≥ 3 such weeks; otherwise `calibrating(weeks, 3)`. The card then shows progress toward the WHO range
  with no personal target.
- **Weekly load** = Σ daily linear TRIMP. Linear TRIMP comes from Effort via `StrainScorer.strainToTRIMP`
  (`StrainCombine.swift`), which undoes the log map. It uses the denominator of the method that scored that
  day (`StrainScorer.logMapDenominator(method:sex:)`). `chronic` = mean weekly load over the last 4 weeks.

**Week type** (decided at the first app open on or after Monday 04:00 local, then frozen for the week):

| Type | When | Evidence note shown in the detail view |
|---|---|---|
| `easy` | Any of: (a) `hrvTier == .suppressed` on ≥ 5 of the last 7 days with no illness flag; (b) illness heads-up raised in the last 3 days; (c) sleep debt ≥ 180 min at week start; (d) the last 3 weeks were all `build` and met ≥ 90 % of targets. (d) is *offered*: the wearer can decline, and declining is not penalised. | (a)–(c): the body's own signals. (d): "A lighter week is common coaching practice; direct evidence that it improves results is limited." |
| `hold` | Not easy, and either `b ≥ 300` (top of the WHO range: more is fine but not needed for health), or last week's load > 1.3 × `chronic`, or Foster monotony ≥ 2.0 (the existing `ReadinessEngine` monotony, computed on linear load) | "Big week-to-week jumps have been linked to more injuries in new runners." No ACWR "sweet spot" or injury-risk figure is shown. |
| `build` | Otherwise | none |

**Targets:**

| Component | build | hold | easy |
|---|---|---|---|
| Aerobic `mvpaEq` | `b < 150`: `min(150, b + max(20, 0.10 b))`. `150 ≤ b < 300`: `min(300, 1.10 b)`. Invariant: `≤ max(1.3 b, b + 20)`. Rounded to 5. | `round5(b)` | `round5(0.6 b)` |
| Hard sessions | 0 while `b < 150` (build the base first; vigorous minutes still count). Otherwise `min(2, round(mean hard/week over 4 weeks))`. When that mean is 0 and `b ≥ 150` for 3 weeks, the target is 1 and the card offers it as optional. | same as build, without the new-hard-session offer | 0 |
| Strength sessions | 2 (WHO), or 1 in the first week if the 4-week mean is < 1 | 2 | 1–2 at about two-thirds of the sets, loads held |
| Steps/day (only if reliable, see 3.4) | `m < P`: `min(P, round250(m + 1000))`, and never more than +1000 above last week's target. `m ≥ P`: `round250(m)`, i.e. hold, with no step-up past the plateau. | same | unchanged (walking is compatible with recovery) |

`P` (plateau) = 8,000 if age < 60, 7,000 if ≥ 60 or age unknown; from the lower edge of the plateau ranges in
Paluch 2022. When age is unknown the card says "7,000 — the lower end of where benefits level off".

**Mid-week load note:** when the week's accumulated load exceeds 1.3 × `chronic` before Sunday, one line
appears on the card: "This week is already well above your usual load — keep the rest easy." There is no push
notification.

#### 3.4 Step reliability gate

`stepsReliable` is true for a day only if one of these holds:
- **5/MG:** `ProfileStore.stepTicksPerStepCalibration != nil` (the wearer calibrated).
- **4.0:** `StepsEstimateEngine` confidence is ≥ building (≥ 3 phone-calibrated days) or a manual `k` is set.
- **Phone:** the day's steps come from Apple Health phone data.

**The gate is not met** when fewer than 70 % of the last 28 days are reliable, or there are fewer than 14
reliable days. Then there is no step target, and the card shows "—" with `stepsUncalibrated` and a link to the
calibration walk. The level's step penalty should use the same gate; flag this to the steps-vo2-audit agent.

#### 3.5 Day guidance: `DayGuidance` in `SA/WeekPlanEngine.swift`

Evaluated each morning after the night is scored. The first matching rule wins:

| Guidance | Rule |
|---|---|
| `rest` | Illness heads-up raised |
| `easy` | Week type is `easy`, **or** (`hrvTier == .suppressed` **and** (`charge < 34` or `sleepDebtMin ≥ 120`)) |
| `moveHard` | `hrvTier == .suppressed` **or** `charge < 34`. Hard sessions are not advised today; easy aerobic minutes and strength at held loads are fine. |
| `asPlanned` | Otherwise |

**Missing inputs:**
- `hrvTier == nil` (fewer than 14 valid nights): guidance uses the Charge band only, and the line says "HRV
  trend still calibrating (n of 14 nights)".
- `charge == nil` as well: `asPlanned`, with the line "No reading this morning". State is never invented.

**Why the 7-day tier leads and one night's Charge only moves a session:**
- The HRV-guided training studies used rolling HRV against a smallest-worthwhile-change band.
- One bad night shifts one session; it never cancels a week.

**Consumers of `DayGuidance`:**
- the week card's day line;
- `QuestDifficulty.targets` (S0 H9);
- the coach's week line.

It replaces `CoupledView.optimalStrainRange` as a *prescription*. The band stays only as a descriptive
"typical range" notch.

#### 3.6 Weekly review: `SA/WeekReview.swift`

**Inputs:** last week's frozen `WeekPlan`, the actual `DayActivity`, `WeeklyDigest` (reused for HRV/RHR/Rest
week-over-week), `SleepRegularity` (S2), the VO₂max series with provenance, and trial states (S1).

**Output:**
- **Plan vs done** per component: `met` (≥ 90 %), `partly` (50–90 %), `missed` (< 50 %) or `notMeasured`.
  Days whose guidance was easy or rest are excluded from the denominator of shortfalls. A shortfall the plan
  itself asked for is not a miss.
- **Trends:** 7-day ln RMSSD vs the normal band; mean RHR vs the 4-week mean; mean sleep vs need; wake SD.
- **VO₂max:** a monthly median ± 5 ml/kg/min, only when two consecutive months each have ≥ 2 valid run/walk
  sessions (`VO2MaxEstimator` session method, not the Uth fallback). Otherwise "—" with the reason. **It is
  never a target.**
- **One suggested change.** The first matching rule wins:
  1. A `missed` strength or aerobic target → "Put 2 strength sessions in the calendar — Tue and Fri worked for
     you before" (days chosen from the wearer's own past session weekdays).
  2. Wake SD > 45 min → "Keep wake time within 30 min of 07:00".
  3. Sleep debt ≥ 120 min → "Bedtime 22:30 this week".
  4. Otherwise "Keep the same plan".
- **Trial status line** from S1.

**Delivery:**
- **Screen:** the deterministic content, always.
- **Coach:** `WeekReview.coachBlock(maxChars: 500)`, registered with the context budget (token-budget agent).
  The "Review my week" preset should use it instead of re-deriving figures.
- **No push notification.** The review appears on the card when the app is next opened on Monday.

#### 3.7 File plan (S3)

**New, package** (`SA/`): `SessionIntensity.swift`, `WeekPlanEngine.swift` (includes `DayGuidance`,
`WeekType`, `WeekPlan` Codable), `WeekReview.swift`.

**New, app** (`Strand/Data/`):
- `SessionIntensityCache.swift`: computes `SessionIntensity` for workouts not yet cached.
  - It reads HR per session in chunks of ≤ 8,000 samples, because `Repository.hrSamples` caps at 8,000 and
    sessions over about 2.2 h would otherwise be silently truncated.
  - It writes day-keyed metricSeries (source `noop-activity`): `aerobic_mod_min`, `aerobic_vig_min`,
    `aerobic_hard_min`, `strength_session`.
  - Recomputed only for days with changed workouts, so it stays idempotent.
- `WeekPlanSource.swift`:
  - assembles `WeekPlanInputs` from the cache, `repo.days`, lift sessions (`liftSetsWithSessionStart`),
    `IllnessSignal` state, `SleepDebt` and the step gate;
  - freezes the week's plan in `week-plans.json` (store directory, last 26 weeks);
  - publishes `currentPlan`, `todayGuidance` and `lastReview`.

**New, screens** (`Strand/Screens/`): `WeekPlanCardView.swift`, `WeekReviewView.swift`.

**Hooks:**
- `HealthV2Refresh` (S1) calls `WeekPlanSource.refresh`.
- `SA/QuestDifficulty.swift` and `Strand/AI/QuestGenerator.swift` gain the `DayGuidance` argument (S0 H9;
  coordinate).
- `Strand/Screens/StrengthProgressionCardView.swift` (design package) reads `WeekPlanSource.currentPlan.type`
  to show "hold loads" in easy weeks.

**Not touched:** `RecoveryScorer` (Charge). Wiring `priorDayEffort` into Charge would change every
historical score and needs its own validation. It is recorded in §5.

#### 3.8 Tests

**`SAT/SessionIntensityTests`:**
- Class edges at exactly 0.40, 0.60 and 0.80.
- The 2-min gap cap.
- Overlapping sessions are unioned.
- Coverage below 50 % gives `unmeasured`, not 0.
- The imported-zones mapping is flagged.

**`SAT/WeekPlanEngineTests`:**
- Calibrating below 3 valid weeks.
- b = 0 gives a target of 20.
- b = 100 gives 120.
- b = 200 gives 220.
- b = 290 gives 300.
- b = 400 gives a hold at 400.
- Invariant sweep: for b = 0…400, the target is never above `max(1.3 b, b + 20)` and never above 300 in a build week.
- Each easy trigger works on its own; (d) is "offered" and a decline records no penalty flag.
- The hold trigger fires on monotony and on a load spike.
- Steps: m = 5,000 gives 6,000; m = 7,600 with P = 8,000 gives 8,000; m = 9,000 gives a hold at 9,000; an
  unreliable gate gives nil.
- DayGuidance precedence table: every row, plus nil tier and nil Charge.
- Determinism: the week plan is frozen once decided; re-running mid-week does not change it.

**`SAT/WeekReviewTests`:**
- An easy-day shortfall is not a miss.
- The VO₂max month rule excludes the Uth fallback.
- There is always exactly one suggestion.
- The coach block stays ≤ `maxChars`.

**App:** `StrandTests/SessionIntensityCacheTests` (chunked reads beyond 8,000 samples;
idempotent re-runs).

#### 3.9 Acceptance

1. A new wearer sees "calibrating (n of 3 weeks)" and the WHO range. No personal target appears before the
   baseline exists.
2. The aerobic target is never above `max(1.3 b, b + 20)` for the wearer's baseline b, and never above 300
   for build.
3. On a day with a suppressed HRV tier, no quest or card advises a hard session.
4. On an easy-guidance day, Relentless issues no training factor above 1.0.
5. Step targets appear only when the reliability gate passes.
6. Every Monday there is exactly one review with one suggestion, and no push notification.

---

### S4. Honest breathing sessions

**Goal.** Keep the existing Breathe experience (pacer, resonance sweep, haptics). Replace its outcome number
with a before/after the data can support, store each session, and feed sessions into the habit model and the
`breathing10` trial.

#### 4.1 What the wearer sees

**Session flow**: the pre and post phases are new; the pacing phase is unchanged.
1. **"Sit comfortably — 90 s quiet reading."** Breathe normally, no pacer. The first 30 s are discarded as
   settling.
2. **The paced session** (5–15 min) exactly as today.
3. **"Stay seated the same way — 90 s quiet reading."** Normal breathing; the first 30 s are discarded.

**Result card:**

```
Before  RMSSD 38 ms · HR 66
After   RMSSD 44 ms · HR 62      (+15 %, −4 bpm)
During  breathing-driven swing 14 bpm — this is expected to be high; it is the breathing itself
```

**Changes after the first sessions:**
- After ≥ 5 stored sessions, one comparison line appears: "a larger / similar / smaller change than your usual
  (+9 %)". It compares against the median of the wearer's own past session changes.
- No "improved" claim appears until then.
- A weekly trend of pre-session RMSSD shows in the Focus tab. It is descriptive; there is no target.

**When a quiet window fails its gate**, it shows "—" with the reason:
- `tooFewBeats` (the strap's R-R dropped out);
- `tooManyArtifacts`;
- `noLiveRR` ("the strap isn't sending beat-to-beat data right now — on a 5/MG this happens while the WHOOP app
  is also connected").

#### 4.2 Pure logic: `SA/BreathSessionOutcome.swift`

**Inputs:**
- `preRR`, `pacedRR`, `postRR` as `[ResonanceEngine.RrBeat]`;
- `paceBpm`, and the HR samples for each window.

**Per quiet window:**
- Drop the first 30 s.
- `HRVAnalyzer.analyze(rawRR:)`: range filter, Malik ectopic rejection, gap-aware RMSSD. The current
  uncleaned `computeRMSSD` must not be used.
- **Gate:** ≥ 40 clean beats **and** ≤ 20 % rejected. That is stricter than the spot reading's 35 %, because
  two 60-s windows are being compared.
- **Output:** `rmssd`, `meanHr`, `cleanBeats`, `rejectedPct`, or an abstention reason.

**Change:**
- `deltaPct = 100 × (exp(ln post − ln pre) − 1)` and `deltaHr = post − pre`.
- Present only when both windows passed.

**During:** the mean per-cycle HR swing (`ResonanceEngine`'s RSA measure over `pacedRR`). It is always
labelled as mechanical, and it **never enters** `deltaPct`.

**Personal comparison:** `usualDeltaPct` = median of past `deltaPct` over ≥ 5 sessions, with the spread as the
interquartile range. The label is:
- `larger` when `deltaPct > Q3`;
- `smaller` when `deltaPct < Q1`;
- `similar` otherwise.

Two 60-s windows are noisy; this label is descriptive, not a test.

#### 4.3 File plan (S4)

**New, package:** `SA/BreathSessionOutcome.swift`.

**New, app:**
- `Strand/Data/BreathSessionLog.swift`:
  - JSON `breath-sessions.json` in the store directory, holding each session's outcome, pace and minutes;
  - metricSeries `breath_session_min` (source `noop-habits`) per local day, read by `HabitLedgerSource`
    (`auto:breathingSession`) and by trial adherence (`breathing10`);
  - it does not write `meditation_min`, to avoid double counting with the level's Focus part. Whether breath
    sessions should count toward Focus is a level decision; flag it to level-audit.
- `Strand/Screens/BreathSessionRecorder.swift`: an `ObservableObject` phase machine (`preQuiet → paced →
  postQuiet → done`) that collects R-R from `RRPacketObserver` per phase.

**Hook:** `Strand/Screens/BreathingView.swift` (design package). `start()` calls `recorder.begin()`;
`stop()`/`captureOutcome()` call `recorder.finish()` and render its result. The existing rolling RMSSD tile may
stay as a live readout. It is no longer the outcome.

#### 4.4 Tests and acceptance

**`SAT/BreathSessionOutcomeTests`:**
- 39 clean beats gives `tooFewBeats`.
- 25 % rejected gives `tooManyArtifacts`.
- A synthetic R-R series with known successive differences gives the expected RMSSD (±0.5 ms).
- Paced-window beats never enter pre/post.
- The first 30 s are dropped.
- `deltaPct` is symmetric in log.
- The comparison label only appears at ≥ 5 sessions.

**Acceptance:**
- No session shows a percentage that is not computed from two gated quiet windows.
- Every completed session is persisted.
- `breath_session_min` appears in the habit ledger.

---

## 4. Coordination and file ownership

Assumption from the brief: **the design packages own the screen files**. Health features add new files and
minimal hooks. The Strand/AI token-budget agent owns `Strand/AI/**` this cycle, and another agent writes
`docs/DESIGN_V2.md`.

### 4.1 Existing files touched, by owner

| File | Spec items | Nature of the change | Owner to coordinate with |
|---|---|---|---|
| `Strand/App/AppModel.swift` | S1 (refresh hook), S0 H7 | 1-line hook; illness input filter | — |
| `Strand/Data/LiveStressMonitor.swift` | H1 | motion-coverage gate | nightly-stress-audit agent |
| `Strand/Data/DayAlerts.swift` | H2 | stop raising the optimum notice | — |
| `Strand/Data/QuestStore.swift` | H3, S1-B | no failure cards; skip `trial-` ids; delegate `checkOff` | penalty-system agent |
| `Strand/System/DayRitualScheduler.swift` | H4 | one default slot at anchor + 15 | token-budget agent (currently adding `budget: .ritual`) |
| `Strand/System/IllnessNotifier.swift` | H7, H8 | no push on `alreadyUnwell`; copy | — |
| `Strand/System/WindDownNudge.swift` | S2 | `reschedule(plan:)` | — |
| `Strand/Data/RoomClimateContext.swift` | S2 | plan-first schedule | — |
| `Strand/Data/WizLights.swift` | S1-A, S2 | daily record; follow the anchor | — |
| `Strand/Data/CaffeineLog.swift` | S1-A, S2 | daily summary; plan bedtime | — |
| `SA/QuestDifficulty.swift` | H9, S2, S1-B | `DayGuidance`, anchored bedtime, excluded metrics (one signature change) | Strand/AI agent (caller) |
| `SA/LevelEngine.swift`, `SA/LevelBaselines.swift`, `Strand/Screens/LevelWiring.swift`, `LevelLedger.swift` | H6 | load cap, HRV once, sleep-duration input, epoch bump | level-audit agent |
| `SA/CoachSuggestions.swift` | H14 | threshold axis | — |
| `Strand/AI/CoachLevelContext.swift`, `AICoach.swift`, `CoachExtraContext.swift`, `QuestGenerator.swift`, `CoachContextBudget.swift` | H5, H9, H12, S1-A, S3 | new objective text; register the habit and week blocks; drop the journal dump and `EffectRanker` lines; pass `DayGuidance` | **token-budget agent: hand over, do not co-edit** |
| `StrandiOS/App/RootTabView.swift` | H1, S1 | stress-screen subtitle string; More-list entry | design package |
| `Strand/Screens/BreathingView.swift`, `QuestPopupView.swift`, `InsightsHubView.swift`, `InsightsView.swift`, `StrengthProgressionCardView.swift`, `HealthAlertBanner.swift`, `HostedCards.swift`, `VitalSignsSummary.swift`, `Strand/Liquid/LiquidTodayView.swift`, Settings | H1–H3, H10–H13, H15, S3, S4 | hooks listed in each spec | design package |

### 4.2 New files, all health-owned

- **Package** (`SA/`):
  - habits: `HabitModel`, `HabitStats`, `HabitAssociation`, `HabitCoachSummary`, `HealthAbsence`;
  - trials: `HabitTrialCatalog`, `HabitTrialRegistration`, `HabitTrialSchedule`, `DeterministicRNG`,
    `HabitTrialAnalysis`, `HabitTrialVerdict`;
  - sleep: `SleepAnchor`, `SleepRegularity`;
  - movement: `SessionIntensity`, `WeekPlanEngine`, `WeekReview`;
  - breathing: `BreathSessionOutcome`;
  - plus a test file for each.
- **App** (`Strand/Data/`):
  - habits: `HabitLedgerSource`, `HabitAnalysisStore`, `CaffeineDailySummary`, `BedroomNightSummary`,
    `WizDailyRecord`;
  - trials: `HabitTrialStore`, `HabitTrialQuestBridge`;
  - `HealthV2Refresh`, `SleepScheduleProvider`, `SessionIntensityCache`, `WeekPlanSource`, `BreathSessionLog`.
- **Screens** (`Strand/Screens/`; styled by the design packages):
  - `HabitsHubView`, `TonightLogSheet`;
  - `HabitTrialSetupView`, `HabitTrialTodayCard`, `HabitTrialResultView`;
  - `TonightCardView`, `WeekPlanCardView`, `WeekReviewView`, `BreathSessionRecorder`.

### 4.3 Stores and backup

New JSON files live in the store directory: `habit-trials.json`, `week-plans.json` and `breath-sessions.json`.
New metricSeries use the sources `noop-habits` and `noop-activity`.

**Backup (`.noopbak`).** metricSeries rows are already in the database backup. The three JSON files and the
new UserDefaults prefs (`sleepAnchor.*`, `wiz.followSleepAnchor`, `stress.alertScreen.enabled`) are **not**
added to the `.noopbak` whitelist in 2.0, because of the Android codec parity contract. This is a known gap and
should be a follow-up PR.

### 4.4 Parity statement for PRs

**New engines are Swift-only.** H6, H9 and H14 change shared engines and diverge from Android. Each PR says so.

---

## 5. What not to build

| Don't build | Why |
|---|---|
| New daily strain targets from population bands, or more "you've done enough" alarms | Not personal, and they push beginners toward spikes. The existing Optimum screen stays by coordinator decision but is re-triggered from S3's day guidance and loses its "paid for tomorrow" overclaim (H2). |
| ACWR "sweet spot" or injury-risk percentages | The ratio's predictive validity is contested (coupling artefacts); showing a risk figure is false precision. A plain ramp note is enough. |
| Calendar-fixed deload every 4th week | Little direct evidence of benefit (Coleman 2024). Easy weeks are triggered by the body's signals, or offered, not imposed. |
| "Zone 2" as a branded target, or lactate-threshold claims from wrist HR | Weak zone-specific evidence; HR zones are not lactate thresholds. Aerobic minutes carry the benefit. |
| VO₂max or Fitness Age as a goal or quest | Estimate error (±5 ml/kg/min) exceeds realistic monthly change, so the wearer would chase noise. Show a trend with a band only. |
| Deep/REM stage targets, stage-based quests, "sleep score" streaks | Staging is not validated on 4.0 (V2 kappa 0.356 on PSG replay), and chasing sleep numbers can itself cause sleep anxiety (orthosomnia). |
| Real-time stress push notifications | HR-only index, weak specificity; alarming raises arousal. Breathing stays one tap away. |
| Expanding illness detection (a named-illness risk score, a COVID-style classifier) | Retrospective evidence, low PPV, no actionable step beyond rest; high anxiety cost. Keep the opt-in heads-up, bug-fixed. |
| Supplement, medication, fasting, caloric-restriction, cold/heat-exposure or sleep-restriction trials | Medical risk, or outside what an app should randomise. Excluded by catalogue rule. |
| Free-text trials or coach-invented experiments | No pre-registration discipline; a door to unsafe or unmeasurable interventions. |
| Pooling or extending trials after seeing results; showing interim estimates | This is p-hacking by another name. Enforced in the store API. |
| Wiring `priorDayEffort` into Charge in 2.0 | It changes every historical score, breaks parity, and needs its own validation study. Day guidance already uses load explicitly. |
| SpO₂ features | The 4.0 value is deliberately nil; 5/MG candidates are unvalidated and moved the opposite way on one device. |
| Wiring the unused engines (`PreSleepHeartRateFeedback`, `SleepHeartRateContrast`, `CircadianEngine.planShift`, `AdaptiveExpenditureEngine`) into UI | They add numbers, not behaviour change. Revisit only with a behaviour they would drive. |
| Leaderboards or social comparison | Out of scope for an offline app, and the populations are not comparable. |
| A composite "healthspan" or "biological age" score | It combines thin estimates into one confident-looking number. The level already covers the "one number" need, with coverage honesty. |
| A light-therapy claim for WiZ bulbs | Indoor bulbs deliver a small fraction of daylight's intensity; S2 uses them for evening dimming, and the copy points to outdoor light for the morning. |

---

## 6. Evidence references

The short honest effect statement next to each source is what the app may say. Nothing stronger.

**Physical activity and fitness**
- **Bull FC et al. 2020, *Br J Sports Med*.** WHO guidelines: 150–300 min moderate or 75–150 min vigorous
  aerobic activity per week, plus ≥ 2 days of muscle strengthening.
- **Arem H et al. 2015, *JAMA Intern Med*.** Mortality benefit rises up to about 3–5× the minimum, then plateaus
  (pooled cohorts; observational).
- **Paluch AE et al. 2022, *Lancet Public Health*.** Steps and mortality in 15 cohorts: risk falls, then
  plateaus around 6–8 k/day (≥ 60 y) and 8–10 k/day (< 60 y). Observational.
- **Saint-Maurice PF et al. 2020, *JAMA*; Ding D et al. 2025, *Lancet Public Health*.** Largest step-related
  gains at the low end. Observational.
- **Kodama S et al. 2009, *JAMA*; Mandsager K et al. 2018, *JAMA Netw Open*.** Higher cardiorespiratory fitness
  is associated with lower all-cause mortality (≈ 13 % per MET). Observational.
- **Milanović Z et al. 2015, *Sports Med*.** HIIT and continuous training both raise VO₂max; HIIT slightly more.
- **Garber CE et al. 2011, *Med Sci Sports Exerc* (ACSM position stand).** Intensity classes by %HRR.

**Strength training**
- **Momma H et al. 2022, *Br J Sports Med*.** Muscle-strengthening activity is associated with 10–20 % lower
  mortality at 30–60 min/week, with a J-shaped curve. Observational.
- **Schoenfeld BJ et al. 2017, *J Sports Sci*.** Weekly set volume shows a dose-response with hypertrophy.
- **Williams TD et al. 2017, *Sports Med*.** Periodised programmes beat non-periodised ones for 1RM strength
  (moderate effect).
- **Coleman M et al. 2024, *PeerJ*.** A one-week deload showed no benefit for hypertrophy or strength in
  trained lifters.

**Training load and HRV-guided training**
- **Nielsen RO et al. 2014, *J Orthop Sports Phys Ther*.** Novice runners with > 30 % weekly distance
  increases had more distance-related injuries.
- **Buist I et al. 2008, *Am J Sports Med*.** A graded "10 %" programme did not reduce injuries.
- **Impellizzeri FM et al. 2020, *Int J Sports Physiol Perform*; Lolli L et al. 2019, *Br J Sports Med*.**
  Critiques of ACWR.
- **Plews DJ et al. 2013, *Int J Sports Physiol Perform*.** 7-day rolling ln RMSSD and the
  smallest-worthwhile-change band.
- **Kiviniemi AM et al. 2007, *Eur J Appl Physiol*; Vesterinen V et al. 2016, *Med Sci Sports Exerc*;
  Javaloyes A et al. 2019, *Int J Sports Physiol Perform*.** HRV-guided endurance training performed as well as
  or better than predefined plans, often with fewer hard sessions.
- **Granero-Gallegos A et al. 2020, *Int J Environ Res Public Health*; Düking P et al. 2021, *Int J Environ
  Res Public Health*.** Meta-analyses: small or unclear advantages for VO₂max and performance; small samples.

**Sleep, light and temperature**
- **Windred DP et al. 2024, *Sleep*.** In UK Biobank accelerometry (~60 k), sleep regularity predicted
  mortality more strongly than duration. Observational.
- **Phillips AJK et al. 2017, *Sci Rep*.** Definition of the Sleep Regularity Index.
- **Wittmann M et al. 2006, *Chronobiol Int*.** Social jet lag.
- **Qaseem A et al. 2016, *Ann Intern Med* (ACP).** CBT-I is first-line for chronic insomnia.
- **Tasali E et al. 2022, *JAMA Intern Med*.** Sleep extension in short sleepers reduced energy intake by about
  270 kcal/day (RCT).
- **Mah CD et al. 2011, *Sleep*.** Sleep extension improved athletic performance (small study).
- **Gooley JJ et al. 2011, *J Clin Endocrinol Metab*.** Room light before bed suppresses and shortens melatonin.
- **Chang AM et al. 2015, *PNAS*.** Light-emitting e-readers before bed delayed circadian timing and impaired
  next-morning alertness.
- **Okamoto-Mizuno K & Mizuno K 2012, *J Physiol Anthropol*; Baniassadi A et al. 2023, *Sci Total Environ*.**
  Bedroom temperature affects sleep, and the optimum is individual.

**Habits: caffeine and alcohol**
- **Drake C et al. 2013, *J Clin Sleep Med*.** Caffeine taken even 6 h before bed disrupted sleep.
- **Pietilä J et al. 2018, *JMIR Ment Health*.** Alcohol dose-dependently reduced nocturnal HRV-based recovery.

**Breathing and HRV biofeedback**
- **Lehrer PM & Gevirtz R 2014, *Front Psychol*.** The resonance-frequency rationale.
- **Lehrer PM et al. 2020, *Appl Psychophysiol Biofeedback*.** Meta-analysis: small-to-moderate effects across
  outcomes.
- **Goessl VC et al. 2017, *Psychol Med*.** HRV biofeedback reduced self-reported stress and anxiety; study
  quality caveats.
- **Laborde S et al. 2022, *Neurosci Biobehav Rev*.** Slow breathing increases vagally mediated HRV during and
  after sessions; no clear advantage of an individual resonance frequency over ~6/min.

**Illness detection**
- **Mishra T et al. 2020, *Nat Biomed Eng*; Miller DJ et al. 2020, *PNAS*; Smarr BL et al. 2020, *Sci Rep*.**
  Retrospective pre-symptomatic deviations.
- **Alavi A et al. 2022, *Nat Med*.** Real-time alerting: many alerts not caused by illness.

**Tracker-related sleep anxiety**
- **Baron KG et al. 2017, *J Clin Sleep Med*.** Orthosomnia.
- **Gavriloff D et al. 2018, *J Sleep Res*.** False negative sleep feedback worsened daytime symptoms.

**Behaviour change**
- **Michie S et al. 2009, *Health Psychol*.** Self-monitoring combined with other self-regulation techniques
  (e.g. goal review) was the most effective combination.

**N-of-1 method**
- **Kravitz RL, Duan N (eds.) 2014, AHRQ,** *Design and Implementation of N-of-1 Trials: A User's Guide*.
- **Vohra S et al. 2015, *BMJ*,** CENT statement.
- **Edgington ES & Onghena P 2007,** *Randomization Tests* (4th ed.).
- **Newey WK & West KD 1987, *Econometrica*.** HAC standard errors.
- **Benjamini Y & Hochberg Y 1995, *J R Stat Soc B*.** False discovery rate.
