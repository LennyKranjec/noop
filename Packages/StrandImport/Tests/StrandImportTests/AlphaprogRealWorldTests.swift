import Foundation
import XCTest
@testable import StrandImport

/// The Alphaprog export IN THE SHAPE THE EXPORTER ACTUALLY WRITES IT, read through the decode helper the
/// app now uses.
///
/// WHY A SECOND FIXTURE. `alphaprog_workouts.csv` — the nine-month file the older tests run on — was
/// normalised somewhere along the way to LF-only line endings, so the CRLF the exporter really writes was
/// never once exercised by a test. `alphaprog_real_world.csv` is distilled from the wearer's own
/// `2026_09_28 Workouts.csv` and keeps every awkward thing about it: a UTF-8 BOM, CRLF terminators,
/// semicolons, the `·` separator, German decimal commas, a `1:42 Std.` duration, a single-digit clock
/// hour, `-;-` rows for sets that were printed and never done, a `#;MIN.` grid, a `#;KG;SEK` grid and a
/// `+10` bodyweight-added load.
///
/// The counts and volumes are read off the fixture BY HAND (they are in the comments below), because the
/// failure this guards against had a plausible shape: a header form the matcher missed produced ONE
/// fabricated day holding most of a year, with totals nobody would have questioned.
final class AlphaprogRealWorldTests: XCTestCase {

    private let zone = TimeZone(identifier: "Europe/Berlin")!

    private func bytes() -> Data { Fixtures.data("alphaprog_real_world.csv") }

    /// Decoded the way the app decodes it — NOT `String(data:encoding:.utf8)`, which is the call that
    /// silently returned "" for the file that started all this.
    private func text() -> String {
        guard let decoded = ImportText.decode(bytes()) else {
            XCTFail("the fixture must decode")
            return ""
        }
        XCTAssertEqual(decoded.encodingName, "utf-8")
        return decoded.text
    }

    private func parsed() -> AlphaprogImporter.Parsed {
        AlphaprogImporter.parse(text(), timeZone: zone)
    }

    // MARK: - The file's real byte shape

    func testTheFixtureReallyIsBomAndCRLF() {
        // If someone normalises this file the way the other fixture was normalised, the test below stops
        // testing anything — so the bytes themselves are asserted.
        let raw = bytes()
        XCTAssertEqual([UInt8](raw.prefix(3)), [0xEF, 0xBB, 0xBF], "the exporter writes a UTF-8 BOM")
        XCTAssertTrue(raw.range(of: Data([0x0D, 0x0A])) != nil, "and CRLF line endings")
    }

    func testTheBomAndTheCarriageReturnsDoNotReachTheParser() {
        let t = text()
        XCTAssertFalse(t.hasPrefix("\u{FEFF}"))
        // ASSERTED ON `utf8`, NOT `contains("\r")`. The first cut of this line used the Character form,
        // and a Swift Character is an extended grapheme cluster: CR+LF is ONE cluster, which is not equal
        // to the cluster "\r". So `contains("\r")` answered false for a string full of CRLF, and the
        // assertion passed while the file it was guarding was not normalised at all. A test that cannot
        // fail is worse than no test.
        XCTAssertFalse(t.utf8.contains(0x0D), "no CR of any kind may survive the decode")
    }

    func testTheParserItselfHandlesCRLFWithoutTheDecodeHelper() {
        // BELT AND BRACES, and the regression that matters most. `parse` is a public entry point: the
        // Android-parity call sites and any future caller can hand it text that never went through
        // `ImportText.decode`. Splitting on "\n" made THAT case read the whole file as one line — one
        // spurious session header, no exercises, and therefore zero workouts.
        let crlf = [
            "\"Upper A (Mo) · Einzelnes Workout\";\"2026-09-25 11:50 Uhr\";\"53 Min.\"",
            "\"1. Brustpresse · Maschine · 10 Wdh\"",
            "#;KG;WDH",
            "1;75;12",
            "2;27,5;8",
        ].joined(separator: "\r\n")
        let p = AlphaprogImporter.parse(crlf, timeZone: zone)
        XCTAssertEqual(p.diagnostics.sessionHeaders, 1)
        XCTAssertEqual(p.diagnostics.exerciseTitles, 1, "the title line must be seen as its own line")
        XCTAssertEqual(p.diagnostics.setRows, 2)
        XCTAssertEqual(p.workouts.count, 1)
        XCTAssertEqual(p.workouts.first?.volumeLoadKg ?? 0, 75 * 12 + 27.5 * 8, accuracy: 1e-9)
        // And a lone CR, which is the case that accidentally worked before.
        let cr = crlf.replacingOccurrences(of: "\r\n", with: "\r")
        XCTAssertEqual(AlphaprogImporter.parse(cr, timeZone: zone), p)
        // And plain LF, which is what the older fixture is.
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(AlphaprogImporter.parse(lf, timeZone: zone), p)
    }

