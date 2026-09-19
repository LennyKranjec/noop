import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAltStoreProvisionedGroupWinsOverBuildTimeIdentifier() {
        let configured = "group.com.noopapp.noop.staging"
        let remapped = configured + ".TEAM123456"

        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": configured,
                "ALTAppGroups": [remapped]
            ]),
            remapped
        )
    }

    func testXcodeBuildFallsBackToConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop"
            ]),
            "group.example.noop"
        )
    }

    func testUnrelatedAltStoreGroupsDoNotOverrideConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop",
                "ALTAppGroups": [
                    "group.example.first",
                    "group.example.second"
                ]
            ]),
            "group.example.noop"
        )
    }

    func testSingleProvisionedGroupIsUsableWithoutConfiguredIdentifier() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "ALTAppGroups": ["group.example.noop.TEAM123456"]
            ]),
            "group.example.noop.TEAM123456"
        )
    }

    func testRuntimeUnavailableSnapshotContainsNoDemoValues() {
        let snapshot = WidgetSnapshot.unavailable

        XCTAssertNil(snapshot.recovery)
        XCTAssertNil(snapshot.bpm)
        XCTAssertNil(snapshot.batteryPct)
        XCTAssertFalse(snapshot.bonded)
    }

    private func renderedSnapshot(updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false)
    }

    func testRenderedContentFirstPublishAlwaysChanges() {
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: renderedSnapshot()))
    }

    func testRenderedContentIgnoresTimestampOnlyChange() {
        let previous = renderedSnapshot()
        let next = renderedSnapshot(updated: previous.updated.addingTimeInterval(900))

        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsLiveFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.bpm = 59

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsScoreFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.rest = 82

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testLiveUpdateReusesSnapshotWithinSameLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let oneHourLater = previous.updated.addingTimeInterval(3_600)

        XCTAssertFalse(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: oneHourLater, calendar: calendar))
    }

    func testLiveUpdateRequiresFullBuildAfterLocalDayRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let nextDay = previous.updated.addingTimeInterval(86_400)

        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: nextDay, calendar: calendar))
        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: nil, now: nextDay, calendar: calendar))
    }

    // MARK: - The lock-screen strip

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2023-11-14 22:13:20 UTC.
    private let evening = Date(timeIntervalSince1970: 1_700_000_000)

    func testRenderedContentDetectsStripDayStampChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.stepsDay = "2023-11-14"
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))

        var effortNext = previous
        effortNext.effortDay = "2023-11-14"
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: effortNext))
    }

    func testRenderedContentAdmitsAConfirmedStressReadOnlyOnceItHasAged() {
        var previous = renderedSnapshot()
        previous.stressNow = 1.2
        previous.stressNowAt = evening
        var soon = previous
        soon.stressNowAt = evening.addingTimeInterval(60)
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: soon))

        var later = previous
        later.stressNowAt = evening.addingTimeInterval(20 * 60)
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: later))
    }

    func testStripDayIsCurrentOnTheCalendarDayAndBeforeTheLogicalRollover() {
        XCTAssertTrue(WidgetSnapshot.isStripDayCurrent("2023-11-14", now: evening, calendar: utc))
        XCTAssertFalse(WidgetSnapshot.isStripDayCurrent("2023-11-13", now: evening, calendar: utc))
        XCTAssertFalse(WidgetSnapshot.isStripDayCurrent(nil, now: evening, calendar: utc))
        // 01:00 the next morning: Today is still on the 14th until 04:00, and so is the strip.
        let smallHours = evening.addingTimeInterval(3 * 3_600)
        XCTAssertTrue(WidgetSnapshot.isStripDayCurrent("2023-11-14", now: smallHours, calendar: utc))
        XCTAssertTrue(WidgetSnapshot.isStripDayCurrent("2023-11-15", now: smallHours, calendar: utc))
        // After the rollover the 14th is over.
        XCTAssertFalse(WidgetSnapshot.isStripDayCurrent("2023-11-14", now: evening.addingTimeInterval(8 * 3_600),
                                                        calendar: utc))
    }

    func testStripStepsAreJudgedByTheirOwnDayNotByUpdated() {
        // A fresh `updated` (a live publish) must not vouch for yesterday's count.
        var snap = renderedSnapshot(updated: evening)
        snap.stepsToday = 8_420
        snap.stepsDay = "2023-11-13"
        XCTAssertNil(snap.stripSteps(now: evening, calendar: utc))
        // And a stale `updated` must not blank today's.
        snap.updated = evening.addingTimeInterval(-3 * 86_400)
        snap.stepsDay = "2023-11-14"
        XCTAssertEqual(snap.stripSteps(now: evening, calendar: utc), 8_420)
    }

    func testFallbackYieldsToFiguresTodayPublishedRecently() {
        var stored = renderedSnapshot()
        stored.stepsToday = 9_100
        stored.stepsDay = "2023-11-14"
        stored.effortToday = 52
        stored.effortTodayDisplay = "52.0"
        stored.effortTarget = 70
        stored.effortDay = "2023-11-14"
        stored.stripTodayAt = evening.addingTimeInterval(-5 * 60)
        var next = renderedSnapshot()
        next.stepsToday = 8_800
        next.stepsDay = "2023-11-14"
        next.effortToday = 50
        next.effortTodayDisplay = "50.0"
        next.effortDay = "2023-11-14"

        WidgetSnapshot.mergeStripFallback(stored: stored, into: &next, now: evening, calendar: utc)

        XCTAssertEqual(next.stepsToday, 9_100)
        XCTAssertEqual(next.effortToday, 52)
        XCTAssertEqual(next.effortTodayDisplay, "52.0")
        XCTAssertEqual(next.effortTarget, 70)
        XCTAssertEqual(next.stripTodayAt, stored.stripTodayAt)
    }

    func testFallbackWinsOnceTodayHasGoneQuietButNeverBlanksTheSameDay() {
        var stored = renderedSnapshot()
        stored.stepsToday = 9_100
        stored.stepsDay = "2023-11-14"
        stored.effortToday = 52
        stored.effortDay = "2023-11-14"
        stored.stripTodayAt = evening.addingTimeInterval(-2 * 3_600)
        var next = renderedSnapshot()
        next.stepsToday = 9_600
        next.stepsDay = "2023-11-14"
        next.effortDay = "2023-11-14"   // resolved no effort

        WidgetSnapshot.mergeStripFallback(stored: stored, into: &next, now: evening, calendar: utc)

        XCTAssertEqual(next.stepsToday, 9_600)
        XCTAssertEqual(next.effortToday, 52)
    }

    func testFallbackDoesNotCarryAnotherDaysFigures() {
        var stored = renderedSnapshot()
        stored.stepsToday = 12_000
        stored.stepsDay = "2023-11-13"
        stored.stripTodayAt = evening.addingTimeInterval(-60)
        var next = renderedSnapshot()
        next.stepsDay = "2023-11-14"

        WidgetSnapshot.mergeStripFallback(stored: stored, into: &next, now: evening, calendar: utc)

        XCTAssertNil(next.stepsToday)
        XCTAssertEqual(next.stepsDay, "2023-11-14")
    }

    func testFallbackKeepsTheNewerLiveStressRead() {
        var stored = renderedSnapshot()
        stored.stressNow = 1.8
        stored.stressNowAt = evening.addingTimeInterval(-2 * 60)
        var next = renderedSnapshot()
        next.stressNow = 0.9
        next.stressNowAt = evening.addingTimeInterval(-10 * 60)

        WidgetSnapshot.mergeStripFallback(stored: stored, into: &next, now: evening, calendar: utc)
        XCTAssertEqual(next.stressNow, 1.8)

        // An expired stored read does not replace an absent one.
        var expired = renderedSnapshot()
        expired.stressNow = 2.5
        expired.stressNowAt = evening.addingTimeInterval(-2 * 3_600)
        var blank = renderedSnapshot()
        WidgetSnapshot.mergeStripFallback(stored: expired, into: &blank, now: evening, calendar: utc)
        XCTAssertNil(blank.stressNow)
    }
}
