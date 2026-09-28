import Foundation
import XCTest
@testable import StrandImport

/// `ImportText` / `ImportFileRead` — the bytes-to-lines seam every text importer now shares.
///
/// THESE PIN A BUG THAT LOOKED LIKE DATA. The Alphaprog import "suddenly stopped working" after the
/// wearer reset their phone and reinstalled: the file was unchanged and parses to 100 sessions, but on a
/// freshly restored device every iCloud Drive file is a placeholder, `Data(contentsOf:)` handed back
/// nothing, `?? ""` made that an empty document, and the screen said "No sessions found — point at an
/// Alphaprog CSV export" about an Alphaprog CSV export.
///
/// So the three outcomes that used to collapse into one sentence are asserted here separately: text
/// that decodes (in any of five encodings), a file with no bytes, and bytes that are not text at all.
/// The last one is the reason `decode` can return nil: latin-1 maps all 256 byte values, so a fallback
/// reached unconditionally would turn a JPEG into a document that parses to zero sessions — identical,
/// on screen, to the wearer's real export failing to arrive.
final class ImportTextTests: XCTestCase {

    // MARK: - Decoding

    func testEmptyBytesAreEmptyTextAndNotAFailure() {
        // Empty is a RESULT, not an encoding problem: the caller checks the byte count so it can say
        // "that file is empty" rather than "that file is not text". nil here would collapse them again.
        let decoded = ImportText.decode(Data())
        XCTAssertEqual(decoded?.text, "")
        XCTAssertEqual(decoded?.encodingName, "empty")
    }

