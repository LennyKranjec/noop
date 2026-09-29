import XCTest
@testable import StrandAnalytics
import WhoopProtocol   // RRInterval

/// #977 — the RSA respiratory-rate path must not splice across dropped beats.
///
/// `respRateFromRR` rebuilds beat times by cumulatively summing RR, which cannot represent a stretch
/// where no beats arrived: a 30–45 s dropout is stitched shut and the two sides become adjacent on the
/// beat-time axis, so the tachogram gets a discontinuity the peak-picker reads as a breath. The reporter
/// measured Σ(rrMs) ÷ wall-clock of 0.859 on one WHOOP 5 corpus — one wearer, one strap, so an existence
/// proof that dropouts reach this magnitude, not a population figure.
///
/// The signal is `ts`, and only `ts`: these beats were lost before storage, so they were never in the
/// array to be marked, and `cleanRRGapAware` — which takes `[Double]` and has no clock — cannot see them.
///
/// Every vector here is synthetic and says so. Inventing a "real capture" for a timing bug would be
/// worse than useless: the property under test is the relationship between `ts` and Σ RR, which a
/// fabricated capture would assert by construction.
final class RespRateGapAwareTests: XCTestCase {

    /// ~15 breaths/min of RSA on ~900 ms beats, with `ts` advancing consistently with the intervals.
    /// `gapAfter` inserts a wall-clock jump of `gapS` after that beat index WITHOUT adding beats —
    /// exactly what a dropout looks like in the store.
    private func series(beats: Int, gapAfter: Int? = nil, gapS: Int = 40) -> [RRInterval] {
        var rows: [RRInterval] = []
        var t = 1_000_000
        var carryMs = 0.0
        for i in 0..<beats {
            let rr = 900.0 + 60.0 * sin(2.0 * Double.pi * Double(i) * 0.9 / 4.0)
            carryMs += rr
            if let g = gapAfter, i == g { t += gapS }
            rows.append(RRInterval(ts: t, rrMs: Int(rr.rounded())))
            if carryMs >= 1000 { t += Int(carryMs / 1000); carryMs -= Double(Int(carryMs / 1000)) * 1000 }
        }
        return rows
    }

    /// The measured non-wake windows of a series, which is what #977 is actually about: the splice skip is a
    /// PER-WINDOW rule. These assertions used to go through `respRateFromRR`, whose value also depends on
    /// how many windows a night needs before it may report at all (`respNonWakeMinWindows`) - a separate
    /// concern that was silently doing half the work of pinning this one. Asserting the window pool directly
    /// keeps each rule pinned by its own test, and keeps these fixtures as small as the property needs.
    private func measuredWindows(_ rr: [RRInterval]) -> [Double] {
        SleepStager.respRateWindows(rr, start: 0, end: 2_000_000, stages: [])?.nonWake ?? []
    }

    /// A contiguous night is untouched. This is the regression guard: the change must alter nothing when
    /// the clock and the beats agree, or it would move every existing user's reported rate.
    func testContiguousNightStillProducesARate() {
        // 800 beats at ~0.9 s is ~720 s: six full 120 s spectral windows, which clears
        // `respNonWakeMinWindows` so the NIGHT-level estimate is answerable at all.
        let rr = series(beats: 800)
        let rate = SleepStager.respRateFromRR(rr, start: 0, end: 2_000_000)
        XCTAssertFalse(rate.isNaN, "a clean series must still yield a rate")
        XCTAssertTrue((6.0...24.0).contains(rate), "expected a plausible breathing rate, got \(rate)")
    }

    /// The same beat VALUES, with a 40 s wall-clock hole punched in: the only difference is `ts`. The window
    /// holding the splice is skipped. Resized with the nightly-metrics rework (spectral 120 s windows, beat
    /// times rebuilt PER WINDOW): the old fixture was one 5-min window, but at 330 beats the new recipe has
    /// clean windows either side of the hole and rightly measures them - a splice now costs only its own
    /// window. So this uses ~140 beats: ONE measurable window, which holds the splice, and a post-gap tail too
    /// short to measure. Clean -> that window is measured; spliced -> it is not, and nothing but `ts` differs.
    func testASplicedWindowIsNotMeasured() {
        let clean = series(beats: 140)
        let spliced = series(beats: 140, gapAfter: 70)
        XCTAssertEqual(clean.map(\.rrMs), spliced.map(\.rrMs), "the fixture must differ only in ts")
        XCTAssertEqual(measuredWindows(clean).count, 1,
                       "the unspliced twin must be measurable, else the emptiness below proves nothing")
        XCTAssertEqual(measuredWindows(spliced).count, 0, "the window holding the splice must be skipped")
    }

