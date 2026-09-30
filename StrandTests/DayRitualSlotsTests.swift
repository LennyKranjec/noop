import XCTest
@testable import Strand

/// HEALTH_V2 H4: one switch per ritual slot, the morning at the sleep anchor + 15. Pinned:
///
///   * DEFAULTS: morning on, midday and evening off.
///   * A LEGACY OFF STAYS OFF: `rituals.enabled == false` migrates to every slot off; a legacy on leaves the
///     per-slot defaults. The legacy key is removed so the migration runs once.
///   * ONLY ENABLED SLOTS ARE DUE, the morning at its anchored minute when there is one.
@MainActor
final class DayRitualSlotsTests: XCTestCase {

    private func suite() -> UserDefaults {
        let name = "DayRitualSlotsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTheMorningIsOnByDefaultAndTheOthersAreOff() {
        let d = suite()
        XCTAssertTrue(DayRitualScheduler.isEnabled(slot: .morning, d))
        XCTAssertFalse(DayRitualScheduler.isEnabled(slot: .midday, d))
        XCTAssertFalse(DayRitualScheduler.isEnabled(slot: .evening, d))
    }

    func testALegacyOffTurnsEverySlotOffOnce() {
        let d = suite()
        d.set(false, forKey: DayRitualScheduler.legacyEnabledKey)
        XCTAssertFalse(DayRitualScheduler.isEnabled(slot: .morning, d))
        XCTAssertFalse(DayRitualScheduler.isEnabled(slot: .midday, d))
        XCTAssertNil(d.object(forKey: DayRitualScheduler.legacyEnabledKey), "migrated once, then removed")
        // An explicit choice after the migration is kept.
        d.set(true, forKey: DayRitualScheduler.enabledKey(.evening))
        XCTAssertTrue(DayRitualScheduler.isEnabled(slot: .evening, d))
    }

    func testALegacyOnLeavesThePerSlotDefaults() {
        let d = suite()
        d.set(true, forKey: DayRitualScheduler.legacyEnabledKey)
        XCTAssertTrue(DayRitualScheduler.isEnabled(slot: .morning, d))
        XCTAssertFalse(DayRitualScheduler.isEnabled(slot: .evening, d))
        XCTAssertNil(d.object(forKey: DayRitualScheduler.legacyEnabledKey))
    }

    func testTheMorningRunsAtTheAnchorWhenThereIsOne() {
        XCTAssertEqual(DayRitualScheduler.minute(.morning, morningAnchorMinute: 7 * 60 + 15), 7 * 60 + 15)
        XCTAssertEqual(DayRitualScheduler.minute(.morning, morningAnchorMinute: nil), DayRitual.morning.minutes)
        XCTAssertEqual(DayRitualScheduler.minute(.evening, morningAnchorMinute: 5 * 60), DayRitual.evening.minutes)
    }

    func testOnlyEnabledSlotsAreDueAndTheMorningAtItsAnchor() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let at = { (h: Int, m: Int) -> Date in
            cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: h, minute: m))!
        }
        // 07:00 with the anchor putting the morning at 07:30: not due yet.
        XCTAssertEqual(DayRitualScheduler.due(now: at(7, 0), calendar: cal, morningAnchorMinute: 7 * 60 + 30,
                                              enabled: { _ in true }, lastRun: { _ in nil }), [])
        // 20:00, everything on and nothing run: all three, in time order.
        XCTAssertEqual(DayRitualScheduler.due(now: at(20, 0), calendar: cal, morningAnchorMinute: nil,
                                              enabled: { _ in true }, lastRun: { _ in nil }),
                       [.morning, .midday, .evening])
        // 20:00 with the defaults: only the morning.
        XCTAssertEqual(DayRitualScheduler.due(now: at(20, 0), calendar: cal, morningAnchorMinute: nil,
                                              enabled: { DayRitualScheduler.defaultEnabled($0) },
                                              lastRun: { _ in nil }),
                       [.morning])
    }

    func testTheMorningHasOneRequestPerWeekdayPlusTheLegacyOne() {
        let ids = DayRitualScheduler.requestIds(.morning)
        XCTAssertEqual(ids.count, 8)
        XCTAssertTrue(ids.contains("ritual-morning"))
        XCTAssertTrue(ids.contains("ritual-morning-7"))
        XCTAssertEqual(DayRitualScheduler.requestIds(.midday), ["ritual-midday"])
    }

    func testNextDateLandsOnTheAskedWeekday() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!  // a Wednesday
        for weekday in 1...7 {
            let d = DayRitualScheduler.nextDate(weekday: weekday, from: now, calendar: cal)
            XCTAssertEqual(cal.component(.weekday, from: d), weekday)
            XCTAssertLessThan(d.timeIntervalSince(now), 7 * 86_400)
            XCTAssertGreaterThanOrEqual(d.timeIntervalSince(now), 0)
        }
    }
}
