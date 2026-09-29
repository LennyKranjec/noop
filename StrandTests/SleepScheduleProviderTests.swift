import XCTest
import StrandAnalytics
@testable import Strand

/// HEALTH_V2 S2 §2.5 — with a plan present, the wind-down reminder, the room-climate window, the WiZ
/// automations, the caffeine cutoff and the bedtime quest all read the SAME bedtime; without one each
/// keeps its own setting.
@MainActor
final class SleepScheduleProviderTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func suite() -> UserDefaults {
        let name = "sleepanchor.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func nights(_ count: Int, wake: Int = 7 * 60) -> [SleepTimingNight] {
        LevelWiring.keysBack("2026-09-28", count, calendar).map {
            SleepTimingNight(wakeDay: $0, onsetMin: 23 * 60, wakeMin: wake, asleepMin: 450, efficiency: 0.9)
        }
    }

    /// A plan waking at 07:00 on a Wednesday with the adult need: lights out 22:45.
    private func plan() throws -> SleepSchedulePlan {
        try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(10)), wakeWeekday: 4).plan)
    }

    func testEveryConsumerReadsTheSameBedtime() throws {
        let p = try plan()
        XCTAssertEqual(p.bedtimeMin, 22 * 60 + 45)

        // Wind-down reminder: the plan's wind-down start, on the evening before the wake day.
        let nudge = try XCTUnwrap(WindDownNudge.planNudge(forWeekday: 4, plan: p))
        XCTAssertEqual(nudge.minute, SleepClock.wrap(p.bedtimeMin - SleepAnchor.windDownLeadMin))
        XCTAssertEqual(nudge.weekday, 3, "Wednesday's wake: the nudge fires on Tuesday evening")

        // Room climate: the plan's sleep window.
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15))!
        let room = RoomClimatePlan.schedule(now: afternoon, calendar: calendar, defaults: suite(),
                                            sleepPlan: { _ in p })
        XCTAssertEqual(room.source, .plan)
        XCTAssertEqual(room.bedtimeMinute, p.bedtimeMin)
        XCTAssertEqual(room.sleepStartMinute, p.windDownStartMin)
        XCTAssertEqual(room.wakeMinute, p.anchorMin)

        // WiZ: evening at lights-dim, wind-down at wind-down start, daylight at the anchor.
        let wiz = WizLightStore.automationTimes(follow: true, morningPlan: p, eveningPlan: p,
                                                wakeMinute: 6 * 60 + 30, windDownMinute: 21 * 60 + 30)
        XCTAssertTrue(wiz.fromPlan)
        XCTAssertEqual(wiz.windDown, p.windDownStartMin)
        XCTAssertEqual(wiz.evening, p.lightsDimMin)
        XCTAssertEqual(wiz.wake, p.anchorMin)

        // Caffeine: the plan's bedtime, into the unchanged decay model.
        XCTAssertEqual(CaffeineBedtime.bedtimeMinutes(plan: p, fallback: 23 * 60), p.bedtimeMin)
        XCTAssertEqual(CaffeineBedtime.cutoffMinutes(plan: p, fallback: 23 * 60),
                       CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes: p.bedtimeMin))

        // Bedtime quest: the plan's asleep-by (bedtime + onset buffer), whichever gear issues it.
        for gear in [QuestDifficulty.push, .relentless] {
            let t = QuestDayPlan.targets(baseline: QuestBaseline(bedtimeTargetMin: p.asleepByMin),
                                         difficulty: gear, day: "2026-09-29")
            XCTAssertEqual(t.first { $0.goal.metric == .bedtimeBy }?.goal.threshold,
                           Double(p.bedtimeMin + SleepAnchor.onsetBufferMin))
        }
    }

    func testWithoutAPlanEveryConsumerKeepsItsOwnSetting() {
        XCTAssertNil(WindDownNudge.planNudge(forWeekday: 4, plan: nil))
        let wiz = WizLightStore.automationTimes(follow: true, morningPlan: nil, eveningPlan: nil,
                                                wakeMinute: 6 * 60 + 30, windDownMinute: 21 * 60 + 30)
        XCTAssertEqual(wiz, WizLightStore.AutomationTimes(wake: 6 * 60 + 30, evening: nil,
                                                          windDown: 21 * 60 + 30, fromPlan: false))
        XCTAssertEqual(CaffeineBedtime.bedtimeMinutes(plan: nil, fallback: 23 * 60), 23 * 60)
        let room = RoomClimatePlan.schedule(now: Date(), calendar: calendar, defaults: suite(), sleepPlan: { _ in nil })
        XCTAssertTrue(room.source != .plan || WindDownNudge.isEnabled, "no anchor: the older fallbacks")
    }

    func testFollowingTheAnchorCanBeSwitchedOffAndTheFixedTimesReturn() throws {
        let p = try plan()
        let wiz = WizLightStore.automationTimes(follow: false, morningPlan: p, eveningPlan: p,
                                                wakeMinute: 6 * 60 + 30, windDownMinute: 21 * 60 + 30)
        XCTAssertEqual(wiz.wake, 6 * 60 + 30)
        XCTAssertEqual(wiz.windDown, 21 * 60 + 30)
        XCTAssertNil(wiz.evening)
    }

    func testTheProviderPlansEveryWeekdayAndAbstainsHonestly() {
        let provider = SleepScheduleProvider(defaults: suite())
        provider.apply(nights: nights(3), needHours: nil, debtMin: nil)
        XCTAssertTrue(provider.plans.isEmpty)
        XCTAssertEqual(provider.abstention, .calibrating(nights: 3, needed: 7))
        // A target wake is enough for a plan, with the population need labelled as such.
        provider.targetWakeMinutes = 6 * 60 + 30
        XCTAssertEqual(provider.plans.count, 7)
        XCTAssertNil(provider.abstention)
        XCTAssertEqual(provider.plans[4]?.anchorMin, 6 * 60 + 30)
        XCTAssertEqual(provider.plans[4]?.needIsPopulationDefault, true)
        // The weekend offset moves only Saturday and Sunday.
        provider.weekendOffsetMinutes = 30
        XCTAssertEqual(provider.plans[7]?.anchorMin, 7 * 60)
        XCTAssertEqual(provider.plans[4]?.anchorMin, 6 * 60 + 30)
        // H4: the morning ritual at anchor + 15 on that weekday.
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 5))!
        XCTAssertEqual(provider.morningRitualMinute(on: wednesday, calendar: calendar), 6 * 60 + 45)
        // Clearing the target returns to the honest abstention.
        provider.targetWakeMinutes = nil
        XCTAssertTrue(provider.plans.isEmpty)
    }

    func testTheComingNightTurnsAtNoon() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 21))!
        XCTAssertEqual(calendar.component(.day, from: SleepScheduleProvider.comingWakeDate(now: morning, calendar: calendar)), 29)
        XCTAssertEqual(calendar.component(.day, from: SleepScheduleProvider.comingWakeDate(now: evening, calendar: calendar)), 30)
    }
}
