import Foundation

// AccountLevel.swift — the level badge and the XP curve behind it.
//
// Pure + deterministic so it is unit-testable without an app target, and so the curve is
// byte-identical to the Android twin `com.noop.gamify.AccountLevel` (the cross-platform parity
// contract: the same XP total must produce the same level and the same bar fraction on both, or the
// two platforms disagree about the wearer's own standing).
//
// HALF PROVISIONAL, HALF REAL. The starting position is a fixed level 15 parked partway through it —
// nothing about the wearer's history has been measured. But XP claimed from a finished quest IS real,
// lives in the ledger, and is added on top. A fresh install therefore reads exactly 15, and every
// point above that line was earned by finishing something.
//
// So the level is DERIVED from the total rather than asserted: claim enough quests and the badge
// moves, which is the only thing that makes showing it worth anything. The provisional half must
// still never be presented as a claim about the wearer's past — it is a starting position, not a
// history.

public enum AccountLevel {

    private static let base: Double = 120
    private static let exponent: Double = 1.45
    private static let provisionalLevel = 15
    private static let provisionalProgress: Double = 0.42

    /// A ceiling on the walk in `level(forXp:)`, so a corrupted total cannot spin.
    private static let maxLevel = 999

    /// The curve: cumulative XP needed to REACH `level`. Level 1 is zero.
    ///
    /// The `Int(...)` truncates, exactly as Kotlin's `.toInt()` does — NOT rounds. Getting that wrong
    /// moves every threshold by up to a point and puts the two platforms on different levels at the
    /// boundaries, which is precisely where a wearer is looking.
    public static func xp(forLevel level: Int) -> Int {
        level <= 1 ? 0 : Int(base * pow(Double(level - 1), exponent))
    }

    /// The baseline XP total: level 15, partway through. What a fresh install starts from.
    public static func baselineXp() -> Int {
        let floor = xp(forLevel: provisionalLevel)
        let ceiling = xp(forLevel: provisionalLevel + 1)
        return floor + Int(Double(ceiling - floor) * provisionalProgress)
    }

    /// Everything the level surfaces need, resolved once so a bar and its badge cannot disagree.
    public struct Standing: Equatable, Sendable {
        public let level: Int
        public let totalXp: Int
        public let xpIntoLevel: Int
        public let xpSpanOfLevel: Int
        public let earnedXp: Int

        public init(level: Int, totalXp: Int, xpIntoLevel: Int, xpSpanOfLevel: Int, earnedXp: Int) {
            self.level = level
            self.totalXp = totalXp
            self.xpIntoLevel = xpIntoLevel
            self.xpSpanOfLevel = xpSpanOfLevel
            self.earnedXp = earnedXp
        }

        /// 0–1 through the current level.
        public var progress: Double {
            min(1, max(0, Double(xpIntoLevel) / Double(xpSpanOfLevel)))
        }

        /// XP still to go before the next level. Never negative.
        public var xpToNextLevel: Int { max(0, xpSpanOfLevel - xpIntoLevel) }
    }

    /// The standing a given XP total produces.
    public static func standing(forTotalXp totalXp: Int, earnedXp: Int = 0) -> Standing {
        let level = level(forXp: totalXp)
        let floor = xp(forLevel: level)
        return Standing(
            level: level,
            totalXp: totalXp,
            xpIntoLevel: totalXp - floor,
            xpSpanOfLevel: max(1, xp(forLevel: level + 1) - floor),
            earnedXp: earnedXp
        )
    }

    /// The wearer's standing: the baseline plus whatever they have actually earned.
    public static func standing(earnedXp: Int) -> Standing {
        standing(forTotalXp: baselineXp() + max(0, earnedXp), earnedXp: max(0, earnedXp))
    }

    /// The highest level whose threshold `totalXp` has reached.
    ///
    /// Walked rather than solved: the inverse of the curve is a `pow` that rounds the wrong way at
    /// exactly the boundaries where a wearer is watching, and the loop is over tens of iterations.
    public static func level(forXp totalXp: Int) -> Int {
        var level = 1
        while level < maxLevel && xp(forLevel: level + 1) <= totalXp { level += 1 }
        return level
    }
}

// MARK: - The ledger

/// XP that was actually earned, and the keys that have already been paid.
///
/// The storage itself belongs to the app target (UserDefaults on Apple, SharedPreferences on Android);
/// this is the pure part: what an award does to a total and a claim set. Twin of the Android
/// `com.noop.gamify.XpLedger`.
///
/// CLAIMED ONCE, EVER. Each award carries a key (a quest's id); the key is recorded and a second claim
/// under the same key adds nothing. Without that, reopening the app and tapping the same finished
/// quest would print XP, which would make the number meaningless — and a gamified figure that can be
/// farmed by tapping is worse than no figure.
public enum XpLedger {

    /// The most a single award may be worth. A day's work, not a level.
    public static let maxAward = 200

    /// How many claim keys are remembered. Oldest fall off; a months-old quest cannot be re-claimed
    /// anyway, because it is long gone from the quest store.
    public static let maxClaimedKeys = 120

    /// The result of an award: the new total, the new claim list, and whether anything happened.
    public struct Award: Equatable, Sendable {
        public let total: Int
        public let claimedKeys: [String]
        public let didAward: Bool
    }

    /// Apply an award. Returns the state unchanged, with `didAward == false`, when the key has already
    /// been claimed, the key is blank, or the amount is not positive.
    public static func award(
        key: String,
        amount: Int,
        total: Int,
        claimedKeys: [String]
    ) -> Award {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, amount > 0, !claimedKeys.contains(trimmed) else {
            return Award(total: max(0, total), claimedKeys: claimedKeys, didAward: false)
        }
        return Award(
            total: max(0, total) + min(amount, maxAward),
            claimedKeys: Array((claimedKeys + [trimmed]).suffix(maxClaimedKeys)),
            didAward: true
        )
    }
}
