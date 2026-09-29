import XCTest
@testable import StrandAnalytics

/// The sitting-break nudge's pure detector: movement minutes, breaks, abstention, suppression (incl. across
/// midnight), reset, backoff after ignored nudges, and the strap late-correction.
final class SittingBreakDetectorTests: XCTestCase {

    // 2023-11-14 00:00:00 UTC. Every test runs at tz offset 0 unless it says otherwise.
    private let midnight = 1_699_920_000
    private func at(_ h: Int, _ m: Int = 0) -> Int { midnight + h * 3600 + m * 60 }

    private let authorized = SittingBreakContext(motionAccess: .authorized)
    /// Default config with quiet hours 22:00–07:00.
    private let cfg = SittingBreakConfig(enabled: true, intervalMinutes: 30)

    // ── Minute builders ───────────────────────────────────────────────────────────────────────────────

    /// `count` seated minutes starting at `start`: phone confidently stationary, no steps, HR `hr`.
    private func sit(_ start: Int, _ count: Int, hr: Double? = 70) -> [MovementMinute] {
        (0..<count).map { MovementMinute(start: start + $0 * 60, activity: .stationary, confidence: .high,
                                         steps: 0, heartRate: hr) }
    }

    /// `count` walking minutes: phone says walking (medium), ~100 steps/min, HR 95.
    private func walk(_ start: Int, _ count: Int) -> [MovementMinute] {
        (0..<count).map { MovementMinute(start: start + $0 * 60, activity: .walking, confidence: .medium,
                                         steps: 100, heartRate: 95) }
    }

    private func eval(_ minutes: [MovementMinute], now: Int, context: SittingBreakContext? = nil,
                      config: SittingBreakConfig? = nil,
                      state: SittingBreakState = .initial) -> SittingBreakDecision {
        SittingBreakDetector.evaluate(minutes: minutes, context: context ?? authorized, config: config ?? cfg,
                                      state: state, nowSec: now, tzOffsetSec: 0)
    }

    // ── Thresholds live in one place ──────────────────────────────────────────────────────────────────

    func testThresholdsArePinned() {
        XCTAssertEqual(SittingBreakDetector.movingCadenceSpm, 60)
        XCTAssertEqual(SittingBreakDetector.hrLiftBpm, 10)
        XCTAssertEqual(SittingBreakDetector.breakMovingMinutes, 2)
        XCTAssertEqual(SittingBreakDetector.breakSpanMinutes, 3)
        XCTAssertEqual(SittingBreakDetector.breakPooledSteps, 120)
        XCTAssertEqual(SittingBreakDetector.baselineMinStillMinutes, 10)
        XCTAssertEqual(SittingBreakDetector.renudgeMinutes, 30)
        XCTAssertEqual(SittingBreakDetector.maxIgnored, 3)
        XCTAssertEqual(SittingBreakDetector.backoffMinutes, 120)
        XCTAssertEqual(StrapCueSettings.defaultSittingIntervalMinutes, 30)
    }

    // ── The timer ─────────────────────────────────────────────────────────────────────────────────────

    func testNudgesOnceTheIntervalPassesWithNoBreak() {
        let now = at(10)
        let d29 = eval(sit(now - 29 * 60, 29), now: now)
        XCTAssertEqual(d29.verdict, .accumulating(seconds: 29 * 60))
        let d30 = eval(sit(now - 30 * 60, 30), now: now)
        XCTAssertEqual(d30.verdict, .nudge(sittingSeconds: 30 * 60))
    }

    func testIntervalSettingIsHonoured() {
        let now = at(11)
        let c45 = SittingBreakConfig(enabled: true, intervalMinutes: 45)
        XCTAssertEqual(eval(sit(now - 40 * 60, 40), now: now, config: c45).verdict, .accumulating(seconds: 40 * 60))
        XCTAssertEqual(eval(sit(now - 45 * 60, 45), now: now, config: c45).verdict, .nudge(sittingSeconds: 45 * 60))
    }

    func testTwoMinuteWalkResetsTheTimer() {
        let now = at(10)
        let start = now - 47 * 60
        let ms = sit(start, 35) + walk(start + 35 * 60, 2) + sit(start + 37 * 60, 10)
        let d = eval(ms, now: now)
        XCTAssertEqual(d.verdict, .accumulating(seconds: 10 * 60))
        XCTAssertEqual(d.nextState.lastBreakEnd, start + 37 * 60)
    }

