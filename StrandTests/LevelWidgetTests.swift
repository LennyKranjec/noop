import XCTest
import StrandAnalytics

/// The level tile's whole decision, pinned.
///
/// The widget draws one number a day and has no way of checking it, so everything that could make it lie
/// lives in `WidgetSnapshot.levelRender` and is tested here: the three honest states, the refusal to invent
/// a delta, the coverage caveat, and — the one that matters most — that a day which is not today can never
/// be captioned as today's.
final class LevelWidgetTests: XCTestCase {

    /// Fixed zone, so a day difference is a day difference wherever this runs.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return c
    }()

    private func date(_ key: String, hour: Int = 9) -> Date {
        var c = DateComponents()
        let parts = key.split(separator: "-").compactMap { Int($0) }
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = hour
        return calendar.date(from: c)!
    }

    private func snapshot(level: Int?, day: String?, prev: Int? = nil, prevDay: String? = nil,
                          coverage: Double? = 1.0, partial: Bool? = false,
                          published: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        var snap = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false,
                                  updated: Date(timeIntervalSince1970: 1_700_000_000))
        snap.levelValue = level
        snap.levelDay = day
        snap.levelPrevValue = prev
        snap.levelPrevDay = prevDay
        snap.levelCoverage = coverage
        snap.levelPartial = partial
        snap.levelPublishedAt = published
        return snap
    }

    private func resolved(_ snap: WidgetSnapshot?, on day: String) -> WidgetSnapshot.LevelRender {
        WidgetSnapshot.levelRender(snapshot: snap, now: date(day), calendar: calendar)
    }

    private func level(_ render: WidgetSnapshot.LevelRender) -> WidgetSnapshot.LevelRender.Level? {
        if case .level(let l) = render { return l }
        return nil
    }

    // MARK: - The three honest states

    func testNothingEverPublishedIsUnknownNotAnAbsentLevel() {
        XCTAssertEqual(resolved(nil, on: "2026-03-10"), .unknown)
    }

    /// A snapshot written by a build older than these fields has a level stamp of nil, which is "we were
    /// never told" — the water tile's fresh-install bug in the other direction.
    func testASnapshotPredatingTheLevelFieldsIsUnknown() {
        let old = snapshot(level: nil, day: nil, published: nil)
        XCTAssertEqual(resolved(old, on: "2026-03-10"), .unknown)
    }

    func testAPublishedAbsenceIsNotScoredYetRatherThanUnknown() {
        let snap = snapshot(level: nil, day: nil)
        XCTAssertEqual(resolved(snap, on: "2026-03-10"), .notScored)
        XCTAssertEqual(WidgetSnapshot.levelCaption(.notScored), "not scored yet")
        XCTAssertNotEqual(WidgetSnapshot.levelCaption(.notScored), WidgetSnapshot.levelCaption(.unknown))
    }

    /// A level with no day to pin it to cannot be placed, so it is not shown at all.
    func testALevelWithNoDayStampIsRefused() {
        XCTAssertEqual(resolved(snapshot(level: 71, day: nil), on: "2026-03-10"), .notScored)
    }

    // MARK: - The delta

    func testTheDeltaComesFromTheTwoWrittenDays() {
        let snap = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.delta, 3)
        XCTAssertEqual(WidgetSnapshot.levelDeltaText(3), "+3")
    }

    func testADropIsSignedWithATrueMinus() {
        let snap = snapshot(level: 64, day: "2026-03-10", prev: 70, prevDay: "2026-03-09")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.delta, -6)
        XCTAssertEqual(WidgetSnapshot.levelDeltaText(-6), "\u{2212}6")
    }

    /// The first scored day has nothing behind it. NO delta — and specifically not a "+0", which would
    /// claim a comparison that was never made.
    func testNoPreviousDayMeansNoDeltaAtAllNotAPlusZero() {
        let snap = snapshot(level: 71, day: "2026-03-10")
        XCTAssertNil(level(resolved(snap, on: "2026-03-10"))?.delta)
        XCTAssertNil(WidgetSnapshot.levelDeltaText(nil))
        XCTAssertEqual(WidgetSnapshot.levelCaption(resolved(snap, on: "2026-03-10")), "no day before")
    }

    /// A gap in the ledger: the stored previous day is real but is not the day before. It is not
    /// "yesterday", so it yields nothing rather than a difference across an unknown span.
    func testANonAdjacentPreviousDayYieldsNoDelta() {
        let snap = snapshot(level: 71, day: "2026-03-10", prev: 60, prevDay: "2026-03-06")
        XCTAssertNil(level(resolved(snap, on: "2026-03-10"))?.delta)
    }

    /// A genuine no-change is a delta of zero, and it must LOOK different from having no delta.
    func testAGenuineNoChangeIsAZeroDeltaShownAsPlusMinusZero() {
        let snap = snapshot(level: 71, day: "2026-03-10", prev: 71, prevDay: "2026-03-09")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.delta, 0)
        XCTAssertEqual(WidgetSnapshot.levelDeltaText(0), "±0")
    }

    /// The adjacency check goes through the calendar, so it still holds across a DST change — 2026-03-29
    /// is a 23-hour day in Europe/Berlin.
    func testAdjacencySurvivesADaylightSavingBoundary() {
        XCTAssertEqual(WidgetSnapshot.dayBefore("2026-03-30", calendar: calendar), "2026-03-29")
        let snap = snapshot(level: 71, day: "2026-03-30", prev: 69, prevDay: "2026-03-29")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-30"))?.delta, 2)
    }

    // MARK: - Day-stamp freshness: a stale day never reads as today

    func testTodaysLevelIsTheOnlyOneCaptionedAgainstYesterday() {
        let snap = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09")
        let render = resolved(snap, on: "2026-03-10")
        XCTAssertEqual(level(render)?.daysBehind, 0)
        XCTAssertTrue(level(render)!.isToday)
        XCTAssertEqual(WidgetSnapshot.levelCaption(render), "vs yesterday")
    }

    /// The pending morning: the level day's own entry has not landed, so the app shows the held stand-in
    /// day. `updated` is fresh — the day stamp is what tells the truth.
    func testYesterdaysLevelIsNamedAsYesterdaysNotAsTodays() {
        let snap = snapshot(level: 71, day: "2026-03-09", prev: 68, prevDay: "2026-03-08")
        let render = resolved(snap, on: "2026-03-10")
        XCTAssertEqual(level(render)?.daysBehind, 1)
        XCTAssertFalse(level(render)!.isToday)
        XCTAssertEqual(WidgetSnapshot.levelCaption(render), "yesterday's level")
    }

    func testAnOlderLevelIsNamedByItsAge() {
        let snap = snapshot(level: 71, day: "2026-03-06")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.daysBehind, 4)
        XCTAssertEqual(WidgetSnapshot.levelCaption(resolved(snap, on: "2026-03-10")), "4 days ago")
    }

    /// A stamp AHEAD of the render date (a clock change) cannot be described, so it counts as not-today
    /// rather than being rounded down to today.
    func testAFutureDayStampIsNeverPresentedAsToday() {
        let snap = snapshot(level: 71, day: "2026-03-11")
        let render = resolved(snap, on: "2026-03-10")
        XCTAssertNil(level(render)?.daysBehind)
        XCTAssertFalse(level(render)!.isToday)
        XCTAssertEqual(WidgetSnapshot.levelCaption(render), "last scored level")
    }

    func testAMalformedDayStampIsNeverPresentedAsToday() {
        let snap = snapshot(level: 71, day: "not-a-day")
        XCTAssertNil(level(resolved(snap, on: "2026-03-10"))?.daysBehind)
        XCTAssertFalse(level(resolved(snap, on: "2026-03-10"))!.isToday)
    }

    /// The day count is taken by the calendar, not by dividing by 86 400: the 23-hour day would otherwise
    /// land in the previous bucket and yesterday's level would read as today's.
    func testTheDayCountHoldsAcrossADaylightSavingBoundary() {
        let snap = snapshot(level: 71, day: "2026-03-29")
        XCTAssertEqual(level(resolved(snap, on: "2026-03-30"))?.daysBehind, 1)
        XCTAssertEqual(level(resolved(snap, on: "2026-03-29"))?.daysBehind, 0)
    }

    // MARK: - The coverage caveat

    func testAFullCoverageLevelIsNotMarkedPartial() {
        XCTAssertEqual(level(resolved(snapshot(level: 71, day: "2026-03-10"), on: "2026-03-10"))?.partial,
                       false)
    }

    func testThinCoverageMarksTheLevelPartial() {
        let snap = snapshot(level: 71, day: "2026-03-10", coverage: 0.62)
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.partial, true)
    }

    /// A day written at its deadline with the night only half in is partial even where the weights that
    /// DID arrive covered the whole formula.
    func testADeadlineWrittenDayIsPartialEvenAtFullCoverage() {
        let snap = snapshot(level: 71, day: "2026-03-10", coverage: 1.0, partial: true)
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.partial, true)
    }

    /// An older snapshot carried neither field: nothing is known, so nothing is claimed either way.
    func testAnUnstampedCoverageIsNotTreatedAsPartial() {
        let snap = snapshot(level: 71, day: "2026-03-10", coverage: nil, partial: nil)
        XCTAssertEqual(level(resolved(snap, on: "2026-03-10"))?.partial, false)
    }

    /// The widget extension links no analytics package, so the threshold is restated in `WidgetSnapshot`.
    /// This is the one place that can see BOTH and check they still agree.
    func testTheRestatedCoverageThresholdStillMatchesTheEngine() {
        func breakdown(_ coverage: Double) -> LevelBreakdown {
            LevelBreakdown(components: [], raw: 0, stepPenalty: 1, level: 0, coverage: coverage)
        }
        XCTAssertTrue(breakdown(WidgetSnapshot.levelFullCoverage - 0.001).isPartialCoverage)
        XCTAssertFalse(breakdown(1.0).isPartialCoverage)
        XCTAssertFalse(breakdown(WidgetSnapshot.levelFullCoverage).isPartialCoverage)
    }

    // MARK: - Change detection

    func testTheFirstLevelPublishIsNeverDedupedAway() {
        let snap = snapshot(level: 71, day: "2026-03-10")
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: snap))
    }

    /// The publish that says "there is no level yet" changes no other field at all, and it still has to
    /// reach WidgetKit so the tile stops asking for the app to be opened.
    func testTheFirstPublishOfAnAbsenceStillCountsAsAChange() {
        let before = snapshot(level: nil, day: nil, published: nil)
        let after = snapshot(level: nil, day: nil)
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: before, to: after))
    }

    /// ...but re-confirming the same absence must not spend a reload, which is why the stamp is compared
    /// only for presence and `publishLevel` writes it once.
    func testReConfirmingTheSameLevelSpendsNothing() {
        let a = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09")
        var b = a
        b.updated = a.updated.addingTimeInterval(3_600)
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: a, to: b))
    }

    func testEachLevelFieldIsDetected() {
        let base = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09")
        var edits: [(String, (inout WidgetSnapshot) -> Void)] = []
        edits.append(("value", { $0.levelValue = 72 }))
        edits.append(("day", { $0.levelDay = "2026-03-11" }))
        edits.append(("coverage", { $0.levelCoverage = 0.7 }))
        edits.append(("partial", { $0.levelPartial = true }))
        edits.append(("prevValue", { $0.levelPrevValue = 69 }))
        edits.append(("prevDay", { $0.levelPrevDay = "2026-03-08" }))
        for (name, edit) in edits {
            var next = base
            edit(&next)
            XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: next),
                          "\(name) must reach WidgetKit")
        }
    }

    /// The day rolling over changes nothing in the snapshot — the caption changes on the widget's own
    /// midnight timeline entry, not on a publish — so this pins that the level fields do NOT pretend to
    /// have moved. It is the freshness test above that keeps the render honest.
    func testARolloverIsNotAContentChangeOfTheLevelFields() {
        let a = snapshot(level: 71, day: "2026-03-10")
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: a, to: a))
        XCTAssertEqual(level(resolved(a, on: "2026-03-10"))?.daysBehind, 0)
        XCTAssertEqual(level(resolved(a, on: "2026-03-11"))?.daysBehind, 1)
    }

    // MARK: - Carry-forward

    /// A full publish rebuilds the snapshot from the repository, which knows nothing about the ledger.
    /// Without the carry it blanked the level and the tile fell back to "not scored yet".
    func testAFullRebuildCarriesTheLevelRatherThanBlankingIt() {
        let stored = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09",
                              coverage: 0.8, partial: true)
        var rebuilt = WidgetSnapshot(recovery: 60, bpm: 55, batteryPct: 80, bonded: true, updated: Date())
        WidgetSnapshot.carryLevel(stored: stored, into: &rebuilt)
        XCTAssertEqual(rebuilt.levelValue, 71)
        XCTAssertEqual(rebuilt.levelDay, "2026-03-10")
        XCTAssertEqual(rebuilt.levelPrevValue, 68)
        XCTAssertEqual(rebuilt.levelPrevDay, "2026-03-09")
        XCTAssertEqual(rebuilt.levelCoverage, 0.8)
        XCTAssertEqual(rebuilt.levelPartial, true)
        XCTAssertEqual(rebuilt.levelPublishedAt, stored.levelPublishedAt)
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: stored, to: {
            var same = stored
            WidgetSnapshot.carryLevel(stored: stored, into: &same)
            return same
        }()))
    }

    func testCarryingFromNothingLeavesTheLevelUntold() {
        var rebuilt = WidgetSnapshot(recovery: 60, bpm: 55, batteryPct: 80, bonded: true, updated: Date())
        WidgetSnapshot.carryLevel(stored: nil, into: &rebuilt)
        XCTAssertNil(rebuilt.levelPublishedAt)
        XCTAssertEqual(WidgetSnapshot.levelRender(snapshot: rebuilt), .unknown)
    }

    // MARK: - Round trip

    /// The level fields ride in the same blob as everything else, so they have to survive a decode — and a
    /// snapshot written WITHOUT them must still decode, or the widget would read a full snapshot as
    /// "nothing has ever been published".
    func testTheLevelFieldsRoundTripAndTheirAbsenceStillDecodes() throws {
        let snap = snapshot(level: 71, day: "2026-03-10", prev: 68, prevDay: "2026-03-09", coverage: 0.9)
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back.levelValue, 71)
        XCTAssertEqual(back.levelDay, "2026-03-10")
        XCTAssertEqual(back.levelCoverage, 0.9)

        let legacy = Data(#"{"bonded":false,"updated":0}"#.utf8)
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)
        XCTAssertNil(old.levelValue)
        XCTAssertNil(old.levelPublishedAt)
        XCTAssertEqual(WidgetSnapshot.levelRender(snapshot: old), .unknown)
    }
}