    // MARK: - What it parses to

    func testEverySessionIsFoundAndOrderedOldestFirst() {
        let workouts = parsed().workouts
        XCTAssertEqual(workouts.count, 3)
        XCTAssertEqual(workouts.map(\.title), ["Tag 1 · Einzelnes Workout",
                                              "Lower A (Di) · Einzelnes Workout",
                                              "Upper A (Mo) · Einzelnes Workout"])
        XCTAssertEqual(workouts.map(\.start), workouts.map(\.start).sorted())
    }

    func testTheHourAndAHalfSessionCarriesItsWholeDuration() {
        // `"1:42 Std."` — 102 minutes, not 1 and not 42.
        guard let upper = parsed().workouts.last else { return XCTFail("no sessions") }
        XCTAssertEqual(upper.end.timeIntervalSince(upper.start), 102 * 60, accuracy: 0.5)
    }

    func testASingleDigitClockHourStillLands() {
        // `"2026-09-02 5:18 Uhr"`. A matcher that insisted on `HH:MM` dropped this whole session, and its
        // exercises were appended to whichever session HAD matched.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let lower = parsed().workouts.first(where: { $0.title.hasPrefix("Lower A") }) else {
            return XCTFail("the 5:18 session must parse")
        }
        XCTAssertEqual(calendar.component(.hour, from: lower.start), 5)
        XCTAssertEqual(calendar.component(.minute, from: lower.start), 18)
    }

    func testTheUpperSessionsVolumeAndSetsMatchTheFileByHand() {
        guard let upper = parsed().workouts.last else { return XCTFail("no sessions") }
        XCTAssertEqual(upper.exercises.map(\.name),
                       ["Brustpresse", "Schulterpresse", "Hyperextensions", "Bauchmaschine dual"])

        // Brustpresse    75×12 + 75×8 + 70×8 + 70×8   = 2 620
        // Schulterpresse 27,5×9 + 27,5×8 + 27,5×8     =   687,5   (German decimal comma)
        // Hyperextensions "+10"×11 + "+10"×12         =   230     (see the note on `+10` below)
        // Bauchmaschine   three "-;-" rows            =     0     (printed, never done)
        let expected: Double = 2620 + 687.5 + 230
        XCTAssertEqual(upper.volumeLoadKg, expected, accuracy: 1e-9)
        XCTAssertEqual(upper.setCount, 9)
        XCTAssertEqual(upper.exercises.count, 4)
        XCTAssertEqual(upper.totalReps, 12 + 8 + 8 + 8 + 9 + 8 + 8 + 11 + 12)
        XCTAssertEqual(upper.topSetKg ?? 0, 75, accuracy: 1e-9)
    }

    func testGermanDecimalCommasSurviveTheWholeRoundTrip() {
        guard let press = parsed().workouts.last?.exercises.first(where: { $0.name == "Schulterpresse" })
        else { return XCTFail("the 27,5 kg exercise must parse") }
        XCTAssertEqual(press.sets.count, 3)
        XCTAssertTrue(press.sets.allSatisfy { abs($0.weightKg - 27.5) < 1e-9 },
                      "27,5 is 27.5 kg, not 275")
    }

    func testAnUnperformedSetIsNotASetAtAll() {
        // `"4. Bauchmaschine dual"` is four printed rows and nothing done. The EXERCISE is still recorded
        // — "they were meant to do this" is true — but it contributes no set and no kilogram.
        guard let core = parsed().workouts.last?.exercises.first(where: { $0.name == "Bauchmaschine dual" })
        else { return XCTFail("the all-dashes exercise must still be recorded") }
        XCTAssertTrue(core.sets.isEmpty)
        XCTAssertEqual(core.sets.reduce(0) { $0 + $1.volumeKg }, 0, accuracy: 1e-9)
    }

    func testABodyweightAddedLoadIsReadAsTheAddedWeightOnly() {
        // `"1;+10;11"` is a bodyweight exercise with TEN KILOGRAMS ADDED. `Double("+10")` is 10, so the
        // volume here is the added weight × reps and not (bodyweight + 10) × reps.
        //
        // THIS TEST PINS THE CURRENT BEHAVIOUR ON PURPOSE. It UNDER-states the load, which is the safe
        // direction: reading it as bodyweight + 10 would need a bodyweight the file does not carry, and
        // inventing one is exactly the imputation this importer refuses. Documented rather than
        // "improved", because changing it moves every already-imported figure.
        guard let hyper = parsed().workouts.last?.exercises.first(where: { $0.name == "Hyperextensions" })
        else { return XCTFail("the +10 exercise must parse") }
        XCTAssertEqual(hyper.sets.count, 2, "the third row is -;- and did not happen")
        XCTAssertEqual(hyper.sets.map(\.weightKg), [10, 10])
        XCTAssertEqual(hyper.sets.reduce(0) { $0 + $1.volumeKg }, 10 * 11 + 10 * 12, accuracy: 1e-9)
        XCTAssertEqual(AlphaprogImporter.germanNumber("+10") ?? 0, 10, accuracy: 1e-9)
    }

    func testTheMinutesGridIsTimeAndNotLoad() {
        // `#;MIN.` — a plank. One minute happened; the other two rows are dashes. No weight exists here
        // at all, so no kilogram may appear in the volume.
        guard let plank = parsed().workouts.first?.exercises.first(where: { $0.name == "Plank" })
        else { return XCTFail("the minutes grid must parse") }
        XCTAssertEqual(plank.sets.count, 1)
        XCTAssertEqual(plank.sets[0].minutes, 1, accuracy: 1e-9)
        XCTAssertEqual(plank.sets[0].reps, 0)
        XCTAssertEqual(plank.sets[0].weightKg, 0, accuracy: 1e-9)
        XCTAssertEqual(parsed().workouts.first?.volumeLoadKg ?? -1, 0, accuracy: 1e-9)
    }

    func testAnUnperformedLoadedHoldContributesNothing() {
        // `#;KG;SEK` with three dash rows: the grid is there, a performed hold is not.
        guard let wallsit = parsed().workouts.first?.exercises.first(where: { $0.name == "Wallsit" })
        else { return XCTFail("the seconds grid must still record the exercise") }
        XCTAssertTrue(wallsit.sets.isEmpty)
    }

    func testTheWholeFixtureConvertsToStorableSessions() {
        let sessions = AlphaprogImporter.toSessions(parsed())
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions.allSatisfy { $0.start.timeIntervalSince1970 > 0 })
        XCTAssertTrue(sessions.allSatisfy { $0.end >= $0.start })
        // 141 kg × (12 + 12 + 10 + 12).
        guard let lower = sessions.first(where: { $0.title == "Lower A (Di) · Einzelnes Workout" })
        else { return XCTFail("the leg session must convert") }
        XCTAssertEqual(lower.volumeLoadKg, 141 * 46, accuracy: 1e-9)
        XCTAssertEqual(lower.setCount, 4)
    }

    func testEveryExerciseInTheFixtureIsPlaceable() {
        XCTAssertTrue(parsed().unattributed.isEmpty,
                      "these would silently lose their volume: \(parsed().unattributed)")
    }

    // MARK: - Diagnostics: what the screen now says instead of "No sessions found"

    func testTheParseReportsWhatItRecognised() {
        let d = parsed().diagnostics
        XCTAssertEqual(d.sessionHeaders, 3)
        XCTAssertEqual(d.exerciseTitles, 7)     // 4 + 1 + 2
        // Every row with the SHAPE of a grid row, dashes included: 13 + 4 + 6.
        XCTAssertEqual(d.setRows, 23)
        XCTAssertEqual(d.delimiter, ";")
        XCTAssertEqual(d.firstLine, "\"Upper A (Mo) · Einzelnes Workout\";\"2026-09-25 11:50 Uhr\";\"1:42 Std.\"")
    }

    func testAWrongFileIsReportedWithItsFirstLineAndNoSessions() {
        // A Hevy export pointed at the Alphaprog button. Nothing is fabricated, and the first line is
        // there for the message to quote — which is the whole difference from the old "No sessions
        // found — point at an Alphaprog CSV export" about a file that WAS one.
        let hevy = "title,start_time,exercise_title,weight_kg,reps\nMorning,12 Jun 2026 18:30,Squat,100,5\n"
        let p = AlphaprogImporter.parse(hevy, timeZone: zone)
        XCTAssertTrue(p.workouts.isEmpty)
        XCTAssertEqual(p.diagnostics.sessionHeaders, 0)
        XCTAssertEqual(p.diagnostics.exerciseTitles, 0)
        XCTAssertEqual(p.diagnostics.firstLine, "title,start_time,exercise_title,weight_kg,reps")
    }

    func testAnEmptyDocumentReportsNothingSeenRatherThanNothingThere() {
        let p = AlphaprogImporter.parse("", timeZone: zone)
        XCTAssertTrue(p.workouts.isEmpty)
        XCTAssertEqual(p.diagnostics.sessionHeaders, 0)
        XCTAssertEqual(p.diagnostics.firstLine, "")
        XCTAssertEqual(p.diagnostics.delimiter, ";", "an empty file keeps the German default")
    }

    // MARK: - Same file, other encoding

    func testTheSameContentAsUTF16LEParsesIdentically() {
        // The point of one shared decode helper: a file cannot read in one importer and come back empty
        // in another because a Windows tool saved it as UTF-16.
        let asUTF8 = text()
        let utf16 = Data([0xFF, 0xFE]) + asUTF8.data(using: .utf16LittleEndian)!
        guard let decoded = ImportText.decode(utf16) else { return XCTFail("utf-16le must decode") }
        XCTAssertEqual(decoded.encodingName, "utf-16le")
        XCTAssertEqual(decoded.text, asUTF8)
        // Whole-result equality, so a difference anywhere — a lost session, a shifted volume, a changed
        // diagnostic — fails here.
        XCTAssertEqual(AlphaprogImporter.parse(decoded.text, timeZone: zone),
                       AlphaprogImporter.parse(asUTF8, timeZone: zone))
    }

    // MARK: - Delimiter tolerance

    func testTheSemicolonFixtureIsUnaffectedByTheDelimiterSniff() {
        // The guard on the whole feature: the grid header names the delimiter outright, so the file in
        // hand is decided on its third line and reads exactly as it did before the sniff existed.
        XCTAssertEqual(AlphaprogImporter.sniffDialect(text()), .german)
    }

    func testACommaDelimitedExportIsReadWithDotDecimals() {
        // Another locale's Alphaprog: `,` separates the fields, so the decimal mark has to be `.`.
        // Stripping dots the way the German reading does would turn 27.5 kg into 275 kg.
        let commaFile = [
            "\"Upper A (Mo) · Einzelnes Workout\",\"2026-09-25 11:50 Uhr\",\"1:42 Std.\"",
            "\"1. Brustpresse · Maschine · 10 Wdh\"",
            "#,KG,WDH",
            "1,75,12",
            "2,27.5,8",
            "3,-,-",
        ].joined(separator: "\r\n")
        XCTAssertEqual(AlphaprogImporter.sniffDialect(commaFile), .dotted)

        let p = AlphaprogImporter.parse(commaFile, timeZone: zone)
        XCTAssertEqual(p.diagnostics.delimiter, ",")
        XCTAssertEqual(p.workouts.count, 1)
        guard let press = p.workouts.first?.exercises.first else { return XCTFail("no exercise") }
        XCTAssertEqual(press.name, "Brustpresse")
        XCTAssertEqual(press.sets.count, 2, "the dash row did not happen")
        XCTAssertEqual(press.sets.map(\.weightKg), [75, 27.5])
        XCTAssertEqual(p.workouts[0].volumeLoadKg, 75 * 12 + 27.5 * 8, accuracy: 1e-9)
    }

    func testTheDottedDialectStillRefusesADash() {
        XCTAssertNil(AlphaprogImporter.number("-", decimalComma: false))
        XCTAssertEqual(AlphaprogImporter.number("27.5", decimalComma: false) ?? 0, 27.5, accuracy: 1e-9)
        // And the German reading is untouched.
        XCTAssertEqual(AlphaprogImporter.number("1.234,5", decimalComma: true) ?? 0, 1234.5, accuracy: 1e-9)
    }
}