    func testTenStepsDoNotReset() {
        let now = at(10)
        let start = now - 36 * 60
        let stroll = [MovementMinute(start: start + 20 * 60, activity: .stationary, confidence: .low,
                                     steps: 10, heartRate: 72)]
        let ms = sit(start, 20) + stroll + sit(start + 21 * 60, 15)
        let d = eval(ms, now: now)
        XCTAssertEqual(d.verdict, .nudge(sittingSeconds: 36 * 60))
        XCTAssertNil(d.nextState.lastBreakEnd)
    }

    func testTwoMinuteWalkSplitAcrossMinuteBoundariesStillCounts() {
        // 50 + 70 steps over two minutes, no activity label: one minute is below cadence, but the pooled
        // 120 steps inside the span make it the studied 2-minute dose.
        let now = at(10)
        let start = now - 40 * 60
        // HR stays near the seated 70, so only the pooled-steps rule can see this break.
        let split = [MovementMinute(start: start + 30 * 60, activity: .unknown, confidence: .low, steps: 50, heartRate: 72),
                     MovementMinute(start: start + 31 * 60, activity: .unknown, confidence: .low, steps: 70, heartRate: 73)]
        let ms = sit(start, 30) + split + sit(start + 32 * 60, 8)
        XCTAssertEqual(eval(ms, now: now).verdict, .accumulating(seconds: 8 * 60))
    }

    func testFiveMinutesOfChoresWithLiftedHRAndPhoneMotionResets() {
        // Cooking/tidying: few steps (25/min), phone moving but not "walking", HR 15 over the seated 70.
        let now = at(10)
        let start = now - 40 * 60
        let chores = (0..<5).map { MovementMinute(start: start + (30 + $0) * 60, activity: .unknown,
                                                  confidence: .low, steps: 25, heartRate: 85) }
        let ms = sit(start, 30) + chores + sit(start + 35 * 60, 5)
        let base = SittingBreakDetector.sittingBaseline(SittingBreakDetector.normalized(ms), nowSec: now)
        XCTAssertEqual(base, 70)
        let classes = SittingBreakDetector.classify(SittingBreakDetector.normalized(ms), baseline: base)
        XCTAssertEqual(classes[31], .moving(.heartRate), "second lifted minute is sustained lift with phone motion")
        XCTAssertEqual(eval(ms, now: now).verdict, .accumulating(seconds: 5 * 60))
    }

    func testLiftedHRAloneWithPhoneConfidentlyStationaryDoesNotReset() {
        // HR jumps for two minutes (a phone call, a coffee) but the phone is confidently at rest, no steps.
        let now = at(10)
        let start = now - 35 * 60
        let ms = sit(start, 30) + sit(start + 30 * 60, 2, hr: 90) + sit(start + 32 * 60, 3)
        let d = eval(ms, now: now)
        XCTAssertNil(d.nextState.lastBreakEnd)
        XCTAssertEqual(d.verdict, .nudge(sittingSeconds: 35 * 60))
    }

    func testHRNeverCountsWithoutAPersonalBaseline() {
        // Fewer than 10 still minutes with HR → no baseline → rule 3 cannot fire, whatever the HR.
        let now = at(10)
        let start = now - 12 * 60
        let ms = sit(start, 5, hr: nil) + (0..<7).map {
            MovementMinute(start: start + (5 + $0) * 60, activity: .unknown, confidence: .low, steps: 20, heartRate: 120)
        }
        XCTAssertNil(SittingBreakDetector.sittingBaseline(ms, nowSec: now))
        XCTAssertTrue(SittingBreakDetector.classify(ms, baseline: nil).allSatisfy { $0 == .still })
    }

    // ── Abstention: never guess ───────────────────────────────────────────────────────────────────────

    func testAbstainsWithoutMotionPermission() {
        let now = at(10)
        for access in [MotionAccess.denied, .notDetermined, .restricted] {
            let d = eval(sit(now - 60 * 60, 60), now: now, context: SittingBreakContext(motionAccess: access))
            XCTAssertEqual(d.verdict, .abstain(.motionNotAuthorized))
        }
        let u = eval(sit(now - 60 * 60, 60), now: now, context: SittingBreakContext(motionAccess: .unavailable))
        XCTAssertEqual(u.verdict, .abstain(.motionUnavailable))
    }

    func testAbstainsWhenPhoneDataIsStale() {
        let now = at(10)
        let d = eval(sit(now - 60 * 60, 50), now: now)   // newest minute ended 10 min ago
        XCTAssertEqual(d.verdict, .abstain(.noRecentPhoneData))
        XCTAssertEqual(eval([], now: now).verdict, .abstain(.noRecentPhoneData))
    }