    /// With clean windows on both sides of the hole, those windows still read the true ~15/min: the spliced
    /// window is dropped rather than contributing a fabricated interval.
    func testASpliceCostsOnlyItsOwnWindow() {
        let clean = measuredWindows(series(beats: 800))
        let spliced = measuredWindows(series(beats: 800, gapAfter: 450))
        XCTAssertEqual(spliced.count, clean.count - 1, "exactly the spliced window is lost")
        for w in spliced { XCTAssertEqual(w, 15.0, accuracy: 1.0) }
        // The gap is placed MID-window on purpose: `spectralRespRate` compares each beat against the
        // PREVIOUS one, so a jump landing on a window's first beat is invisible to the splice check.
        // And the night still reports, from the windows that survived.
        XCTAssertEqual(SleepStager.respRateFromRR(series(beats: 800, gapAfter: 450),
                                                 start: 0, end: 2_000_000), 15.0, accuracy: 1.0)
    }

    /// A one-second discrepancy is `ts` quantisation, not a dropout: `ts` is whole seconds while beats
    /// are sub-second, so a strict "any disagreement is a gap" rule would reject every ordinary night.
    func testSecondLevelJitterIsNotTreatedAsAGap() {
        let plain = measuredWindows(series(beats: 330))
        let jittered = measuredWindows(series(beats: 330, gapAfter: 165, gapS: 1))
        XCTAssertEqual(jittered.count, plain.count, "1 s of ts quantisation must cost no window")
        XCTAssertFalse(plain.isEmpty, "the fixture must measure something, else this proves nothing")
    }

    // MARK: - The night-level pool minimum (its own concern, pinned on its own)

    /// One surviving 120 s window is not a night's respiratory rate. The deep pool has always needed
    /// `respDeepMinWindows`; the non-wake fallback pool was gated on nothing but emptiness, so a night that
    /// measured a single window reported that window's number as the night's - and it then fed the resp
    /// baseline the illness and readiness gates read. Below `respNonWakeMinWindows` the night abstains.
    func testASingleMeasuredWindowDoesNotBecomeTheNightsRate() {
        let oneWindow = series(beats: 140)
        XCTAssertEqual(measuredWindows(oneWindow).count, 1, "fixture must measure exactly one window")
        XCTAssertTrue(SleepStager.respRateFromRR(oneWindow, start: 0, end: 2_000_000).isNaN,
                      "one window is thin evidence, not a night's respiratory rate")
    }

    /// The boundary: exactly `respNonWakeMinWindows` measured non-wake windows reports, one fewer abstains.
    func testNonWakePoolMinimumBoundary() {
        // ~133 beats fill one 120 s window at ~0.9 s per beat, so N windows need ~134 * N beats.
        let perWindow = 134
        let below = series(beats: perWindow * (SleepStager.respNonWakeMinWindows - 1))
        let atBar = series(beats: perWindow * SleepStager.respNonWakeMinWindows)
        XCTAssertEqual(measuredWindows(below).count, SleepStager.respNonWakeMinWindows - 1)
        XCTAssertEqual(measuredWindows(atBar).count, SleepStager.respNonWakeMinWindows)
        XCTAssertTrue(SleepStager.respRateFromRR(below, start: 0, end: 2_000_000).isNaN,
                      "one window short of the bar must abstain")
        XCTAssertFalse(SleepStager.respRateFromRR(atBar, start: 0, end: 2_000_000).isNaN,
                       "exactly at the bar must report")
    }

    /// The row filter must keep exactly what `HRVAnalyzer.rangeFilter` keeps — the fix filters rows
    /// rather than values to retain `ts`, and that equivalence is the reason it is safe.
    func testRowFilterMatchesRangeFilter() {
        let raw: [Double] = [250, 300, 900, 1500, 2000, 2001, 45]
        let viaRange = HRVAnalyzer.rangeFilter(raw)
        let viaRows = raw.filter { $0 >= HRVAnalyzer.rrMinMs && $0 <= HRVAnalyzer.rrMaxMs }
        XCTAssertEqual(viaRange, viaRows)
    }
}
