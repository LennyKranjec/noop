import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class DaytimeStressTests: XCTestCase {

    /// Fill one local hour-of-day with `n` 1 Hz HR samples at `bpm` (UTC, tz offset 0).
    private func hourHR(_ hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        let base = hour * 3_600
        return (0..<n).map { HRSample(ts: base + $0, bpm: bpm) }
    }

    func testTheSlidingReadIsOptIn() {
        let (hr, rr) = wornMorning()
        // The Stress screen reads `hours` and draws its own timeline, so it must not pay for a second
        // pass of bucketing and an RMSSD per extra window. Default off means `timeline` IS `hours`.
        let plain = DaytimeStress.analyze(hr: hr, rr: rr)
        XCTAssertEqual(plain.timeline, plain.hours)
        XCTAssertGreaterThan(
            DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true).timeline.count,
            plain.hours.count)
    }

    // MARK: - the half-step display timeline

    /// A plain worn morning: several waking hours of steady HR with a little R-R jitter.
    private func wornMorning() -> ([HRSample], [RRInterval]) {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in 7...11 {
            hr += hourHR(h, bpm: 60 + (h - 7) * 4)
            rr += hourRRVariable(h, rrMs: 900, jitter: 20)
        }
        return (hr, rr)
    }

    func testTimelineKeepsEveryHourlyPointExactlyAsScored() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        // The sliding read must not restate the hours it slides between: a point on the hour has to
        // carry the same level it carried before this existed, or the curve would disagree with every
        // other surface that reads `hours`.
        let byStart = Dictionary(uniqueKeysWithValues: res.timeline.map { ($0.startTs, $0) })
        XCTAssertFalse(res.hours.isEmpty)
        for h in res.hours {
            XCTAssertEqual(byStart[h.startTs]?.level, h.level, "hour \(h.startTs) restated")
            XCTAssertEqual(byStart[h.startTs]?.maskedForActivity, h.maskedForActivity)
        }
    }

    func testTimelineAddsTheStraddlingMidpointsAndNothingElse() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        XCTAssertGreaterThan(res.timeline.count, res.hours.count)
        let hourly = Set(res.hours.map(\.startTs))
        let extras = res.timeline.filter { !hourly.contains($0.startTs) }
        XCTAssertFalse(extras.isEmpty)
        // Every added point sits exactly half a window off the hour, which is what "slid" means. A
        // point anywhere else would mean the grid, not the phase, had moved.
        for e in extras {
            let offset = ((e.startTs % DaytimeStress.bucketSeconds) + DaytimeStress.bucketSeconds)
                % DaytimeStress.bucketSeconds
            XCTAssertEqual(offset, DaytimeStress.timelineStepSeconds)
        }
        XCTAssertEqual(res.timeline.map(\.startTs), res.timeline.map(\.startTs).sorted())
    }

    func testHourCountingIgnoresTheSlidingRead() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        // Overlapping windows would count the same minute twice, so the minute total stays on the
        // non-overlapping hours. This is the assertion that fails first if someone later points
        // `highStressMinutes` at the denser series.
        let highHours = res.hours.filter { ($0.level ?? 0) >= DaytimeStress.highBandFloor }.count
        XCTAssertEqual(res.highStressMinutes, highHours * 60)
        XCTAssertEqual(res.activityMaskedHours, res.hours.filter(\.maskedForActivity).count)
    }

    func testASteadyDayScoresItsMidpointsLikeItsHours() {
        // Same HR every hour: with one shared reference the midpoints must land on the same level as
        // the hours they straddle. If the sliding pass ever derived its OWN calm reference, this is
        // where it would show up, as a curve that zigzags between two scales rather than tracking one.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in 8...12 { hr += hourHR(h, bpm: 66); rr += hourRRVariable(h, rrMs: 900, jitter: 20) }
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        let levels = Set(res.timeline.compactMap { $0.level.map { String(format: "%.6f", $0) } })
        XCTAssertLessThanOrEqual(levels.count, 1, "a flat day should not zigzag, got \(levels)")
    }

    func testTimelineMatchesTheKotlinTwinValueForValue() {
        // The other half of the oracle. The Kotlin `DaytimeStressTest` asserts these same literals for
        // this same scenario, so a change landing on ONE platform moves one of the two and fails here
        // or there. An oracle only guards the direction it is written in.
        //
        // RECALIBRATED (day-relative median centre + robust spread + ln 2-shifted curve). These literals
        // MOVED ON PURPOSE and the Kotlin twin must move with them. Hours 60/64/68/72/76 bpm: median 68,
        // IQR 64…72 → σ = 8 / 1.349 = 5.93, so z = −1.35/−0.67/0/+0.67/+1.35 → 0.34/0.61/1.00/1.49/1.97.
        // The old anchor (Q1 = 64, population SD) put the MIDDLE hour at 2.01 and called a gentle
        // 16 bpm morning ramp "sustained high" — exactly the over-read the recalibration removes. Now no
        // hour reaches 2.0: zero high minutes, no sustained run, the last hour is still the peak.
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        func render(_ points: [DaytimeStress.HourPoint]) -> String {
            points.map { "\($0.startTs):" + ($0.level.map { String(format: "%.6f", $0) } ?? "nil") }
                .joined(separator: " ")
        }
        XCTAssertEqual(render(res.hours),
                       "25200:0.344545 28800:0.609001 32400:1.000000 36000:1.486015 39600:1.974985")
        XCTAssertEqual(render(res.timeline),
                       "23400:0.344545 25200:0.344545 27000:0.609001 28800:0.609001 30600:1.000000 "
                       + "32400:1.000000 34200:1.486015 36000:1.486015 37800:1.974985 39600:1.974985")
        XCTAssertEqual(res.highStressMinutes, 0)
        XCTAssertFalse(res.sustainedHigh)
        XCTAssertEqual(res.sustainedRun, 0)
        XCTAssertEqual(res.peak?.startTs, 39600)
    }

    func testEmptyWhenNoHR() {
        XCTAssertEqual(DaytimeStress.analyze(hr: [], rr: []), .empty)
    }

    func testHourBelowGateIsUnscored() {
        // One waking hour with too few HR samples → present but unscored (honest gap).
        let hr = hourHR(9, bpm: 70, n: DaytimeStress.minHourHRSamples - 1)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.scored.isEmpty, "an under-gate hour must not be scored")
    }

    func testScoresMapOntoZeroToThree() {
        // Three calm hours + one tense hour (high HR). All scored values stay within 0…3.
        var hr: [HRSample] = []
        hr += hourHR(8, bpm: 62)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 61)
        hr += hourHR(11, bpm: 95)   // the spike
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.scored.isEmpty)
        for p in r.scored {
            let lvl = p.level!
            XCTAssertGreaterThanOrEqual(lvl, 0)
            XCTAssertLessThanOrEqual(lvl, 3)
        }
        // The high-HR hour must be the day's peak and read above the calm hours.
        XCTAssertEqual(r.peak?.hour, 11)
        let calm = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, calm)
    }

    func testNonWakingHoursAreExcluded() {
        // A 3 am hour (outside 06:00–22:00) is never placed on the waking timeline.
        let hr = hourHR(3, bpm: 80) + hourHR(9, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.hours.contains { $0.hour == 3 })
        XCTAssertTrue(r.hours.contains { $0.hour == 9 })
    }

    func testSustainedHighFlagsAfterThreeConsecutiveHighHours() {
        // A calm morning, then three increasingly tense afternoon hours that finish HIGH.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }   // calm baseline hours
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.sustainedHigh, "three trailing HIGH hours should flag sustained stress")
        XCTAssertGreaterThanOrEqual(r.sustainedRun, DaytimeStress.sustainedHours)
    }

    func testFlatDayDoesNotFlagSustained() {
        // Every hour at the same HR → no hour is meaningfully elevated, no flag.
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 64) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.sustainedHigh)
        // A flat day sits at the TYPICAL-hour level (1.0 since the recalibration; it was ≈1.5 on the
        // old curve), not pinned high. Its IQR is 0, so this also exercises the HR spread floor.
        if let mean = r.dayMean {
            XCTAssertLessThan(mean, DaytimeStress.highBandFloor)
            XCTAssertEqual(mean, 1.0, accuracy: 1e-9)
        }
    }

    func testSleepHoursInTheWindowDoNotShiftTheWakingTimeline() {
        // Regression: the calm reference is built from the WAKING hours that are actually
        // scored, not the whole 24 h. The analysis window always starts at local midnight, so
        // the current day routinely carries several hours of sleep — the calmest, lowest-HR
        // stretch of the day. If those night hours leak into the reference they drag the "calm"
        // anchor far below every waking hour, inflating an ordinary calm day into sustained
        // high stress (tripping the passive Breathe nudge). So adding calm sleep hours to the
        // input must NOT change the waking timeline.
        let waking: [HRSample] = zip(6...17, [62, 64, 63, 65, 64, 63, 62, 64, 66, 63, 64, 65])
            .flatMap { hourHR($0.0, bpm: $0.1) }
        let sleep: [HRSample] = zip(0...5, [50, 51, 52, 51, 50, 53])
            .flatMap { hourHR($0.0, bpm: $0.1) }

        let wakingOnly = DaytimeStress.analyze(hr: waking, rr: [])
        let withSleep = DaytimeStress.analyze(hr: sleep + waking, rr: [])

        XCTAssertEqual(withSleep.sustainedHigh, wakingOnly.sustainedHigh,
            "sleep hours sharing the window must not change the sustained-high verdict")
        for h in 6...17 {
            guard let withLvl = withSleep.scored.first(where: { $0.hour == h })?.level,
                  let withoutLvl = wakingOnly.scored.first(where: { $0.hour == h })?.level else {
                XCTFail("waking hour \(h) should be scored in both runs"); continue
            }
            XCTAssertEqual(withLvl, withoutLvl, accuracy: 1e-9,
                "the night's sleep hours leaked into the daytime reference and shifted waking hour \(h)")
        }
        // The plain sanity check the bug violated: an ordinary calm day is not "sustained high".
        XCTAssertFalse(withSleep.sustainedHigh,
            "a calm desk day must not read as sustained high stress")
    }

    func testTimezoneOffsetShiftsWakingWindow() {
        // ts at UTC hour 4 with a +3 h offset lands at local hour 7 → inside waking hours.
        let hr = hourHR(4, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 3 * 3_600)
        XCTAssertTrue(r.hours.contains { $0.hour == 7 })
    }

    func testRMSSDLowersStressDirectionMatchesDailyScore() {
        // Same HR across hours; the hour with the LOWEST HRV (RMSSD) should read more
        // stressed — the same directionality as the daily score (HRV down = stress).
        //
        // CHANGED with the recalibration: day-relative mode now obeys the SAME daytime-RMSSD
        // reliability gate as the baseline mode. While `daytimeRMSSDScoringEnabled` is false the
        // RMSSD term is dropped, so identical-HR hours must score IDENTICALLY (the gate works); the
        // direction itself is then pinned on the RMSSD-active path directly via `dayRelativeZ`.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 65) }
        // High-variability (relaxed) hours vs one low-variability (tense) hour.
        rr += hourRRVariable(8, rrMs: 900, jitter: 40)
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(10, rrMs: 900, jitter: 40)
        rr += hourRRVariable(11, rrMs: 900, jitter: 2)   // suppressed HRV
        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        let relaxed = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        if DaytimeStress.daytimeRMSSDScoringEnabled {
            XCTAssertGreaterThan(tense, relaxed)
        } else {
            XCTAssertEqual(tense, relaxed, accuracy: 1e-9,
                "gate off: daytime RMSSD must not move the day-relative score")
        }
        // The RMSSD-active path, whatever the gate: suppressed HRV reads more stressed.
        let ref = DaytimeStress.dayReference(hrMeans: [65, 65, 65, 65], rmssds: [80, 80, 80, 4])
        let zRelaxed = DaytimeStress.dayRelativeZ(hr: 65, rmssd: 80, ref: ref, useRMSSD: true)
        let zTense = DaytimeStress.dayRelativeZ(hr: 65, rmssd: 4, ref: ref, useRMSSD: true)
        XCTAssertGreaterThan(zTense, zRelaxed)
    }

    // MARK: - Recalibrated day-relative scale

    /// A synthetic ordinary day: 16 waking hours (06–21) whose mean HR is spread like a normal sample
    /// around 70 bpm, deliberately shuffled so nothing depends on time order. Median 70, IQR 66.75…73.25
    /// → robust σ = 6.5 / 1.349 = 4.82 bpm. The 80 bpm hour is +2.08 robust SDs; the 62 bpm hour −1.66.
    private let normalDayBPM: [Int] = [70, 66, 74, 62, 71, 68, 75, 65, 80, 69, 73, 64, 72, 67, 76, 70]

    private func normalDay() -> [HRSample] {
        zip(6...21, normalDayBPM).flatMap { hourHR($0.0, bpm: $0.1) }
    }

    func testNormalDayTypicalHourReadsAboutOne() {
        let r = DaytimeStress.analyze(hr: normalDay(), rr: [])
        XCTAssertEqual(r.scored.count, 16)
        // The typical (median, 70 bpm) hours of the wearer's own day sit at ≈1.0, NOT on the HIGH
        // floor as they effectively did under the old calm-quartile anchor (≈1.99).
        for p in r.scored where p.meanHR == 70 {
            XCTAssertEqual(p.level!, 1.0, accuracy: 0.25, "a typical hour should read ≈1.0")
        }
        // The day as a whole reads as unremarkable.
        XCTAssertFalse(r.sustainedHigh)
        XCTAssertLessThan(r.dayMean!, 1.5)
    }

    func testNormalDayStressedHourIsHighAndCalmestHourIsLow() {
        let r = DaytimeStress.analyze(hr: normalDay(), rr: [])
        // +2 robust SDs over the typical hour → HIGH (≈2.39 on the curve).
        let stressed = r.scored.first { $0.meanHR == 80 }!.level!
        XCTAssertGreaterThanOrEqual(stressed, DaytimeStress.highBandFloor)
        // The calmest hour of the day (62 bpm, ≈−1.66 robust SDs) reads clearly low (≈0.26).
        let calmest = r.scored.first { $0.meanHR == 62 }!.level!
        XCTAssertLessThan(calmest, 0.7)
        XCTAssertEqual(r.peak?.meanHR, 80)
        XCTAssertEqual(r.highStressMinutes, 60, "only the one genuinely elevated hour is HIGH")
    }

    func testDayRelativeSquashMapping() {
        // The documented table: z = 0 → exactly 1.0, z = 2·ln 2 → exactly the HIGH floor, clamped 0–3.
        XCTAssertEqual(DaytimeStress.dayRelativeSquash(0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(DaytimeStress.dayRelativeSquash(2 * log(2.0)), DaytimeStress.highBandFloor, accuracy: 1e-12)
        XCTAssertEqual(DaytimeStress.dayRelativeSquash(-1), 0.466, accuracy: 0.001)
        XCTAssertEqual(DaytimeStress.dayRelativeSquash(2), 2.361, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(DaytimeStress.dayRelativeSquash(-1_000), 0)
        XCTAssertLessThanOrEqual(DaytimeStress.dayRelativeSquash(1_000), 3)
    }

    func testFlatDayWithSmallWigglesDoesNotExplode() {
        // IQR ≈ 1 bpm → without the 3 bpm spread floor a ±1 bpm wiggle would be ~±1.3σ and swing the
        // hours between LOW and HIGH on noise. With the floor every hour stays near the typical 1.0.
        var hr: [HRSample] = []
        for (i, h) in (8...16).enumerated() { hr += hourHR(h, bpm: [63, 64, 65][i % 3]) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertEqual(r.highStressMinutes, 0)
        XCTAssertFalse(r.sustainedHigh)
        for p in r.scored {
            XCTAssertGreaterThan(p.level!, 0.6)
            XCTAssertLessThan(p.level!, 1.4)
        }
    }

    func testRobustSpreadIgnoresOneSpikeHour() {
        // One 130 bpm hour among eight calm ones must not inflate the spread and hide itself: the IQR
        // never sees it, so it reads as a (clamped-near-3) HIGH hour, not a mild one.
        var hr: [HRSample] = []
        for h in 8...15 { hr += hourHR(h, bpm: 60 + (h % 3)) }
        hr += hourHR(16, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertGreaterThan(r.scored.first { $0.hour == 16 }!.level!, 2.8)
    }

    func testRMSSDSpreadFloors() {
        // Flat RMSSD → IQR 0 → floored at max(4 ms, 15 % of the median).
        XCTAssertEqual(DaytimeStress.dayReference(hrMeans: [60], rmssds: [100, 100, 100]).sdRMSSD, 15, accuracy: 1e-9)
        XCTAssertEqual(DaytimeStress.dayReference(hrMeans: [60], rmssds: [20, 20, 20]).sdRMSSD, 4, accuracy: 1e-9)
        // And the HR spread is floored at 3 bpm.
        XCTAssertEqual(DaytimeStress.dayReference(hrMeans: [60, 60, 60], rmssds: []).sdHR, 3, accuracy: 1e-9)
    }

    func testRMSSDTermIsDownWeightedAndKeepsTheZScale() {
        let ref = DaytimeStress.DayReference(hr: 70, sdHR: 5, rmssd: 40, sdRMSSD: 10)
        // HR-only hour and an HR+RMSSD hour where both terms agree at +1σ share one z (a weighted MEAN).
        XCTAssertEqual(DaytimeStress.dayRelativeZ(hr: 75, rmssd: nil, ref: ref, useRMSSD: true), 1, accuracy: 1e-12)
        XCTAssertEqual(DaytimeStress.dayRelativeZ(hr: 75, rmssd: 30, ref: ref, useRMSSD: true), 1, accuracy: 1e-12)
        // RMSSD alone at −3σ moves a typical-HR hour by only w·3/(1+w) = 1σ at w = 0.5.
        XCTAssertEqual(DaytimeStress.dayRelativeZ(hr: 70, rmssd: 10, ref: ref, useRMSSD: true),
                       DaytimeStress.dayRelativeRMSSDWeight * 3 / (1 + DaytimeStress.dayRelativeRMSSDWeight),
                       accuracy: 1e-12)
        // Gate off → the RMSSD term is ignored entirely.
        XCTAssertEqual(DaytimeStress.dayRelativeZ(hr: 70, rmssd: 10, ref: ref, useRMSSD: false), 0, accuracy: 1e-12)
    }

    func testBimodalDaySpreadCapStillFlagsTheTenseHalf() {
        // Half calm, half genuinely tense: the IQR spans both modes (σ ≈ 49 bpm). Without the
        // `dayRelativeMaxHRSigma` cap the 120–130 bpm hours would read ≈1.5 and the day would hide its
        // own stress; with it they read ≈2.9 and the calm hours ≈0.03. (Same scenario as
        // `testSustainedHighFlagsAfterThreeConsecutiveHighHours`, which is what keeps that test green.)
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        for h in [13, 14, 15] { XCTAssertGreaterThan(r.scored.first { $0.hour == h }!.level!, 2.8) }
        for h in [8, 9, 10] { XCTAssertLessThan(r.scored.first { $0.hour == h }!.level!, 0.1) }
    }

    // MARK: - Wake window

    func testWakeWindowReplacesTheFixedWakingHours() {
        // A late sleeper: asleep until ~10:00 (HR 50), up until ~23:30. With the fixed 06–22 window the
        // still-asleep 06–09 hours are scored AND drag the day's reference down; with the real window
        // they are neither, and the 22:00 hour (midpoint 22:30, still awake) is read too.
        var hr: [HRSample] = []
        for h in 6...9 { hr += hourHR(h, bpm: 50) }
        // Awake hours 10–22; their median is 70 bpm (the 16:00 hour).
        for (h, bpm) in zip(10...22, [64, 68, 70, 66, 73, 71, 70, 69, 75, 67, 72, 65, 70]) {
            hr += hourHR(h, bpm: bpm)
        }
        let window = (10 * 3_600)...(23 * 3_600 + 1_800)

        let fixed = DaytimeStress.analyze(hr: hr, rr: [])
        let real = DaytimeStress.analyze(hr: hr, rr: [], wakeWindow: window)

        XCTAssertTrue(fixed.hours.contains { $0.hour == 6 }, "precondition: the fixed window reads 06:00")
        XCTAssertFalse(fixed.hours.contains { $0.hour == 22 })
        XCTAssertFalse(real.hours.contains { $0.hour < 10 }, "asleep hours must not be scored")
        XCTAssertTrue(real.hours.contains { $0.hour == 22 }, "an awake hour past 22:00 must be scored")
        // Sleep hours no longer pull the reference down: the typical awake hour reads ≈1.0 with the real
        // window, but reads elevated against the sleep-dragged reference of the fixed one.
        let typicalReal = real.scored.first { $0.hour == 16 }!.level!    // 70 bpm = the awake median
        let typicalFixed = fixed.scored.first { $0.hour == 16 }!.level!
        XCTAssertEqual(typicalReal, 1.0, accuracy: 0.1)
        XCTAssertGreaterThan(typicalFixed, typicalReal)
    }

    func testWakeWindowIsPartOfTheMemoKey() {
        // Same streams, different window → different Result (never a stale cached one).
        var hr: [HRSample] = []
        for h in 8...14 { hr += hourHR(h, bpm: 60 + h) }
        let a = DaytimeStress.analyze(hr: hr, rr: [], wakeWindow: (8 * 3_600)...(15 * 3_600))
        let b = DaytimeStress.analyze(hr: hr, rr: [], wakeWindow: (11 * 3_600)...(15 * 3_600))
        XCTAssertNotEqual(a.hours.count, b.hours.count)
    }

    // MARK: - Live stays on the hourly scale

    func testLiveMatchesTheHourlyScale() {
        // Same centre and curve as the hours: a live window at the typical hour reads exactly that hour's
        // level. The SPREAD is the hours' floored at `liveMinHRSigma` (E9), so off-centre windows read
        // closer to 1.0 than the hour with the same mean does, never further.
        let day = DaytimeStress.analyze(hr: normalDay(), rr: [])
        func window(_ bpm: Int) -> [HRSample] { (0..<120).map { HRSample(ts: 90_000 + $0, bpm: bpm) } }
        let hourMeans = day.scored.compactMap(\.meanHR)
        let ref = DaytimeStress.liveReference(DaytimeStress.dayReference(hrMeans: hourMeans, rmssds: []))
        XCTAssertGreaterThanOrEqual(ref.sdHR, DaytimeStress.liveMinHRSigma)
        for bpm in [62, 70, 80] {
            let hourLevel = day.scored.first { $0.meanHR == Double(bpm) }!.level!
            let live = DaytimeStress.live(hr: window(bpm), rr: [], dayHours: day.hours)
            XCTAssertNotNil(live)
            let expected = DaytimeStress.dayRelativeSquash((Double(bpm) - ref.hr!) / ref.sdHR)
            XCTAssertEqual(live!, expected, accuracy: 1e-9, "live at \(bpm) bpm drifted off the live scale")
            XCTAssertLessThanOrEqual(abs(live! - 1.0), abs(hourLevel - 1.0) + 1e-9)
        }
        XCTAssertEqual(DaytimeStress.live(hr: window(70), rr: [], dayHours: day.hours)!,
                       day.scored.first { $0.meanHR == 70 }!.level!, accuracy: 1e-9)
        // A typical window at rest stays well under the live red warning (2.0).
        XCTAssertLessThan(DaytimeStress.live(hr: window(70), rr: [], dayHours: day.hours)!, 2.0)
    }

    /// E9: "HIGH" live is ~8 bpm over the typical hour, not ~4, and a morning with fewer than
    /// `liveMinReferenceHours` scored hours says nothing at all.
    func testLiveNeedsAReferenceAndARealMargin() {
        func window(_ bpm: Int) -> [HRSample] { (0..<120).map { HRSample(ts: 90_000 + $0, bpm: bpm) } }
        // A flat day: every hour at 70, so the day's own spread is ~0 and the floor decides.
        let flat = DaytimeStress.analyze(hr: (6...21).flatMap { hourHR($0, bpm: 70) }, rr: [])
        XCTAssertLessThan(DaytimeStress.live(hr: window(75), rr: [], dayHours: flat.hours)!, 2.0,
                          "5 bpm over a flat day is not HIGH")
        XCTAssertGreaterThanOrEqual(DaytimeStress.live(hr: window(80), rr: [], dayHours: flat.hours)!, 2.0,
                                    "10 bpm over a flat day is")
        // Only three scored hours: no reference yet, so no live reading.
        let early = DaytimeStress.analyze(hr: (6...8).flatMap { hourHR($0, bpm: 70) }, rr: [])
        XCTAssertLessThan(early.scored.count, DaytimeStress.liveMinReferenceHours)
        XCTAssertNil(DaytimeStress.live(hr: window(90), rr: [], dayHours: early.hours))
    }

    /// R-R for one hour with a controllable beat-to-beat jitter (drives RMSSD).
    private func hourRRVariable(_ hour: Int, rrMs: Int, jitter: Int, n: Int = 60) -> [RRInterval] {
        let base = hour * 3_600
        return (0..<n).map { RRInterval(ts: base + $0 * 50, rrMs: rrMs + ($0 % 2 == 0 ? jitter : -jitter)) }
    }

    // MARK: - Motion gate

    /// Gravity for one local hour. `activeFraction` of the records step far enough between
    /// consecutive samples to clear `WorkoutDetector.motionThreshold` (0.20 g L2); the rest hold
    /// still. The alternating ±step keeps every active record above the floor rather than only the
    /// first, so the produced active fraction matches `activeFraction` closely.
    private func hourGravity(_ hour: Int, activeFraction: Double, n: Int = 120) -> [GravitySample] {
        let base = hour * 3_600
        let activeCount = Int((Double(n) * activeFraction).rounded())
        return (0..<n).map { i in
            // 0.5 g of step per axis-pair is comfortably above the 0.20 walk floor when it alternates.
            let x = i < activeCount ? (i % 2 == 0 ? 0.5 : 0.0) : 0.0
            return GravitySample(ts: base + i * 30, x: x, y: 0, z: 1)
        }
    }

    func testEmptyGravityIsByteIdenticalToNoGravity() {
        // The degradation contract: with no motion channel NOTHING is masked and the read is
        // unchanged from the pre-gate behaviour.
        var hr: [HRSample] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 60 + (h - 8) * 5) }
        let withoutGravity = DaytimeStress.analyze(hr: hr, rr: [])
        let withEmptyGravity = DaytimeStress.analyze(hr: hr, rr: [], gravity: [])
        XCTAssertEqual(withoutGravity, withEmptyGravity)
        XCTAssertEqual(withEmptyGravity.activityMaskedHours, 0)
        XCTAssertFalse(withEmptyGravity.hours.contains { $0.maskedForActivity })
    }

    func testAmbulatoryHourIsMaskedNotScored() {
        // Four hours; the 11:00 hour has an elevated HR AND is ambulatory. Without motion it scores
        // as the day's most "stressed" hour — the exact false positive the gate exists to remove.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 60) }
        hr += hourHR(11, bpm: 110)   // the walk

        let unGated = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertNotNil(unGated.scored.first { $0.hour == 11 }?.level,
            "precondition: without gravity the ambulatory hour is scored as stress")

        var gravity: [GravitySample] = []
        for h in [8, 9, 10] { gravity += hourGravity(h, activeFraction: 0.0) }
        gravity += hourGravity(11, activeFraction: 1.0)

        let gated = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        let masked = gated.hours.first { $0.hour == 11 }
        XCTAssertNotNil(masked)
        XCTAssertNil(masked?.level, "an ambulatory hour must not be scored")
        XCTAssertTrue(masked?.maskedForActivity ?? false,
            "the hour must report WHY it is unscored — masked, not noData")
        XCTAssertEqual(masked?.meanHR, 110, "the reading itself is still reported, only the score is withheld")
        XCTAssertEqual(gated.activityMaskedHours, 1)
    }

    func testStillHourIsStillScoredWhenGravityPresent() {
        // The gate must not swallow a genuinely sedentary day just because gravity was supplied.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: h == 11 ? 85 : 60)
            gravity += hourGravity(h, activeFraction: 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0, "a still day must have nothing masked")
        XCTAssertNotNil(r.scored.first { $0.hour == 11 }?.level,
            "a stationary elevated-HR hour is exactly what the timeline SHOULD score")
    }

    func testLightMovementBelowFractionDoesNotMask() {
        // A stray reach or one trip to the kitchen (under activityMaskFraction) is not exertion.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: 60)
            gravity += hourGravity(h, activeFraction: h == 10 ? 0.10 : 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0,
            "10 % ambulatory is below activityMaskFraction (0.30) and must not mask the hour")
    }

    func testPostActivityShadowMasksOnlyWhileHRStaysElevated() {
        // The hour AFTER exertion is masked while its HR is still above the calm reference by
        // postActivityShadowBPM, and scored normally once it has recovered.
        func day(followingBPM: Int) -> DaytimeStress.Result {
            var hr: [HRSample] = []
            var gravity: [GravitySample] = []
            for h in [8, 9, 10, 13] {                       // still hours, set the ~60 bpm calm anchor
                hr += hourHR(h, bpm: 60)
                gravity += hourGravity(h, activeFraction: 0.0)
            }
            hr += hourHR(11, bpm: 120)                      // 11:00 — the workout hour
            gravity += hourGravity(11, activeFraction: 1.0)
            hr += hourHR(12, bpm: followingBPM)             // 12:00 — the shadow hour, now still
            gravity += hourGravity(12, activeFraction: 0.0)
            return DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        }
        // Still elevated well above the ~60 bpm calm reference → masked.
        let hot = day(followingBPM: 100)
        XCTAssertTrue(hot.hours.first { $0.hour == 12 }?.maskedForActivity ?? false,
            "an unrecovered post-exercise hour must be masked, not read as stress")
        // Back at the calm reference → the shadow self-limits and the hour is scored.
        let recovered = day(followingBPM: 60)
        XCTAssertFalse(recovered.hours.first { $0.hour == 12 }?.maskedForActivity ?? true,
            "once HR is back at the calm reference the shadow must not keep masking")
    }

    func testMaskedHoursAreExcludedFromTheCalmReference() {
        // An exertion hour must not drag the day's calm anchor upward, which would depress every
        // other hour's score. Same still hours, with and without an added ambulatory hour.
        var stillHR: [HRSample] = []
        var stillGravity: [GravitySample] = []
        for h in [8, 9, 10, 13] {
            stillHR += hourHR(h, bpm: h == 13 ? 80 : 60)
            stillGravity += hourGravity(h, activeFraction: 0.0)
        }
        let withoutWorkout = DaytimeStress.analyze(hr: stillHR, rr: [], gravity: stillGravity)

        var withHR = stillHR, withGravity = stillGravity
        withHR += hourHR(11, bpm: 130)
        withGravity += hourGravity(11, activeFraction: 1.0)
        let withWorkout = DaytimeStress.analyze(hr: withHR, rr: [], gravity: withGravity)

        let before = withoutWorkout.scored.first { $0.hour == 13 }?.level
        let after = withWorkout.scored.first { $0.hour == 13 }?.level
        XCTAssertNotNil(before); XCTAssertNotNil(after)
        XCTAssertEqual(before!, after!, accuracy: 1e-9,
            "a masked exertion hour leaked into the calm reference and moved an unrelated hour's score")
    }

    func testDifferentGravityDoesNotReuseAMemoizedResult() {
        // The analyze memo is keyed on the streams; two identical hr/rr days with DIFFERENT motion
        // must not share a cached Result.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 60) }
        hr += hourHR(11, bpm: 110)

        var still: [GravitySample] = []
        var moving: [GravitySample] = []
        for h in [8, 9, 10] {
            still += hourGravity(h, activeFraction: 0.0)
            moving += hourGravity(h, activeFraction: 0.0)
        }
        still += hourGravity(11, activeFraction: 0.0)
        moving += hourGravity(11, activeFraction: 1.0)

        let a = DaytimeStress.analyze(hr: hr, rr: [], gravity: still)
        let b = DaytimeStress.analyze(hr: hr, rr: [], gravity: moving)
        XCTAssertEqual(a.activityMaskedHours, 0)
        XCTAssertEqual(b.activityMaskedHours, 1, "the memo key ignored gravity and returned a stale Result")
    }

    // MARK: - Additivity: the `mode` parameter is opt-in, day-relative stays the default

    func testDayRelativeDefaultIsByteIdenticalToExplicitMode() {
        // The additive `mode` parameter defaults to `.dayRelative`. Confirms the implicit call
        // (every pre-existing call site, unmodified) and the explicit `.dayRelative` case
        // produce a BYTE-IDENTICAL `Result` — every field, not just the pre-existing ones —
        // proving the new mode is purely additive and never a silent behaviour change.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        var rr: [RRInterval] = []
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(14, rrMs: 900, jitter: 5)

        let implicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600)
        let explicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600, mode: .dayRelative)
        XCTAssertEqual(implicit, explicit,
            "omitting `mode` must be byte-identical to passing `.dayRelative` explicitly")
    }

    func testHighStressMinutesCountsAllHighBandHoursNotJustTheTrailingRun() {
        // An isolated morning spike, then a calm run ending the day: sustainedHigh only cares
        // about the TRAILING run (and must be false here, since the day ends calm), but
        // highStressMinutes is a day-wide tally and must still count the earlier spike hour —
        // proving it is computed independently, not derived from sustainedRun.
        var hr: [HRSample] = []
        hr += hourHR(7, bpm: 130)   // isolated high spike
        hr += hourHR(8, bpm: 60)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 60)
        hr += hourHR(11, bpm: 60)   // trailing hour is calm -> NOT sustained
        let r = DaytimeStress.analyze(hr: hr, rr: [])

        XCTAssertFalse(r.sustainedHigh, "the trailing hour is calm, so sustained-high must not fire")
        let expectedHighHours = r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count
        XCTAssertGreaterThan(expectedHighHours, 0, "the isolated morning spike should read as high band")
        XCTAssertEqual(r.highStressMinutes, expectedHighHours * (DaytimeStress.bucketSeconds / 60))
        XCTAssertFalse(r.hrOnlyFallback, "day-relative mode never sets the baseline-relative fallback flag")
    }

    // MARK: - Baseline-relative mode (Oura-style, vs a PERSONAL rolling baseline)
    //
    // Fixtures below use a 65 bpm personal HR baseline (matching the ~65 bpm pooled
    // 10th-percentile figure from the validated 26-day Oura-reference correlation — see
    // `DaytimeStress.baselineRelativeHighMarginBPM`) and elevations measured from it in terms of
    // that validated ~15 bpm margin, so the expected band crossings are exact, not approximate.

    func testMarginToSigmaLandsExactlyOnBand() {
        // The validated 15 bpm margin over baseline must land EXACTLY on highBandFloor (2.0) on
        // the shared squash curve — the core identity `.baselineRelative` scoring relies on.
        let sd = DaytimeStress.marginToSigma(marginBPM: DaytimeStress.baselineRelativeHighMarginBPM,
                                             atBand: DaytimeStress.highBandFloor)
        XCTAssertEqual(DaytimeStress.squash(DaytimeStress.baselineRelativeHighMarginBPM / sd),
                      DaytimeStress.highBandFloor, accuracy: 1e-9)
    }

    func testBaselineRelativeModeRecoversMultipleInjectedElevations() {
        // Personal daytime-HR baseline: 20 constant "days" at 65 bpm converges the EWMA center
        // to exactly 65 (spread is folded but NOT used for the HR high-band threshold — see
        // baselineRelativeHighMarginBPM).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        XCTAssertEqual(hrBaseline.baseline, 65.0, accuracy: 1e-6)

        // FOUR distinct injected HR elevations across the SAME day's waking hours — the repo's
        // derived-signal rule (CLAUDE.md "validate against the artifact, not one match") requires
        // recovering MULTIPLE injected values, not a single high-vs-low pair. 65 (at baseline),
        // 72 (+7, mild), 80 (+15, exactly the validated margin), 95 (+30, well past it).
        let levels: [(hour: Int, bpm: Int)] = [(8, 65), (10, 72), (13, 80), (16, 95)]
        var hr: [HRSample] = []
        for (h, bpm) in levels { hr += hourHR(h, bpm: bpm) }

        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))
        let scores = levels.map { pair in r.scored.first { $0.hour == pair.hour }!.level! }

        // Strictly increasing with the injected elevation — all four levels recovered, in order.
        for i in 1..<scores.count {
            XCTAssertGreaterThan(scores[i], scores[i - 1],
                "hour \(levels[i].hour) (\(levels[i].bpm) bpm) should score higher than hour \(levels[i - 1].hour) (\(levels[i - 1].bpm) bpm)")
        }
        // The at-baseline hour reads at the 1.5 midpoint; +15 bpm (the validated margin) lands
        // exactly on highBandFloor; the most-elevated hour clears well past it.
        XCTAssertEqual(scores[0], 1.5, accuracy: 0.05)
        XCTAssertEqual(scores[2], DaytimeStress.highBandFloor, accuracy: 0.01,
            "the validated +15 bpm margin should land exactly on highBandFloor")
        XCTAssertGreaterThan(scores.last!, DaytimeStress.highBandFloor)
        XCTAssertTrue(r.hrOnlyFallback, "rmssd: nil must flag the HR-only fallback")
    }

    func testBaselineRelativeCalmDayAtPersonalBaselineReadsLowNotHigh() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [8, 10, 13, 16] { hr += hourHR(h, bpm: 65) }   // every hour sits exactly at baseline
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        for p in r.scored {
            XCTAssertEqual(p.level!, 1.5, accuracy: 0.05,
                "a day flat at the personal baseline should read ~1.5, not elevated")
        }
        XCTAssertEqual(r.highStressMinutes, 0)
        XCTAssertFalse(r.sustainedHigh)
    }

    func testBaselineRelativeElevatedDayProducesHighStressMinutes() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 95) }   // +30 bpm — twice the validated high-band margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertGreaterThan(r.highStressMinutes, 0)
        XCTAssertEqual(r.highStressMinutes,
                      r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count * (DaytimeStress.bucketSeconds / 60))
        for p in r.scored { XCTAssertGreaterThanOrEqual(p.level!, DaytimeStress.highBandFloor) }
    }

    func testBaselineRelativeNilRMSSDFallsBackToHROnlyAndFlagsDegraded() {
        // An imported, Oura-era day: no personal RMSSD baseline exists yet (rmssd: nil) and no
        // R-R stream is available either. The read must still complete honestly, never crash.
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 80) }   // right at the validated +15 bpm margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertTrue(r.hrOnlyFallback)
        XCTAssertFalse(r.scored.isEmpty, "HR-only scoring must still produce a timeline")
        for p in r.scored { XCTAssertNotNil(p.level) }
    }

    func testBaselineRelativeUsesRMSSDBaselineWhenAvailable() {
        // Personal baselines: HR steady at 65 bpm, RMSSD steady at 40 ms (both spread-floored).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        let rmssdBaseline = Baselines.foldHistory(Array(repeating: 40.0, count: 20), cfg: Baselines.daytimeRMSSDCfg)

        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 65) }        // HR AT baseline in both hours — isolates RMSSD
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)        // normal variability
        rr += hourRRVariable(14, rrMs: 900, jitter: 2)        // suppressed HRV -> more stressed

        let r = DaytimeStress.analyze(hr: hr, rr: rr,
                                      mode: .baselineRelative(hr: hrBaseline, rmssd: rmssdBaseline))
        XCTAssertFalse(r.hrOnlyFallback, "an RMSSD baseline was supplied — no fallback")
        let normal = r.scored.first { $0.hour == 9 }!.level!
        let suppressed = r.scored.first { $0.hour == 14 }!.level!
        XCTAssertGreaterThan(suppressed, normal,
            "suppressed RMSSD vs. the personal baseline should read MORE stressed than normal variability")
    }
}
