import XCTest
import StrandDesign
import StrandAnalytics
@testable import Strand

/// Pins the dynamic Today order (DESIGN_V2 decision 15) and the pure half of the Telos hero.
final class TodayDynamicOrderTests: XCTestCase {

    private let base = TodaySection.defaultOrder

    private func ctx(_ h: Int, _ m: Int = 0, windDown: Int? = nil, flowDone: Bool = true,
                     workout: Bool = false, penalty: Bool = false, trial: Bool = false,
                     today: Bool = true) -> TodayDynamicContext {
        TodayDynamicContext(minuteOfDay: h * 60 + m, windDownStartMinute: windDown, morningFlowDone: flowDone,
                            workoutActive: workout, penaltyOpen: penalty, trialAnswerPending: trial,
                            isToday: today)
    }

    private func sections(_ blocks: [TodayBlock]) -> [TodaySection] {
        blocks.compactMap { if case .section(let s) = $0 { return s } else { return nil } }
    }

    // MARK: Phases

    func testPhaseBoundaries() {
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(9, 0, flowDone: true)), .morning)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(11, 59)), .morning)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(12, 0)), .day)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(17, 59)), .day)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(18, 0)), .night)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(23, 30)), .night)
    }

    func testNightLastsUntilTheMorningFlowOrTenAtTheLatest() {
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(2, 0, flowDone: false)), .night)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(9, 30, flowDone: false)), .night)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(9, 30, flowDone: true)), .morning)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(10, 0, flowDone: false)), .morning)
    }

    func testAnEarlierWindDownStartsTheEveningEarly() {
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(17, 40, windDown: 17 * 60 + 30)), .night)
        XCTAssertEqual(TodayDynamicOrder.phase(ctx(17, 20, windDown: 17 * 60 + 30)), .day)
        // A wind-down after midnight (late sleeper) never starts the evening early…
        XCTAssertEqual(TodayDynamicOrder.eveningStart(windDownStartMinute: 30), 18 * 60)
        // …and a later one never delays it.
        XCTAssertEqual(TodayDynamicOrder.eveningStart(windDownStartMinute: 21 * 60), 18 * 60)
    }

    // MARK: Promotions

    func testEveningPutsTheSleepPanelDirectlyUnderTheHeroRun() {
        let blocks = TodayDynamicOrder.blocks(base: base, context: ctx(19))
        XCTAssertEqual(Array(blocks.prefix(4)),
                       [.section(.quests), .section(.hero), .section(.dailyMission), .eveningSleep])
        XCTAssertEqual(sections(blocks), base, "the evening lifts nothing out of the wearer's order")
    }

    func testDayLiftsTheStateTileUnderTheHeroRun() {
        let blocks = TodayDynamicOrder.blocks(base: base, context: ctx(14))
        XCTAssertEqual(blocks[3], .section(.synthesis))
        XCTAssertFalse(blocks.contains(.eveningSleep))
        XCTAssertEqual(blocks.filter { $0 == .section(.synthesis) }.count, 1)
    }

    func testMorningLiftsQuestsTheWearerMovedDown() {
        let custom: [TodaySection] = [.hero, .synthesis, .keyMetrics, .quests, .journal]
        let blocks = TodayDynamicOrder.blocks(base: custom, context: ctx(8, flowDone: true))
        XCTAssertEqual(sections(blocks), [.hero, .quests, .synthesis, .keyMetrics, .journal])
    }

    func testAnOpenPenaltyLiftsTheQuestsAtAnyTime() {
        let custom: [TodaySection] = [.hero, .keyMetrics, .quests]
        let blocks = TodayDynamicOrder.blocks(base: custom, context: ctx(20, penalty: true))
        XCTAssertEqual(blocks, [.section(.hero), .eveningSleep, .section(.quests), .section(.keyMetrics)])
    }

    func testALiveWorkoutIsFirstOfAll() {
        let blocks = TodayDynamicOrder.blocks(base: base, context: ctx(19, workout: true))
        XCTAssertEqual(blocks.first, .liveWorkout)
        XCTAssertEqual(blocks[4], .eveningSleep)
    }

    func testAPendingTrialSitsDirectlyUnderTheQuestChips() {
        let blocks = TodayDynamicOrder.blocks(base: base, context: ctx(14, trial: true))
        let q = blocks.firstIndex(of: .section(.quests))!
        XCTAssertEqual(blocks[q + 1], .trialAnswer)
    }

    func testAPendingTrialWithTheQuestsHiddenJoinsThePromotedBlocks() {
        let custom: [TodaySection] = [.hero, .dailyMission, .keyMetrics]
        let blocks = TodayDynamicOrder.blocks(base: custom, context: ctx(19, trial: true))
        XCTAssertEqual(blocks, [.section(.hero), .section(.dailyMission), .eveningSleep, .trialAnswer,
                                .section(.keyMetrics)])
    }

    func testAPastDayGetsNoPromotions() {
        let blocks = TodayDynamicOrder.blocks(base: base, context: ctx(19, penalty: true, trial: true, today: false))
        XCTAssertEqual(blocks, base.map(TodayBlock.section))
        let withWorkout = TodayDynamicOrder.blocks(base: base, context: ctx(19, workout: true, today: false))
        XCTAssertEqual(withWorkout.first, .liveWorkout)
    }

    // MARK: Invariants

    /// Nothing hidden is shown, nothing visible is lost, nothing appears twice — at every minute.
    func testEveryVisibleSectionAppearsExactlyOnceAndNothingHiddenAppears() {
        let hidden: Set<TodaySection> = [.synthesis, .streaks]
        let visible = base.filter { !hidden.contains($0) }
        for minute in stride(from: 0, to: 24 * 60, by: 20) {
            for flags in 0..<16 {
                let c = TodayDynamicContext(minuteOfDay: minute, windDownStartMinute: 17 * 60,
                                            morningFlowDone: flags & 1 != 0, workoutActive: flags & 2 != 0,
                                            penaltyOpen: flags & 4 != 0, trialAnswerPending: flags & 8 != 0)
                let blocks = TodayDynamicOrder.blocks(base: visible, context: c)
                let secs = sections(blocks)
                XCTAssertEqual(Set(secs), Set(visible))
                XCTAssertEqual(secs.count, visible.count)
                XCTAssertTrue(hidden.isDisjoint(with: secs))
                XCTAssertEqual(Set(blocks).count, blocks.count)
            }
        }
    }

    func testAMalformedBaseNeverRendersASectionTwice() {
        let blocks = TodayDynamicOrder.blocks(base: [.hero, .hero, .journal], context: ctx(14))
        XCTAssertEqual(blocks, [.section(.hero), .section(.journal)])
    }
}

