import XCTest
@testable import Strand

/// Pins the PURE half of the Sleep tab's wake buzz (`WakeBuzzAlarm`): the quarter-hour grid, the next
/// fire instant, and the ring policy the ringer obeys for auto-stop and for the strap's double-tap.
///
/// The ringer itself (timers, BLE, notifications) is deliberately not exercised here — everything that
/// can be decided without a strap, a run loop or a view lives in these functions, which is the point of
/// splitting them out.
final class WakeBuzzAlarmTests: XCTestCase {

    // Every date test pins an explicit timezone. `.current` on a CI runner is whatever the machine says,
    // and the DST cases below only mean anything in a zone that actually observes it.
    private func berlin() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Local wall-clock "HH:mm" of a date in `cal`'s zone.
    private func wallClock(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? -1, c.minute ?? -1)
    }

    // MARK: - The quarter-hour grid

    func testOptions_areTheNinetySixQuarterHourSlots() {
        let options = WakeBuzzAlarm.options
        XCTAssertEqual(options.count, 96)
        XCTAssertEqual(options.first, 0)            // 00:00
        XCTAssertEqual(options.last, 23 * 60 + 45)  // 23:45
        XCTAssertTrue(options.allSatisfy { $0 % WakeBuzzAlarm.stepMinutes == 0 })
    }

    func testSnapped_roundsToTheNearestSlot() {
        XCTAssertEqual(WakeBuzzAlarm.snapped(0), 0)
        XCTAssertEqual(WakeBuzzAlarm.snapped(7), 0)     // 7 min past is nearer 00:00 than 00:15
        XCTAssertEqual(WakeBuzzAlarm.snapped(8), 15)    // 8 min past tips to 00:15
        XCTAssertEqual(WakeBuzzAlarm.snapped(7 * 60 + 17), 7 * 60 + 15)
        XCTAssertEqual(WakeBuzzAlarm.snapped(7 * 60 + 23), 7 * 60 + 30)
    }

    /// The top of the day must NOT wrap: 23:58 rounds up past 23:45, and wrapping it to 00:00 would
    /// move the alarm by nearly a whole day instead of a couple of minutes.
    func testSnapped_clampsIntoTheDayWithoutWrapping() {
        XCTAssertEqual(WakeBuzzAlarm.snapped(23 * 60 + 58), 23 * 60 + 45)
        XCTAssertEqual(WakeBuzzAlarm.snapped(24 * 60), 23 * 60 + 45)
        XCTAssertEqual(WakeBuzzAlarm.snapped(99_999), 23 * 60 + 45)
        XCTAssertEqual(WakeBuzzAlarm.snapped(-1), 0)
        XCTAssertEqual(WakeBuzzAlarm.snapped(Int.min), 0)
    }

    func testTimeLabel_isZeroPadded24Hour() {
        XCTAssertEqual(WakeBuzzAlarm.timeLabel(0), "00:00")
        XCTAssertEqual(WakeBuzzAlarm.timeLabel(7 * 60 + 45), "07:45")
        XCTAssertEqual(WakeBuzzAlarm.timeLabel(23 * 60 + 45), "23:45")
    }

    // MARK: - Next fire

    func testNextFire_laterToday_isToday() {
        let cal = berlin()
        let now = at(2026, 5, 10, 6, 0, cal)
        let fire = WakeBuzzAlarm.nextFireDate(minutes: 7 * 60, from: now, calendar: cal)
        XCTAssertEqual(fire, at(2026, 5, 10, 7, 0, cal))
    }

    func testNextFire_alreadyPassedToday_rollsToTomorrow() {
        let cal = berlin()
        let now = at(2026, 5, 10, 8, 0, cal)
        let fire = WakeBuzzAlarm.nextFireDate(minutes: 7 * 60, from: now, calendar: cal)
        XCTAssertEqual(fire, at(2026, 5, 11, 7, 0, cal))
    }

    /// The instant is strictly future, so a `now` that lands exactly on the wake minute resolves to
    /// tomorrow rather than ringing twice for the same minute.
    func testNextFire_exactlyOnTheMinute_isTomorrow() {
        let cal = berlin()
        let now = at(2026, 5, 10, 7, 0, cal)
        XCTAssertEqual(WakeBuzzAlarm.nextFireDate(minutes: 7 * 60, from: now, calendar: cal),
                       at(2026, 5, 11, 7, 0, cal))
    }

    /// Across midnight: 23:50 with a 00:00 alarm is the NEXT calendar day's midnight, not a time in the
    /// past ten minutes ago.
    func testNextFire_acrossMidnight() {
        let cal = berlin()
        let now = at(2026, 5, 10, 23, 50, cal)
        let fire = WakeBuzzAlarm.nextFireDate(minutes: 0, from: now, calendar: cal)
        XCTAssertEqual(fire, at(2026, 5, 11, 0, 0, cal))
        XCTAssertEqual(fire.map { $0.timeIntervalSince(now) }, 10 * 60)
    }

    /// An off-grid stored minute still resolves onto the grid — the picker can only show slots, so the
    /// schedule must agree with what it shows.
    func testNextFire_snapsAnOffGridMinute() {
        let cal = berlin()
        let now = at(2026, 5, 10, 6, 0, cal)
        XCTAssertEqual(WakeBuzzAlarm.nextFireDate(minutes: 7 * 60 + 17, from: now, calendar: cal),
                       at(2026, 5, 10, 7, 15, cal))
    }

    // MARK: - DST

    /// Spring forward (Europe/Berlin, 2026-03-29, 02:00 → 03:00): the day is 23 hours long, so the same
    /// wall-clock time tomorrow is 23 hours away. A `now + 86400` implementation would land an hour late,
    /// at 11:00, which is exactly the failure this pins.
    func testNextFire_springForward_keepsTheWallClockTime() {
        let cal = berlin()
        let now = at(2026, 3, 28, 12, 0, cal)
        let fire = WakeBuzzAlarm.nextFireDate(minutes: 12 * 60, from: now, calendar: cal)
        XCTAssertEqual(fire.map { wallClock($0, cal) }, "12:00")
        XCTAssertEqual(fire.map { $0.timeIntervalSince(now) }, 23 * 3600)
    }

    /// Fall back (Europe/Berlin, 2026-10-25, 03:00 → 02:00): a 25-hour day. Same assertion, other sign —
    /// `now + 86400` would ring an hour early, at 11:00.
    func testNextFire_fallBack_keepsTheWallClockTime() {
        let cal = berlin()
        let now = at(2026, 10, 24, 12, 0, cal)
        let fire = WakeBuzzAlarm.nextFireDate(minutes: 12 * 60, from: now, calendar: cal)
        XCTAssertEqual(fire.map { wallClock($0, cal) }, "12:00")
        XCTAssertEqual(fire.map { $0.timeIntervalSince(now) }, 25 * 3600)
    }

    /// 02:30 does not exist on the spring-forward morning — the clocks jump 02:00 → 03:00. The alarm
    /// must still resolve to a REAL instant rather than returning nil, which is an alarm that never goes
    /// off. The bound is deliberately loose (a day) rather than pinning a specific minute: Foundation
    /// moves a skipped wall time forward to the next one that exists, and exactly where it lands inside
    /// that morning is its business, not a contract this feature should freeze.
    func testNextFire_springForwardIntoASkippedHour_stillResolves() {
        let cal = berlin()
        let now = at(2026, 3, 29, 1, 0, cal)
        guard let fire = WakeBuzzAlarm.nextFireDate(minutes: 2 * 60 + 30, from: now, calendar: cal) else {
            return XCTFail("a skipped wall-clock time must still resolve to an instant")
        }
        XCTAssertGreaterThan(fire, now)
        XCTAssertLessThan(fire.timeIntervalSince(now), 26 * 3600)
    }

    // MARK: - Ring policy: auto-stop

    func testAutoStop_onlyOnceTheWindowHasElapsed() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(WakeBuzzAlarm.shouldAutoStop(startedAt: start, now: start))
        XCTAssertFalse(WakeBuzzAlarm.shouldAutoStop(startedAt: start,
                                                    now: start.addingTimeInterval(WakeBuzzAlarm.autoStopSeconds - 0.5)))
        // The boundary counts as elapsed, so a ring can never outlive the window it advertises.
        XCTAssertTrue(WakeBuzzAlarm.shouldAutoStop(startedAt: start,
                                                   now: start.addingTimeInterval(WakeBuzzAlarm.autoStopSeconds)))
        XCTAssertTrue(WakeBuzzAlarm.shouldAutoStop(startedAt: start, now: start.addingTimeInterval(600)))
    }

    func testAutoStopWindow_isAboutHalfAMinute() {
        XCTAssertEqual(WakeBuzzAlarm.autoStopSeconds, 30)
        // Several volleys inside the window, but not a continuous write storm.
        XCTAssertGreaterThan(WakeBuzzAlarm.buzzIntervalSeconds, 1)
        XCTAssertLessThan(WakeBuzzAlarm.buzzIntervalSeconds, WakeBuzzAlarm.autoStopSeconds / 4)
    }

    // MARK: - Ring policy: the strap's double-tap

    /// A sample series of DOUBLE_TAP arrivals against one ring that started at t=0: only the taps that
    /// land inside the ring window belong to the alarm. The earlier one is somebody else's gesture (it
    /// must still run the user's configured double-tap action), and the later ones arrive after the ring
    /// has already stopped itself.
    func testDoubleTapSeries_onlyTapsInsideTheRingWindowStopIt() {
        let ringStart = Date(timeIntervalSince1970: 1_800_000_000)
        let taps: [(offset: TimeInterval, stops: Bool)] = [
            (-5.0, false),   // before the alarm even started
            (-0.001, false), // a hair before
            (0.0, true),     // the instant it started
            (1.4, true),
            (29.9, true),    // last moment inside the window
            (30.0, false),   // the window has elapsed — nothing is ringing any more
            (45.0, false),
        ]
        for tap in taps {
            XCTAssertEqual(
                WakeBuzzAlarm.tapStopsRing(tapAt: ringStart.addingTimeInterval(tap.offset),
                                           ringStartedAt: ringStart),
                tap.stops,
                "tap at \(tap.offset)s relative to the ring"
            )
        }
    }

    // MARK: - Catch-up window

    /// The catch-up grace is one ring window: a fire instant missed by less than a ring still rings,
    /// anything older is dropped rather than buzzing a wrist long after the wake time.
    func testMissedGrace_isOneRingWindow() {
        XCTAssertEqual(WakeBuzzAlarm.missedGraceSeconds, WakeBuzzAlarm.autoStopSeconds)
    }

    // MARK: - Defaults round-trip

    func testSettings_defaultOffAtSevenAndSnapOnWrite() {
        let d = UserDefaults(suiteName: "WakeBuzzAlarmTests.\(UUID().uuidString)")!
        XCTAssertFalse(WakeBuzzAlarm.isEnabled(d))                  // nothing may buzz a wrist by default
        XCTAssertEqual(WakeBuzzAlarm.minutes(d), 7 * 60)

        WakeBuzzAlarm.setEnabled(true, d)
        WakeBuzzAlarm.setMinutes(6 * 60 + 23, d)
        XCTAssertTrue(WakeBuzzAlarm.isEnabled(d))
        XCTAssertEqual(WakeBuzzAlarm.minutes(d), 6 * 60 + 30)       // snapped on the way in

        // A value an older build wrote off-grid still reads back on the grid.
        d.set(6 * 60 + 7, forKey: WakeBuzzAlarm.Key.minutes)
        XCTAssertEqual(WakeBuzzAlarm.minutes(d), 6 * 60)
    }
}
