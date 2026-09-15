import Foundation
import XCTest
@testable import StrandAnalytics

/// Byte-identity pin for the XP curve. The same totals MUST produce the same levels and bar fractions
/// as the Android twin `com.noop.gamify.AccountLevelTest`; the two platforms disagreeing about the
/// wearer's own level is the most visible parity break this app could ship.
///
/// WHY A LITERAL TABLE AND NOT A RECOMPUTED FORMULA. Asserting `xp(forLevel:) == Int(120 * pow(n-1,
/// 1.45))` would pass on any platform whose `pow` differs, which is exactly the drift the table exists
/// to catch. These values came out of an oracle run over the whole band.
///
/// ON `pow` ROUNDING: `pow` is not guaranteed correctly-rounded by every libm, so a table like this is
/// only safe if no value sits within a few ULPs of an integer — truncation would then land on
/// different sides. Measured across levels 1–40, the closest any raw value comes to an integer
/// boundary is 0.0287 (level 19), against a ULP of ~1.4e-14 at that magnitude. The one exact landing
/// is level 2, where `pow(1.0, 1.45)` is required by IEEE 754 to be exactly 1.0. There is no margin
/// problem here, but re-run the oracle before changing `base` or `exponent`.
final class AccountLevelTests: XCTestCase {

    /// Cumulative XP to REACH each level, levels 1…20. Oracle output, pasted verbatim.
    private let thresholds: [Int] = [
        0, 120, 327, 590, 895, 1237, 1612, 2016, 2447, 2902,
        3382, 3883, 4405, 4947, 5508, 6088, 6685, 7300, 7930, 8577,
    ]

    func testTheCurveMatchesTheOracle() {
        for (index, expected) in thresholds.enumerated() {
            XCTAssertEqual(AccountLevel.xp(forLevel: index + 1), expected, "level \(index + 1)")
        }
    }

    func testTheCurveTruncatesRatherThanRounds() {
        // Level 3's raw value is 327.8497. Rounding would give 328 and put every threshold above it on
        // a different integer than Kotlin's `.toInt()`, which truncates.
        XCTAssertEqual(AccountLevel.xp(forLevel: 3), 327)
        XCTAssertEqual(AccountLevel.xp(forLevel: 13), 4405)   // raw 4405.4883
    }

    func testLevelOneAndBelowCostNothing() {
        XCTAssertEqual(AccountLevel.xp(forLevel: 1), 0)
        XCTAssertEqual(AccountLevel.xp(forLevel: 0), 0)
        XCTAssertEqual(AccountLevel.xp(forLevel: -5), 0)
    }

    func testAFreshInstallReadsExactlyFifteen() {
        // The whole point of the provisional baseline: nothing has been measured, so the badge starts
        // at 15 and every point above it was earned. If this drifts, a fresh install shows 14 or 16 and
        // the "provisional" framing silently becomes a lie.
        XCTAssertEqual(AccountLevel.baselineXp(), 5751)
        XCTAssertEqual(AccountLevel.standing(earnedXp: 0).level, 15)
    }

    func testTheBoundaryIsInclusive() {
        // Reaching a threshold IS the level, not one short of it.
        XCTAssertEqual(AccountLevel.level(forXp: 119), 1)
        XCTAssertEqual(AccountLevel.level(forXp: 120), 2)
        XCTAssertEqual(AccountLevel.level(forXp: 121), 2)
    }

    func testStandingSplitsTheTotalAcrossTheCurrentLevel() {
        let s = AccountLevel.standing(forTotalXp: 5751)
        XCTAssertEqual(s.level, 15)
        XCTAssertEqual(s.xpIntoLevel, 243)      // 5751 - 5508
        XCTAssertEqual(s.xpSpanOfLevel, 580)    // 6088 - 5508
        XCTAssertEqual(s.xpToNextLevel, 337)
        XCTAssertEqual(s.progress, 243.0 / 580.0, accuracy: 0.000_001)
    }

    func testEarnedXpMovesTheBadge() {
        // Claiming enough quests has to actually level you up, or the number is decoration.
        XCTAssertEqual(AccountLevel.standing(earnedXp: 2000).level, 18)
        XCTAssertEqual(AccountLevel.standing(earnedXp: 2000).earnedXp, 2000)
    }

    func testProgressIsClampedAtBothEnds() {
        XCTAssertEqual(AccountLevel.standing(forTotalXp: 0).progress, 0, accuracy: 0.000_001)
        // A total sitting exactly on a threshold is at the START of the new level, not the end of the old.
        XCTAssertEqual(AccountLevel.standing(forTotalXp: 120).progress, 0, accuracy: 0.000_001)
    }

    // MARK: - The ledger

    func testAnAwardAddsOnceAndOnlyOnce() {
        let first = XpLedger.award(key: "quest-a", amount: 40, total: 100, claimedKeys: [])
        XCTAssertTrue(first.didAward)
        XCTAssertEqual(first.total, 140)

        // The same key again pays nothing, however the UI got there.
        let second = XpLedger.award(key: "quest-a", amount: 40, total: first.total, claimedKeys: first.claimedKeys)
        XCTAssertFalse(second.didAward)
        XCTAssertEqual(second.total, 140)
    }

    func testAnAbsurdAwardIsCapped() {
        // The amount originates from a language model. 100000 XP would end the level system in one tap.
        let a = XpLedger.award(key: "q", amount: 100_000, total: 0, claimedKeys: [])
        XCTAssertEqual(a.total, XpLedger.maxAward)
    }

    func testNothingIsAwardedForABlankKeyOrANonPositiveAmount() {
        XCTAssertFalse(XpLedger.award(key: "  ", amount: 40, total: 0, claimedKeys: []).didAward)
        XCTAssertFalse(XpLedger.award(key: "q", amount: 0, total: 0, claimedKeys: []).didAward)
        XCTAssertFalse(XpLedger.award(key: "q", amount: -10, total: 0, claimedKeys: []).didAward)
    }

    func testTheClaimListIsBoundedAndKeepsTheNewest() {
        let old = (0..<XpLedger.maxClaimedKeys).map { "old-\($0)" }
        let a = XpLedger.award(key: "new", amount: 10, total: 0, claimedKeys: old)
        XCTAssertEqual(a.claimedKeys.count, XpLedger.maxClaimedKeys)
        XCTAssertEqual(a.claimedKeys.last, "new")
        XCTAssertFalse(a.claimedKeys.contains("old-0"))
    }
}