    func testAbstainsWhenPhoneIsNotWithTheWearer() {
        // Phone confidently still on a desk for 30 min while the strap shows HR lifted for 10 of them.
        let now = at(10)
        let start = now - 30 * 60
        let ms = sit(start, 20) + sit(start + 20 * 60, 10, hr: 95)
        XCTAssertEqual(eval(ms, now: now).verdict, .abstain(.phoneNotWithWearer))
    }

    func testTimeTheWearerWasUnseenRestartsTheTimer() {
        // After a not-carried stretch the phone is picked up: the timer starts from the pick-up, not from
        // before the stretch, because nobody saw what happened in between.
        let now = at(11)
        let start = now - 60 * 60
        let pickUp = start + 40 * 60
        let ms = sit(start, 25) + sit(start + 25 * 60, 15, hr: 95) + [
            MovementMinute(start: pickUp, activity: .stationary, confidence: .medium, steps: 5, heartRate: 75)
        ] + sit(pickUp + 60, 19)
        XCTAssertEqual(eval(ms, now: now).verdict, .accumulating(seconds: 20 * 60))
    }

    func testLongHoleInPhoneDataRestartsTheTimerButShortHolesDoNot() {
        let now = at(10)
        // 5-minute hole: restart after it.
        let a = sit(now - 37 * 60, 20) + sit(now - 12 * 60, 12)
        XCTAssertEqual(eval(a, now: now).verdict, .accumulating(seconds: 12 * 60))
        // 2-minute hole: tolerated.
        let b = sit(now - 34 * 60, 20) + sit(now - 12 * 60, 12)
        XCTAssertEqual(eval(b, now: now).verdict, .nudge(sittingSeconds: 34 * 60))
    }

    // ── Suppression windows ───────────────────────────────────────────────────────────────────────────

    func testQuietHoursAcrossMidnightSuppressAndFloorTheTimer() {
        // Quiet 22:00–07:00. 23:30 and 06:30 are inside; at 07:20 the timer counts only from 07:00.
        XCTAssertEqual(eval(sit(at(23, 30) - 60 * 60, 60), now: at(23, 30)).verdict, .suppressed(.quietHours))
        XCTAssertEqual(eval(sit(at(6, 30) - 60 * 60, 60), now: at(6, 30)).verdict, .suppressed(.quietHours))
        XCTAssertEqual(eval(sit(at(6), 80), now: at(7, 20)).verdict, .accumulating(seconds: 20 * 60))
        XCTAssertEqual(eval(sit(at(6), 90), now: at(7, 30)).verdict, .nudge(sittingSeconds: 30 * 60))
    }

    func testSleepWindowFromTheAnchorAcrossMidnight() {
        // Lights out 23:15 the evening before, wake 07:00.
        let night = StrapCueNight(bedtimeMin: 23 * 60 + 15, wakeMin: 7 * 60, bedtimeOnPreviousDay: true)
        XCTAssertTrue(StrapCueNight.inSleepWindow(nowSec: at(23, 30), tzOffsetSec: 0, endingToday: night, endingTomorrow: night))
        XCTAssertTrue(StrapCueNight.inSleepWindow(nowSec: at(3), tzOffsetSec: 0, endingToday: night, endingTomorrow: night))
        XCTAssertFalse(StrapCueNight.inSleepWindow(nowSec: at(12), tzOffsetSec: 0, endingToday: night, endingTomorrow: night))
        XCTAssertFalse(StrapCueNight.inSleepWindow(nowSec: at(23), tzOffsetSec: 0, endingToday: night, endingTomorrow: night))
        // A lights-out AFTER midnight (00:30) belongs to the wake day itself.
        let late = StrapCueNight(bedtimeMin: 30, wakeMin: 8 * 60, bedtimeOnPreviousDay: false)
        XCTAssertFalse(StrapCueNight.inSleepWindow(nowSec: at(23, 50), tzOffsetSec: 0, endingToday: late, endingTomorrow: late))
        XCTAssertTrue(StrapCueNight.inSleepWindow(nowSec: at(1), tzOffsetSec: 0, endingToday: late, endingTomorrow: late))
        // No plan → no window (quiet hours still apply separately).
        XCTAssertFalse(StrapCueNight.inSleepWindow(nowSec: at(3), tzOffsetSec: 0, endingToday: nil, endingTomorrow: nil))
        // Local time, not UTC: 23:30 UTC is 00:30 at +1h, still inside.
        XCTAssertTrue(StrapCueNight.inSleepWindow(nowSec: at(23, 30), tzOffsetSec: 3600, endingToday: night, endingTomorrow: night))

        let ctx = SittingBreakContext(motionAccess: .authorized, inSleepWindow: true)
        XCTAssertEqual(eval(sit(at(3) - 60 * 60, 60), now: at(3), context: ctx).verdict, .suppressed(.sleepWindow))
    }

