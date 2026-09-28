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

    // MARK: - "Is water tracking on" — ON vs OFF vs NOT KNOWN YET
    //
    // The bug these pin: the water widget rendered `snapshot?.waterEnabled ?? false`, so a fresh install
    // — where the app had never written anything into the App Group — was drawn as the wearer having
    // TURNED THE SETTING OFF, and the tile told them to go and enable something already enabled. An
    // absent answer is now its own state.

    func testWaterTrackingIsUnknownWhenNothingHasEverBeenPublished() {
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: nil, mirror: nil), .unknown)
    }

    func testWaterTrackingIsUnknownWhenASnapshotExistsButPredatesTheWaterFields() {
        // A snapshot written by a build older than the water widget: present, readable, silent on water.
        let old = renderedSnapshot()
        XCTAssertNil(old.waterEnabled)
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: old, mirror: nil), .unknown)
    }

    func testWaterTrackingIsOffOnlyWhenSomethingActuallySaysOff() {
        var snap = renderedSnapshot()
        snap.waterEnabled = false
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: snap, mirror: nil), .off)
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: nil, mirror: false), .off)
    }

    func testWaterTrackingReadsTheMirrorWithoutAnySnapshot() {
        // The reinstall case: the app has mirrored the setting at launch but has not managed a full
        // publish yet. The tile must already know the setting is on rather than tell the wearer to
        // enable it.
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: nil, mirror: true), .on)
    }

    func testTheMirrorWinsOverAStaleSnapshotCopy() {
        // The mirror is rewritten on every launch and on every flip of the toggle; the snapshot's copy
        // is only refreshed by a publish. Where they disagree the mirror is the newer fact.
        var snap = renderedSnapshot()
        snap.waterEnabled = false
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: snap, mirror: true), .on)

        snap.waterEnabled = true
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: snap, mirror: false), .off)
    }

    func testAnAbsentMirrorIsNotAStoredFalse() {
        // `bool(forKey:)` would collapse these two; the mirror read must not.
        let defaults = UserDefaults(suiteName: "noop.tests.waterMirror") ?? .standard
        defaults.removeObject(forKey: WidgetSnapshot.waterEnabledKey)
        XCTAssertNil(WidgetSnapshot.waterEnabledMirror(defaults: defaults))

        defaults.set(false, forKey: WidgetSnapshot.waterEnabledKey)
        XCTAssertEqual(WidgetSnapshot.waterEnabledMirror(defaults: defaults), false)

        defaults.set(true, forKey: WidgetSnapshot.waterEnabledKey)
        XCTAssertEqual(WidgetSnapshot.waterEnabledMirror(defaults: defaults), true)

        defaults.removeObject(forKey: WidgetSnapshot.waterEnabledKey)
    }

    func testAnUnreachableSuiteReadsAsUnknownRatherThanOff() {
        // A missing App Group entitlement makes `UserDefaults(suiteName:)` nil. That must surface as "we
        // cannot tell", never as a confident "the wearer turned it off".
        XCTAssertNil(WidgetSnapshot.waterEnabledMirror(defaults: nil))
        XCTAssertEqual(WidgetSnapshot.waterTracking(snapshot: nil, mirror: nil), .unknown)
    }

    // MARK: - Water-field change detection

    func testRenderedContentDetectsEachWaterField() {
        var base = renderedSnapshot()
        base.waterEnabled = true
        base.waterDay = "2023-11-14"
        base.waterMl = 500
        base.waterGoalMl = 2800

        var enabledOff = base
        enabledOff.waterEnabled = false
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: enabledOff))

        // nil is a DIFFERENT value from false here — a snapshot that stops carrying the flag must still
        // be published, or the widget keeps rendering a figure for a setting it no longer knows about.
        var enabledUnknown = base
        enabledUnknown.waterEnabled = nil
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: enabledUnknown))

        var rolled = base
        rolled.waterDay = "2023-11-15"
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: rolled))

        var drank = base
        drank.waterMl = 750
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: drank))

        var harderDay = base
        harderDay.waterGoalMl = 3100
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: base, to: harderDay))

        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: base, to: base))
    }

    func testTheFirstWaterPublishIsNeverDedupedAway() {
        // The fresh-install write must always land, whatever it says.
        var first = renderedSnapshot()
        first.waterEnabled = false
        first.waterMl = 0
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: first))
    }

    // MARK: - Decoding a snapshot written by another build

    func testASnapshotMissingTheWaterFieldsStillDecodes() throws {
        // The app-update case: the stored blob predates every water key. Codable fills an absent
        // optional with nil, so the snapshot survives and the water state resolves to `unknown` (above)
        // rather than the whole snapshot being lost and read as "off".
        let json = #"{"bonded":true,"updated":721000000,"recovery":66}"#
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.recovery, 66)
        XCTAssertNil(snap.waterEnabled)
        XCTAssertNil(snap.waterMl)
    }

    func testAnUndecodableSeriesDoesNotTakeTheWholeSnapshotDownWithIt() throws {
        // `hrSeries` / `stressSeries` carry their own point types. A field added to one of those without
        // an optional (or any other shape change) makes the STRICT decode of the whole snapshot fail —
        // and `load()` returning nil is exactly what the water tile used to read as "the setting is
        // off". The fallback keeps every scalar and drops only the trace the widget can redraw.
        let json = """
        {"bonded":true,"updated":721000000,"recovery":66,\
        "waterEnabled":true,"waterDay":"2023-11-14","waterMl":900,"waterGoalMl":2800,\
        "hrSeries":[{"ts":1,"bpm":60,"newRequiredField":7}],\
        "stressSeries":"not an array at all"}
        """
        XCTAssertNil(try? JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8)),
                     "the strict decode is expected to fail here — that is the situation being covered")

        let salvaged = try XCTUnwrap(WidgetSnapshot.decodeWithoutSeries(Data(json.utf8)))
        XCTAssertEqual(salvaged.waterEnabled, true)
        XCTAssertEqual(salvaged.waterMl, 900)
        XCTAssertEqual(salvaged.waterGoalMl, 2800)
        XCTAssertEqual(salvaged.recovery, 66)
        XCTAssertNil(salvaged.hrSeries)
        XCTAssertNil(salvaged.stressSeries)
    }

    func testSalvagingGivesUpHonestlyOnRubbish() {
        XCTAssertNil(WidgetSnapshot.decodeWithoutSeries(Data("not json".utf8)))
        // Valid JSON, but nothing a snapshot can be built from (no `bonded`, no `updated`).
        XCTAssertNil(WidgetSnapshot.decodeWithoutSeries(Data(#"{"recovery":66}"#.utf8)))
    }

    func testAStrictlyDecodableSnapshotRoundTripsWithItsSeriesIntact() throws {
        var snap = renderedSnapshot()
        snap.waterEnabled = true
        snap.waterMl = 400
        snap.hrSeries = [HrPoint(ts: 1, bpm: 60)]
        snap.stressSeries = [StressPoint(ts: 2, level: 1.5, moving: true)]
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snap)
        // The salvage path is lossy by design, so it must only ever be the fallback.
        XCTAssertNil(WidgetSnapshot.decodeWithoutSeries(data)?.hrSeries)
    }
}
