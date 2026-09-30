import Foundation
import StrandDesign
import StrandAnalytics

// HomeHeroMapping.swift — the pure half of Today's Telos hero (DESIGN_V2 VISUAL DIRECTION, decision 18).
//
// Everything the hero PRINTS or FEEDS INTO THE ORB that needs a decision lives here, so it can be tested
// without a view (`StrandTests/HomeHeroMappingTests`). Every function abstains (nil) on a missing input —
// nothing here substitutes a default for a measurement.

enum HomeHeroMapping {

    // MARK: - The tier word under the Level

    /// The word under the Level number. The app has no tier naming of its own, so this is DERIVED, and
    /// only from where the Level sits on the wearer's OWN scale (50 ≈ their own average, 100 = their own
    /// 95th percentile — `LevelComponent`). It is never a population rank, and it is unbounded at the top:
    /// every level from 120 up is "beyond peak", the only honest thing to say about a figure past
    /// anything the wearer's history has shown. No "superhuman": nothing in the Level supports that claim.
    ///
    /// | level      | tier        |
    /// |------------|-------------|
    /// | < 35       | LOW         |
    /// | 35 ..< 60  | BASELINE    |
    /// | 60 ..< 80  | STRONG      |
    /// | 80 ..< 100 | NEAR PEAK   |
    /// | 100 ..< 120| PEAK        |
    /// | ≥ 120      | BEYOND PEAK |
    enum Tier: String, CaseIterable, Equatable {
        case low, baseline, strong, nearPeak, peak, beyondPeak

        /// The caps word. Localised; drawn upper-cased.
        var label: String {
            switch self {
            case .low: return String(localized: "Low")
            case .baseline: return String(localized: "Baseline")
            case .strong: return String(localized: "Strong")
            case .nearPeak: return String(localized: "Near peak")
            case .peak: return String(localized: "Peak")
            case .beyondPeak: return String(localized: "Beyond peak")
            }
        }
    }

    static func tier(level: Double?) -> Tier? {
        guard let level, level.isFinite else { return nil }
        switch level {
        case ..<35: return .low
        case ..<60: return .baseline
        case ..<80: return .strong
        case ..<100: return .nearPeak
        case ..<120: return .peak
        default: return .beyondPeak
        }
    }

    // MARK: - Delta vs yesterday

    /// Points above (+) or below (−) yesterday's Level, or nil when either is missing.
    static func levelDelta(now: Double?, yesterday: Double?) -> Double? {
        guard let now, let yesterday, now.isFinite, yesterday.isFinite else { return nil }
        return now - yesterday
    }

    /// "+24 pts" / "−3 pts" / "±0 pts" (a change that rounds to nothing is flat, and says so — distinct
    /// from "not computed", which the caller hides).
    static func deltaText(_ delta: Double) -> String {
        let points = Int(delta.rounded())
        if abs(delta) < 0.5 || points == 0 { return String(localized: "±0 pts") }
        return points > 0 ? String(localized: "+\(points) pts") : String(localized: "\u{2212}\(abs(points)) pts")
    }

    // MARK: - The progress ring (today's quests)

    /// Today's quests the wearer took on, and how many of them the data has already closed.
    struct QuestProgress: Equatable {
        let done: Int
        let total: Int
        /// done ÷ total × 100. Never above 100: a quest cannot be done twice.
        var percent: Double { total > 0 ? Double(done) / Double(total) * 100 : 0 }
    }

    /// Counted over the quests for `dayKey` that were ACCEPTED (active or completed). An offered quest
    /// is not a commitment yet, and a declined one is not one at all. Nil when nothing was taken on — the
    /// ring then shows its honest empty state, never "0 %".
    static func questProgress(_ quests: [Quest], dayKey: String) -> QuestProgress? {
        let taken = quests.filter { $0.dayKey == dayKey && ($0.state == .active || $0.state == .completed) }
        guard !taken.isEmpty else { return nil }
        return QuestProgress(done: taken.filter { $0.state == .completed }.count, total: taken.count)
    }

    // MARK: - The orb's feed

    /// Each Level part's share of the Level: the points it contributes (score × effective weight). Parts
    /// without a score are left out — never painted as a zero share. Meditation is not a part.
    static func partShares(_ components: [LevelComponent]) -> [TelosOrbPart: Double] {
        var out: [TelosOrbPart: Double] = [:]
        for c in components {
            guard let score = c.score, score.isFinite, c.effectiveWeight > 0,
                  let part = TelosOrbPart(rawValue: c.part.rawValue) else { continue }
            let points = score * c.effectiveWeight
            if points > 0 { out[part] = points }
        }
        return out
    }

    /// How settled the Level on screen is. A stand-in day (today's not written yet) or a Level computed
    /// without part of its formula is provisional → `.building`; otherwise `.solid`. The Level has no
    /// calibrating state of its own (a day too thin to score has NO level, not a provisional one).
    static func levelConfidence(pendingToday: Bool, coverage: Double?) -> TelosConfidence {
        if pendingToday { return .building }
        if let coverage, coverage < 0.999 { return .building }
        return .solid
    }

    /// Today's Effort ÷ today's target (both on the 0–100 Effort axis). Unbounded; nil when either is
    /// missing or the target is not positive.
    static func effortRatio(effort: Double?, target: Double?) -> Double? {
        guard let effort, let target, effort.isFinite, target.isFinite, target > 0 else { return nil }
        return max(0, effort) / target
    }

    // MARK: - Mission card

    /// The mission split into the card's title (its first sentence) and subtitle (the rest), so a
    /// two-sentence mission reads like the reference. A one-sentence mission has no subtitle.
    static func missionParts(_ mission: String) -> (title: String, subtitle: String?) {
        let text = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: ". ") else { return (text, nil) }
        let title = String(text[..<range.lowerBound]) + "."
        let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, rest.isEmpty ? nil : rest)
    }
}
