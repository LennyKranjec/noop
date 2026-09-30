# Telos 2.0 — Design Specification

Status: **binding spec for the 2.0 redesign (iOS)**. Author: design direction. Scope: the iOS app
(`NOOPiOS`), its widget extension, and the shared `Strand/` + `Packages/StrandDesign` sources it
compiles. Android, watchOS and the macOS shell are **not** redesigned here, but every shared file must
keep compiling for them (see §2.2).

How to use this document: §1 is the idea, §2 the constraints no package may break, §3 what exists and
what we keep, §4 the tokens (exact values), §5 the components, §6 the screens, §7 motion, §8 who builds
what in which order, §9 the risks. Where this spec and a source comment disagree, **this spec wins for
visuals**; the code wins for behaviour and data. Where this spec is silent, use the nearest component in
§5 unchanged — do not invent.

Naming used below: *Rest / Charge / Effort* are the three daily scores (sleep performance, recovery,
strain). *Level* is the 0–100 composite with five parts (sleep, heart, lungs, muscle, focus) drawn as the
pentagon radar. *Package* means one implementation agent's unit of work (§8).

---


> ## VISUAL DIRECTION — KEY REFERENCE (owner, binding; supersedes the colour/mood parts of §1 and §4)
>
> Reference images (open them before designing anything): `docs/design-ref/telos-v2-today.jpg` — the Today
> ("Home") screen to recreate **one to one** (adapting only content), and `docs/design-ref/telos-v2-screens.png`
> — the family of screens (Biometrics, Sleep & Recovery, Nervous System, Training Coach, Metabolic Engine,
> Mind & Focus, Environment) showing how every tab should look.
>
> **Mood:** organic, bioluminescent, alien. Dark near-black backgrounds with subtle depth; shining lights;
> dotted/particle fields; glowing organic blobs; thin luminous rings and scales; abstract, technological,
> futuristic — "as if the app served to breed an alien-like human". Wordmark "T E L O S" (wide tracking) with
> the subline "BIOLOGICAL OPTIMIZATION ENGINE".
>
> **Palette (from the references):** background ≈ #05090A → #0B1214 with a faint green-teal vignette;
> primary bioluminescent green ≈ #3CF0A0 (glow #2BD98B); teal/cyan ≈ #3FD6D0; effort blue ≈ #3A8DFF;
> rest pale blue ≈ #A9C8FF; violet/magenta for mind/sleep ≈ #8B5CFF / #C45CFF; warm amber/orange for
> metabolic/fuel ≈ #FF8A3D / #FFB547; warning sun-yellow ≈ #FFC94A. Text: primary #E8F2F0, secondary ≈ 60 %.
> Contrast rules from §2 still apply — tune values so body text passes 4.5:1.
>
> **Tiles:** "futuristic transparent glass": dark translucent fill (≈ 6–10 % white over the background),
> a 1 pt luminous gradient hairline border (brighter top-left), large radius (~22–26 pt), a faint inner
> glow at the top edge, generous dark negative space. Metric labels in small caps with wide tracking; big
> numbers light/regular weight; thin icon glyphs in the accent colour.
>
> **Today / Home layout (recreate 1:1):** wordmark header with a small ring button at top right; LEVEL block
> left (big number, tier word e.g. "SUPERHUMAN" in green caps, "↑ +24 pts" delta, "◇ × 1.00" multiplier);
> centre the glowing organic 3-D blob of dotted particles with thin orbit ellipses and two small orbiting
> glowing dots; right a thin progress ring with a percentage and a status word ("87 % OPTIMAL"); a pill row
> "☼ Today · date | temperature | humidity"; a glowing pill for the window advice ("Open now · shut 10:35 ›")
> with dotted light trails; a glass panel with three large thin rings REST / CHARGE / EFFORT (values inside,
> label below, a small glyph and a secondary line); a glass strip of three compact metrics (Body temp · HRV ·
> UV index); a "TODAY'S MISSION" glass card with title, subtitle and a round chevron button; a floating glass
> tab bar with a glowing selected pill: Home · Biometrics · Focus · System · More. Content adapts to the
> app's real data and honesty rules (e.g. "—" plus reason when absent; the level stays unbounded; confidence
> tags where a value is provisional); every existing Today feature must still be reachable below this hero
> (State tile, workouts today, quests + penalties, sleep panel promotion in the evening, etc.).
>
> **Performance — how to get this look cheaply (binding, the owner reports lag):** "glass" is faux-glass
> (translucent fill + gradient stroke), NOT `.ultraThinMaterial`/live blur behind scrolling content; glows
> are pre-composited gradients/radial fills or a single `.shadow` on a small static element, never stacked
> blurred shadows per card; particle fields and the blob are drawn with `Canvas` into a cached layer
> (`drawingGroup`) and animate only while visible, at ≤30 fps, pausing offscreen and under Reduce Motion /
> Low Power (a still frame then); rings animate only on value change. If a flourish costs frames on an
> iPhone 12 Pro, simplify it — keep the look, drop the cost.
>
> ## COORDINATOR DECISIONS — binding, they override anything below that disagrees
>
> Recorded by the coordinator on behalf of the owner, who asked for full autonomy. Every package must
> follow these; where a section of this document or of `HEALTH_V2.md` says otherwise, this block wins.
>
> 1. **Penalties are real and visible (owner's explicit request).** The once-a-day failure card for unmet
>    quests IS a red, consequential card with exact numbers (what was missed, by how much, what it cost) —
>    not a neutral summary. One card per day, never a stack of modals. The pinned penalty/debt block above
>    the quest chips stays as specified in §5.14.
> 2. **Penalise behaviour, never physiology.** Penalties may apply to what the wearer DOES: steps, water,
>    workout minutes, meditation minutes, journal, bedtime. They never apply to what the body DOES: HRV,
>    resting HR, Charge/recovery, stress, sleep score/Rest, sleep hours as an outcome. Trial (n-of-1) quests
>    are never penalised on either arm. Unmeasured metrics are never penalised. Penalties touch the game layer
>    only (XP, rank, streaks, debt quests) and never the measured health Level.
> 3. **The Focus tab stays.** Do NOT replace it with Habits. The Habits hub is reached from a primary entry
>    in Today (next to the quest strip / the running trial's card), from the Coach, and from More. The daily
>    trial assignment reaches the wearer as a quest in Today, so no tab is needed for the one-tap entry.
>    The Android tab bar therefore does not diverge.
> 4. **No owner-requested feature is removed.** (Later owner decision: the stress ALERT that pops up on its own
>    is OFF by default from 2.0 — the diagnostic screen stays reachable from the stress tile and the alert can be
>    re-enabled in Settings.) The "Optimum reached" full-screen, the full-screen stress
>    diagnostic with BREATHE / IGNORE, the step-calibration tile, the wake-buzz alarm, the State tile's
>    WORKOUTS TODAY with its gear/checklist/+/✕, the level widget, the window-ventilation advice, the morning
>    gate and the Steady/Push/Relentless gear choice all stay. They may be restyled; they may not be dropped
>    or hidden behind a new opt-in. Where `HEALTH_V2.md` proposes removing or defaulting one of them off,
>    keep it on and restyle instead.
> 5. **Performance budget in §2 is binding and is checked in the final audit.** A package that cannot meet
>    it for a flourish drops the flourish.
> 6. **Translations:** packages do not edit `Localizable.xcstrings`; the coordinator's integration pass does.
> 7. **Full-screen moments (owner's direction for 2.0).** The significant interactions become immersive,
>    full-screen moments instead of small cards and alerts: a quest being issued, a quest completed, the
>    daily failure / penalty card, a debt cleared, the day's gear choice, a trial's daily assignment and its
>    final verdict, the level settling for the day, coach messages the app pushes (not the chat itself), the
>    stress diagnostic and the "Optimum reached" moment. Routine browsing (Today's tiles, charts, lists)
>    stays in cards. Rules:
>    - ONE global presenter: a single `TelosMomentPresenter` hosted once at the app root with a queue
>      (priority-ordered, one at a time, never stacked, deduped per day where the moment already has a
>      fire-once guard). No screen attaches its own `.fullScreenCover` for these moments — that is exactly
>      the torn-down-presenter bug this project has shipped three times.
>    - Every moment is dismissible with one tap or a swipe down, never traps the wearer, and is suppressed
>      (queued) during an active workout, the morning flow, or while another sheet is up.
>    - Anatomy: full-bleed backdrop drawn from the living-instrument language (liquid fill / organic form
>      that encodes the moment's data — e.g. the vessel filling to the completion fraction), a headline, the
>      exact numbers, one primary action. Motion must encode data; Reduce Motion gets a cross-fade.
>    - Performance: the backdrop animates only while visible and for at most the entrance + one settle
>      (≈1.2 s), then rests; content underneath pauses (it is covered). No blur over live content.
> 9. **The Level is unbounded (owner's explicit decision).** No cap, ceiling, clamp, saturation or
>    diminishing-returns curve on the level or any of its parts — the only bound is the wearer's physiology.
>    100 means the wearer's own 95th percentile, not a maximum. Any UI (radar, bar, widget, gauges, full-screen
>    moments) must render values above 100 honestly: axes and vessels scale or overflow visibly rather than
>    clipping at 100, and no copy calls 100 "max". Correctness fixes (e.g. HRV counted once) are allowed; limits
>    are not. `HEALTH_V2.md` H6's load cap is overridden.
> 10. **Meditation is a penalty-only input to the Level (owner's explicit decision), for comparability.** The
>    Level's positive side uses only inputs that exist across the whole history (strap/WHOOP physiology and
>    workouts), so January and today are scored by the same recipe. From the first day with a logged
>    meditation onward, a day under the meditation minimum subtracts a documented penalty; before that day
>    there is no meditation term at all. This is the single exception to "penalties never touch the Level".
>    UI consequence: the level breakdown must not show meditation as a positive contributor; it may show a
>    missed-meditation deduction as its own line.
> 11. **Size to content — density (owner's direction).** No panel is bigger than what it shows. A tile that
>    carries one attribute (HRV, resting HR, respiratory rate, SpO₂, skin temp, steps, water …) is a compact
>    tile: number + unit + delta/confidence + an optional micro-sparkline, laid out several per row (a 2-, 3-
>    or 4-column grid chosen by content width and Dynamic Type, never a full-width card for one number).
>    Cards hug their content: no fixed minimum heights, no decorative padding, no empty hero areas; the
>    spacing scale's smaller steps are the default inside cards. Large surfaces are reserved for content that
>    needs them (charts, the hero, the full-screen moments). Dynamic Type still must not clip — compact tiles
>    reflow to fewer columns at large text sizes rather than truncating. Applies to every screen; TODAY and
>    BODY are the first places to fix.
> 12. **Meditation history glow-up (owner's direction).** The Focus tab's per-day meditation log is too
>    simplistic. Replace it with a real practice view: a calendar/heat-map of the meditation era (from the first
>    logged session) where each day's cell encodes minutes against the day's minimum (10 minutes from
>    2026-09-29, 5 minutes before — the threshold is date-effective, so past days keep the rule they were set under); the current and best
>    streak; weekly minutes as a compact bar series; the session list with time, duration and — where the new
>    honest breathing sessions (HEALTH_V2 S4) recorded one — the before/after reading or "—" with its reason;
>    and, because meditation is now a penalty-only Level input (item 10), the missed days in the era marked
>    plainly with the Level deduction each cost. Days before the era are shown as "not tracked yet", never as
>    missed. Ownership: the BODY package (P6, which owns the Focus screen) builds the view; the MeditationCardView
>    part in PROGRESS part A adopts the same visual language. The data comes from the existing meditation log —
>    no new storage.
> 13. **Look ahead — projections (owner's direction, key 2.0 feature).** A "Look ahead" view projects where the
>    wearer will be in 4 / 8 / 12 weeks on two scenarios side by side: **"on your current trend"** and **"if you
>    follow the plan"** (the weekly movement plan, sleep anchor and gear). Metrics: the Level and its measured
>    parts, resting HR, HRV, VO₂max (with its ±5 error band), weekly aerobic minutes, steps, and strength
>    (estimated 1RM per main lift). Honesty is the whole design problem:
>    - every projection is drawn as a widening band (prediction interval), never a single line, and the band
>      is computed, not decorative;
>    - the "current trend" uses a robust trend over the wearer's own recent weeks; the "plan" scenario uses the
>      wearer's own measured response where it exists (e.g. their dose-response from past weeks) and literature
>      priors only where it doesn't, labelled as such, with wider bands;
>    - a metric with too little history, or a trend that is not distinguishable from noise, abstains ("not
>      enough history to project" / "no clear trend") instead of drawing a line;
>    - physiological ceilings and floors are not invented; the Level projection stays unbounded (item 9);
>    - copy says "projection", never "you will"; the horizon is capped where the interval becomes uninformative.
>    Placement: its own screen, reached from the Level breakdown, the Health tab and the weekly review, plus a
>    compact "in 8 weeks" line inside the Level breakdown. Built by health package HF (new files); the design
>    packages add the entry points.
> 14. **Goals (owner's direction, key 2.0 feature — built together with Look ahead, item 13).** A Goals screen,
>    reached from More (and from the Level breakdown and Look ahead), laid out like a calendar: the wearer sets,
>    for any metric (Level and its parts, resting HR, HRV, VO₂max, weekly aerobic minutes, steps, estimated 1RM
>    per lift, sleep regularity, meditation minutes …), a target value on a target date. The calendar shows
>    goals as dated markers, the months between as the projection bands from Look ahead, and each goal's
>    status. Each goal gets an honest feasibility verdict computed from the required rate of change versus
>    (a) the wearer's own projection band and (b) documented physiological rates of change: **on track** /
>    **ambitious but plausible** / **unrealistic at this date — here is a realistic date or value** /
>    **can't judge yet (too little history)**. No verdict is shown without its reasoning numbers.
>    - The coach receives the active goals (target, date, current value, required weekly rate, verdict) as a
>      compact dated block inside its token budget, plans toward them (the weekly plan, gear suggestions and
>      quests may reference a goal), and says plainly when a goal is too ambitious — including what would make
>      it realistic.
>    - A short coach panel sits on the Goals screen (a compact prompt row + the latest answer), reusing the
>      coach engine and its budget — not a second chat implementation.
>    - Goals never alter measured values; the Level stays unbounded; reaching a goal is a full-screen moment
>      (item 7). A missed goal date produces an honest review, not a penalty (goals are aspirations; the
>      penalty system stays on daily quests).
>    Built by health package HF (new files + minimal hooks); the design packages add entry points in More,
>    the Level breakdown and Look ahead.
> 15. **A dynamic, context-aware Today (owner's direction).** Today reorders itself by time of day and state,
>    so the thing that matters now is on top. Concretely:
>    - **Evening → night:** the Sleep panel appears from the evening (18:00, or the wind-down start from the S2
>      sleep anchor if that is earlier) until the next morning, and it sits at the TOP of Today, with its
>      recommendations (improved in 2.0 from the sleep anchor: tonight's bedtime target, wind-down start,
>      caffeine cut-off, the room's window/temperature advice, the WiZ light plan, sleep debt pay-back) right
>      there. In the morning it disappears again (after wake + the morning flow, or by 10:00 at the latest).
>    - **Morning:** last night's result, the gear choice / today's quests and any penalty board on top.
>    - **Day:** the State tile with what's left today, the workout suggestions, and climate focus advice.
>    - **During a workout:** the live workout card first.
>    - Other time-bound cards (e.g. an active trial assignment, a goal milestone, a stress alert follow-up)
>      rise when they are relevant and settle when they are not.
>    Rules: one pure, tested ordering function (inputs: clock, sleep-anchor schedule, workout state, open
>    penalties/trial/goal events, the wearer's own Today layout preferences) in a NEW logic file; the wearer's
>    customised order is respected as the base order and dynamic promotion only lifts the time-relevant cards
>    above it; nothing the wearer hid is ever shown; movement between positions animates with the settle
>    token (cross-fade under Reduce Motion) and never jumps while the wearer is scrolling. Owned by the TODAY
>    package (P4) plus that new logic file; the SLEEP package supplies the evening sleep panel component.
> 16. **Telos Lift — the in-app strength logger that replaces Alphaprogress (owner's direction, key 2.0
>    feature).** When a strength workout starts, Telos opens its own logger inside the live workout (the HR,
>    zones and effort keep running underneath):
>    - **Programs** imported from the Alphaprog plan export (`Lower` → Lower A (Di) / Lower B (Fr); `Upper` →
>      Upper A (Mo) / Upper B (Do); each exercise with equipment, target sets and target reps) and fully editable
>      in the app afterwards: add/remove/reorder exercises, change equipment, sets, rep target, set type
>      (working / warm-up / drop / failure), rest time per exercise. The owner's plan file ships as a test fixture;
>      the import lives in Data Sources and in the logger's empty state.
>    - **Per-set rows** like the reference screenshot: # · KG · WDH · e1RM, a check to complete the set; warm-up
>      sets collapsible above; the previous session of the same day shown underneath ("Last time · Lower A (Di)");
>      new rows prefilled from last time; weight and reps adjusted with steppers and a wheel/drop-down whose steps
>      come from the wearer's own increments per machine (inferred from history, e.g. 2.5 kg or 8 kg plates).
>    - **Rest timer** starts when a set is checked: default **2:30**, adjustable per exercise and on the fly (±15 s),
>      shown as a large pill; at zero the **strap buzzes** (plus a phone haptic when the app is foreground), so the
>      phone can stay in the pocket. Honest delivery rules from the strap-cue system apply.
>    - **Progression proposal** per exercise before the first working set: the double-progression suggestion from
>      `StrengthProgression` (+reps within the range, then one observed increment; hold on easy/low-Charge days per
>      the week plan; deload when stalled per its rules), with an optional one-line coach note inside the token
>      budget. Shown as a suggestion, never auto-applied.
>    - **Finish** is always reachable in the header; it becomes the prominent primary action once every planned
>      set is done. Finishing early asks once and records unfinished sets as not done (never as zero).
>    - **Finish screen** (a full-screen moment, item 7): the session's star/count badge, workout count, duration,
>      streak, exercises with their set count, PRs and e1RM change, **muscle groups with % change** in volume versus
>      the previous comparable session (honest: "—" when there is no comparable session), achievements, and a
>      share action — with a vivid celebration animation and a strap reward buzz for PRs.
>    - Data: sets persist to the existing `liftSession`/`liftSet` tables so StrengthProgression, the muscle model,
>      the Level's strength term and the coach all read one source; a session logged in Telos and the same session
>      later imported from Alphaprog must not double count (dedupe by start time ± tolerance and day template).
> 17. **Rewarding and punishing, vividly — within the performance budget (owner's direction).** Big rewards (a PR,
>    a quest or goal completed, a debt cleared, the level settling above yesterday, a trial finishing) and
>    penalties (the daily penalty card, a broken streak) get full-screen moments with lively but short animations
>    (particles/liquid, ≤1.5 s, then rest; Reduce Motion → cross-fade) and a **strap buzz** from the vocabulary:
>    a reward pattern and a heavier penalty pattern, counted in the strap-cue daily budget, never during sleep,
>    never twice for one event. Everyday UI is more alive too — values count up when they change, cards settle
>    in, charts draw in — but nothing animates without a data change, and nothing loops offscreen.
> 18. **The Home blob is a data object, not decoration (owner's direction).** The organic particle orb from the
>    reference image is driven by real numbers: its size and particle density grow with the Level (unbounded —
>    a slow soft curve plus extra shells at high levels, never a hard cap); its colour mix shows each Level part's
>    share (sleep/heart/muscle/lungs/focus tints); surface turbulence follows today's stress; its pulse follows
>    heart rate (slowed visually); glow follows Charge; the orbiting dots' speed follows effort vs target. A
>    calibrating/building level renders as a sparser, dimmer "assembling" orb; absent inputs give a neutral dim
>    still orb — never a fabricated state. Transitions animate only when a value changes; performance rules apply.
> 8. **Haptic, organic feel (owner's direction for 2.0).** Define ONE haptic vocabulary in the design system
>    (P1 owns `Haptics.swift`): named patterns — select (light tick), settle (soft), commit (rigid), success,
>    warning, failure/penalty (a heavier two-beat), level-settle (a slow three-step rise), and a subtle
>    heartbeat-like pulse reserved for full-screen moments that concern the heart. Use Core Haptics
>    (`CHHapticEngine`) where available for the organic curves, with a `UIFeedbackGenerator` fallback, one
>    engine instance, honour the app's existing haptics setting and Reduce Motion/Low Power, never fire two
>    patterns for one action, and never haptic-spam lists or scroll. Every package maps its interactions to
>    this vocabulary instead of calling generators directly. Organic motion: springs without bounce for
>    data, a gentle overshoot only for the wearer's own direct manipulation (drag, press release).

## 1. The concept — "Living Instrument"

Telos reads a living body with a precision instrument, and the design says exactly that. **Organic** is
the *specimen*: the body's scores are liquid held in vessels — fills that rise and settle with a
biological, critically-damped ease, soft continuous-curvature shapes, the day's sky behind the header.
**Technical** is the *instrument* around the specimen: hairline graduated bezels and scales, carets that
mark a target, monospaced labels and timestamps, every reading carrying its provenance and its
confidence like a lab printout. **Dynamic** means the liquid only moves when the data moves: a fill
settles when a score changes, the heart-rate thread advances when a beat-sample arrives, a caret slides
when a target is recomputed — and when nothing is happening, nothing moves. One mood: *a calm lab bench
at night, one lamp on, the specimen glowing faintly in its flask.* Numbers are rounded and friendly
(SF Rounded); everything that *qualifies* a number — unit, scale, time, source, confidence — is set in
SF Mono. Improvement is the point of the app, so the design always answers three questions in this
order: **where am I** (the reading), **how sure is that** (confidence and provenance), **what moves it**
(levers, quests, trials).

---

## 2. Hard constraints (every package, every screen)

### 2.1 Performance is a first-class requirement

Reference device: **iPhone 12 Pro (A14, 60 Hz)**, the owner's phone, which has reported lag. Budgets are
measured with Instruments (Time Profiler + Animation Hitches) on that class of device, Release build.

| Situation | Budget |
|---|---|
| Any screen idle (no touch, no strap stream) | **0 per-frame clocks running**; CPU < 2 % over 30 s |
| Today with strap streaming 1 Hz HR | ≤ 1 subtree invalidation/s, confined to the HR card leaf; CPU < 5 % |
| Scrolling Today / Health / Sleep / Workouts | 60 fps; hitch time < 5 ms/s; no frame > 33 ms |
| A value change (fill settle, count-up) | ≤ 1.2 s of per-frame drawing, ≤ 3 Canvases at once |
| Sheet presentation over Today | background frame loops paused (`noopBackgroundCovered`) |
| Launch to first Today frame | no regression vs 11.7.0 |

Rules (each one is checked in review, §9):

1. **No always-on animation.** `TimelineView(.animation…)` is allowed only while something is *settling*
   or *live* (list in §7.3), must be `paused:` by `NoopMotionState.poseStill(_:)`, by
   `\.noopBackgroundCovered`, and by the `liquidOffscreen` gate, and must request ≤ 60 fps (the panel is
   60 Hz; asking for more buys nothing on the reference phone). The `QuietMotionCoverageTests` census
   must stay green — any new file with a loop must name the gate.
2. **No blur, no `Material`, no `.drawingGroup()` / `.compositingGroup()` over or inside scrolling
   content.** The six existing `Material` uses (LiquidTodayView, LiveWorkoutView,
   WorkoutSelectionScreen) are replaced by the solid glass fallback (§4.9).
3. **Glass only on the five static chrome roles in §4.9.** Never on cards, tiles, chips, rows, charts,
   the level strip, or anything inside a scroll view's content except the Today header cluster.
4. **Shadows only where they cannot stack:** cards, tiles and rows cast **no shadow in either scheme**
   (separation by fill + 1 pt line). At most 3 shadowed views on screen; never a shadowed view inside
   another shadowed view.
5. **Narrow observation.** No view may observe `LiveState`, `AppModel`, `AICoachEngine` or `Repository`
   broadly *for a single field*. Live values are read in leaf views (the `LiquidLiveHR` pattern); a shell
   or screen that needs one flag uses the de-duplicated publisher pattern already in `RootTabView`
   (`appModelRef` + `.onReceive($field.removeDuplicates())`). No package may add a new broad observer;
   a package that touches a file with one for a single field converts it.
6. **Tokens are `static let`.** A computed `Color(light:dark:)` builds a new dynamic provider per access;
   inside Canvas loops that is measurable. New tokens are stored lets; branching tokens cache both arms.
7. **No per-card `@AppStorage`.** `FrostedCardSurface` currently subscribes every card to UserDefaults;
   V2 reads card opacity from an environment value set once at the root (§8, DS + FRAME).
8. **Every flourish names its cost** in a code comment at its call site: what runs, how often, for how
   long, and what pauses it.

### 2.2 Deployment targets

- iOS app + widgets: **iOS 17.0** floor (`project.yml`: `NOOPiOS`, `NOOPWidgets` → `deploymentTarget
  "17.0"`). macOS shared target: **13.0**. `StrandDesign` also builds for **watchOS 10** — new files in
  the package must compile there (guard with `#if !os(watchOS)` where they use Charts or hover).
- iOS 26 Liquid Glass is allowed **only** behind `if #available(iOS 26.0, *)` inside `#if os(iOS)`, with
  a faithful fallback, and **only** through the existing `nativeLiquidGlass*` helper family
  (`NoopLiquidGlassSearchField.swift` + the app-side role helpers). Extend that family; never call
  `glassEffect` / `.buttonStyle(.glass)` directly at a call site; never introduce a second idiom.
- macOS-13-safe APIs only in `Strand/` and `StrandDesign` (use the existing shims: `onChangeCompat`,
  `liquidTapHaptic`, `liquidOffscreen`, `symbolEffect*Compat`, `plotRectCompat`).
- No `project.yml` edits are needed: sources are directory-based; new files under existing folders are
  picked up by `xcodegen generate` in the integration step.

### 2.3 Honesty rules (the app's core value — a design that hides these is wrong)

1. **Absent data shows `—` (U+2014 em dash) plus a reason**, never `0`, never `–` (en dash, currently
   80 literal uses), never a blank. Use `TelosType.absent`. The reason sits in the same card (reuse
   existing strings: "No night recorded", "Strap not connected", "Not enough data yet", "Calibrating
   (n of m)", "Waiting for the strap").
2. **Never feed `?? 0` into a fill, arc, bar or tube.** Nil renders a bare track with no fill, no tip, no
   caret. Known violations to fix: `LiveWorkoutView.SessionSummaryCard(avgHr: … ?? 0, peakHr: … ?? 0)`,
   `LiquidTube(frac: (w.strain ?? 0) …)` in Today's workouts, `LiquidTube(frac: (strength ?? 0) …)` in
   HealthView.
3. **Confidence is always visible** where it is below *solid*: `ScoreConfidence.calibrating` and
   `.building` get a `ConfidenceTag` on every hero, tile and widget that shows the score; calibrating
   additionally renders the fill hatched and the numeral in `textTertiary` (§5.3). Level `coverage` below
   100 % always shows "NN% measured" next to the level number (strip, widget, brief, timeline).
4. **Carried values** (an earlier day's figure shown because today has none) keep the existing "Repeating
   d MMM" line and render their numerals in `textSecondary`.
5. **Charts never invent values:** interpolation `.monotone` (never `.catmullRom`, which overshoots past
   the data extremes — `TrendChart` uses it today), gaps break the line (`hrGapSegments`), bars start at
   0, targets/bands only when computed.
6. Count-up animations are transitions only: VoiceOver reads the final value, and an absent value never
   counts.
7. Associations are labelled as associations; only a finished trial may say "helped" (§5.15).

### 2.4 Accessibility

- **Dynamic Type to AX5 without clipping.** Prose never uses `minimumScaleFactor` < 0.8; numerals inside
  fixed geometry (gauges) may scale to 0.7 and are capped (§4.2). From `.accessibility1` up, layouts
  switch (trio → rows, 2-column grids → 1 column, level strip → compact).
- **Contrast** (both schemes, against the real surface): text ≥ 4.5:1 (≥ 3:1 at ≥ 18 pt bold / 24 pt);
  non-text UI (arcs, chart lines, focus ring, selected-segment edge, tick marks that carry value) ≥ 3:1.
  Enforced by `TelosContrastTests` over the hex table in §4.1. (Today's tertiary text fails: #7D7F88 on
  #2A2C34 ≈ 3.5:1; the light mint accent #149A78 on white ≈ 3.5:1.)
- **Reduce Motion alternative for every motion** (table §4.8). Low Power Mode and "Reduce motion in NOOP"
  pose loops still via `NoopMotionState`.
- **VoiceOver:** one element per gauge/tile/row; label = metric, value = number + unit + confidence /
  carried / absent reason, hint when it navigates. Canvas charts provide `accessibilityChartDescriptor`.
- **44 × 44 pt hit targets** everywhere (visuals may be smaller with an expanded `contentShape`). The
  segmented control is 38 pt today — V2 makes it 44.
- Never colour alone: deltas carry sign + arrow, states carry words. Honour
  `accessibilityDifferentiateWithoutColor` (chart series get dash patterns) and Increase Contrast
  (`line` → `lineStrong`, `textTertiary` → `textSecondary`).

### 2.5 Strings

No new strings where avoidable; where copy changes, keep meaning. Every unavoidable new string is listed
in its package's hand-off (§8) and in Appendix A. **No package edits any `Localizable.xcstrings`**
(four catalogs; the i18n CI gate needs de/es/fr/pt-PT) — the integration step adds them in one pass.

---

## 3. What exists — keep, fix, retire

**Keep (the brand):**
- The **liquid vessel** and tube (`LiquidCore`/`LiquidPrimitives`): the signature. V2 makes the vessel
  hold liquid again — today `LiquidRender.vessel` draws a ring from `sim.level` only and ignores the
  simulated surface entirely, while running a 60 fps `TimelineView` forever (a pure cost with no visible
  effect once settled).
- The **day-cycle sky** (`LiquidSky`), but static and actually time-of-day coloured: all ten current dark
  keyframes sit within #191A1F–#292C34, so the sky no longer reads as a time of day at all.
- The **pentagon level radar** in the persistent top strip (trend chips left, radar centre, levers right).
- The **lock-screen strip widget** (`TelosStripWidget`): hairline ticks, cells and carets — already the
  purest expression of "instrument". It is the reference for the technical voice.
- The **diagnostic register** (morning flow, `DiagnosticAlertView`): heavy expanded capitals on black.
  Keep as the ceremonial register, tokenised.
- Honest data plumbing already present: `hrGapSegments`, carried-day footers, `coveragePercent`,
  confidence tiers, `pendingToday` dimming, the de-duplicated-publisher shell pattern.

**Fix (inconsistent or dated):**
- Three palettes in one app: `StrandPalette` (names that lie — `gold` is blue, `titanium*` unused),
  the morning flow's private `Diag` enum, `DiagnosticAlertView`'s literal reds; 34 `Color(.sRGB …)` /
  `Color(white:)` literals and 382 fixed `.font(.system(size:))` calls in app/widget code.
- Every card draws three gradients, a gradient rim and a 9 pt shadow (`NoopPanelSurface`), multiplied by
  every card in a scroll view.
- Type: everything rounded, including prose and labels; gauge and strip text at fixed 8–11 pt ignores
  Dynamic Type; hero ring labels use `.system(size: 15)`.
- Tab switching animates the whole `TabView` subtree (`.animation(…, value: selectedTab)`).
- The level radar's count-up schedules up to 34 `DispatchQueue.asyncAfter` blocks per appear.
- `LiquidSky` twinkles at 20 fps when starry; its stars are re-randomised every launch.
- Hero trio (`TodayTrioHeroView`) is a plain `Circle().trim` ring with literal fonts — the liquid vessel
  it replaced was the stronger brand element.
- Detail screens use `ScenicHeroBackground` starfields that belong to an earlier theme.

**Retire:** additive bloom/glow helpers (`additiveBloom`, `glowAmbient`), scenic starfields
(`ScenicHeroBackground`, `SceneHeroBackground` images on heroes), rim gradients, the titanium plate
gradient on icon plates, the travelling glint on the HR thread, the sky's twinkle/breath loop, the
tab crossfade. Retire means "no V2 call site uses it"; public symbols stay compiled (macOS/Android
parity, no API breaks).

---

## 4. Tokens

All new tokens live in `Packages/StrandDesign/Sources/StrandDesign/Telos/` under the namespaces
`TelosColor`, `TelosType`, `TelosSpace`, `TelosRadius`, `TelosStroke`, `TelosOpacity`,
`TelosElevation`, `TelosMotion`. **Migration strategy:** the DS package re-points the *existing* token
names to V2 values (e.g. `StrandPalette.surfaceBase` returns `TelosColor.canvas`), so every existing
call site turns V2 with no edit; new and rewritten code uses the `Telos*` names. No existing public
symbol is renamed or removed.

### 4.1 Colour

Hex given as dark / light. Every pair is also exported as a testable table `TelosColor.Spec` (hex
strings, like `BrandSleepRamp`) so `TelosContrastTests` can compute WCAG ratios.

**Chrome**

| Token | Dark | Light | Replaces (old → re-pointed) |
|---|---|---|---|
| `canvas` | #0B0E11 | #F3F4F1 | `NoopVisualStyle.canvas`, `StrandPalette.surfaceBase` |
| `surface` | #13171B | #FFFFFF | `NoopVisualStyle.surface/surfaceTop/surfaceBottom` (gradient collapses to flat), `surfaceRaised`, `heroFill`, `cardFillTop/Bottom` |
| `surfaceRaised` | #1A1F24 | #FFFFFF | `surfaceOverlay` (popovers, selected segment, sheets' inner cards) |
| `surfaceInset` | #0F1215 | #E9EBE7 | `NoopVisualStyle.inset`, `surfaceInset` (tracks, wells, fields) |
| `line` | #252B31 | #D8DBD5 | `border`, `hairline`, `heroBorder` |
| `lineStrong` | #39414A | #B3B9B2 | `borderHighlight`, `hairlineStrong` |
| `lineSoft` | #1B2025 | #E7E9E4 | `hairlineSoft`, `divider` (grids, in-card separators) — precomputed, no opacity |
| `textPrimary` | #F2F4F3 | #111416 | `primaryText`, `textPrimary` |
| `textSecondary` | #A9B0B4 | #4A5156 | `secondaryText`, `textSecondary` |
| `textTertiary` | #858D92 | #666D72 | `tertiaryText`, `textTertiary` (both now ≥ 4.5:1 on `surface`) |
| `textDisabled` | #4E555B | #A5AAA6 | new — disabled labels only, never information |
| `onDark*` | unchanged | unchanged | kept for the sky title |

`NoopVisualStyle.rimGradient` returns a flat `line` gradient (both stops equal) so old call sites draw a
plain 1 pt edge.

**Accent** (chrome only: links, toggles, selection, focus ring, primary button, live dot). The user
setting (`AccentColor` mint / WHOOP blue / custom) stays; V2 changes the **mint** values only:

| Token | Dark | Light | Replaces |
|---|---|---|---|
| `accent` (mint) | #5FE0B5 | #0B7F63 | `NoopVisualStyle.mint` (#69DDB8 / #149A78 — light failed AA) |
| `accentPressed` | #8DEBCD | #086A52 | `mintGlow`, `accentHover` |
| `accentMuted` | accent @ 0.16 | accent @ 0.16 | `accentMuted` (0.18) |
| `onAccent` | #062019 | #FFFFFF | `goldDeepText` |

Rule: the accent never encodes data and never fills a data surface. Inside data cards, "this navigates"
is a `textTertiary` chevron, not accent — this keeps mint visually apart from Charge green.

**Status** (values for the default chart style; `ChartStyle.classic` keeps its existing branches)

| Token | Dark | Light | Replaces |
|---|---|---|---|
| `positive` | #3FD68F | #0A7F4F | `statusPositive` |
| `warning` | #F2B03D | #9A6100 | `statusWarning` |
| `critical` | #FF5A5F | #C62A32 | `statusCritical`, `DiagnosticAlertView.red`, `metricRose` in alerts |
| `criticalWash` | critical @ 0.10 | critical @ 0.07 | new (penalty block, alert fields) |

**Metric identity** (graphic fill ≥ 3:1; `…Ink` is the text variant ≥ 4.5:1 — equals the fill in dark)

| Token | Fill dark | Fill light | Ink light | Replaces |
|---|---|---|---|---|
| `charge` | #03E095 | #0F9D62 | #087F50 | `chargeColor` (values unchanged, ink added) |
| `effort` | #4090E0 | #2A78C8 | #2468B0 | `effortColor` (unchanged, ink added) |
| `rest` | #9D9BF2 | #6663D6 | #6663D6 | `restColor/restLine/restGlow` (steel #83A0B8 → lavender, tied to the hypnogram's light-sleep hue); `restDeep` #5B57C9/#4A46B0, `restBright` #B9B7F7/#6663D6 |
| `stress` | #F0A020 | #C7891A | #8F5E00 | `stressColor` (unchanged, ink added) |
| `heart` | #FF6B81 | #D94C64 | #B8354D | `liquidHeart`; Level "heart" part (was `statusCritical`) |
| `lungs` | #3FA9C9 | #1F7F9E | #1F7F9E | `metricCyan`; Level "lungs" part |
| `muscle` | #F08A4B | #B5561C | #B5561C | Level "muscle" part (was `statusWarning`) |
| `focus` | #C39BFF | #7A4FD0 | #7A4FD0 | Level "focus" part (was `accent`); mind / meditation |
| `bestGold` | #E5B84B | #9A7310 | — | `radarBestGold` literal — "the only gold", personal bests only |

`levelPartTint(_:)` maps sleep→`rest`, heart→`heart`, lungs→`lungs`, muscle→`muscle`, focus→`focus`.
Status colours are never used as identity again.

**Data ramps are unchanged**: `recoveryStops`, `strainStops`, sleep-stage colours (incl. Oura/Garmin
`BrandSleepRamp`, pinned by tests and a Kotlin twin), HR zones, stress gradient, every classic branch.
They are measurements, not chrome.

**Sky keyframes** (owned by INS; top / mid / horizon; `settle` colour = `TelosColor.canvas`, resolved
from the token — the current literal RGB copies go):

| Hour | Dark | Light |
|---|---|---|
| 0 | #070A12 / #0A0E18 / #0E1320 | #D7DEEA / #E2E7EF / #ECEFF3 |
| 5.5 | #0A0D18 / #111425 / #1E1A2A | #DCDDEA / #E8E6EE / #F1EBEA |
| 7 | #0E1220 / #1A1A28 / #2E2224 | #E6E4EC / #F2E9E4 / #F7EDE3 |
| 12 | #0C1218 / #111A22 / #16222C | #DDE9F1 / #E7F0F5 / #F0F4F6 |
| 18.5 | #110F1A / #1C1620 / #2E1F1C | #E4DFEA / #F1E6E4 / #F7EADF |
| 21 | #080B14 / #0B0F1A / #101522 | #D8DEEA / #E3E7EF / #ECEFF3 |
| 24 | = hour 0 | = hour 0 |

Stars: dark scheme only, hours 20–5.5, fixed seed (deterministic positions), opacity ≤ 0.35, static.

**Diagnostic register** (dark-only screens: morning flow, full-screen alerts): `diagField` #000000,
`diagCard` #121214, `diagLine` #2B2B2E, `diagText` #FFFFFF, `diagMuted` #8C8C8C, signal = `accent`
(was a private blue #2E75FF), alarm = `critical` dark value. Replaces `MorningFlowView.Diag` and the
literals in `DiagnosticAlertView`.

### 4.2 Typography

Three voices, one rule: **numbers are Rounded, prose is SF Pro, anything that qualifies a number is SF
Mono.** A fourth, ceremonial register (Expanded) exists only in the diagnostic screens.

| Token | Family | Weight | Size @ Large | Scales with | Tracking | Replaces |
|---|---|---|---|---|---|---|
| `hero` | SF Rounded | semibold | 56 | `.largeTitle`, cap 1.3× | −1.1 | `StrandFont.display(_)`, `rounded(≥40)` |
| `numeralL` | SF Rounded | semibold | 34 | `.largeTitle`, cap 1.4× | −0.5 | `rounded(28…36)` |
| `numeralM` | SF Rounded | semibold | 24 | `.title2`, cap 1.6× | −0.2 | `number(26)`, StatTile value |
| `numeralS` | SF Rounded | medium | 17 | `.body` | 0 | `bodyNumber` |
| `numeralXS` | SF Rounded | medium | 13 | `.footnote` | 0 | `captionNumber` |
| `title` | SF Pro | bold | 28 | `.title` | 0 | `title1`, scaffold `rounded(28)`, Today day title |
| `title2` | SF Pro | semibold | 22 | `.title2` | 0 | `title2` |
| `headline` | SF Pro | semibold | 17 | `.headline` | 0 | `headline` |
| `body` | SF Pro | regular | 17 | `.body` | 0 | `body` |
| `callout` | SF Pro | regular | 16 | `.callout` | 0 | new |
| `subhead` | SF Pro | regular | 15 | `.subheadline` | 0 | `subhead` |
| `footnote` | SF Pro | regular | 13 | `.footnote` | 0 | `footnote` |
| `caption` | SF Pro | regular | 12 | `.caption` | 0 | `caption` |
| `scale` | SF Mono | medium | 11 | `.caption2` | +0.8, UPPERCASE | `overline` + `overlineTracking` |
| `scaleNumber` | SF Mono | regular | 11 | `.caption2` | 0 | axis ticks, timestamps, IDs |
| `diagnostic` | SF Pro Expanded | black | 34 | `.largeTitle` | +0.5 | `Diag.display(38)`, alert title |
| `diagnosticS` | SF Pro Expanded | heavy | 17 | `.headline` | +1.0, UPPERCASE | `Diag.heavy(20)`, CONFIRM |

Rules:
- All numerals `.monospacedDigit()` (tabular). Units follow a numeral in `scale` at 0.55× the numeral
  size (min 11), baseline-aligned, `textSecondary`. Signs use a true minus (U+2212) in deltas.
- Minimum rendered size at default Dynamic Type: **11 pt** (the level strip's 8–9 pt text goes).
- Geometry-bound numerals (inside a vessel/ring) use `TelosType.numeral(size:relativeTo:cap:)` which
  scales through `UIFontMetrics` and clamps at `cap`; they never overflow their gauge — the gauge grows
  or the layout switches (§2.4).
- **Re-pointing:** DS changes `StrandFont.title1/title2/headline/body/subhead/caption/footnote` to SF Pro
  (drop `.rounded`) and `StrandFont.overline` to SF Mono medium with `overlineTracking = 0.8`.
  `StrandFont.display/rounded/number` stay Rounded and fixed-size (geometry-bound callers depend on it).
  This single change gives the whole app the V2 voice; each screen package then checks its
  `strandOverline()` sites for truncation (mono is ~12 % wider).
- `TelosType.absent = "—"`.

### 4.3 Spacing (4-pt grid)

`TelosSpace`: `xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 · xxxl 48`.

| Use | Value | Replaces |
|---|---|---|
| Page gutter (every screen, incl. Today) | 16 | `pagePadding` 16; Today's private `todayGutter` 22 → 16 |
| Card padding / compact tile padding | 16 / 12 | `cardPadding` 16, StatTile 14 |
| Gap between cards | 12 | `itemGap` 12 |
| Gap between sections | 24 | `sectionGap` 26 |
| Section header → first card | 8 | ad hoc 4–10 |
| Row vertical padding | 12 (min row height 52) | `rowSpacing` 10 |
| Tab-bar clearance | 76 | `tabBarClearance` (unchanged) |

`NoopMetrics.space1…space10` already form this ramp and stay.

### 4.4 Corner radii (all `.continuous`)

| Token | Value | Replaces |
|---|---|---|
| `hero` | 24 | hero card 26 |
| `card` | 20 | `cardRadius` 22 |
| `tile` | 14 | `compactRadius` 16 |
| `control` | 12 | buttons 13, segmented track 13, fields |
| `segment` | 9 | selected segment 10 |
| `plate` | 8 | icon plates |
| `pill` | capsule | `pillRadius` |

### 4.5 Strokes

| Token | Width | Use |
|---|---|---|
| `hair` | 0.5 | chart grid, minor ticks (3 pt long) |
| `line` | 1 | card edge, dividers, track outline, major ticks (6 pt long) |
| `strong` | 1.5 | radar web, secondary series, whiskers |
| `data` | 2 | primary chart series, interval line |
| `dataHero` | 2.5 | the one hero chart per screen |
| `focus` | 2 | focus ring (`noopFocusRing`) |
| `gauge` | clamp(d × 0.08, 4, 12) | ring/bezel arc width by diameter `d` |
| `rail` | 3 | penalty/alert leading rail |

`rimWidth` 0.8 → 1.

### 4.6 Elevation

| Level | Shadow (y, radius, black opacity dark / light) | Use | Replaces |
|---|---|---|---|
| `flat` | none | cards, tiles, rows, chips, charts — **everything in a scroll view** | `NoopSurfaceElevation.resting` (r 9 → 0) |
| `raised` | 3, 10, 0.30 / 0.10 | radar plate, popover, floating stress pill, pull-refresh vessel | `.raised` (r 18 → 10) |
| `overlay` | 10, 28, 0.45 / 0.16 | modal cards (quest failure card, alert card) | new |

`StrandCardHover` keeps its macOS hover lift; iOS draws none.

### 4.7 Opacity

`TelosOpacity`: `full 1 · card 0.85 · secondary 0.72 · disabled 0.45 · border 0.32 · fill 0.16 · wash 0.10 · whisper 0.06`.
Maps: `chipFillOpacity` 0.14 → 0.16, `chipBorderOpacity` 0.30 → 0.32, `disabledOpacity` 0.45
(unchanged). Card transparency (the Settings slider) is clamped to **0.55…1.0** so text contrast holds;
the SYS package changes the slider range to 55–100 so the control never shows a value that is not drawn.

### 4.8 Motion tokens

| Token | Curve | Use | Replaces | Reduce Motion |
|---|---|---|---|---|
| `press` | easeOut 0.12 s; scale 0.97, opacity 0.88 | press feedback | `LiquidPressStyle` 0.16, pressable 0.985 | opacity 0.88 only |
| `select` | spring(response 0.28, damping 0.86) | segment/chip/toggle selection | `StrandMotion.interactive` | none (instant) |
| `settle` | spring(response 0.45, damping 0.90) | numeral change, arc/caret move, delta chips | `StrandMotion.gentle`, `NoopMotion.value`, `NoopMotion.card` | none |
| `flow` | spring(response 0.80, damping 0.92) | liquid level change | `StrandMotion.hero`, `drawIn` (0.9 easeOut), gauge 0.9 easeOut | none (posed at value) |
| `screen` | spring(response 0.46, damping 0.88) | expand/collapse, in-sheet page swap | `NoopMotion.screen` | fade 0.20 |
| `fade` | easeInOut 0.20 s | insert/remove, content swap | `StrandMotion.fade` 0.30 | same (fades are allowed) |
| `countUp` | `settle`, ≤ 0.6 s | numeral count on a *new* value | `CountUpText` default | instant |
| `beat` | easeOut 0.30 s | HR dot pulse per received sample | LiquidLiveHR 0.28 | static dot |
| `live` | easeInOut 2.0 s loop | LIVE dot only while streaming | `StrandMotion.breathe` 3.2 s | static dot |
| `breath` | 5.5 s period | guided breathing content only | `breathPeriod` 3.2 | exercise's own static mode |
| `stagger` | 0.035 s per item, first 4 items | first data arrival on a screen | `NoopMotion.stagger` 0.04 | none |

Every token has a `TelosMotion.gated(_:reduced:)` accessor returning `nil` under Reduce Motion (as
`NoopMotion.gated` does). The old names stay and return the new curves.

### 4.9 Glass

Allowed roles (≤ 5 glass elements visible at once):

| # | Role | Helper | Note |
|---|---|---|---|
| 1 | System tab bar | system | automatic on iOS 26 |
| 2 | Today header cluster (profile, add, battery/sync, customize) | `nativeLiquidGlassHeaderButton()` (exists) | the only glass inside a scroll view; it scrolls over the *static* sky |
| 3 | Live Workout / Live Session control row | `nativeLiquidGlassWorkoutControl()` (exists) | must sit on an **opaque** `surface` band (safe-area inset), not over the scrolling cards |
| 4 | Search field in a fixed header position | `nativeLiquidGlassSearchChrome()` (exists) | |
| 5 | Close/skip button on full-screen covers | `nativeLiquidGlassButtonChrome(controlSize: .regular)` (exists) | morning flow, live screens |

New in the family (DS package, `NoopLiquidGlassSearchField.swift`):
`nativeLiquidGlassFallbackSurface<S: Shape>(_ shape: S)` — the one fallback everybody uses (solid
`surfaceRaised` + 1 pt `line` stroke, no material). App-side role helpers are rewritten to call it
instead of hand-rolled fallbacks.

---

## 5. Components

Each entry: anatomy · states · tokens · glass. All components live in
`StrandDesign/Telos/` unless noted; existing public components (`NoopCard`, `StrandCard`, `StatTile`,
`TrendChip`, `SectionHeader`, `SegmentedPillControl`, `ScoreStatePill`, `StatePill`, `SourceBadge`,
`ChartCard`, `ChartFooter`, `InsightCard`, button styles) keep their initialisers and render V2.

### 5.1 Card (`NoopCard` / `StrandCard` / `FrostedCardSurface` → V2 surface)
- Anatomy: flat `surface` fill · 1 pt `line` stroke · radius `card` (20) · padding 16. Optional
  **header** (scale overline + `headline` title + trailing accessory: chevron `textTertiary` 13 pt if the
  card navigates, or a 44 pt icon button). Optional **footer**: `ProvenanceRow` (§5.3).
- `tint:` is accepted but draws only a 3 pt-high top edge in the tint at 0.6 opacity (no washes).
- States: rest · pressed (`press` token, if tappable, via `StrandPressableButtonStyle`) · disabled
  (content `disabled` opacity).
- Opacity: fill × environment `\.telosCardOpacity` (0.55…1). No shadow. **Glass: never.**

### 5.2 Metric hero (`MetricReadout`)
The one way a primary number is shown.
- Anatomy, left-aligned: `scale` label (e.g. CHARGE) → numeral (`hero` or `numeralL`) + unit (`scale`) on
  one baseline → `DeltaChip` (vs 30-day baseline) → `ConfidenceTag` if not solid → `ProvenanceRow`.
- States: **value** · **carried** (numeral `textSecondary` + "Repeating d MMM") · **calibrating**
  (numeral `textTertiary`, tag "Calibrating (n of m)") · **building** (tag) · **absent** (`—` in
  `textTertiary` + reason line in `footnote`) · **loading** (`—` + no reason for ≤ 1 s, then
  system `ProgressView` small in the unit slot).
- Motion: `countUp` on a new value only (not on re-appear); Reduce Motion instant.
- VoiceOver: one element, e.g. "Charge, 72 percent, building confidence, updated 07:12".
- Glass: never.

### 5.3 Qualifiers: `ConfidenceTag`, `AbsentValue`, `ProvenanceRow`
- `ConfidenceTag`: capsule, height 20, `scale` text, 1 pt border. *calibrating* → `textTertiary` ink,
  dashed border [2,2] (visually provisional); *building* → `warning` ink, solid border @ 0.32, fill @
  0.10; *solid* → not rendered on heroes/tiles; in detail provenance rows it reads "Solid" in
  `textTertiary`. Replaces `ScoreStatePill` colours (its API stays and maps to these).
- `AbsentValue`: `—` + reason, reason in `footnote textTertiary`, max 2 lines, never truncated.
- `ProvenanceRow`: `scaleNumber`, `textTertiary`: `SOURCE · HH:MM · N DAYS` (existing `SourceBadge` text
  inside, restyled to an outline tag). Always the last row of a hero or detail card.
- Calibrating fills: vessels/tubes/rings draw their fill with `DiagonalHatch` (existing, public in
  `TypicalRangeBar.swift`) in the metric colour instead of a solid fill.

### 5.4 Stat tile (`StatTile`)
- Anatomy: radius `tile` (14), padding 12, min height 96 (`NoopMetrics.tileHeight`). Row 1: `scale`
  label + optional accessory. Row 2: numeral `numeralM` + unit + `DeltaChip` trailing. Row 3 (optional):
  sparkline 22 pt (static, `data` 1.5 pt, last-point dot 4 pt). Row 4 (optional): caption `footnote`,
  or `ConfidenceTag`.
- `accent:` colours the numeral only when it is a metric identity ink; default `textPrimary`.
- Grid: 2 columns on iPhone, 1 column at `.accessibility1`+; heights equalised per row.
- States as §5.2. Glass: never.

### 5.5 Chips & pills
| Kind | Anatomy | Tokens | Use |
|---|---|---|---|
| `TelosChip` (selectable) | capsule 32 visual / 44 hit, `subhead` semibold, 12 h-pad | off: `surfaceInset` + `line`; on: `textPrimary` fill + `canvas` text | filters, gear chip, quest chips |
| `TelosTag` (static) | capsule 20, `scale` | outline 1 pt at 0.32, ink at 1.0 | source, BETA, DEBT, ASSOCIATION |
| `DeltaChip` (`TrendChip`) | arrow 9 pt + signed value `numeralXS` | fill @ 0.16, no border; tone: better `positive`, worse `critical`, flat `textTertiary`. Flat (|Δ| rounds to 0) shows `±0`; no delta computed shows `—` — the two must stay distinguishable | deltas |
| `StatePill` / `ScoreStatePill` | dot 7 + `scale` | tone colour; LIVE dot uses `live` motion | connection, live |

"Better/worse" is decided by the metric's direction (RHR down is better), passed in by the caller —
never inferred from the sign alone.

### 5.6 Gauge family
**Vessel (`LiquidVessel`, INS)** — the primary-score gauge (Rest, Charge, Effort, Fitness Age,
Vitality, Hydration, Breathing orb).
- Anatomy (outside → in): **bezel** ring of ticks at diameter `d` (40 minor `hair` ticks 3 pt, major
  `line` ticks 6 pt at 0/25/50/75/100 %, `lineStrong`) → **glass wall** circle at `d − 12` (1 pt `line`
  stroke, `surfaceInset` fill) → **liquid** inside the wall: fill *height* linear in value (not area),
  metric colour at 0.85 with a darker 0.35 bottom gradient, meniscus + two-sine surface from
  `liquidWave` → **value caret** on the bezel at the exact fraction (2 pt × 8 pt, `textPrimary`) →
  optional **target caret** (Effort's optimum) hollow, `textSecondary` → centre numeral (§4.2
  geometry-bound).
- States: value · calibrating (hatched liquid) · absent (empty wall, dashed bezel [2,3], `—`) · carried
  (liquid at 0.5 opacity).
- Motion: on a new value the level animates with `flow` and the surface sloshes for ≤ 1.2 s, then the
  `TimelineView` pauses (`paused: settled || poseStill || covered || offscreen`). **Tilt response only
  while settling or within 1.5 s of a tap splash**; CoreMotion is acquired only then. Idle cost: zero.
  Reduce Motion: posed at value, no slosh, no splash (tap still navigates).
- Sizes: hero 92–120, detail 140, compact rows use the ring instead (liquid below 60 pt is mush).
- Glass: never (the "glass wall" is drawn, not a material).

**Ring (`TelosRing`, INS, StrandDesign so widgets can use it)** — compact score (≤ 60 pt): track
`surfaceInset`, arc metric colour, `gauge` width, 12-o'clock start clockwise, bezel caret optional,
absent = bare track. Replaces `GlowRing`, `BevelGauge` visuals, small `LiquidVessel(animated:false)`.

**Radial scale / dial (`TelosBezel`, INS)** — the tick bezel alone, for dials (body clock, stress 0–3,
zone dial). Major/minor ticks as above; value caret; optional band arcs (`fill` opacity) for typical
ranges.

**Linear scale** — `LiquidTube` (static unless its value changes; `flow` settle ≤ 1.2 s), `PipBar`
(cells, count-up once on new value), `TypicalRangeBar` (hatch = typical, solid = you). All: absent =
empty track + `—`.

**Radar (`LevelRadarView`, FRAME)** — pentagon plate (`surfaceRaised`, `raised` elevation), two grid
rings + spokes `hair` `lineSoft`, web fill `textPrimary` @ 0.10 + stroke `strong` `textPrimary` @ 0.8,
**vertex dots 5 pt in each part's identity colour**, unmeasured part → hollow vertex at centre + dashed
spoke, personal best dashed `bestGold`. Level numeral `numeralL` heavy; "NN% measured" in `scale`
below it whenever coverage < 100 %. Count-up: one `Animatable` numeral (`countUp`), no dispatch queue.

### 5.7 Charts (`TrendChart`, `OverviewHRChart`, `Hypnogram`, `Sparkline`, `YearHeatStrip`; INS)
- Plot: no chart border, no axis lines. Horizontal grid: 4 lines `hair` `lineSoft`. Vertical grid only
  at day boundaries (intraday) or month starts (long ranges).
- Axis labels: `scaleNumber`, `textTertiary`; y labels trailing; x labels 5 max.
- Series: primary `data` 2 pt (`dataHero` 2.5 for the screen's hero chart), round caps, interpolation
  `.monotone`, colour = metric identity or the data ramp for score series; area fill optional: one
  gradient series colour 0.18 → 0. Points only for n ≤ 14.
- Baseline (personal typical): `line` 1 pt dashed [3,3] `lineStrong` + `scale` label at right edge;
  typical range: `DiagonalHatch` band in `lineSoft`.
- Gaps: segments break (`hrGapSegments`); never bridged.
- Workout spans (intraday): band `effort` @ 0.10 full plot height, 1 pt top rule in `effort`, sport glyph
  11 pt at top-left. Sleep spans: `rest` @ 0.08.
- **Scrub:** sideways drag (existing `ChartHoverMath.scrubAxis`), vertical rule 1 pt `textSecondary`,
  point 7 pt + 2 pt `surface` ring, **callout pinned to the top edge of the plot** (never covering the
  point): `surfaceRaised` + `line` border, radius 10, value `numeralS` + unit `scale` + date
  `scaleNumber`; flips side at the edges. One selection haptic when the scrub engages.
- Empty: plot area with grid + centred `AbsentValue`. Sparse (< 2 points): single dot + "Not enough
  data yet".
- Canvas charts supply `accessibilityChartDescriptor`; Swift Charts keep audio graphs.

### 5.8 List rows (`MoreRow`, settings rows, Explore rows, session rows)
- Anatomy: min height 52; leading icon plate 28 × 28 radius `plate`, `surfaceInset` + `line`, symbol
  15 pt `textSecondary` (tinted with identity colour only for metric rows); title `body`; optional
  subtitle `footnote textSecondary`; trailing value `numeralS` + unit, or toggle, then chevron 13 pt
  `textTertiary`. Divider `lineSoft` inset to the title.
- Grouped inside one card (radius 20). Pressed: row fill `surfaceInset`. Glass: never.

### 5.9 Section header (`SectionHeader`)
- `scale` overline (`textTertiary`) → `title2` title (optional) → trailing text button (`subhead`
  semibold, accent, 44 pt hit). Today's section heads use the overline alone.

### 5.10 Buttons
| Style | Anatomy | States |
|---|---|---|
| `.noopPrimary` | height 50, radius 12, fill `accent`, `onAccent` `headline` | pressed `press`; disabled fill `lineStrong`, text `textDisabled`; loading: spinner replaces label, width fixed |
| `.noopSecondary` | height 50, fill `surfaceInset`, 1 pt `line`, `textPrimary` `headline` | same |
| `.noopGhost` (tertiary) | no fill/border, `accent` `headline`, 44 hit | pressed opacity 0.6 |
| Destructive | secondary shape, `critical` ink | confirm via system dialog |
| Icon button | 44 hit, 36 visual circle, `surfaceInset` + `line`; glass only in the §4.9 roles | |

No gradients on any button (the `goldGradient` fill goes).

### 5.11 Segmented control (`SegmentedPillControl`)
- Track: height 44, radius 12, `surfaceInset` + 1 pt `line`, 4 pt inner padding. Selected segment:
  radius 9, `surfaceRaised` + 1 pt `lineStrong`, **no shadow**; label `subhead` semibold `textPrimary`;
  unselected `textSecondary` (was `textTertiary`). Disabled segment `textDisabled` + "dimmed" trait.
- Motion: selection slides with `select`; Reduce Motion instant. Haptic: selection.
- Glass: never.

### 5.12 Sheets, covers, alerts
- Sheets: system sheet, `presentationBackground(TelosColor.canvas)` (solid), grabber visible, existing
  `noopSheetPresentation(largeFirst:)` detents. Header: `headline` title centred, close as icon button
  (44). No material.
- Full-screen covers (morning flow, live workout, live session): canvas or diagnostic field, close/skip
  with glass role 5.
- **Diagnostic alert** (`DiagnosticAlertView`): after HEALTH_V2 H1/H2 its only remaining caller is the
  **opt-in** stress screen (`stress.alertScreen.enabled`, default off); the "Optimum reached" screen is
  removed. Keep the layout; tokens `diagField`, `critical`, `diagnostic`/`diagnosticS`, `scale` overline;
  grid `hair` critical @ 0.07. Shadows reduced to one (symbol, radius 12); the glowing title shadow goes;
  no summon haptic; the reading is a word (low / moderate / high), not "x.x of 3". Typewriter: Reduce
  Motion shows full text.

### 5.13 Empty / loading / abstaining / error
| State | Visual |
|---|---|
| Loading (< 1 s) | final layout with `—` values, no shimmer, no skeleton animation |
| Loading (≥ 1 s) | + system `ProgressView` (small) in the card header trailing slot |
| Empty (never had data) | card: symbol 20 pt `textTertiary`, `headline`, one `subhead` line, one action (`noopSecondary`) — `ComingSoon`/`DataPendingNote` restyled |
| Abstaining (data exists, too thin to be honest) | `AbsentValue` + progress to threshold as `PipBar` ("3 of 4 nights") |
| Syncing | `SyncingHistoryNote` (LIVE dot + chunks count, never a percent) |
| Error (recoverable) | `warning` symbol + one line + "Retry" ghost button |

### 5.14 Quest penalty / debt block (+ the daily failure card) — PROGRESS package

Logic, strings and data come from the quest agent (penalties affect XP, rank, streaks and debt quests
only, **never the Level**). This is the visual contract.

**Implementation vehicle:** the quest agent's `Strand/Screens/QuestPenaltyViews.swift`
(`QuestPenaltyBoard`, `QuestPenaltyRow`, `QuestAwaitingRow`, `QuestLedgerChip`,
`QuestPenaltyHistorySheet`) — PROGRESS restyles those types to this contract; it does not rename them
or change what they read.

**Placement:** first child inside `QuestStripView`'s root `VStack`, above the gear/quest chips. The
single `.sheet(item: $reviewing)` stays on that root; the block opens the review by setting
`reviewing` — it presents nothing itself.

**Anatomy (active state):**
- Container: radius `tile` 14, fill `surface`, 1 pt border `critical` @ 0.45, inner leading **rail** 3 pt
  full-height `critical`, padding 12 (16 on the leading side after the rail). Flat elevation.
- Header row: symbol `arrow.down.right.circle` 15 pt `critical` · `scale` overline in `critical` ink
  (e.g. MISSED) · trailing summary `numeralXS` `critical`: total cost ("−150 XP").
- Miss rows (max 3; "+N more" ghost button opens the review): quest title `subhead textPrimary` (2
  lines max) · when, `scaleNumber textTertiary` ("YESTERDAY 23:59") · result vs target in `scaleNumber`
  `textPrimary` ("6 412 / 10 000 STEPS") with shortfall in `critical` ink ("−3 588") · costs, right-
  aligned `scaleNumber` stacked: "−100 XP", "STREAK 12 → 0", "RANK ↓ …" exactly as the logic reports.
  Divider `lineSoft`.
- Debt sub-block: fill `criticalWash`, radius 10, `TelosTag` "DEBT" in `critical`, debt title
  `subhead` semibold, target `scaleNumber`, deadline `QuestCountdownView` in `scaleNumber`, progress
  `LiquidTube` (static; `flow` settle on change), trailing chevron → review.

**States:** *none* — the block is not rendered (zero height; no "all clear" celebration). *active* — as
above (misses and/or open debt). *cleared* — one compact row, `positive` check symbol + "Debt cleared"
+ what was restored, shown until the day rolls, then gone.

**Tone rules:** exact integers with grouping and units, never rounded or "~"; facts not adjectives; no
warning triangle, no strike-through, no 00:00:00 countdown, no per-letter typewriter, no shake, no
haptic, no full-screen takeover, no red backgrounds beyond the wash. Seriousness comes from the rail, the
critical ink on the *cost* column and the exactness of the numbers — not from alarm. The block has **no
row type for physiology** (sleep hours, HRV, RHR, Charge, stress are never penalised — HEALTH_V2 penalty
rule 1) and **never lists a trial quest** (rule 3); a cost column shows at most one day's cost per miss
(rule 4, no compounding).

**Daily summary card** (replaces the red "DIRECTIVE FAILED" `QuestFailedPopupView`, per HEALTH_V2 H3):
once per day, a modal card, `overlay` elevation, radius 24, `surface` fill over a `black @ 0.5` scrim (no
blur), max width 360, driven by the quest agent's day summary (`QuestPlanReporter` shape). Sections in
this order: **Met** (rows with `positive` check, `scaleNumber` readings) · **Fell short** (the miss rows
of the block above, with the reading behind each) · **Could not be measured** (rows in `textTertiary`
with the reason — never counted as a miss) · **What it cost** (the block's cost rows in `critical` ink,
plus any debt quest offer as the debt sub-block). Header `scale` overline "YESTERDAY" / the day's date
in `scaleNumber`; title `title2` in `textPrimary` (not red). Actions: primary `.noopPrimary` (the
logic's accept action, e.g. accept the debt quest) + ghost "Review". Enter: `fade` + scale 0.98 → 1
(`settle`); Reduce Motion fade only.

VoiceOver: each miss row is one element: "Missed: Walk 10,000 steps, yesterday. 6,412 of 10,000. Cost
100 XP. Streak reset from 12."

### 5.15 Trial card & result card (Habits) — PROGRESS package

Logic (design, randomisation, validity, effect estimate, 95 % interval, verdict) belongs to the health
implementation package (`docs/HEALTH_V2.md` §S1-A/S1-B: pure types in `Packages/StrandAnalytics`,
stores in new `Strand/Data/*Store.swift`). Its section S1 was still being written when this spec was
cut; where names differ, HEALTH_V2's model names win and the view structs below adapt. The views take a plain value model; the
PROGRESS package defines the view-side structs and maps the health package's types onto them.

**Trial card** (running trial)
- Header: `scale` overline "TRIAL" + `TelosTag` of the arm schedule (e.g. "RANDOMISED" /
  "ALTERNATING") · title `headline` (the habit, e.g. "No caffeine after 14:00") · outcome line `subhead
  textSecondary` ("Outcome: overnight HRV").
- **Today's assignment** (the hero of the card): a 56 pt-high band, radius 12, `surfaceInset`; left a
  large `numeralL`-weight word **ON** or **OFF** (`textPrimary`; ON also gets a 3 pt accent rail), right
  the instruction for today in `body`. If today is not assigned yet: "—" + reason.
- **Progress:** two `PipBar` rows, "ON" and "OFF", one cell per *planned* day: valid day = filled
  (`textPrimary`), invalid (missing data / not adhered) = hollow with a diagonal slash (`textTertiary`),
  upcoming = empty track. Right of each row `scaleNumber`: "7 / 14 VALID".
- Adherence: "Did you do it today?" row with two `TelosChip`s (logged through the quest the trial
  issued). Footer `ProvenanceRow`: started date · planned end.

**Result card** (finished trial)
- Header as the trial card, overline "RESULT".
- **Verdict** in words, `title2`: "Helped" / "No meaningful effect" / "Inconclusive" (+ "Made it worse" if
  the health spec defines it). The verdict carries a `TelosTag` tone: helped → `positive` **outline**
  (never filled), no meaningful effect → neutral, inconclusive → neutral (identical to no effect), worse →
  `warning` outline.
- **Effect line**, `scaleNumber`: "+3.1 ms · 95% CI −0.4 to +6.6".
- **Effect-interval plot** (`EffectIntervalPlot`, height 64): horizontal axis in the outcome's units,
  symmetric around 0 with half-width `max(|lo|, |hi|, 2·MID) × 1.15`. **Zero line** 1 pt `lineStrong`
  full height. **Meaningful band:** the region beyond the minimal meaningful difference on the
  *better* side is shaded flat `positive` @ 0.10, bounded by a dashed 1 pt `line` at ±MID; `scale` label
  "MEANINGFUL" inside the band; a direction hint "BETTER →" (or "← BETTER") under the axis. **Interval:**
  line `data` 2 pt `textPrimary`, whiskers `strong` 1.5 × 12 pt, point estimate 9 pt filled
  `textPrimary` with a 2 pt `surface` ring — **identical for every verdict**; colour never encodes the
  verdict. Axis ticks `scaleNumber` at lo/0/hi.
- **Sample:** `scaleNumber` "ON 12 · OFF 11 VALID DAYS · 3 EXCLUDED".
- Inconclusive adds one line: what would resolve it, from the logic ("≈ 8 more valid days").

Honesty guards: the plot draws exactly the interval it is given; if the model says "helped" while the
interval crosses zero, the view shows the interval truthfully and fires `assertionFailure` in Debug.
Association rows elsewhere never use the result card and always carry an "ASSOCIATION" tag.

---

## 6. Screen blueprints

Every existing feature stays reachable. "→" means where an existing section goes.

### 6.1 Shell, tab bar, level strip (FRAME)
- Tabs (5): **Today** (`sun.max`) · **Health** (`chart.line.uptrend.xyaxis`) · **Habits**
  (`flask`, replaces Focus — §6.8) · **System** (`sparkles` / working glyph, unchanged) · **More**.
  The Focus tab's meditation badge moves with tab tag 2 (meditation is itself a tracked habit and its
  card lives in the Habits hub); its a11y label changes to name Habits (new string).
- Remove `.animation(.timingCurve(…), value: selectedTab)` from the `TabView`: tab switches are instant
  (the crossfade encoded nothing and animated the whole subtree).
- Level strip: keep geometry (46 pt strip, 86 pt radar, −9 drop). Text to V2 type at 11 pt minimum:
  trend chips `numeralXS` + `scale`; step multiplier `scaleNumber`; levers `scale` in part identity
  colours (opacity still encodes share). Background opaque `canvas`. At `.accessibility1`+: strip shows
  only the radar + level number; trends and levers move into `LevelTimelineSheetView`'s header. Stress
  alert pill: `critical` fill, `onAccent`-white text, `raised` elevation, 44 pt hit.
- `ScreenScaffold`: title `title` (SF Pro bold 28), subtitle `subhead textSecondary`, gutter 16, section
  spacing 24, sky via `liquidScaffoldSky()` (static). Empty/pending notes restyled (§5.13).
- Root injects `\.telosCardOpacity` once from the card-opacity preference (replacing per-card
  `@AppStorage`).
- Quick-action sheet (`QuickActionSheet`): list rows §5.8 on `canvas`, no hairline "gold" top edge.
- Alerts (HEALTH_V2 H1/H2, 2-line hooks in this file): the stress full-screen overlay renders only when
  `stress.alertScreen.enabled` is on (default off; toggle in Settings, SYS); the "Optimum reached"
  overlay is removed. The level-strip stress pill stays and reads a word ("Stress high"), not a decimal.

### 6.2 Today (TODAY)
**Primary:** Rest · Charge · Effort. **Secondary:** the state line and today's mission. **Then** the
user's own order. The default section order and the Arrange/Customise behaviour are unchanged.

Top to bottom:
1. **Header (pinned):** day title `title` (tap → date picker popover, unchanged) + date line `scale`;
   trailing glass cluster (profile→Settings, add, battery/sync `ChargeSyncIndicator`, customise). Title
   shadows over the sky go (the sky is dark/light-correct now).
2. Bedroom climate chip (if configured) → `TelosChip` style, 44 hit.
3. **TELOS wordmark** → `scale` type, letter-spaced 12, `textTertiary`; the tap easter egg stays
   (user-initiated; Reduce Motion → haptic only).
4. Pinned banners, unchanged order: `HealthAlertBanner` (restyled as a `critical`-railed card, §5.14
   container), `ActiveWorkoutIndicatorSection`, `StepCalibrationTile`.
5. Reorderable sections:
   - `.hero` → **VesselTrio**: hero card (radius 24, padding 16), three columns of 92 pt vessels with
     bezels; numeral inside (geometry-bound, `numeral(size: 26, cap: 34)`), "%"/scale unit under it;
     below each: `scale` label + chevron (Rest → Sleep, Charge → scoring guide, Effort → Effort
     dossier, as today), then `ConfidenceTag` if not solid. Effort vessel carries the optimum
     **target caret**, labelled "typical range" wherever it is named (HEALTH_V2 H2); the
     `checkOptimum` call that raised the full-screen notice is removed. Footer bands (carried notice, weather) on `surfaceInset`, `scaleNumber`. At
     `.accessibility1`+ → three `MetricReadout` rows with a 44 pt `TelosRing`.
   - `.liveSession` → card row: shield symbol in `lungs`, "Start session" `body`, `TelosTag` "BETA".
   - `.synthesis` → **State card**: `InsightCard` V2 (status word `title2` in the status' ink, one-liner
     `subhead`, readiness chips); mission below as plain text: `scale` overline + `body`.
   - `.keyMetrics` → `StatTile` grid, 2 columns, detailed mode adds sparklines.
   - `.workouts` → list rows: sport plate, name, time `scaleNumber`, duration, static `LiquidTube` of
     effort **only when effort exists** (`—` otherwise), feedback button unchanged.
   - `.heartRate` → HR card: header `scale` "BEATS PER MINUTE" + current value `numeralL` in `heart` ink
     + `beat` dot; subtitle; thread 92 pt over a static grid; Min · Avg · Max `scaleNumber`.
   - `.recoveryVitals` → rows with 28 pt `TelosRing` (was static vessels), value `numeralS` + unit +
     `DeltaChip`, carried days marked.
   - `.quests` → `QuestStripView` (PROGRESS) with the penalty block on top.
   - `.streaks`, `.stressEnergy`, `.hydrationNutrition`, `.yourCards`, `.menstrualCycle`, `.journal`,
     `.addedCards` → unchanged content in V2 cards; `.dailyMission` still renders nothing.
6. `AutoWorkoutCard`, Data sources (as `ProvenanceRow`-style list rows).

**What moves and why:** vessels fill (`flow`) when a day's score first lands or changes — the score
arriving *is* the event; numerals count up with them; the HR dot pulses once per received sample and
the thread shifts one column per second (the data's own cadence); the sync indicator spins while a
sync runs; the pull-to-refresh vessel follows the finger. **Nothing else moves**: the sky is static, the
travelling glint and endpoint breathing are removed, and re-appearing on the tab does not replay fills.

### 6.3 Sleep (SLEEP) — `SleepView`
**Primary:** last night's Rest and time asleep. **Secondary:** the night's architecture.
1. Header: "Sleep" + night navigator (existing) + alarm icon button (→ `SleepAlarmSheet`).
2. **Rest hero** card: `MetricReadout` (Rest %, confidence, provenance) beside a 120 pt vessel; below,
   inline tiles: Asleep (h:mm, `numeralM`) · In bed · Efficiency · Need. The painted
   `SleepPerformanceNightScene` → the static night sky band (hour 0 keyframe) behind the card top.
3. **Night timeline:** hypnogram in the user's `SleepChartStyle` (classic rows / fill / Garmin / ribbon,
   unchanged), time axis `scaleNumber`, awake spans marked; card menu holds edit wake time, add nap,
   delete (with undo banner) — all existing.
4. Stages → `TypicalRangeRow` per stage + "Stages vs typical".
5. Sleep marks card; Naps section.
6. Metrics grid (`StatTile` + sparklines).
7. **Patterns** group: body-clock dial (on `TelosBezel`), sleep debt ledger, hours vs needed,
   consistency.
8. 30-day asleep trend (chart §5.7).
9. Explainer ("why this is your main sleep") + provenance.
Syncing note pinned above 2 while backfilling. Moves: hero vessel `flow` on a new night; nothing else.

### 6.4 Health tab (BODY) — `TrendsView`
Screen title becomes **"Health"** (matches the tab; existing string). Section order is kept (muscle model
first was an explicit owner choice): Muscle model → Strength progression → Vital trio (heart · lungs ·
sleep door) → Weekly digest (prev/next) → Week in review (Charge/Effort/Rest pips) → range control →
Charge over time (hero chart, `dataHero`, recovery ramp line, baseline dashed) → Daily signals (HRV,
RHR, Effort small multiples, 1 column on iPhone) → Training load → Calendar year strip → Export
report row. **New final group "Go deeper"** (list rows): Health Monitor (`HealthView`), Explore,
Sleep, Stress, Compare — these already exist in More and stay there too.
Moves: charts appear with the data (no draw-in animation); range change crossfades (`fade`).

**Health Monitor** (`HealthView`, More → Health): sync status → live HR (`MetricReadout` + thread,
live leaf) → recovery contributors (`TypicalRangeRow`s) → Fitness Age (vessel 120, bounded values keep
"≤20" prefix) → readiness checklist → Vitality → Vital signs grid (`StatTile`s with 44 pt rings) →
skin-temperature suite → records & sources. The `AppModel` observations in its sections move to leaves.

### 6.5 Explore (BODY) — `MetricExplorerView` / `MetricDetailView`
- Index: search field (glass role 4) → categories as `SectionHeader` + grouped list rows: plate, name,
  latest value `numeralS` + unit, 60 × 20 static sparkline, chevron.
- **Metric dossier** (the canonical detail template, also used by ring taps): `MetricReadout` hero
  (no scenic starfield) → range control → hero chart with typical band and baseline → stat tiles (Avg,
  Min, Max, Days) → readings table (`scaleNumber` dates, `numeralS` values, source tags) →
  correlations (each row tagged ASSOCIATION, r and n in `scaleNumber`).

### 6.6 Workouts (MOVE) — `WorkoutsView`
Order: Effort hero (typical effort, vessel) → range control → **All sessions** (moved up from
seventh; this is what the screen is opened for) → summary tiles → HR zones (stacked bar in zone ramp +
`scaleNumber` minutes) → activity breakdown → HR-recovery trend → active-calories heatmap. Session row:
sport plate, name + source tag, time/duration `scaleNumber`, effort tube (absent → `—`). Detail sheet,
manual add/edit, merge, relabel, dismiss, delete — unchanged flows, V2 sheets.

### 6.7 Live Workout & Live Session (MOVE)
**Primary:** heart rate. **Secondary:** effort vs today's target, elapsed time.
- Status pill: LIVE dot (`live` motion, `heart`) + "Recording workout" / "Paused" (`scale`).
- HR block: `hero` numeral in the current zone's colour (HR zone ramp, unchanged), "bpm" `scale`;
  absent → `—` + "Waiting for the strap".
- **Zone scale**: horizontal 5-band bar (zone ramp at 0.35, current band at 1.0), caret at current bpm
  (`settle`), zone labels `scale`, lock indicator when a zone is locked (existing zone slider).
- Effort vessel 96 pt with target caret; elapsed time `numeralM` via `TimelineView(.periodic(by: 1))`.
- Session summary tiles: Avg HR · Peak HR · Effort — **`—` until samples exist** (fixes `?? 0`).
- HR trace card (zone bands faint behind the line), distance/pace row, sensor row (leaves).
- Bottom: **opaque `surface` band** (safe-area inset) holding the glass controls (pause/resume, end,
  delete, lock) — role 3. Background plain `canvas` (`ScenicHeroBackground` goes).
- `LiveSessionView` (silent guardian) uses the same register: session ring on `TelosBezel`, guidance
  text `title2`, controls on the opaque band.

### 6.8 Habits hub (PROGRESS) — new, tab 3
**Where and why:** a tab, replacing Focus. A trial assigns something *every day* and needs a one-tap,
always-visible daily entry; only the tab bar gives that. Coach is conversational and would bury
structured results in a transcript; Today already carries too much and shows the day's trial only as
a quest chip. Focus's content already has three other doors (Today's stress tile, More → Stress, the
Health tab's "Go deeper"), and its one daily nudge — the meditation badge — is itself a habit and
moves with the tab. Android's tab set will differ until its lane follows; this is a feature-level, not
data-level, divergence and is flagged to the owner.

Layout (`ScreenScaffold`, title "Habits"):
1. **Today** group: running trial's `TrialCard` (assignment first). If none: empty state "No trial
   running" + primary "Ask the coach" (opens System with a pending prompt through `NavRouter`,
   existing coach launcher path).
2. **Meditation** card (`MeditationCardView`, moved from Focus; badge rule unchanged).
3. **Proposed by the coach**: cards for pending habit-change proposals (title, rationale `subhead`,
   the outcome it targets, expected trial length `scaleNumber`); actions "Start trial" (primary) / "Not
   now" (ghost). Shown only when proposals exist.
4. **Your habits**: grouped rows per tracked habit (caffeine, alcohol, meditation, bedtime, journal
   factors…): name, 30-day frequency `scaleNumber`, strongest measured relationship as one line
   ("HRV +4 ms on days with…", r and n `scaleNumber`) with an **ASSOCIATION** tag, or **TRIAL-TESTED**
   tag + verdict word when a finished trial covers it. Row → habit detail (same dossier template:
   frequency chart, association list, trials).
5. **Finished trials**: `ResultCard`s, newest first.
6. **Go deeper** rows: What Moves You (`InsightsHubView`), Insights (journal), Lab Book, Compare.

HEALTH_V2 changes carried by the same package: `InsightsHubView` drops the dose-response cards and the
damage forecast (H11) and lists `HabitAssociation` rows instead of `EffectRanker` output (H12);
`InsightsView`'s Personal Experiment section is retired and its entry points to this hub's trials (H13).
Moves: nothing ambient. Pips fill on a new valid day (`settle`); the assignment band crossfades at the
day roll.

### 6.9 Coach — "System" tab (SYS) — `CoachView`
- Setup (no key): `ScreenScaffold` with one setup card (fields radius 12, `surfaceInset`), provider
  choice as `TelosChip`s.
- Chat: assistant messages full-width on `canvas` with a 2 pt `accent` leading rail and markdown in V2
  type (`CoachMarkdownTheme`: headings `headline`, tables `scaleNumber`, code SF Mono); user messages
  right-aligned bubbles `surfaceInset` radius 16; numbers the coach cites from state rendered as-is.
  Streaming: only the last message's leaf re-renders (isolate the list from `AICoachEngine`
  publishing). Input bar on an opaque `surface` band (no glass — content scrolls under it), voice
  button icon style, send `accent`. Menu, custom tasks, memory panel → V2 sheets.
- The Coach launcher sheet from Today → V2 sheet.

### 6.10 Focus / Stress (BODY) — `StressView`, `MindfulnessView`
`StressView` keeps its content: current stress on a `TelosBezel` 0–3 dial with three band arcs
(`stress` gradient) whose centre reads a **word** (low / moderate / high, HEALTH_V2 H1d) with the number
only in the provenance row; a window without motion evidence shows `—` + its reason
(`noMotionEvidence`); intraday curve chart (gaps honest), check-in card, breathing entry, meditation card
slot (empty when hosted from Stress). Breathing's "+X % vs start · peak Y ms" outcome shows `—` until
HEALTH_V2 S4 lands (H10), then S4's pre/post readings as two `MetricReadout`s. `MindfulnessView` remains (reachable from More → Stress route is
`StressView`; `MindfulnessView` keeps compiling for the classic path). Breathing (`BreathingView`): the
guided orb is the one place `breath` motion runs, as content.

### 6.11 Settings & More (SYS / FRAME)
- **More** (FRAME, in `RootTabView`): collapsible groups kept (Insights, Body, Data, App), rows §5.8.
- **Settings** (SYS): sections kept in order (Profile, Units, Appearance, Strap, Recovery, Test Centre,
  Features, Backup, Experimental, Diagnostics, About, iOS reality) as grouped row cards. Appearance:
  theme presets as swatch chips (each chip shows accent + chart ramp), appearance mode segmented,
  accent, chart style, sleep chart style, day-cycle background, sky behind cards, card transparency
  (**55–100**), background image, reduce motion in NOOP, app icon. Advanced disclosure unchanged.
- Data/devices/diagnostic screens (Devices, Add Device, Data Sources, Backup, Apple Health, Test Centre,
  Automations, Alarms…) inherit tokens; SYS converts their literal fonts/colours and absent glyphs.

### 6.12 Morning flow (SYS) — `MorningFlowView`
Diagnostic register, dark-only, tokenised (`Diag` → §4.1 diagnostic tokens, `diagnostic` type):
1. Top bar: close/back (glass role 5) + **segmented progress** (one cell per step, `accent` filled,
   `diagLine` empty) + step counter `scaleNumber` "2/7".
2. Dream stage: overline `scale` `diagMuted`, question `diagnostic`, editor on `diagCard`.
3. Question stages: option cards (`diagCard`, 1 pt `diagLine`, selected: 2 pt `accent` border + accent
   radio), CONFIRM `diagnosticS` on a white capsule (existing).
4. **Brief:** Level `numeralL`→`hero` count-up **once** (no dispatch loop) with "NN% measured" when
   partial; Rest and Charge vessels (`flow` settle) with confidence tags; key figures table
   (`scaleNumber` labels, `numeralS` values, deltas vs yesterday with sign + arrow); written brief `body`.
   **Gate checklist** (from `MorningGate`): strap drained · night scored · level written, each a row with
   a state glyph (pending ○ / done ●) — the continue button says what it waits for, as today.
5. Gear choice (Steady / Push / Relentless): three option cards, level still on screen.

### 6.13 Widgets & Live Activity (FRAME)
Widgets cannot animate or use app-target views; they use `TelosRing`, `TelosBezel`, `TelosType`,
`TelosColor`. Container background `surface` (light/dark), `containerBackground(for: .widget)` always.
- **NOOP widget** (small/medium/large, accessory): small = three 44 pt rings (Rest, Charge, Effort)
  with numerals; medium adds live HR `numeralL` + strap battery `scaleNumber`; large adds the Level
  radar mini (static) and today's quest count. Accessory circular = Charge ring; rectangular = three
  figures; inline = "C 72 · E 41 · R 88".
- **Level** (small, circular): radar mini + level `numeralL` + delta chip + "NN% measured" when partial
  (`scale`); pending day dims to 0.55 (existing honesty).
- **Steps · Effort · Stress strip** (lock screen): unchanged design language (it is the reference); only
  token names swap.
- **Heart Rate**, **Stress** (medium): chart §5.7 static, current value `numeralL`, stale data →
  `textSecondary` + "as of HH:MM" `scaleNumber`.
- **Water** (small): tube (static) + `numeralM` ml + goal `scaleNumber`.
- **Coach brief** (small, rect, inline): `scale` "BRIEF" + 3 lines `footnote`, time `scaleNumber`.
- **Live Activity / Dynamic Island**: HR `numeralL` in `heart`, effort `scaleNumber`, elapsed; compact
  leading heart glyph, trailing bpm.
Every figure judged by its own day stamp (existing); absent → `—`.

### 6.14 Surfaces that come from HEALTH_V2 (placement decided here)
HEALTH_V2 leaves placement to design. Decisions, all built from §5 components, no new component kinds:
- **Weekly movement plan & review (S3):** a "This week" card at the **top of the Health tab** (above the
  muscle model): aerobic minutes vs range as a `TelosLinearScale` with the range hatched, strength
  sessions as pips (2 cells), step target as a caret on a linear scale, the day's guidance word. The
  day's slice (today's guidance line) appears on Today inside the State card. The weekly review is a
  `MetricReadout`-led card in the same slot on review day, and a page in the morning brief. VO₂max
  appears only there, as a monthly trend with its ±5 band and method (H15). BODY builds it.
- **Sleep anchor (S2):** a "Tonight" card directly under the Rest hero on Sleep (wake anchor, bedtime
  target, wind-down start, caffeine cutoff as a timeline on a `TelosLinearScale` with carets, times in
  `scaleNumber`); in the evening the State card on Today carries the next anchor step. SLEEP builds it.
- **Honest breathing (S4):** pre/post quiet readings on the breathing result as two `MetricReadout`s
  with confidence, and a trend in Health Monitor. BODY builds it.
- **Imprecise numbers (H15):** VO₂max as an integer with "±5" and its method; stage minutes on sparse
  4.0 nights as "~1 h 10 m" (the "~" is the honest mark there). TODAY owns `HostedCards.swift` and
  `VitalSignsSummary.swift`; SLEEP applies the same formatter output in its stage rows.
- **Settings (H1b, H4):** "Full-screen stress alert" toggle (default off) and one toggle per ritual slot,
  in Settings → Features. SYS builds them.
- **Illness heads-up (H7–H8):** `HealthAlertBanner` layout is TODAY's; wording and gating are the health
  package's.

These screens are new files owned by the health implementation package's wiring plus the design
package named above for layout; each design package adds the new file to its own ownership list when
the health package lands, and never edits the health package's store/logic files.

---

## 7. Motion system

### 7.1 The rule
**Motion must encode data or state.** If removing an animation would lose no information about the
data or the app's state, it does not ship. Allowed triggers: a value changed · data arrived · the user
touched something · a live stream is running · a sync is running · a screen/sheet transition the user
caused.

### 7.2 What animates
| Thing | Trigger | Token | Max duration |
|---|---|---|---|
| Vessel/tube level + slosh | score/value changed or first arrived | `flow` | 1.2 s, then paused |
| Numerals | value changed | `countUp` | 0.6 s |
| Carets (target, bezel value) | value/target changed | `settle` | 0.5 s |
| HR thread | new sample (1 Hz) | redraw on sample; dot `beat` | 0.3 s per sample |
| LIVE dot | stream active | `live` loop (gated) | while live |
| Sync indicator | sync running | existing `ChargeSyncIndicator` (gated) | while syncing |
| Pull-to-refresh vessel | finger | direct | — |
| Segments, chips, toggles | touch | `select` | 0.3 s |
| Press | touch | `press` | 0.12 s |
| Card insert/remove, expand | data/state change | `fade` / `screen` | 0.46 s |
| First-arrival stagger | first data on a screen per launch | `stagger` (4 items) | 0.14 s total offset |
| Tap splash (vessel) | touch | sim splash | ≤ 1.2 s |
| Breathing orb | exercise running | `breath` | while running |

### 7.3 Frame clocks allowed (all gated per §2.1 rule 1)
Vessel settle, tube settle, vessel tap splash, `ChargeSyncIndicator` spinner, LIVE dot, breathing
exercise, `LiveSessionView` guidance ring. Periodic clocks (not censused, still minimal): elapsed-time
1 s, quest countdowns 1 s, sky re-evaluation every 900 s.

### 7.4 What never animates
Backgrounds and the sky (static; re-rendered at most every 15 min) · charts on scroll or appear (no
draw-in) · layout on data refresh (no implicit `.animation` on containers; animations attach to the
smallest view whose value changed — the #104 lesson) · tab switches · shimmer/skeletons · text reflow ·
anything behind a sheet · anything offscreen · the wordmark (except its tap egg) · gradients.

### 7.5 Reduce Motion / Low Power / quiet motion
All loops pose still (`poseStill`); fills and numerals jump to value; slosh, splash, stagger, count-up
and caret slides are removed; fades remain (≤ 0.2 s); the typewriter shows full text; the tap egg plays
only its haptic. CoreMotion is never started while any of the three signals is set (existing
`LiquidMotion.quietNow`).

---

## 8. Work breakdown for parallel implementation

### 8.1 Phases and dependencies

```
Phase 0  DS  Foundations ──────────────┐
Phase 1  INS Instruments (needs DS) ────┤
Phase 2  (parallel, need DS + INS)      ├─> FRAME · TODAY · SLEEP · BODY · MOVE · SYS · PROGRESS(part A)
External gates:                          │
  quest agent lands ────────────────────┼─> PROGRESS part B (quests)  and  FRAME's RootTabView edits
  health logic package lands ───────────┼─> PROGRESS part C (habits wiring)
  PROGRESS HabitsHubView merged ────────┴─> FRAME final step: tab 3 swap to Habits
Phase 3  Integration (coordinator): strings catalogs, xcodegen, builds, perf + a11y pass
```

DS and INS are small and must merge before anyone else starts writing view code; screen packages may
read the spec and plan in the meantime.

### 8.2 Global rules for every package
- Own exactly the files listed. **Any file not listed in your package is read-only for you.** If you
  need a change in someone else's file, write it in your hand-off note; do not edit.
- Global do-not-touch (no package): `Strand/AI/**` (another agent is editing it now), `Strand/BLE/**`,
  `Strand/Collect/**`, `Strand/Data/**` (incl. `QuestStore`, `QuestModeStore`, `QuestAutoComplete`,
  `TodayLayoutPrefs`), `Strand/App/**`, `Strand/System/**`, `Strand/Oura/**`, `Strand/MenuBar/**`,
  `Strand/Resources/**`, every `Localizable.xcstrings`, `Packages/*` except `StrandDesign`,
  `StrandiOSShared/**`, `StrandiOS/Widgets/**`, `StrandiOS/Health/**`, `StrandiOS/System/**`,
  `NOOPWatch*/**`, `android/**`, `Tools/**`, `project.yml`, `Strand.xcodeproj`, and the logic files
  `LevelBarModel`, `LevelBaselineStore`, `LevelDayFreeze`, `LevelLedger`, `LevelWiring`, `MorningGate`,
  `SleepModel`, `MuscleBaselineStore`, `ChargeBreakdownFormat/Wiring`, `BiofeedbackController/Prefs`,
  `RRPacketObserver`, `LiveConsoleSnapshot`, `SystemHaptics`, `TodayCustomizationMetadata`,
  `StrengthProgressionCopy`, and the classic `TodayView.swift` (it inherits tokens; no edits).
- Behaviour, data flow, navigation targets and persisted keys do not change unless this spec says so.
- Every package: build `NOOPiOS` **and** `Strand` (macOS 13) locally, run `swift test` in
  `Packages/StrandDesign`, run the grep gates (§9.1), attach light + dark screenshots at default and
  AX3 text size for each screen touched, and list new strings.
- Do not commit or push unless the coordinator says so.
- **Files other agents had uncommitted edits in when this spec was cut** (start on them only after those
  edits land, then rebase): `StrandiOS/App/RootTabView.swift` and the quest view files (quest agent),
  `Strand/Screens/LevelTimelineSheetView.swift` (FRAME), `Strand/Screens/MuscleModelCardView.swift`
  (BODY), `Strand/System/DayRitualScheduler.swift` (nobody here), everything in `Strand/AI/**`.

### 8.3 Packages

**P1 · DS — Foundations** (first; no dependencies)
- Owns: `Packages/StrandDesign/Sources/StrandDesign/`: `NoopVisualStyle.swift`, `Palette.swift`
  (values/re-pointing only; data ramps untouched), `Typography.swift`, `Motion.swift`,
  `NoopMotion.swift`, `Components.swift`, `StrandCard.swift`, `StatePill.swift`, `NoopButton.swift`,
  `NoopLiquidGlassSearchField.swift`, `Appearance.swift` (AccentColor mint values only; enums, keys and
  raw values frozen), `DomainTheme.swift`, `SceneHeroBackground.swift`, `TimeOfDayBackground.swift`,
  `Haptics.swift`; **new** `Telos/TelosColor.swift`, `Telos/TelosType.swift`,
  `Telos/TelosMetrics.swift` (space, radius, stroke, opacity, elevation), `Telos/TelosMotion.swift`,
  `Telos/TelosComponents.swift` (`MetricReadout`, `ConfidenceTag`, `AbsentValue`, `ProvenanceRow`,
  `TelosChip`, `TelosTag`, `TelosListRow`, `TelosEmptyState`, `\.telosCardOpacity` key);
  **new tests** `Tests/StrandDesignTests/TelosContrastTests.swift` (every text/fill pair in §4.1 against
  its surfaces, both schemes), `TelosTokenMappingTests.swift` (old names resolve to V2 values).
- Do not touch: `WatchScoreSnapshot.swift`, `ChargeSyncIndicator.swift`, `SportIcon.swift`,
  `MotionTrace.swift`, `StrandDesign.swift` (version pinned by a test), all chart/gauge files (INS),
  `BrandSleepRamp` values, any `Localizable.xcstrings`.
- Acceptance: all §4 tokens exist with the exact values; re-pointing makes the unmodified app render V2
  surfaces/text/type; cards have no shadow and one flat fill; `FrostedCardSurface` has no
  `@AppStorage`; existing StrandDesign tests pass; new contrast tests pass; watchOS/macOS compile.

**P2 · INS — Instruments** (after DS)
- Owns: StrandDesign `BevelGauge.swift`, `RecoveryRing.swift`, `StrainGauge.swift`, `GlowRing.swift`,
  `BrandMark.swift`, `Sparkline.swift`, `TrendChart.swift`, `ChartHover.swift`, `OverviewHRChart.swift`,
  `Hypnogram.swift`, `PipBar.swift`, `TypicalRangeBar.swift`, `YearHeatStrip.swift`, `DayNavBar.swift`;
  **new** `Telos/TelosRing.swift`, `Telos/TelosBezel.swift`, `Telos/TelosLinearScale.swift`;
  `Strand/Liquid/LiquidCore.swift`, `Strand/Liquid/LiquidPrimitives.swift`,
  `Strand/Liquid/LiquidSky.swift`.
- Deliver: the vessel of §5.6 behind the unchanged `LiquidVessel`/`LiquidScoreGauge`/`LiquidTube`
  initialisers; settle-then-pause clocks; tilt only while settling; HR thread redrawn per sample with
  no glint and no endpoint loop; static sky with §4.1 keyframes, deterministic stars, 900 s
  re-evaluation, `LiquidSky` becomes a thin wrapper over the static renderer; chart style §5.7
  (`.monotone`, grid, callout pinned top); `TelosRing/Bezel/LinearScale` usable from widgets.
- Do not touch: `LiquidTodayView.swift`, `StateTileViews.swift`, `StepCalibrationTile.swift`,
  `WorkoutFeedbackButton.swift`, `LiveSessionView.swift`, `ChargeSyncIndicator.swift`, screen files.
- Acceptance: idle Today (after P4) shows zero running `TimelineView(.animation)`; a value change
  settles and pauses within 1.2 s; `TrendChartScrub*`, `HypnogramTimeLabelTests`,
  `OverviewHRChartAnnotationTests`, `HrGap*`, `QuietMotionCoverageTests` pass; nil values draw bare
  tracks.

**P3 · FRAME — Shell, level strip, widgets** (after DS+INS; `RootTabView` only after the quest agent
lands; tab-3 swap only after P9's `HabitsHubView` merges)
- Owns: `StrandiOS/App/RootTabView.swift` (all of it except the quest-summary hosting block, which stays
  byte-identical), `StrandiOS/App/StrandiOSApp.swift`, `Strand/Screens/ScreenScaffold.swift`,
  `Strand/Screens/LevelOverlayBarView.swift`, `Strand/Screens/LevelRadarView.swift`,
  `Strand/Screens/LevelTimelineSheetView.swift`, `StrandiOSWidgets/*.swift` (all widget views, incl.
  `NOOPLiveActivity.swift`).
- Deliver: §6.1, §6.13; remove the tab crossfade; inject `\.telosCardOpacity`; level strip type and
  AX layout; radar per §5.6 with single-animation count-up; tab 3 swap (label, symbol `flask`, badge,
  a11y label); HEALTH_V2 hooks H1 (gate the stress overlay on `stress.alertScreen.enabled`) and H2
  (remove the optimum overlay) — coordinate timing with the health package, which owns
  `LiveStressMonitor`/`DayAlerts`.
- Do not touch: `WidgetPublish.swift`, `WidgetSnapshot.swift` and all snapshot schema, quest files,
  `MindfulnessView.swift` (BODY), `HabitsHubView` (PROGRESS).
- Acceptance: tab switches have no implicit animation; strip readable at AX sizes; widgets render in
  light/dark/tinted/vibrant modes with `—` for missing figures; Live Activity compiles for iOS 17.

**P4 · TODAY** (after DS+INS)
- Owns: `Strand/Liquid/LiquidTodayView.swift`, `Strand/Liquid/StateTileViews.swift`,
  `Strand/Liquid/StepCalibrationTile.swift`, `Strand/Liquid/WorkoutFeedbackButton.swift`;
  `Strand/Screens/`: `TodayTrioHeroView.swift`, `TodayStressTileView.swift`, `EnergyTileView.swift`,
  `HydrationTileView.swift`, `NutritionTileView.swift`, `JournalReminderCard.swift`,
  `MissionMarqueeView.swift`, `HealthAlertBanner.swift`, `AutoWorkoutCard.swift`,
  `DashboardCards.swift`, `HostedCards.swift`, `HostedTrendCard.swift`,
  `TodayCustomizationSheet.swift`, `EditableLayoutList.swift`, `BedroomClimateViews.swift`,
  `RitualSheetView.swift`, `VitalSignsSummary.swift`, `ProfileAvatarView.swift`.
- Deliver: §6.2 (VesselTrio replaces the ring trio; gutter 16; Material removed; honest nil fills; HR
  card per spec; state card; recovery vitals rings); remove `checkOptimum` (H2); H15 display formatting
  in `HostedCards.swift` / `VitalSignsSummary.swift` using the health package's formatter functions.
- Do not touch: `TodayView.swift`, `QuestViews.swift`, `StreakStripView.swift`, sleep cards hosted on
  Today (SLEEP owns them), `MenstrualCycleHomeCard` (in `SkinTempCardsView.swift`, BODY).
- Acceptance: §2.1 Today budgets met on an iPhone 12 Pro-class device; no section lost; Arrange and
  Customise unchanged; every hero/tile shows confidence below solid; VoiceOver reads each vessel as
  one element with value and confidence.

**P5 · SLEEP** (after DS+INS)
- Owns: `Strand/Screens/`: `SleepView.swift`, `StagesCard.swift`, `StagesVsTypicalCard.swift`,
  `NightDetailCard.swift`, `AsleepDurationCard.swift`, `SleepDebtLedgerCard.swift`,
  `HoursVsNeededCard.swift`, `ConsistencyCard.swift`, `BodyClockDialCard.swift`,
  `SleepAlarmSheet.swift`, `SleepCustomizationSheet.swift`, `SmartAlarmView.swift`,
  `DreamJournalView.swift`, `BedroomHistoryView.swift`.
- Deliver: §6.3; `SleepBodyClockDial`'s `AppModel` observation moved to a leaf.
- Do not touch: `SleepModel.swift`, `Hypnogram.swift` (INS), `EditableLayoutList.swift` (TODAY).
- Acceptance: all four sleep chart styles render; naps/wake edit/undo flows intact; empty/sparse
  states per §5.13.

**P6 · BODY — Health, Explore, Stress** (after DS+INS)
- Owns: `Strand/Screens/`: `TrendsView.swift`, `VitalTrioCardView.swift`, `WeeklyDigestView.swift`,
  `TrendsReportView.swift`, `TrainingLoadCard.swift`, `MuscleModelCardView.swift`,
  `StrengthProgressionCardView.swift`, `StrengthProgressionDetailView.swift`, `HealthView.swift`,
  `SkinTempCardsView.swift`, `HRVSnapshotView.swift`, `FullDayChartView.swift`,
  `MetricExplorerView.swift`, `CompareView.swift`, `CoupledView.swift`, `StressView.swift`,
  `MindfulnessView.swift`, `BreathingView.swift`, `StressCheckInCard.swift`, `HydrationView.swift`.
- Deliver: §6.4, §6.5, §6.10, the Health-tab and breathing parts of §6.14; the metric dossier
  template; `AppModel` observations in HealthView sections moved to leaves; `?? 0` tube fixed; stress
  as words (H1d); breathing outcome `—` until S4 (H10).
- Do not touch: `MeditationCardView.swift` (PROGRESS), `LevelBarModel.swift`, analytics.
- Acceptance: Health tab title "Health"; "Go deeper" links resolve to existing routes; all charts
  `.monotone` with honest gaps; the dossier used by every `TabRoute.metric` push.

**P7 · MOVE — Workouts & live** (after DS+INS)
- Owns: `Strand/Screens/`: `WorkoutsView.swift`, `WorkoutDetailView.swift`, `ManualWorkoutSheet.swift`,
  `WorkoutSelectionScreen.swift`, `LiveWorkoutView.swift`, `LiveView.swift`, `IntervalTimerView.swift`;
  `Strand/Liquid/LiveSessionView.swift`.
- Deliver: §6.6, §6.7; Material removed; control band opaque; `SessionSummaryCard` shows `—` without
  samples.
- Do not touch: `ActiveWorkout*` / `LiveSessionRunner` / `GpsWorkoutRecorder` (Strand/App), BLE.
- Acceptance: live screen sustains 60 fps while streaming; controls reachable one-handed with 44 pt
  targets; Reduce Motion leaves no looping element except the gated LIVE dot (which poses still).

**P8 · SYS — Coach, Settings, morning flow, data screens** (after DS+INS)
- Owns: `Strand/Screens/`: `CoachView.swift`, `CoachLauncherSheet.swift`, `CoachMarkdownTheme.swift`,
  `CoachPrompts.swift` (display only), `CustomTaskSheet.swift`, `SettingsView.swift`,
  `MorningFlowView.swift`, `ScoringGuideView.swift`, `HowNoopWorksView.swift`,
  `NoopLimitationsView.swift`, `WhatsNewView.swift`, `UpdatesInboxView.swift`, `DevicesView.swift`,
  `AddDeviceWizard.swift`, `DataSourcesView.swift`, `WhoopCloudCard.swift`, `BackupSyncView.swift`,
  `StorageView.swift`, `AppleHealthView.swift`, `XiaomiBandView.swift`, `TestCentreView.swift`,
  `RawDataCollectorView.swift`, `AutomationsView.swift`, `PowerSavingView.swift`, `RoutinesView.swift`,
  `SmartLightsView.swift`, `MarkerEditorView.swift`, `AppleWatchSetupView.swift`,
  `AppleWatchAboutView.swift`; `Strand/Onboarding/OnboardingWizard.swift`;
  `StrandiOS/App/CoachVoiceInput.swift`, `StrandiOS/App/SiriShortcutsSettingsView.swift`,
  `StrandiOS/App/ShortcutExportSettingsView.swift`.
- Deliver: §6.9, §6.11 (Settings), §6.12; card-transparency slider 55–100; chat streaming isolated;
  Settings toggles for the opt-in stress screen (H1b) and each ritual slot (H4), bound to keys the
  health package defines.
- Do not touch: `Strand/AI/**` (coach engine, prompts logic — another agent), `MorningGate.swift`,
  `NotificationSettingsView.swift` (macOS-only), `Strand/App/TermsGateView.swift`.
- Acceptance: morning flow uses only tokens (no `Diag` literals); coach streaming re-renders only the
  last message; Settings has every existing control.

**P9 · PROGRESS — Habits, quests, insights** (part A after DS+INS; part B after the quest agent; part C
after the health logic package)
- Owns: part A — `Strand/Screens/`: `InsightsHubView.swift`, `InsightsView.swift`, `LabBookView.swift`,
  `IntelligenceView.swift`, `FusedRecordView.swift`, `RhythmView.swift`, `V5PillarHosts.swift`,
  `MindSection.swift`, `CaffeineLogCard.swift`, `JournalLogCard.swift`, `MeditationCardView.swift`;
  **new** `Strand/Screens/Habits/HabitsHubView.swift`, `HabitsViewModels.swift` (view-side structs),
  `TrialCardView.swift`, `TrialResultCardView.swift`, `EffectIntervalPlot.swift`,
  `HabitRowView.swift`, `HabitDetailView.swift`. Part B — `Strand/Screens/QuestViews.swift`,
  `Strand/Screens/QuestPopupView.swift`, `Strand/Screens/QuestPenaltyViews.swift`,
  `Strand/Screens/StreakStripView.swift` (every quest view file is in this one package so they are never
  split).
- Deliver: §5.14, §5.15, §6.8; HEALTH_V2 H11–H13 in `InsightsHubView` / `InsightsView` (part A,
  after the health package exposes `HabitAssociation`); the neutral daily summary card of §5.14 (H3).
  Part B **restyles without restructuring**: `QuestStripView`'s single
  `.sheet` stays on its root `VStack`; no new presenters; the penalty block is the first child of that
  root; `DiagnosticAlertView` restyled per §5.12.
- Coordination: the health logic package owns the trial/habit model and store; P9 maps it onto
  `HabitsViewModels` in one adapter function and ships `#if DEBUG` preview fixtures only (never
  runtime fixtures). Until part C, `HabitsHubView` renders the meditation card, Go-deeper rows and the
  empty trial state — it must compile and ship honestly without the logic.
- Do not touch: `Quest.swift`, `QuestGoal.swift`, `QuestDifficulty.swift`, `QuestPenalty.swift`
  (StrandAnalytics), `QuestStore.swift`, `QuestModeStore.swift`, `QuestAutoComplete.swift`,
  `QuestPenaltyAssessor.swift`, `QuestPenaltyStore.swift`, `QuestGenerator.swift`,
  `DailyMission.swift`, the quest-summary hosting in `RootTabView.swift`, any habit/trial logic file.
- Acceptance: the effect plot draws identical interval styling for all verdicts; inconclusive never
  uses critical colour; association rows always tagged; penalty numbers match the logic exactly;
  the review sheet still opens after the last quest resolves (the #regression the root presenter
  exists for).

### 8.4 Integration step (coordinator, after all packages)
1. Collect the new-string lists; add English + de/es/fr/pt-PT to the right catalog in one commit.
2. `xcodegen generate`; build `NOOPiOS`, `NOOPWidgets`, `Strand` (macOS), watch targets.
3. `swift test` in all packages; `Tools/i18n_audit.py --ci`; doc-comment lint.
4. Perf pass on an iPhone 12 Pro-class device against §2.1; a11y pass (VoiceOver route through each
   tab, AX5 screenshots, Increase Contrast, Reduce Motion).

---

## 9. Risks and how each package verifies

### 9.1 Mechanical gates (run on owned files before hand-off)
```
grep -nE 'Color\(\.sRGB|Color\(white:|Color\(hex:' <files>            # 0 outside Telos/ token files
grep -nE '\.font\(\.system\(size:' <files>                              # 0 (use TelosType)
grep -nE 'ultraThinMaterial|thinMaterial|regularMaterial|\.blur\(' <files>  # 0
grep -nE '"–"' <files>                                                  # 0 (use TelosType.absent)
grep -nE '\?\? 0\)' <files>                                             # each hit justified in the PR
grep -nE 'repeatForever|TimelineView\(\.animation' <files>              # each names poseStill
grep -nE 'glassEffect|buttonStyle\(\.glass' <files>                     # 0 outside nativeLiquidGlass* helpers
grep -nE 'EnvironmentObject.*(AppModel|LiveState|AICoachEngine)' <files> # no new ones
```

### 9.2 Risks
| Risk | Where | Mitigation / verification |
|---|---|---|
| Re-pointed tokens change every screen at once (unexpected contrast or truncation) | DS | Contrast tests; DS posts before/after screenshots of Today, Sleep, Settings; screen packages re-check `strandOverline()` truncation (mono is wider) at default and AX3 |
| Vessel liquid reintroduces per-frame cost | INS, TODAY | Instruments: idle Today 0 clocks; settle ≤ 1.2 s; `QuietMotionCoverageTests` |
| Removing shadows/gradients flattens hierarchy | DS | hierarchy carried by fill steps (`canvas` < `surface` < `surfaceRaised`) + 1 pt lines; review in both schemes |
| Broad observation creeps back | all | grep gate; Instruments "SwiftUI View Body" count while streaming: only HR leaf per second |
| Honesty regression (zeros, hidden confidence, overshooting curves) | all | grep gates; checklist per screen: absent, calibrating, building, carried, partial-coverage states screenshotted |
| Dynamic Type clipping in gauges and the level strip | TODAY, FRAME, INS | AX3 and AX5 screenshots; layout switches at `.accessibility1` |
| macOS 13 / watchOS compile break from shared files | all | build `Strand` macOS and watch targets locally (CI does not) |
| "Serious" penalties vs HEALTH_V2's no-punitive-screens rule (H3) | PROGRESS | seriousness only through the rail, critical *cost* ink and exact numbers; no red card, no strike-through, no haptic; physiology and trial quests never appear; screenshots reviewed against both documents |
| Quest restyle collides with the quest agent | PROGRESS, FRAME | part B and RootTabView edits start only after that agent's merge; single root `.sheet` preserved |
| Habits UI shipped before its logic shows invented data | PROGRESS | no runtime fixtures; empty state until the health package lands |
| String catalog merge conflicts | all | nobody edits catalogs; integration step only |
| Android tab-set divergence (Habits vs Focus) | FRAME | flagged to owner; no stored data or keys change |
| Glass over moving content re-samples every frame | TODAY, MOVE | glass only in §4.9 roles; live controls on an opaque band |

---

## Appendix A — Expected new strings (everything else reuses existing copy)

Habits hub: "Habits", "Trial", "Result", "Today", "ON", "OFF", "valid", "excluded", "Did you do it
today?", "No trial running", "Ask the coach", "Proposed by the coach", "Start trial", "Not now",
"Your habits", "Finished trials", "Helped", "No meaningful effect", "Inconclusive", "Meaningful",
"Better", "Association", "Trial-tested", "Randomised", "Alternating", "Outcome: %@", "95% CI %@ to %@".
Shell: "Habits, today's meditation is still open". Health tab: "Go deeper". Penalty block: copy supplied
by the quest agent ("Missed", "Debt", "Debt cleared" if not already present). Morning flow: step counter
"%d/%d" (format only).

## Appendix B — Token migration checklist (DS)

`surfaceBase→canvas` · `surfaceRaised→surface` · `surfaceOverlay→surfaceRaised` ·
`surfaceInset→surfaceInset` · `hairline→line` · `hairlineStrong→lineStrong` · `hairlineSoft→lineSoft` ·
`text*→text*` (new values) · `heroFill→surface` · `heroBorder→line` · `mint/mintDeep/mintGlow→accent
family` · `statusPositive/Warning/Critical→positive/warning/critical` (titanium arm) ·
`restColor/restLine/restGlow→rest` · `liquidHeart→heart` · `metricCyan→lungs` ·
`glowAmbient→.clear` · `rimGradient→flat line` · `NoopSurfaceElevation.resting→flat` ·
`.raised→raised` · `StrandFont prose styles→SF Pro` · `StrandFont.overline→SF Mono` ·
`overlineTracking 0.45→0.8` · `cardRadius 22→20` · `compactRadius 16→14` · `sectionGap 26→24` ·
`chipFillOpacity 0.14→0.16` · `chipBorderOpacity 0.30→0.32` · `StrandMotion.*/NoopMotion.*→TelosMotion`.
