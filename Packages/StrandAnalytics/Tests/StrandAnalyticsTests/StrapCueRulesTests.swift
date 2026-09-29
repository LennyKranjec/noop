import XCTest
@testable import StrandAnalytics

/// Strap-cue system rules: the pattern vocabulary (one distinct pattern per cue type), the daily budget and
/// minimum spacing, quiet hours, honest delivery, the settings defaults, and the timers / pacer plan.
final class StrapCueRulesTests: XCTestCase {

    // 2023-11-14 00:00:00 UTC.
    private let midnight = 1_699_920_000
    private func ms(_ h: Int, _ m: Int = 0, _ s: Int = 0) -> Int { (midnight + h * 3600 + m * 60 + s) * 1000 }
    private let settings = StrapCueSettings()

    // ── Vocabulary ────────────────────────────────────────────────────────────────────────────────────

    func testEveryPatternIsDistinct() {
        let all = StrapCuePattern.allCases.map { $0.pulses }
        for i in all.indices {
            for j in all.indices where j > i {
                XCTAssertNotEqual(all[i], all[j], "\(StrapCuePattern.allCases[i]) and \(StrapCuePattern.allCases[j]) feel the same")
            }
        }
    }

    func testOnlyTimerEndsSharePatternAndMoveIsTheSittingBreaksAlone() {
        var byPattern: [StrapCuePattern: [StrapCueKind]] = [:]
        for k in StrapCueKind.allCases { byPattern[k.pattern, default: []].append(k) }
        for (p, kinds) in byPattern where kinds.count > 1 {
            XCTAssertEqual(p, .timesUp)
            XCTAssertEqual(Set(kinds), [.breathingDone, .focusEnd, .meditationEnd])
        }
        XCTAssertEqual(byPattern[.move], [.sittingBreak])
        // Every pattern is used by at least one cue.
        XCTAssertEqual(Set(byPattern.keys), Set(StrapCuePattern.allCases))
    }

    func testGapsInsideEveryPatternAreFelt() {
        for p in StrapCuePattern.allCases {
            let pulses = p.pulses
            XCTAssertFalse(pulses.isEmpty)
            XCTAssertEqual(pulses.first?.offsetMs, 0)
            for i in pulses.indices.dropFirst() {
                let prevEnd = pulses[i - 1].offsetMs + pulses[i - 1].loops * StrapCueVocabulary.motorMsPerLoop
                XCTAssertGreaterThanOrEqual(pulses[i].offsetMs - prevEnd, StrapCueVocabulary.minFeltGapMs, "\(p)")
            }
            XCTAssertTrue(pulses.allSatisfy { (1...3).contains($0.loops) }, "\(p)")
        }
    }

    func testBreathingKeepsTheShippedBreatheLanguage() {
        XCTAssertEqual(StrapCuePattern.inhale.pulses, [StrapCuePulse(offsetMs: 0, loops: BreathPacer.inhaleLoops)])
        XCTAssertEqual(StrapCuePattern.exhale.pulses, [StrapCuePulse(offsetMs: 0, loops: BreathPacer.exhaleLoops)])
    }

    func testRequestedVersusAmbient() {
        XCTAssertEqual(Set(StrapCueKind.allCases.filter { !$0.isRequested }), [.sittingBreak, .windDown, .screensOff])
    }

    // ── Settings defaults ─────────────────────────────────────────────────────────────────────────────

    func testOnlyTheSittingBreakIsOnByDefault() {
        let s = StrapCueSettings()
        XCTAssertTrue(s.sittingBreakEnabled)
        XCTAssertFalse(s.breathingPacerEnabled || s.windDownEnabled || s.screensOffEnabled
                       || s.focusBlocksEnabled || s.meditationTimerEnabled)
        XCTAssertEqual(s.sittingIntervalMinutes, 30)
        XCTAssertEqual(s.dailyBudget, 8)
        XCTAssertEqual(s.meditationMinutes, 10)
        XCTAssertEqual(s.quietStartMin, 22 * 60)
        XCTAssertEqual(s.quietEndMin, 7 * 60)
    }

    func testSanitizedSnapsCorruptValues() {
        var s = StrapCueSettings()
        s.sittingIntervalMinutes = 7
        s.meditationMinutes = 3
        s.dailyBudget = 500
        s.focusMinutes = 60
        s.breathingPaceBpm = .nan
        let c = s.sanitized()
        XCTAssertEqual(c.sittingIntervalMinutes, 30)
        XCTAssertEqual(c.meditationMinutes, 10)
        XCTAssertEqual(c.dailyBudget, 20)
        XCTAssertEqual(c.focusMinutes, 50)
        XCTAssertEqual(c.breathingPaceBpm, 6)
        XCTAssertEqual(StrapCueSettings(sittingIntervalMinutes: 44).sanitized().sittingIntervalMinutes, 45)
    }