    func testUTF8WithABomAndCRLFArrivesAsPlainLines() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("a;b\r\nc;d\r\n".utf8)
        guard let decoded = ImportText.decode(bytes) else { return XCTFail("utf-8 must decode") }
        XCTAssertEqual(decoded.encodingName, "utf-8")
        // No BOM survives into the first line, and no `\r` survives into any of them: a parser that
        // splits on "\n" must not have to know either exists.
        XCTAssertEqual(decoded.text, "a;b\nc;d\n")
    }

    func testALoneCarriageReturnIsAlsoALineBreak() {
        // A classic-Mac / some-spreadsheet export. Left as-is, a `split(separator: "\n")` reader sees
        // ONE line holding the whole file — which parses to nothing, honestly and uselessly.
        guard let decoded = ImportText.decode(Data("a;b\rc;d".utf8)) else { return XCTFail("must decode") }
        XCTAssertEqual(decoded.text, "a;b\nc;d")
    }

    func testUTF16WithABomDecodes() {
        let source = "\"Titel\";\"2026-09-25 11:50 Uhr\";\"53 Min.\"\n#;KG;WDH\n1;27,5;9\n"
        for (name, encoding, bom) in [("utf-16le", String.Encoding.utf16LittleEndian, Data([0xFF, 0xFE])),
                                      ("utf-16be", String.Encoding.utf16BigEndian, Data([0xFE, 0xFF]))] {
            let bytes = bom + source.data(using: encoding)!
            guard let decoded = ImportText.decode(bytes) else { return XCTFail("\(name) must decode") }
            XCTAssertEqual(decoded.encodingName, name)
            XCTAssertEqual(decoded.text, source)
        }
    }

    func testUTF16WithoutABomIsNotMisreadAsUTF8() {
        // THE ORDERING TEST. U+0000 is legal UTF-8, so `String(data:encoding:.utf8)` ACCEPTS a BOM-less
        // UTF-16 file and returns a NUL-riddled ghost of it — text, of a sort, that parses to nothing.
        // The parity sniff therefore runs BEFORE the UTF-8 attempt.
        let source = "#;KG;WDH\n1;30;10\n"
        for (name, encoding) in [("utf-16le", String.Encoding.utf16LittleEndian),
                                 ("utf-16be", String.Encoding.utf16BigEndian)] {
            guard let decoded = ImportText.decode(source.data(using: encoding)!) else {
                return XCTFail("\(name) must decode")
            }
            XCTAssertEqual(decoded.encodingName, name)
            XCTAssertEqual(decoded.text, source)
            XCTAssertFalse(decoded.text.contains("\0"), "a NUL in the text means UTF-8 won the race")
        }
    }

    func testAUTF8FileIsNeverMistakenForUTF16() {
        // The other half of that ordering: a plain UTF-8 export has no NULs, so the parity sniff must
        // decline it. (An odd byte count alone would not be enough — this one is even.)
        let source = "1;30;10\n"
        XCTAssertNil(ImportText.headlessUTF16Endianness(Data(source.utf8)))
        XCTAssertEqual(ImportText.decode(Data(source.utf8))?.encodingName, "utf-8")
    }

    func testWindows1252UmlautDecodes() {
        // A single-byte German export: 0xFC is "ü" in cp1252 and INVALID UTF-8 on its own, so UTF-8
        // rejects the file outright and the codepage fallback is the only honest reading.
        var bytes = Data("\"1. K".utf8)
        bytes.append(0xF6)                      // ö
        bytes.append(Data("rpergewicht f".utf8))
        bytes.append(0xFC)                      // ü
        bytes.append(Data("r B".utf8))
        bytes.append(0xE4)                      // ä
        bytes.append(Data("nke\"\n".utf8))

        XCTAssertNil(String(data: bytes, encoding: .utf8), "the fixture must not be valid UTF-8")
        guard let decoded = ImportText.decode(bytes) else { return XCTFail("cp1252 must decode") }
        XCTAssertEqual(decoded.encodingName, "windows-1252")
        XCTAssertEqual(decoded.text, "\"1. Körpergewicht für Bänke\"\n")
    }

    func testBinaryIsRefusedRatherThanGuessedAtAsText() {
        // A PNG header. latin-1 would happily "decode" it, and the Alphaprog parser would then find zero
        // sessions in it — the SAME message as a file that never downloaded. Returning nil is what lets
        // the screen say "that isn't text" instead.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
                            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0xF3, 0xFF]
        XCTAssertNil(ImportText.decode(Data(png)))
    }

    func testUndecodableBytesCannotProduceASession() {
        // The honesty end of it: whatever the bytes are, nothing may reach the store. `decode` refuses,
        // so the parser is never handed a string at all — and if a caller forced one through, the parser
        // still finds nothing rather than inventing a day.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
                        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0xF3, 0xFF])
        XCTAssertNil(ImportText.decode(png))
        let forced = String(data: png, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(AlphaprogImporter.parse(forced).workouts.isEmpty)
    }

    // MARK: - Reading the file

    func testAZeroByteFileReadsAsEmptyRatherThanThrowing() async throws {
        // The placeholder case, expressed without iCloud: a file that exists and holds nothing. The read
        // must SUCCEED and report zero bytes, because that is what lets the screen say "empty or not
        // downloaded yet" instead of either "import failed" or "no sessions found".
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-empty-\(UUID().uuidString).csv")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try await ImportFileRead.read(url)
        XCTAssertTrue(outcome.data.isEmpty)
        XCTAssertFalse(outcome.downloadPending, "a local temp file is not an iCloud placeholder")
        XCTAssertFalse(outcome.waitedForDownload, "and must not buy a download wait")
        XCTAssertTrue(outcome.logDetail.hasPrefix("0 bytes"), outcome.logDetail)
        // And the byte count is what the caller branches on — not a nil decode.
        XCTAssertEqual(ImportText.decode(outcome.data)?.text, "")
    }

    func testARealFileReadsItsBytes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-bytes-\(UUID().uuidString).csv")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("#;KG;WDH\r\n1;30;10\r\n".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try await ImportFileRead.read(url)
        XCTAssertEqual(outcome.data.count, bytes.count)
        XCTAssertEqual(ImportText.decode(outcome.data)?.text, "#;KG;WDH\n1;30;10\n")
    }

    func testAMissingFileThrowsRatherThanReadingEmpty() async {
        // "Import failed: …" and "that file is empty" are different sentences and must stay that way.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-absent-\(UUID().uuidString).csv")
        do {
            let outcome = try await ImportFileRead.read(url)
            XCTFail("a missing file must throw, not read \(outcome.data.count) bytes")
        } catch {
            // expected
        }
    }
}