final class HomeHeroMappingTests: XCTestCase {

    func testTierBandsAreUnboundedAndAbstainWithoutALevel() {
        XCTAssertNil(HomeHeroMapping.tier(level: nil))
        XCTAssertNil(HomeHeroMapping.tier(level: .nan))
        XCTAssertEqual(HomeHeroMapping.tier(level: 20), .low)
        XCTAssertEqual(HomeHeroMapping.tier(level: 50), .baseline)
        XCTAssertEqual(HomeHeroMapping.tier(level: 60), .strong)
        XCTAssertEqual(HomeHeroMapping.tier(level: 81), .nearPeak)
        XCTAssertEqual(HomeHeroMapping.tier(level: 100), .peak)
        XCTAssertEqual(HomeHeroMapping.tier(level: 120), .beyondPeak)
        XCTAssertEqual(HomeHeroMapping.tier(level: 400), .beyondPeak)
    }

    func testDeltaAbstainsAndFlatIsDistinct() {
        XCTAssertNil(HomeHeroMapping.levelDelta(now: 80, yesterday: nil))
        XCTAssertNil(HomeHeroMapping.levelDelta(now: nil, yesterday: 80))
        XCTAssertEqual(HomeHeroMapping.levelDelta(now: 81, yesterday: 57), 24)
        XCTAssertEqual(HomeHeroMapping.deltaText(24), "+24 pts")
        XCTAssertEqual(HomeHeroMapping.deltaText(-3.2), "\u{2212}3 pts")
        XCTAssertEqual(HomeHeroMapping.deltaText(0.3), "±0 pts")
    }

    private func quest(_ state: QuestState, day: String = "2026-09-30") -> Quest {
        Quest(kind: .side, title: "t", taunt: "", target: "x", rewards: [], xp: 10,
              state: state, dayKey: day, createdAtMs: 0)
    }

    func testQuestProgressCountsOnlyAcceptedQuestsOfTheDay() {
        XCTAssertNil(HomeHeroMapping.questProgress([], dayKey: "2026-09-30"))
        XCTAssertNil(HomeHeroMapping.questProgress([quest(.offered), quest(.declined)], dayKey: "2026-09-30"))
        let p = HomeHeroMapping.questProgress(
            [quest(.completed), quest(.active), quest(.offered), quest(.completed, day: "2026-09-29")],
            dayKey: "2026-09-30")
        XCTAssertEqual(p, HomeHeroMapping.QuestProgress(done: 1, total: 2))
        XCTAssertEqual(p?.percent, 50)
    }

    func testPartSharesSkipUnscoredParts() {
        let shares = HomeHeroMapping.partShares([
            LevelComponent(part: .sleep, score: 80, effectiveWeight: 0.5),
            LevelComponent(part: .heart, score: nil, effectiveWeight: 0),
            LevelComponent(part: .muscle, score: 60, effectiveWeight: 0.5),
        ])
        XCTAssertEqual(shares, [.sleep: 40, .muscle: 30])
    }

    func testLevelConfidence() {
        XCTAssertEqual(HomeHeroMapping.levelConfidence(pendingToday: false, coverage: 1), .solid)
        XCTAssertEqual(HomeHeroMapping.levelConfidence(pendingToday: true, coverage: 1), .building)
        XCTAssertEqual(HomeHeroMapping.levelConfidence(pendingToday: false, coverage: 0.7), .building)
    }

    func testEffortRatioIsUnboundedAndAbstains() {
        XCTAssertNil(HomeHeroMapping.effortRatio(effort: 50, target: nil))
        XCTAssertNil(HomeHeroMapping.effortRatio(effort: nil, target: 70))
        XCTAssertNil(HomeHeroMapping.effortRatio(effort: 50, target: 0))
        XCTAssertEqual(HomeHeroMapping.effortRatio(effort: 140, target: 70), 2)
    }

    func testMissionSplitsIntoTitleAndSubtitle() {
        let p = HomeHeroMapping.missionParts("Land well. Build higher. Focus on zone 2.")
        XCTAssertEqual(p.title, "Land well.")
        XCTAssertEqual(p.subtitle, "Build higher. Focus on zone 2.")
        XCTAssertNil(HomeHeroMapping.missionParts("Walk 8,000 steps before dinner").subtitle)
    }
}
