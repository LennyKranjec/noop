import XCTest
@testable import Strand

/// Twin of the Android `TodayLayoutPrefsTest` (#today-layout): default order, encode/decode round-trip,
/// reorder, and the never-hide "insert missing section at its default position" invariant — pinned on both
/// platforms so the byte-identical "today.sectionOrder" wire format can't drift.
final class TodayLayoutPrefsTests: XCTestCase {

    func testEmptyOrUnsetYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(""), TodaySection.defaultOrder)
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("   "), TodaySection.defaultOrder)
    }

    /// EVERY section, deliberately. `decodeOrder` back-fills anything missing from a saved order, so a
    /// partial list does not round-trip and never could — this pins the encoding, not the back-fill.
    func testEncodeDecodeRoundTripsAReorderedList() {
        let reordered: [TodaySection] = [
            .heartRate, .hero, .quests, .streaks, .dailyMission, .yourCards, .liveSession, .synthesis,
            .keyMetrics, .workouts, .recoveryVitals, .stressEnergy, .hydrationNutrition,
            .journal, .menstrualCycle, .addedCards,
        ]
        let encoded = TodayLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "heartRate,hero,quests,streaks,dailyMission,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,stressEnergy,hydrationNutrition,journal,menstrualCycle,addedCards")
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// The v1 upgrade path: an order saved by the FIRST cut (6 sections — no hero/liveSession, which were
    /// pinned then) must surface the two new sections at the TOP (their default position), not teleport
    /// them to the bottom of the user's saved order.
    func testSavedOrderFromFirstCutInsertsHeroAndSessionAtTheirDefaultPosition() {
        let firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(firstCut),
            // The saved six are already in their default relative order, so every section added since
            // lands exactly where the default order puts it and the result IS the default order. That is
            // the invariant worth pinning: a saved layout that never disagreed with the default must not
            // start disagreeing with it just because the app grew sections.
            TodaySection.defaultOrder
        )
    }

    func testInsertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved() {
        // heartRate is saved ABOVE synthesis, which is not where the default order has it — so the saved
        // disagreement is kept and everything missing is threaded around it. workouts lands before
        // heartRate (it precedes it by default), and the pair it separated stays split.
        let partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(partial),
            [.quests, .hero, .dailyMission, .streaks, .liveSession, .workouts, .heartRate, .synthesis,
             .keyMetrics, .recoveryVitals, .stressEnergy, .hydrationNutrition, .yourCards,
             .menstrualCycle, .journal, .addedCards]
        )
    }

    func testDropsUnknownTokensAndCollapsesDuplicates() {
        let messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(messy),
            [.quests, .hero, .dailyMission, .streaks, .liveSession, .synthesis, .keyMetrics, .workouts,
             .recoveryVitals, .stressEnergy, .hydrationNutrition, .yourCards, .heartRate,
             .menstrualCycle, .journal, .addedCards]
        )
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("nope,,zzz"), TodaySection.defaultOrder)
    }

    func testHiddenSectionsAreExplicitReversibleAndDeduplicated() {
        let hidden = TodayLayoutPrefs.decodeHidden("workouts,BOGUS,workouts,journal")
        XCTAssertEqual(hidden, [.workouts, .journal])
        XCTAssertEqual(TodayLayoutPrefs.encodeHidden(hidden), "workouts,journal")
    }

    func testVisibleOrderFiltersHiddenWithoutChangingSavedOrder() {
        let order = "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal"
        XCTAssertEqual(
            TodayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "hero,workouts"),
            [.quests, .dailyMission, .streaks, .heartRate, .stressEnergy, .hydrationNutrition,
             .yourCards, .liveSession, .synthesis, .keyMetrics, .recoveryVitals,
             .menstrualCycle, .journal, .addedCards]
        )
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(order), [
            .quests, .dailyMission, .streaks, .heartRate, .hero, .stressEnergy, .hydrationNutrition,
            .yourCards, .liveSession, .synthesis, .keyMetrics, .workouts, .recoveryVitals,
            .menstrualCycle, .journal, .addedCards,
        ])
    }

    func testNewOrPreviouslyMissingSectionsDefaultToVisible() {
        XCTAssertTrue(
            TodayLayoutPrefs.visibleOrder(
                orderRaw: "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards",
                hiddenRaw: "workouts"
            ).contains(.journal)
        )
    }

    /// defaultOrder must cover EVERY case: the never-hide merge iterates it, so a case missing from the
    /// default order could otherwise be dropped from render (Android) or mis-sorted (iOS).
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(TodaySection.defaultOrder), Set(TodaySection.allCases))
        XCTAssertEqual(TodaySection.defaultOrder.count, TodaySection.allCases.count)
    }

    func testSectionRawKeysAreStableAndUnique() {
        let raws = TodaySection.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "raw keys must be unique (they're the persisted identity)")
        // Pin the exact wire strings — they must match the Android TodaySection byte-for-byte.
        XCTAssertEqual(
            raws,
            ["hero", "liveSession", "synthesis", "keyMetrics", "workouts", "heartRate", "recoveryVitals",
             "stressEnergy", "hydrationNutrition", "dailyMission", "quests", "streaks", "yourCards",
             "menstrualCycle", "journal", "addedCards"]
        )
    }

    func testEditableLayoutHidesAndRestoresWithoutDeleting() {
        var draft = EditableLayoutDraft(
            visible: TodaySection.defaultOrder,
            allItems: TodaySection.defaultOrder
        )

        draft.hide(.workouts)
        XCTAssertFalse(draft.visible.contains(.workouts))
        XCTAssertEqual(draft.hidden, [.workouts])

        draft.show(.workouts)
        XCTAssertEqual(draft.visible.last, .workouts)
        XCTAssertTrue(draft.hidden.isEmpty)
        XCTAssertEqual(Set(draft.visible), Set(TodaySection.defaultOrder))
    }

    func testEditableLayoutKeepsAtLeastOneItemVisible() {
        var draft = EditableLayoutDraft(visible: [KeyMetric.hrv], hidden: KeyMetric.defaultOrder.filter { $0 != .hrv })
        draft.hide(.hrv)
        XCTAssertEqual(draft.visible, [.hrv])
    }
}
