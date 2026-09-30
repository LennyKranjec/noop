import Foundation
import StrandDesign
import StrandAnalytics

// HomeHeroMapping.swift — the pure half of Today's Telos hero (DESIGN_V2 VISUAL DIRECTION, decision 18).
//
// Everything the hero PRINTS or FEEDS INTO THE ORB that needs a decision lives here, so it can be tested
// without a view (`StrandTests/OrbExplainerMappingTests` pins the orb legend and its history). Every
// function abstains (nil) on a missing input — nothing here substitutes a default for a measurement.

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

    // MARK: - The orb explainer ("What shapes your orb")

    /// One line of the orb's legend: a visual channel, the input it reads, TODAY's value (nil = absent,
    /// drawn "—") and, in plain words, what it means — or why it is absent. The values are the SAME
    /// numbers the orb was built from (`TelosOrbInputs` + the Level breakdown), never re-derived.
    struct OrbLegendRow: Equatable, Identifiable {
        let id: String
        /// SF Symbol for the row.
        let glyph: String
        /// Tints the row with that part's colour (the lobe rows); nil = the house accent.
        let part: TelosOrbPart?
        let title: String
        /// Today's value, formatted; nil = not measured (the row prints "—").
        let value: String?
        /// What the channel means, or the reason it is absent.
        let detail: String
    }

    /// The part's written name, in the wearer's language.
    static func orbPartName(_ part: TelosOrbPart) -> String {
        switch part {
        case .sleep: return String(localized: "Sleep")
        case .heart: return String(localized: "Heart")
        case .lungs: return String(localized: "Lungs")
        case .muscle: return String(localized: "Muscle")
        case .focus: return String(localized: "Focus")
        }
    }

    /// The part's glyph: the SAME symbol the orb draws on that part's lobe (`TelosOrbPart.symbolName`).
    static func orbPartGlyph(_ part: TelosOrbPart) -> String { part.symbolName }

    /// The parts that have a lobe on the orb (a finite, positive share), in lobe order — for VoiceOver,
    /// which cannot see the lobe glyphs.
    static func orbLobeNames(_ inputs: TelosOrbInputs) -> [String] {
        TelosOrbPart.allCases.filter { part in
            guard let share = inputs.partShares[part] else { return false }
            return share.isFinite && share > 0
        }
        .map(orbPartName)
    }

    /// The orb button's VoiceOver value: "Lobes: Sleep, Heart, Muscle", or "No lobes yet".
    static func orbAccessibilityValue(_ inputs: TelosOrbInputs) -> String {
        let names = orbLobeNames(inputs)
        guard !names.isEmpty else { return String(localized: "No lobes yet") }
        let list = names.joined(separator: ", ")
        return String(localized: "Lobes: \(list)")
    }

    /// The legend, top to bottom: size (Level) · one lobe per part · surface (stress) · pulse (resting HR)
    /// · glow (Charge) · orbit speed (Effort ÷ target) · orbit dots (Level ÷ 10) · assembling (how settled
    /// the Level is).
    /// `pending` = the Level shown is a stand-in until today's night is in.
    static func orbLegend(inputs: TelosOrbInputs, breakdown: LevelBreakdown?, pending: Bool) -> [OrbLegendRow] {
        func finite(_ v: Double?) -> Double? {
            guard let v, v.isFinite else { return nil }
            return v
        }
        var rows: [OrbLegendRow] = []

        // Size ← Level (unbounded).
        let level = finite(inputs.level)
        rows.append(OrbLegendRow(
            id: "size", glyph: "circle.dashed", part: nil, title: String(localized: "Size"),
            value: level.map { String(localized: "Level \(TelosFormat.integer($0))") },
            detail: level == nil
                ? String(localized: "No Level yet, so the orb rests at a neutral size.")
                : String(localized: "Grows with your Level and fills in with more dots. There is no limit: past 100 a dotted shell appears around it.")))

        // One lobe per part ← that part's score and share of the Level.
        let shares = breakdown.map { partShares($0.components) } ?? [:]
        let total = shares.values.reduce(0, +)
        for part in TelosOrbPart.allCases {
            let name = orbPartName(part)
            let component = breakdown?.components.first(where: { $0.part.rawValue == part.rawValue })
            let score = finite(component?.score)
            if let score, let share = shares[part], total > 0 {
                let percent = Int((share / total * 100).rounded())
                rows.append(OrbLegendRow(
                    id: "lobe.\(part.rawValue)", glyph: orbPartGlyph(part), part: part,
                    title: String(localized: "\(name) lobe"),
                    value: String(localized: "\(name) part \(TelosFormat.integer(score))"),
                    detail: String(localized: "\(percent) % of your Level. The bigger its share, the bigger this organ.")))
            } else {
                rows.append(OrbLegendRow(
                    id: "lobe.\(part.rawValue)", glyph: orbPartGlyph(part), part: part,
                    title: String(localized: "\(name) lobe"), value: nil,
                    detail: String(localized: "No \(name.lowercased()) score in this Level, so there is no lobe for it.")))
            }
        }

        // Surface ← stress (0–3).
        let stress = finite(inputs.stress)
        rows.append(OrbLegendRow(
            id: "surface", glyph: "water.waves", part: nil, title: String(localized: "Surface calm"),
            value: stress.map { s in
                let word = StressBand(score: s).word.lowercased()
                let figure = String(format: "%.1f", s)
                return String(localized: "Stress \(word) (\(figure) of 3)")
            },
            detail: stress == nil
                ? String(localized: "No stress reading today, so the surface rests calm.")
                : String(localized: "Calm keeps the membrane smooth; stress ripples it and makes it sway more.")))

        // Pulse ← resting heart rate.
        let bpm: Double? = finite(inputs.heartRateBpm).flatMap { $0 > 0 ? $0 : nil }
        let pulseDetail: String
        if let bpm {
            let seconds = String(format: "%.1f", TelosOrbAppearance.pulseSlowdown * 60 / bpm)
            pulseDetail = String(localized: "It breathes once every \(seconds) s: your resting heartbeat, slowed six times.")
        } else {
            pulseDetail = String(localized: "No resting heart rate yet, so it breathes at a slow neutral pace.")
        }
        rows.append(OrbLegendRow(
            id: "pulse", glyph: "waveform.path.ecg", part: nil, title: String(localized: "Pulse"),
            value: bpm.map { String(localized: "Resting HR \(TelosFormat.integer($0))") },
            detail: pulseDetail))

        // Glow ← today's Charge.
        let charge = finite(inputs.charge)
        rows.append(OrbLegendRow(
            id: "glow", glyph: "sun.max", part: nil, title: String(localized: "Glow"),
            value: charge.map { String(localized: "Charge \(TelosFormat.integer($0))") },
            detail: charge == nil
                ? String(localized: "Charge not measured today, so the glow stays dim.")
                : String(localized: "The higher your Charge, the brighter the orb and its dots.")))

        // Orbit speed ← Effort ÷ target (unbounded).
        let effort = finite(inputs.effortRatio)
        rows.append(OrbLegendRow(
            id: "orbit", glyph: "circle.circle", part: nil, title: String(localized: "Orbit speed"),
            value: effort.map { String(localized: "Effort \(TelosFormat.integer(max(0, $0) * 100)) % of target") },
            detail: effort == nil
                ? String(localized: "No effort or no target today, so the orbit dots drift at a resting pace.")
                : String(localized: "The dots on the orbits travel faster the more of today's target you have done, and keep speeding up past 100 %.")))

        // Orbit dots ← Level: one per 10 points, unbounded (the speed above is effort's).
        let dots = level.map { TelosOrbAppearance.orbitDots(level: $0) }
        rows.append(OrbLegendRow(
            id: "dots", glyph: "circle.dotted", part: nil, title: String(localized: "Orbit dots"),
            value: dots.map { String($0) },
            detail: level == nil
                ? String(localized: "No Level yet, so nothing orbits the orb.")
                : String(localized: "One per 10 Level points, with no limit. Past 30 they get smaller instead of stopping.")))

        // Assembling ← how settled the Level is.
        let assemblyValue: String?
        let assemblyDetail: String
        if level == nil {
            assemblyValue = nil
            assemblyDetail = String(localized: "No Level to settle yet.")
        } else {
            switch inputs.confidence {
            case .solid:
                assemblyValue = String(localized: "Settled")
                assemblyDetail = String(localized: "This Level is final, so every dot sits on the membrane.")
            case .building:
                if pending {
                    assemblyValue = String(localized: "Waiting for today's night")
                    assemblyDetail = String(localized: "Your last scored day stands in until today's night is in: the membrane is faint and some dots are still drifting in.")
                } else {
                    let covered = breakdown.map { "\($0.coveragePercent) %" } ?? TelosType.absent
                    assemblyValue = String(localized: "Part of the formula missing")
                    assemblyDetail = String(localized: "Only \(covered) of the Level's formula had data: the membrane is faint and some dots are still drifting in.")
                }
            case .calibrating:
                assemblyValue = String(localized: "Level still calibrating")
                assemblyDetail = String(localized: "The membrane is faint and dots are still drifting in until your Level settles.")
            }
        }
        rows.append(OrbLegendRow(id: "assembly", glyph: "sparkles", part: nil,
                                 title: String(localized: "Assembling"), value: assemblyValue, detail: assemblyDetail))
        return rows
    }

    // MARK: - The orb at other levels (the explainer's preview)

    /// The thumbnail strip's levels: 0, 20 … 200.
    static let orbPreviewLevels: [Double] = stride(from: 0.0, through: 200.0, by: 20.0).map { $0 }

    /// Where the preview starts: today's Level to the nearest 10, or 50 (the wearer's own average) when
    /// there is none. A starting point for a what-if, never shown as a measurement.
    static func orbPreviewStart(level: Double?) -> Double {
        guard let level, level.isFinite else { return 50 }
        return (max(0, level) / 10).rounded() * 10
    }

    /// A typed or stepped preview level: non-finite or negative → 0; no upper limit (the Level has none).
    static func sanitizedPreviewLevel(_ level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return max(0, level)
    }

    /// What the preview orb draws for `level`: its orbiting dots and its size as a percentage of a
    /// Level-100 orb's.
    static func orbPreviewSummary(level: Double) -> (dots: Int, sizePercent: Int) {
        let a = TelosOrbAppearance.from(TelosOrbInputs(level: sanitizedPreviewLevel(level)))
        return (a.orbitDots, Int((a.size / TelosOrbAppearance.sizeAtReference * 100).rounded()))
    }

    // MARK: - The orb's history

    /// One STORED day of the Level, as the orb can draw it (Level + part shares — the other channels are
    /// not stored per day, so a past orb shows only these).
    struct OrbHistoryDay: Equatable {
        let day: String
        let level: Double
        let partShares: [TelosOrbPart: Double]
        /// Written partly (a thin night) or from part of the formula — drawn as still assembling.
        let provisional: Bool
    }

    /// A past orb to show: the stored day nearest `daysBack` days before the end day, or nil when nothing
    /// is stored within the tolerance — never a made-up day.
    struct OrbSnapshot: Equatable, Identifiable {
        var id: Int { daysBack }
        let daysBack: Int
        let entry: OrbHistoryDay?
    }

    /// Whole days from `from` to `to` (day keys), or nil when either does not parse.
    static func dayDistance(from: String, to: String, calendar: Calendar) -> Int? {
        guard let a = LevelWiring.date(from: from, calendar: calendar),
              let b = LevelWiring.date(from: to, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: a),
                                       to: calendar.startOfDay(for: b)).day
    }

    /// For each offset, the stored day nearest to `endDay − offset` within ±`tolerance` days (on a tie,
    /// the earlier one). Honest: a gap in the history is a nil, not a neighbour from further away.
    static func orbSnapshots(history: [OrbHistoryDay], endDay: String, daysBack: [Int], tolerance: Int = 7,
                             calendar: Calendar = .current) -> [OrbSnapshot] {
        var placed: [(entry: OrbHistoryDay, back: Int)] = []
        for entry in history {
            if let back = dayDistance(from: entry.day, to: endDay, calendar: calendar) {
                placed.append((entry, back))
            }
        }
        return daysBack.map { offset in
            var best: (entry: OrbHistoryDay, back: Int)? = nil
            for candidate in placed where abs(candidate.back - offset) <= tolerance {
                guard let current = best else {
                    best = candidate
                    continue
                }
                let dc = abs(candidate.back - offset), db = abs(current.back - offset)
                if dc < db || (dc == db && candidate.back > current.back) { best = candidate }
            }
            return OrbSnapshot(daysBack: offset, entry: best?.entry)
        }
    }

    /// A point of the development chart: `index` = days since the window's first day.
    struct OrbChartPoint: Equatable {
        let index: Int
        let level: Double
    }

    /// The stored Levels inside the last `span` days ending on `endDay`, oldest first, placed by their
    /// real date (a gap stays a gap). Non-finite levels are dropped.
    static func orbChartPoints(history: [OrbHistoryDay], endDay: String, span: Int,
                               calendar: Calendar = .current) -> [OrbChartPoint] {
        let width = max(span, 1)
        var out: [OrbChartPoint] = []
        for entry in history where entry.level.isFinite {
            guard let back = dayDistance(from: entry.day, to: endDay, calendar: calendar),
                  back >= 0, back < width else { continue }
            out.append(OrbChartPoint(index: width - 1 - back, level: entry.level))
        }
        return out.sorted { $0.index < $1.index }
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
