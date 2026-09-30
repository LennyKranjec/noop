import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// The orb explainer ("What shapes your orb", opened from the Today orb). Pinned: every channel the orb
/// draws has a legend row carrying TODAY's value from the same inputs the orb was drawn from; an absent
/// input is a nil value with a reason, never a stand-in; a part without a score has no lobe; the history
/// shows only stored days (a gap is a nil snapshot, not a neighbour from further away) and places chart
/// points by their real date.
final class OrbExplainerMappingTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func breakdown(level: Double = 64, coverage: Double = 1,
                           scores: [LevelPart: Double?] = [.sleep: 70, .heart: 58, .lungs: 50,
                                                           .muscle: 66, .focus: 60]) -> LevelBreakdown {
        let components = LevelPart.allCases.map { part -> LevelComponent in
            let score = scores[part] ?? nil
            return LevelComponent(part: part, score: score, effectiveWeight: score == nil ? 0 : part.weight)
        }
        return LevelBreakdown(components: components, raw: level, stepPenalty: 1, level: level, coverage: coverage)
    }

    private func row(_ rows: [HomeHeroMapping.OrbLegendRow], _ id: String) -> HomeHeroMapping.OrbLegendRow {
        guard let r = rows.first(where: { $0.id == id }) else {
            XCTFail("no row \(id)")
            return HomeHeroMapping.OrbLegendRow(id: id, glyph: "", part: nil, title: "", value: nil, detail: "")
        }
        return r
    }

    // MARK: The legend

    func testEveryChannelHasARowInOrder() {
        let rows = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(), breakdown: nil, pending: false)
        XCTAssertEqual(rows.map(\.id), ["size", "lobe.sleep", "lobe.heart", "lobe.lungs", "lobe.muscle", "lobe.focus",
                                        "surface", "pulse", "glow", "orbit", "dots", "assembly"])
    }

    func testNothingMeasuredIsAllAbsentWithAReason() {
        let rows = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(), breakdown: nil, pending: false)
        for r in rows {
            XCTAssertNil(r.value, "\(r.id) must not invent a value")
            XCTAssertFalse(r.detail.isEmpty, "\(r.id) says why it is absent")
        }
    }

    func testTodaysValuesAreTheOrbsOwnInputs() {
        let b = breakdown()
        let inputs = TelosOrbInputs(level: b.level, partShares: HomeHeroMapping.partShares(b.components),
                                    stress: 0.8, heartRateBpm: 52, charge: 71, effortRatio: 0.8)
        let rows = HomeHeroMapping.orbLegend(inputs: inputs, breakdown: b, pending: false)
        XCTAssertTrue(row(rows, "size").value?.contains("64") == true)
        XCTAssertTrue(row(rows, "lobe.heart").value?.contains("58") == true)
        XCTAssertEqual(row(rows, "lobe.heart").part, .heart)
        XCTAssertTrue(row(rows, "surface").value?.contains("0.8") == true)
        XCTAssertTrue(row(rows, "pulse").value?.contains("52") == true)
        XCTAssertTrue(row(rows, "pulse").detail.contains("6.9"), "6 × 60 / 52 = 6.9 s per breath")
        XCTAssertTrue(row(rows, "glow").value?.contains("71") == true)
        XCTAssertTrue(row(rows, "orbit").value?.contains("80") == true)
        XCTAssertEqual(row(rows, "dots").value, "6", "one orbiting dot per 10 Level points")
        XCTAssertNotNil(row(rows, "assembly").value)
    }

    func testAPartWithoutAScoreHasNoLobeValue() {
        let b = breakdown(scores: [.sleep: 70, .heart: nil, .lungs: 50, .muscle: 66, .focus: 60])
        let inputs = TelosOrbInputs(level: b.level, partShares: HomeHeroMapping.partShares(b.components))
        let rows = HomeHeroMapping.orbLegend(inputs: inputs, breakdown: b, pending: false)
        XCTAssertNil(row(rows, "lobe.heart").value)
        XCTAssertNotNil(row(rows, "lobe.sleep").value)
    }

    func testLobeSharesSumToTheWholeLevel() {
        let b = breakdown()
        let rows = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(level: b.level), breakdown: b, pending: false)
        let percents = rows.filter { $0.id.hasPrefix("lobe.") }.compactMap { r -> Int? in
            Int(r.detail.prefix { $0.isNumber })
        }
        XCTAssertEqual(percents.count, 5)
        XCTAssertEqual(Double(percents.reduce(0, +)), 100, accuracy: 2)
    }

    func testNonFiniteAndNonPositiveInputsAreAbsent() {
        let rows = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(level: .nan, stress: .infinity, heartRateBpm: 0,
                                                                    charge: .nan, effortRatio: .nan),
                                             breakdown: nil, pending: false)
        for id in ["size", "surface", "pulse", "glow", "orbit", "dots", "assembly"] {
            XCTAssertNil(row(rows, id).value, id)
        }
    }

    func testAssemblingSaysWhyTheLevelIsProvisional() {
        let b = breakdown(coverage: 0.7)
        let pending = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(level: 64, confidence: .building),
                                                breakdown: b, pending: true)
        let partial = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(level: 64, confidence: .building),
                                                breakdown: b, pending: false)
        let solid = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(level: 64), breakdown: breakdown(), pending: false)
        XCTAssertNotEqual(row(pending, "assembly").value, row(partial, "assembly").value)
        XCTAssertTrue(row(partial, "assembly").detail.contains("70"), "names the covered share of the formula")
        XCTAssertNotEqual(row(solid, "assembly").value, row(partial, "assembly").value)
    }

    func testLegendGlyphsAreTheLobeGlyphs() {
        let rows = HomeHeroMapping.orbLegend(inputs: TelosOrbInputs(), breakdown: nil, pending: false)
        for part in TelosOrbPart.allCases {
            XCTAssertEqual(row(rows, "lobe.\(part.rawValue)").glyph, part.symbolName)
        }
    }

    func testVoiceOverNamesTheLobesDrawn() {
        let inputs = TelosOrbInputs(partShares: [.muscle: 20, .sleep: 30, .heart: 0, .focus: .nan])
        XCTAssertEqual(HomeHeroMapping.orbLobeNames(inputs),
                       [HomeHeroMapping.orbPartName(.sleep), HomeHeroMapping.orbPartName(.muscle)],
                       "lobe order; zero / non-finite shares have no lobe")
        XCTAssertTrue(HomeHeroMapping.orbAccessibilityValue(inputs).contains(HomeHeroMapping.orbPartName(.sleep)))
        XCTAssertTrue(HomeHeroMapping.orbLobeNames(TelosOrbInputs()).isEmpty)
    }

    // MARK: The other-levels preview

    func testPreviewStartsAtTodaysLevelToTheNearestTen() {
        XCTAssertEqual(HomeHeroMapping.orbPreviewStart(level: 64), 60)
        XCTAssertEqual(HomeHeroMapping.orbPreviewStart(level: 66), 70)
        XCTAssertEqual(HomeHeroMapping.orbPreviewStart(level: 340), 340, "no cap at 200")
        XCTAssertEqual(HomeHeroMapping.orbPreviewStart(level: nil), 50)
        XCTAssertEqual(HomeHeroMapping.orbPreviewStart(level: .nan), 50)
    }

    func testPreviewLevelsAndSanitising() {
        XCTAssertEqual(HomeHeroMapping.orbPreviewLevels, [0, 20, 40, 60, 80, 100, 120, 140, 160, 180, 200])
        XCTAssertEqual(HomeHeroMapping.sanitizedPreviewLevel(-30), 0)
        XCTAssertEqual(HomeHeroMapping.sanitizedPreviewLevel(.infinity), 0)
        XCTAssertEqual(HomeHeroMapping.sanitizedPreviewLevel(450), 450, "typed levels above 200 are kept")
    }

    func testPreviewSummaryGrowsWithTheLevel() {
        let low = HomeHeroMapping.orbPreviewSummary(level: 20)
        let ref = HomeHeroMapping.orbPreviewSummary(level: 100)
        let high = HomeHeroMapping.orbPreviewSummary(level: 450)
        XCTAssertEqual(low.dots, 2)
        XCTAssertEqual(ref.dots, 10)
        XCTAssertEqual(high.dots, 45)
        XCTAssertEqual(ref.sizePercent, 100)
        XCTAssertLessThan(low.sizePercent, ref.sizePercent)
        XCTAssertGreaterThan(high.sizePercent, ref.sizePercent)
    }

    // MARK: The history

    private func day(_ key: String, _ level: Double) -> HomeHeroMapping.OrbHistoryDay {
        HomeHeroMapping.OrbHistoryDay(day: key, level: level, partShares: [:], provisional: false)
    }

    func testSnapshotsPickTheNearestStoredDayWithinTolerance() {
        let history = [day("2026-07-03", 40), day("2026-08-30", 52), day("2026-09-02", 55), day("2026-09-30", 64)]
        let snaps = HomeHeroMapping.orbSnapshots(history: history, endDay: "2026-09-30", daysBack: [90, 30, 0],
                                                 tolerance: 7, calendar: calendar)
        XCTAssertEqual(snaps.map(\.daysBack), [90, 30, 0])
        XCTAssertEqual(snaps[0].entry?.day, "2026-07-03", "89 days back stands for 90")
        XCTAssertEqual(snaps[1].entry?.day, "2026-08-30", "31 back beats 28 back")
        XCTAssertEqual(snaps[2].entry?.day, "2026-09-30")
    }

    func testAGapIsANilSnapshotNotAFarNeighbour() {
        let history = [day("2026-09-28", 60), day("2026-09-30", 64)]
        let snaps = HomeHeroMapping.orbSnapshots(history: history, endDay: "2026-09-30", daysBack: [90, 30, 0],
                                                 tolerance: 7, calendar: calendar)
        XCTAssertNil(snaps[0].entry)
        XCTAssertNil(snaps[1].entry)
        XCTAssertEqual(snaps[2].entry?.day, "2026-09-30")
        XCTAssertTrue(HomeHeroMapping.orbSnapshots(history: [], endDay: "2026-09-30", daysBack: [0],
                                                   calendar: calendar).allSatisfy { $0.entry == nil })
    }

    func testChartPointsArePlacedByRealDateInsideTheSpan() {
        let history = [day("2026-06-01", 10), day("2026-09-01", 50), day("2026-09-03", .nan),
                       day("2026-09-29", 62), day("2026-09-30", 64)]
        let points = HomeHeroMapping.orbChartPoints(history: history, endDay: "2026-09-30", span: 30, calendar: calendar)
        XCTAssertEqual(points.map(\.index), [0, 28, 29], "outside the span and non-finite days are dropped")
        XCTAssertEqual(points.map(\.level), [50, 62, 64])
    }

    func testDayDistanceCrossesMonthsAndRejectsGarbage() {
        XCTAssertEqual(HomeHeroMapping.dayDistance(from: "2026-07-02", to: "2026-09-30", calendar: calendar), 90)
        XCTAssertNil(HomeHeroMapping.dayDistance(from: "garbage", to: "2026-09-30", calendar: calendar))
    }
}