    func testWakeTimeFloorsTheTimer() {
        let noQuiet = SittingBreakConfig(enabled: true, intervalMinutes: 30, quietStartMin: 0, quietEndMin: 0)
        let night = StrapCueNight(bedtimeMin: 23 * 60, wakeMin: 7 * 60, bedtimeOnPreviousDay: true)
        let wake = StrapCueNight.lastWakeAt(nowSec: at(7, 20), tzOffsetSec: 0, endingToday: night)
        XCTAssertEqual(wake, at(7))
        let ctx = SittingBreakContext(motionAccess: .authorized, lastWakeAt: wake)
        XCTAssertEqual(eval(sit(at(6), 80), now: at(7, 20), context: ctx, config: noQuiet).verdict,
                       .accumulating(seconds: 20 * 60))
    }

    func testWorkoutAndMindfulSessionsSuppressAndRestartTheTimer() {
        let now = at(10)
        let w = eval(sit(now - 60 * 60, 60), now: now, context: SittingBreakContext(motionAccess: .authorized, workoutActive: true))
        XCTAssertEqual(w.verdict, .suppressed(.workout))
        XCTAssertEqual(w.nextState.sessionFloor, now)
        let after = eval(sit(now - 50 * 60, 60), now: now + 10 * 60, state: w.nextState)
        XCTAssertEqual(after.verdict, .accumulating(seconds: 10 * 60))

        let m = eval(sit(now - 60 * 60, 60), now: now, context: SittingBreakContext(motionAccess: .authorized, mindfulSessionActive: true))
        XCTAssertEqual(m.verdict, .suppressed(.mindfulSession))
        XCTAssertEqual(m.nextState.sessionFloor, now)
    }

    func testFocusMorningFlowAndDrivingWaitWithoutResetting() {
        let now = at(10)
        let ms = sit(now - 40 * 60, 40)
        let f = eval(ms, now: now, context: SittingBreakContext(motionAccess: .authorized, focusBlockActive: true))
        XCTAssertEqual(f.verdict, .suppressed(.focusBlock))
        XCTAssertEqual(f.sittingSeconds, 40 * 60)
        XCTAssertNil(f.nextState.sessionFloor)
        let mf = eval(ms, now: now, context: SittingBreakContext(motionAccess: .authorized, morningFlowActive: true))
        XCTAssertEqual(mf.verdict, .suppressed(.morningFlow))
        let car = sit(now - 40 * 60, 39) + [MovementMinute(start: now - 60, activity: .automotive, confidence: .medium,
                                                           steps: 0, heartRate: 72)]
        XCTAssertEqual(eval(car, now: now).verdict, .suppressed(.driving))
    }

    func testDisabledIsOff() {
        let now = at(10)
        XCTAssertEqual(eval(sit(now - 60 * 60, 60), now: now, config: SittingBreakConfig(enabled: false)).verdict, .off)
    }

    // ── After the nudge: wait, re-nudge, back off ─────────────────────────────────────────────────────

    /// Seated minutes covering the lookback before `now`.
    private func seated(until now: Int) -> [MovementMinute] { sit(now - 150 * 60, 150) }

    func testWaitsForTheBreakThenBacksOffAfterThreeIgnored() {
        let t = at(10)
        var s = SittingBreakState.initial
        XCTAssertEqual(eval(seated(until: t), now: t, state: s).verdict, .nudge(sittingSeconds: 150 * 60))
        s = SittingBreakDetector.recordNudge(s, at: t)

        let wait = eval(seated(until: t + 10 * 60), now: t + 10 * 60, state: s)
        XCTAssertEqual(wait.verdict, .awaitingBreak(since: t))

        // Ignored #1 → re-nudge at +30.
        var d = eval(seated(until: t + 30 * 60), now: t + 30 * 60, state: s)
        XCTAssertEqual(d.verdict, .nudge(sittingSeconds: 150 * 60))
        XCTAssertEqual(d.nextState.ignoredStreak, 1)
        s = SittingBreakDetector.recordNudge(d.nextState, at: t + 30 * 60)
        // Ignored #2 → re-nudge at +60.
        d = eval(seated(until: t + 60 * 60), now: t + 60 * 60, state: s)
        XCTAssertEqual(d.nextState.ignoredStreak, 2)
        s = SittingBreakDetector.recordNudge(d.nextState, at: t + 60 * 60)
        // Ignored #3 → two hours of rest.
        d = eval(seated(until: t + 90 * 60), now: t + 90 * 60, state: s)
        XCTAssertEqual(d.verdict, .suppressed(.backoff))
        XCTAssertEqual(d.nextState.backoffUntil, t + 210 * 60)
        s = d.nextState
        XCTAssertEqual(eval(seated(until: t + 150 * 60), now: t + 150 * 60, state: s).verdict, .suppressed(.backoff))
        // Rest over, still no break → nudges again from a clean streak.
        d = eval(seated(until: t + 211 * 60), now: t + 211 * 60, state: s)
        XCTAssertEqual(d.verdict, .nudge(sittingSeconds: 150 * 60))
        XCTAssertEqual(d.nextState.ignoredStreak, 0)
    }