    // ── Budget, spacing, quiet hours ──────────────────────────────────────────────────────────────────

    private func check(_ k: StrapCueKind, _ l: StrapCueLedger, _ now: Int, wrist: Bool = true,
                       _ s: StrapCueSettings? = nil) -> StrapCueGateVerdict {
        StrapCueGate.check(k, ledger: l, settings: s ?? settings, wristAlertsOn: wrist, nowMs: now, tzOffsetSec: 0)
    }

    func testDailyBudgetHoldsUnrequestedCuesAndResetsAtLocalMidnight() {
        var l = StrapCueLedger.empty
        var t = ms(9)
        for _ in 0..<8 {
            XCTAssertEqual(check(.sittingBreak, l, t), .allow)
            l = StrapCueGate.recordDelivered(.sittingBreak, ledger: l, nowMs: t, tzOffsetSec: 0)
            t += 30 * 60 * 1000
        }
        XCTAssertEqual(l.unrequestedToday, 8)
        XCTAssertEqual(check(.sittingBreak, l, t), .hold(.budgetSpent))
        XCTAssertEqual(check(.windDown, l, t), .hold(.budgetSpent))
        // Requested cues are not paid from the budget.
        XCTAssertEqual(check(.focusEnd, l, t), .allow)
        XCTAssertEqual(StrapCueGate.remainingBudget(l, settings: settings, nowMs: t, tzOffsetSec: 0), 0)
        // Next local day (after quiet hours) the budget is back.
        let tomorrow = ms(24 + 8)
        XCTAssertEqual(check(.sittingBreak, l, tomorrow), .allow)
        XCTAssertEqual(StrapCueGate.remainingBudget(l, settings: settings, nowMs: tomorrow, tzOffsetSec: 0), 8)
        // …and the day boundary is LOCAL: at UTC-5 the 04:00 UTC instant is still the previous local day.
        XCTAssertEqual(StrapCueClock.dayKey(epochSec: midnight + 4 * 3600, tzOffsetSec: -5 * 3600), "2023-11-13")
    }

    func testRequestedCuesDoNotSpendBudget() {
        var l = StrapCueLedger.empty
        l = StrapCueGate.recordDelivered(.breathInhale, ledger: l, nowMs: ms(9), tzOffsetSec: 0)
        l = StrapCueGate.recordDelivered(.meditationEnd, ledger: l, nowMs: ms(9, 10), tzOffsetSec: 0)
        XCTAssertEqual(l.unrequestedToday, 0)
    }

    func testNeverTwoCuesWithinAMinute() {
        let t = ms(10)
        let l = StrapCueGate.recordDelivered(.sittingBreak, ledger: .empty, nowMs: t, tzOffsetSec: 0)
        XCTAssertEqual(check(.windDown, l, t + 30_000), .deferUntil(ms: t + 60_000))
        XCTAssertEqual(check(.windDown, l, t + 60_000), .allow)
        // A requested cue a minute ago also spaces an ambient one.
        let r = StrapCueGate.recordDelivered(.focusEnd, ledger: .empty, nowMs: t, tzOffsetSec: 0)
        XCTAssertEqual(check(.sittingBreak, r, t + 10_000), .deferUntil(ms: t + 60_000))
    }

    func testRequestedCuesOnlyWaitForTheMotor() {
        let t = ms(10)
        let l = StrapCueGate.recordDelivered(.breathExhale, ledger: .empty, nowMs: t, tzOffsetSec: 0)
        let busy = t + StrapCuePattern.exhale.durationMs
        XCTAssertEqual(check(.breathInhale, l, t + 300), .deferUntil(ms: busy))
        XCTAssertEqual(check(.breathInhale, l, busy), .allow)
    }

    func testQuietHoursAcrossMidnightHoldAmbientButNotRequested() {
        let l = StrapCueLedger.empty
        XCTAssertEqual(check(.sittingBreak, l, ms(23, 30)), .hold(.quietHours))
        XCTAssertEqual(check(.sittingBreak, l, ms(3)), .hold(.quietHours))
        XCTAssertEqual(check(.sittingBreak, l, ms(7)), .allow)
        XCTAssertEqual(check(.sittingBreak, l, ms(21, 59)), .allow)
        XCTAssertEqual(check(.meditationEnd, l, ms(23, 30)), .allow)
        // start == end: no quiet hours at all.
        let none = StrapCueSettings(quietStartMin: 0, quietEndMin: 0)
        XCTAssertEqual(check(.sittingBreak, l, ms(3), none), .allow)
    }

