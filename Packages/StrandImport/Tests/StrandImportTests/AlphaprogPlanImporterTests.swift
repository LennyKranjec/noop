import Foundation
import XCTest
@testable import StrandImport

/// The Alphaprog PLAN export, on the owner's own file (`alphaprog_plans.csv`: UTF-8 BOM, CRLF, `;`).
///
/// The counts below are read off the fixture by hand: Lower → Lower A (Di) 8 exercises, Lower B (Fr) 8;
/// Upper → Upper A (Mo) 11, Upper B (Do) 10.
final class AlphaprogPlanImporterTests: XCTestCase {

    private func bytes() -> Data { Fixtures.data("alphaprog_plans.csv") }

    private func parsed() -> AlphaprogPlanImporter.Parsed {
        guard let p = AlphaprogPlanImporter.parse(data: bytes()) else {
            XCTFail("the fixture must decode")
            return AlphaprogPlanImporter.Parsed(programs: [], diagnostics: .init())
        }
        return p
    }

    func testTheFixtureReallyIsBomAndCRLF() {
        let raw = bytes()
        XCTAssertEqual([UInt8](raw.prefix(3)), [0xEF, 0xBB, 0xBF], "the exporter writes a UTF-8 BOM")
        XCTAssertTrue(raw.range(of: Data([0x0D, 0x0A])) != nil, "and CRLF line endings")
    }

    func testFourDayTemplatesWithTheirExerciseCounts() {
        let p = parsed()
        XCTAssertEqual(p.programs.map(\.name), ["Lower", "Upper"])
        XCTAssertEqual(p.programs.map(\.date), ["2026-01-05", "2025-12-12"])
        XCTAssertEqual(p.dayCount, 4)
        XCTAssertEqual(p.programs[0].days.map(\.name), ["Lower A (Di)", "Lower B (Fr)"])
        XCTAssertEqual(p.programs[1].days.map(\.name), ["Upper A (Mo)", "Upper B (Do)"])
        XCTAssertEqual(p.programs[0].days.map(\.dayNumber), [1, 2])
        XCTAssertEqual(p.programs.flatMap(\.days).map(\.exercises.count), [8, 8, 11, 10])
        XCTAssertEqual(p.diagnostics.programHeaders, 2)
        XCTAssertEqual(p.diagnostics.dayHeaders, 4)
        XCTAssertEqual(p.diagnostics.exerciseRows, 37)
        XCTAssertEqual(p.diagnostics.skippedLines, 0)
        XCTAssertEqual(p.diagnostics.firstLine, "Lower;2026-01-05", "the BOM never reaches a field")
    }

    func testEquipmentSetsAndReps() {
        let p = parsed()
        let lowerA = p.programs[0].days[0].exercises
        XCTAssertEqual(lowerA[0], AlphaprogPlanImporter.Exercise(position: 1, name: "Beinpresse", equipment: "Maschine",
                                                                 targetSets: 4, targetRepsLow: 10, targetRepsHigh: 10))
        XCTAssertEqual(lowerA.map(\.targetSets), [4, 3, 3, 4, 4, 3, 3, 3])
        XCTAssertEqual(lowerA.last?.name, "Wadenheben an der Beinpresse")
        let upperA = p.programs[1].days[0].exercises
        XCTAssertEqual(upperA[7].name, "Trizepsdrücken mit dem Seil")
        XCTAssertEqual(upperA[7].equipment, "Kabelzug")
        XCTAssertEqual(upperA[8].name, "Hyperextensions")
        XCTAssertEqual(upperA[8].equipment, "Körpergewicht")
        XCTAssertEqual(upperA.map(\.position), Array(1...11))
        XCTAssertTrue(p.programs.flatMap(\.days).flatMap(\.exercises).allSatisfy { $0.targetRepsLow == 10 })
        let equipment = Set(p.programs.flatMap(\.days).flatMap(\.exercises).compactMap(\.equipment))
        XCTAssertEqual(equipment, ["Maschine", "Kabelzug", "Körpergewicht"])
    }

    /// The CRLF trap the history importer fell into: the same text with LF only, CRLF, and a lone CR must parse
    /// identically, even when handed in without going through `ImportText.decode`.
    func testLineEndingsDoNotMatter() {
        let lf = "Lower;2026-01-05\n\"Tag 1 · Lower A (Di)\"\n\"1. Beinpresse · Maschine\";\"4 Sätze\";\"8-12 Wdh\"\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let cr = lf.replacingOccurrences(of: "\n", with: "\r")
        let a = AlphaprogPlanImporter.parse(lf)
        XCTAssertEqual(a.programs.first?.days.first?.exercises.first?.targetRepsHigh, 12)
        XCTAssertEqual(a.programs.first?.days.first?.exercises.first?.targetRepsLow, 8)
        XCTAssertEqual(AlphaprogPlanImporter.parse(crlf), a)
        XCTAssertEqual(AlphaprogPlanImporter.parse(cr), a)
    }

    func testAHistoryExportIsNotAPlan() {
        // A workout-history header is three quoted fields; it must not be read as a day or an exercise.
        let history = "\"Upper B (Do) · Tag 2 · Woche 32 · Upper\";\"2026-09-14 13:44 Uhr\";\"53 Min.\"\n#;KG;WDH\n1;30;10\n"
        let p = AlphaprogPlanImporter.parse(history)
        XCTAssertTrue(p.programs.isEmpty)
        XCTAssertEqual(p.diagnostics.programHeaders, 0, "`#;KG;WDH` and `1;30;10` are not program names")
        XCTAssertEqual(p.diagnostics.exerciseRows, 0)
        XCTAssertGreaterThan(p.diagnostics.skippedLines, 0)
    }

    func testUndecodableBytesAreNil() {
        // Invalid UTF-8 (0xFF) with a NUL: no encoding reads it, and the single-byte fallback is gated off.
        XCTAssertNil(AlphaprogPlanImporter.parse(data: Data([0xFF, 0x00, 0xC3])))
    }
}