    func testABreakAnswersTheNudgeAndClearsTheBackoff() {
        let t = at(10)
        var s = SittingBreakDetector.recordNudge(.initial, at: t)
        s.ignoredStreak = 2
        s.backoffUntil = t + 100 * 60
        let now = t + 20 * 60
        let ms = sit(now - 40 * 60, 30) + walk(now - 10 * 60, 3) + sit(now - 7 * 60, 7)
        let d = eval(ms, now: now, state: s)
        XCTAssertEqual(d.verdict, .accumulating(seconds: 7 * 60))
        XCTAssertNil(d.nextState.awaitingBreakSince)
        XCTAssertEqual(d.nextState.ignoredStreak, 0)
        XCTAssertNil(d.nextState.backoffUntil)
    }

    func testAnUndeliveredNudgeIsRetriedLaterAndNotCountedAsIgnored() {
        let t = at(10)
        let s = SittingBreakDetector.recordUndelivered(.initial, at: t)
        let d = eval(seated(until: t + 60), now: t + 60, state: s)
        XCTAssertEqual(d.verdict, .retryLater(until: t + 300))
        XCTAssertEqual(d.nextState.ignoredStreak, 0)
        XCTAssertNil(d.nextState.lastNudgeAt)
        XCTAssertEqual(eval(seated(until: t + 301), now: t + 301, state: s).verdict, .nudge(sittingSeconds: 150 * 60))
    }

    // ── Late correction from the strap offload ────────────────────────────────────────────────────────

    func testStrapMinuteStepsDropCounterResetsAndJumps() {
        let base = at(10)
        let ts = [base, base + 30, base + 60, base + 90, base + 120]
        let counter = [1000, 1040, 1100, 5, 60]   // a reset between 60 s and 90 s
        let per = SittingBreakDetector.strapMinuteSteps(ts: ts, counter: counter)
        XCTAssertEqual(per[base], 40)
        XCTAssertEqual(per[base + 60], 60)
        XCTAssertEqual(per[base + 120], 55)
        // The negative delta (counter reset) is dropped, not guessed: nothing else was attributed.
        XCTAssertEqual(per.values.reduce(0, +), 155)
        XCTAssertEqual(per.count, 3)
    }

    func testReconcileMarksAFalseAlarmAndMovesTheBreakButNeverNudges() {
        let t = at(10)
        let s = SittingBreakDetector.recordNudge(.initial, at: t)
        // The strap saw a walk 10 minutes before the nudge that the phone (left on the desk) missed.
        let walkStart = t - 12 * 60
        let steps = [walkStart: 90, walkStart + 60: 95]
        let r = SittingBreakDetector.reconcile(s, strapMinuteSteps: steps, intervalMinutes: 30)
        XCTAssertEqual(r.falseAlarmAt, t)
        XCTAssertEqual(r.state.falseAlarms, 1)
        XCTAssertEqual(r.state.lastBreakEnd, walkStart + 120)
        XCTAssertNil(r.state.awaitingBreakSince, "a false alarm is never later judged as ignored")
        // It can only delay the next nudge: the timer now runs from the strap's break (09:50 → 10:05).
        let d = eval(seated(until: t + 5 * 60), now: t + 5 * 60, state: r.state)
        XCTAssertEqual(d.verdict, .accumulating(seconds: 15 * 60))
    }

    func testReconcileAfterTheNudgeAnswersIt() {
        let t = at(10)
        let s = SittingBreakDetector.recordNudge(.initial, at: t)
        let steps = [t + 3 * 60: 100, t + 4 * 60: 100, t + 5 * 60: 100]
        let r = SittingBreakDetector.reconcile(s, strapMinuteSteps: steps, intervalMinutes: 30)
        XCTAssertNil(r.falseAlarmAt)
        XCTAssertNil(r.state.awaitingBreakSince)
        XCTAssertEqual(r.state.lastBreakEnd, t + 6 * 60)
    }
}