    func testWristAlertsMasterHoldsAmbientCuesOnly() {
        let l = StrapCueLedger.empty
        XCTAssertEqual(check(.sittingBreak, l, ms(10), wrist: false), .hold(.wristAlertsOff))
        XCTAssertEqual(check(.focusEnd, l, ms(10), wrist: false), .allow)
    }

    func testFireOnceKeysAreBounded() {
        var l = StrapCueLedger.empty
        for d in 0..<40 { l = StrapCueGate.markFired("windDown:\(d)", ledger: l) }
        XCTAssertEqual(l.firedKeys.count, StrapCueGate.maxFiredKeys)
        XCTAssertTrue(StrapCueGate.hasFired("windDown:39", ledger: l))
        XCTAssertFalse(StrapCueGate.hasFired("windDown:0", ledger: l))
        let again = StrapCueGate.markFired("windDown:39", ledger: l)
        XCTAssertEqual(again, l)
    }

    func testClockHelpers() {
        XCTAssertEqual(StrapCueClock.dayKey(epochSec: midnight, tzOffsetSec: 0), "2023-11-14")
        XCTAssertEqual(StrapCueClock.dayKey(epochSec: 1_709_164_800, tzOffsetSec: 0), "2024-02-29")
        XCTAssertEqual(StrapCueClock.dayKey(epochSec: 0, tzOffsetSec: -3600), "1969-12-31")
        let now = midnight + 10 * 3600
        XCTAssertEqual(StrapCueClock.lastClockInstant(atOrBefore: now, minuteOfDay: 7 * 60, tzOffsetSec: 0), midnight + 7 * 3600)
        XCTAssertEqual(StrapCueClock.lastClockInstant(atOrBefore: now, minuteOfDay: 22 * 60, tzOffsetSec: 0), midnight - 2 * 3600)
        XCTAssertEqual(StrapCueClock.lastClockInstant(atOrBefore: now, minuteOfDay: 10 * 60, tzOffsetSec: 0), now)
        // Local 07:00 at +2h is 05:00 UTC.
        XCTAssertEqual(StrapCueClock.lastClockInstant(atOrBefore: now, minuteOfDay: 7 * 60, tzOffsetSec: 7200), midnight + 5 * 3600)
    }

    // ── Honest delivery ───────────────────────────────────────────────────────────────────────────────

    func testDeliveryVerdictPrecedenceMatchesTheWakeBuzz() {
        XCTAssertEqual(StrapCueDelivery.verdict(hasSink: false, strapReachable: true, bondRefused: true), .noSink)
        XCTAssertEqual(StrapCueDelivery.verdict(hasSink: true, strapReachable: false, bondRefused: true), .strapRefused)
        XCTAssertEqual(StrapCueDelivery.verdict(hasSink: true, strapReachable: false, bondRefused: false), .noStrap)
        XCTAssertEqual(StrapCueDelivery.verdict(hasSink: true, strapReachable: true, bondRefused: false), .sent)
    }

    func testPhoneFallbackOnlyInTheForegroundAndOnlyWhenOn() {
        XCTAssertEqual(StrapCueOutcome.resolve(.sent, appInForeground: false, phoneFallbackEnabled: false), .strap)
        XCTAssertEqual(StrapCueOutcome.resolve(.noStrap, appInForeground: true, phoneFallbackEnabled: true),
                       .phone(reason: .noStrap))
        XCTAssertEqual(StrapCueOutcome.resolve(.noStrap, appInForeground: false, phoneFallbackEnabled: true),
                       .notDelivered(reason: .noStrap))
        XCTAssertEqual(StrapCueOutcome.resolve(.strapRefused, appInForeground: true, phoneFallbackEnabled: false),
                       .notDelivered(reason: .strapRefused))
        XCTAssertTrue(StrapCueOutcome.strap.reachedWearer)
        XCTAssertTrue(StrapCueOutcome.phone(reason: .noStrap).reachedWearer)
        XCTAssertFalse(StrapCueOutcome.notDelivered(reason: .noStrap).reachedWearer)
    }

    func testAnUndeliveredCueIsNeverLoggedAsSentAndCostsNoBudget() {
        for reason in [StrapCueDelivery.noStrap, .strapRefused, .noSink] {
            let line = StrapCueOutcome.notDelivered(reason: reason).logLine(.sittingBreak)
            XCTAssertTrue(line.contains("NOT delivered"), line)
            XCTAssertFalse(line.contains("sent to the strap"), line)
            let phone = StrapCueOutcome.phone(reason: reason).logLine(.sittingBreak)
            XCTAssertTrue(phone.contains("NOT sent to the strap"), phone)
        }
        XCTAssertTrue(StrapCueOutcome.notDelivered(reason: .strapRefused).logLine(.windDown).contains("re-pairing"))
        XCTAssertFalse(StrapCueOutcome.notDelivered(reason: .strapRefused).logLine(.windDown).contains("not connected"))
        // The runtime only records a cue that reachedWearer; an undelivered one leaves the ledger as it was.
        let l = StrapCueLedger.empty
        let outcome = StrapCueOutcome.resolve(.noStrap, appInForeground: false, phoneFallbackEnabled: true)
        let after = outcome.reachedWearer
            ? StrapCueGate.recordDelivered(.sittingBreak, ledger: l, nowMs: ms(10), tzOffsetSec: 0) : l
        XCTAssertEqual(after.unrequestedToday, 0)
    }

    // ── Timers and the pacer ──────────────────────────────────────────────────────────────────────────

    func testTimerDueCheckWithGrace() {
        let end = midnight + 10 * 3600
        XCTAssertEqual(StrapCueTimers.state(endsAt: end, nowSec: end - 90), .running(remaining: 90))
        XCTAssertEqual(StrapCueTimers.state(endsAt: end, nowSec: end), .fire)
        XCTAssertEqual(StrapCueTimers.state(endsAt: end, nowSec: end + 15 * 60), .fire)
        XCTAssertEqual(StrapCueTimers.state(endsAt: end, nowSec: end + 15 * 60 + 1), .missed(lateBy: 15 * 60 + 1))
    }

    func testBreathPlanHasQuietReadingsAroundThePacedPart() {
        let plan = StrapCueTimers.breathPlan(pacedMinutes: 5, paceBpm: 6)
        let quiet = BreathSessionOutcome.quietSeconds * 1000
        XCTAssertEqual(plan.steps.first?.phase, .preQuietStart)
        XCTAssertEqual(plan.steps.first?.offsetMs, 0)
        let cues = plan.steps.filter { $0.cue != nil && $0.cue != .breathingDone }
        XCTAssertEqual(cues.count, 60)   // 30 breaths × (inhale + exhale)
        XCTAssertEqual(cues.first?.offsetMs, quiet)
        XCTAssertEqual(cues.first?.cue, .breathInhale)
        XCTAssertEqual(cues.first?.phase, .pacedStart)
        XCTAssertEqual(cues[1].cue, .breathExhale)
        XCTAssertEqual(cues[1].offsetMs, quiet + 4000)   // 10 s breath, 40 % inhale
        let pacedEnd = quiet + 5 * 60 * 1000
        XCTAssertEqual(plan.steps.first(where: { $0.phase == .pacedEnd })?.offsetMs, pacedEnd)
        // No cue inside either quiet reading.
        XCTAssertTrue(cues.allSatisfy { $0.offsetMs >= quiet && $0.offsetMs < pacedEnd })
        XCTAssertEqual(plan.steps.last?.cue, .breathingDone)
        XCTAssertEqual(plan.steps.last?.phase, .postQuietEnd)
        XCTAssertEqual(plan.totalMs, pacedEnd + quiet)
        // Consecutive pacer cues never overlap on the motor.
        for i in cues.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(cues[i].offsetMs - cues[i - 1].offsetMs, cues[i - 1].cue!.pattern.durationMs)
        }
    }

    func testEveningSlotsComeFromTheSleepAnchor() {
        // Wake 07:00, need 8 h, 15 min onset buffer → lights out 22:45 the evening before.
        let plan = SleepSchedulePlan(wakeWeekday: 3, anchorMin: 420, anchorSource: .userTarget, weekendOffsetMin: 0,
                                     needMin: 480, needIsPopulationDefault: true, debtMin: nil, paybackMin: 0,
                                     insomniaGuard: false, nightsUsed: 0, confidence: .building, bedtimeLeadMin: 495)
        XCTAssertEqual(plan.bedtimeMin, 22 * 60 + 45)
        let wd = StrapCueTimers.eveningSlot(.windDown, plan: plan)
        XCTAssertEqual(wd?.minuteOfDay, 21 * 60 + 45)
        XCTAssertEqual(wd?.dayShift, -1)
        let so = StrapCueTimers.eveningSlot(.screensOff, plan: plan)
        XCTAssertEqual(so?.minuteOfDay, 22 * 60 + 15)
        XCTAssertEqual(so?.dayShift, -1)
        XCTAssertNil(StrapCueTimers.eveningSlot(.sittingBreak, plan: plan))
        let night = StrapCueNight(plan)
        XCTAssertEqual(night, StrapCueNight(bedtimeMin: 22 * 60 + 45, wakeMin: 420, bedtimeOnPreviousDay: true))
    }
}
