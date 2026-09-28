import Foundation

// ImportText.swift — the one place a picked file's BYTES become text, and the one place a picked
// file's bytes are READ.
//
// WHY THIS EXISTS. Every text importer used to write its own `String(data: data, encoding: .utf8)
// ?? ""`, which has two failure modes that look identical from the screen:
//
//   1. The bytes were not UTF-8 (a Windows tool wrote UTF-16, or cp1252), so the decode returned nil,
//      `?? ""` turned that into an empty document, and the parser honestly reported "nothing in it".
//      The wearer was told to point at a different file; the file was fine.
//   2. The bytes were never there. On iOS a file picked out of iCloud Drive can be a PLACEHOLDER: the
//      name and size are in Files, the contents are not on the device. `Data(contentsOf:)` then hands
//      back nothing (or throws), and the same "nothing in it" message appears — most likely right
//      after a restore or a reinstall, when every iCloud file on the device is a placeholder again.
//
// The two are different problems with different fixes, so they are reported differently and the
// second one is now actually resolved rather than only named: the read goes through
// `NSFileCoordinator`, which MATERIALISES a placeholder, and when the item is still not downloaded it
// asks for the download and waits a bounded few seconds before trying once more.
//
// NEVER GUESS TEXT OUT OF BYTES. `decode` returns nil rather than a best effort when nothing decodes,
// because a mojibake document parses to zero sessions exactly like an empty one does, and the wearer
// deserves to be told which. The one deliberate "last resort" is cp1252/latin-1, which cannot fail —
// but it is reached only after every self-describing encoding has been ruled out, and the encoding it
// used is reported so a wrong guess is visible rather than silent.

public enum ImportText {

    /// Decoded text plus the name of the encoding that worked, which is the single most useful fact in
    /// a failure report: "0 sessions, 80 696 bytes, utf-8" and "0 sessions, 80 696 bytes, utf-16le"
    /// point at completely different bugs.
    public struct Decoded: Equatable, Sendable {
        public let text: String
        public let encodingName: String

        public init(text: String, encodingName: String) {
            self.text = text
            self.encodingName = encodingName
        }
    }

    /// Decode a picked file's bytes, newline-normalised and BOM-free.
    ///
    /// Returns nil ONLY when no encoding produced text at all. Empty input is not a failure — it is
    /// empty text, and the caller checks the byte count itself so it can say "the file is empty"
    /// rather than "the file is not text".
    ///
    /// THE ORDER MATTERS, and not for taste:
    ///
    ///   * A UTF-16/UTF-32 BOM is checked FIRST, by byte, because `.utf16` accepts `FF FE` as a
    ///     little-endian mark and would read a UTF-32LE file (`FF FE 00 00`) as UTF-16 full of NULs.
    ///   * HEADLESS UTF-16 COMES BEFORE UTF-8, which looks backwards and is the whole point: an ASCII
    ///     document in 16-bit cells is `L \0 o \0 w \0`, and U+0000 is perfectly legal UTF-8 — so UTF-8
    ///     ACCEPTS a BOM-less UTF-16 file and returns a NUL-riddled ghost of it. The parity test below
    ///     needs NULs on exactly one parity and a quarter of the bytes to be NUL, which no real UTF-8
    ///     text can satisfy (it has no NULs at all), so nothing legitimate is diverted here.
    ///   * cp1252 before latin-1: cp1252 is latin-1 with the 0x80–0x9F control block filled in with
    ///     the punctuation Windows exporters actually emit, so it decodes a superset correctly.
    ///   * AND THE SINGLE-BYTE FALLBACK IS GATED. latin-1 maps all 256 byte values, so reaching it
    ///     unconditionally would mean this function can never return nil — every JPEG would become
    ///     "text" and every parser would report "nothing in it" instead of "that is not a CSV". The gate
    ///     is the one thing a text export never contains: NUL bytes and a mass of C0 controls.
    public static func decode(_ data: Data) -> Decoded? {
        guard !data.isEmpty else { return Decoded(text: "", encodingName: "empty") }

        // Self-describing byte-order marks, widest first.
        if let (encoding, name) = bomEncoding(data),
           let s = String(data: data, encoding: encoding) {
            return finish(s, name)
        }
        // Headless UTF-16, only where the byte pattern leaves no real doubt.
        if let endian = headlessUTF16Endianness(data),
           let s = String(data: data, encoding: endian == .little ? .utf16LittleEndian : .utf16BigEndian) {
            return finish(s, endian == .little ? "utf-16le" : "utf-16be")
        }
        // UTF-8, with or without its own BOM (stripped either way by `finish`).
        if let s = String(data: data, encoding: .utf8) {
            return finish(s, "utf-8")
        }
        // Last resort: a single-byte codepage. Said out loud, because it cannot fail on any byte it is
        // actually offered — which is why it is offered so little.
        guard looksLikeSingleByteText(data) else { return nil }
        if let s = String(data: data, encoding: .windowsCP1252) {
            return finish(s, "windows-1252")
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return finish(s, "iso-8859-1")
        }
        return nil
    }

    /// Whether these bytes are plausibly a single-byte-encoded TEXT document.
    ///
    /// A NUL disqualifies outright: no text export contains one, and its presence means this is either
    /// binary or a 16-bit encoding the checks above already declined. Beyond that, more than a twentieth
    /// of the sample being C0 control characters (tab, CR and LF excepted, since those are the file's
    /// own structure) is binary too.
    static func looksLikeSingleByteText(_ data: Data) -> Bool {
        var controls = 0
        var sampled = 0
        for byte in data.prefix(4096) {
            sampled += 1
            if byte == 0x00 { return false }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { controls += 1 }
        }
        guard sampled > 0 else { return false }
        return controls * 20 <= sampled
    }

    /// Strip a surviving BOM and make every line terminator a lone `\n`, so no downstream parser has to
    /// know about CRLF. Alphaprog writes CRLF; classic Mac tools and some spreadsheet exports write a
    /// lone CR, which a `split(separator: "\n")` reader sees as ONE enormous line.
    private static func finish(_ raw: String, _ name: String) -> Decoded {
        var s = raw
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        if s.contains("\r") {
            s = s.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")
        }
        return Decoded(text: s, encodingName: name)
    }

    private static func bomEncoding(_ data: Data) -> (String.Encoding, String)? {
        let b = [UInt8](data.prefix(4))
        // UTF-32 before UTF-16: `FF FE 00 00` starts with the UTF-16LE mark.
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0x00, b[3] == 0x00 { return (.utf32, "utf-32le") }
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0xFE, b[3] == 0xFF { return (.utf32, "utf-32be") }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return (.utf16, "utf-16le") }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return (.utf16, "utf-16be") }
        return nil
    }

    enum Endianness { case little, big }

    /// Whether these bytes look like BOM-less UTF-16, and which way round.
    ///
    /// Only ASCII-ish text is detectable this way: in UTF-16LE every ASCII character is `xx 00`, so the
    /// NULs land on ODD indices; in UTF-16BE they land on EVEN ones. A file with no NULs at all is not
    /// UTF-16 text, and a file with NULs on both parities is not text this can read.
    ///
    /// The QUARTER threshold is what keeps this from stealing a UTF-8 file: ASCII in 16-bit cells is
    /// half NULs, and a text file that is a quarter NUL on one parity by accident does not exist.
    static func headlessUTF16Endianness(_ data: Data) -> Endianness? {
        guard data.count >= 4, data.count % 2 == 0 else { return nil }
        var oddNULs = 0, evenNULs = 0
        // A prefix is enough to decide, and keeps this O(1) on a large export.
        let sample = data.prefix(4096)
        for (offset, byte) in sample.enumerated() where byte == 0x00 {
            if offset % 2 == 0 { evenNULs += 1 } else { oddNULs += 1 }
        }
        let sampled = sample.count
        guard (oddNULs + evenNULs) * 4 >= sampled else { return nil }
        if oddNULs > 0 && evenNULs == 0 { return .little }
        if evenNULs > 0 && oddNULs == 0 { return .big }
        return nil
    }
}

// MARK: - Reading the picked file

/// Reading a user-picked file's bytes in the one way that works for an iCloud placeholder.
///
/// This is the lightweight twin of `AppModel.materializeForImport`, which already coordinates the read
/// for the big archive imports (WHOOP / Apple Health / Mi Fitness). The small CSV importers did a bare
/// `Data(contentsOf:)`, so they were the only ones that could be handed nothing and not notice.
public enum ImportFileRead {

    /// What the read saw, including the facts a failure message needs.
    public struct Outcome: Sendable {
        public let data: Data
        /// Whether the read went through `NSFileCoordinator` (false on platforms without it).
        public let coordinated: Bool
        /// Whether the item reported itself as not-yet-downloaded from iCloud at any point.
        public let downloadPending: Bool
        /// Whether we asked for the download and waited for it before the final attempt.
        public let waitedForDownload: Bool

        public init(data: Data, coordinated: Bool, downloadPending: Bool, waitedForDownload: Bool) {
            self.data = data
            self.coordinated = coordinated
            self.downloadPending = downloadPending
            self.waitedForDownload = waitedForDownload
        }

        /// One privacy-safe phrase for the import log and the on-screen detail: counts and states only,
        /// never a path or a file name.
        public var logDetail: String {
            var parts = ["\(data.count) bytes"]
            if !coordinated { parts.append("uncoordinated") }
            if downloadPending { parts.append(waitedForDownload ? "icloud-waited" : "icloud-pending") }
            return parts.joined(separator: ", ")
        }
    }

    /// Read `url`, materialising an iCloud placeholder if that is what it is.
    ///
    /// `async` and deliberately NOT actor-isolated: a nonisolated async function runs on the
    /// concurrent executor, so the coordinated read (which blocks) and the download wait never run on
    /// the caller's main actor even though every call site is a `@MainActor` view Task.
    ///
    /// Throws only a real I/O or coordination failure — a file that read as ZERO bytes is a result, not
    /// an error, because "empty" and "could not be read" need different words on screen.
    public static func read(_ url: URL,
                           options: Data.ReadingOptions = [],
                           downloadWait: TimeInterval = 4) async throws -> Outcome {
        #if canImport(Darwin)
        var pending = isDownloadPending(url)
        var waited = false
        var data = try coordinatedRead(url, options: options)

        // The only case worth a second attempt: nothing came back AND the item is (or was) a
        // placeholder. A genuinely empty file must not buy a four-second stall.
        if data.isEmpty, pending {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            waited = true
            await waitForDownload(url, upTo: downloadWait)
            pending = isDownloadPending(url)
            data = (try? coordinatedRead(url, options: options)) ?? data
        }
        return Outcome(data: data, coordinated: true, downloadPending: pending, waitedForDownload: waited)
        #else
        let data = try Data(contentsOf: url, options: options)
        return Outcome(data: data, coordinated: false, downloadPending: false, waitedForDownload: false)
        #endif
    }

    #if canImport(Darwin)
    /// A coordinated read. `options: []` is the plain reading intent, which is what materialises a
    /// placeholder; `.forUploading` (used by the archive path) additionally snapshots, which a
    /// kilobyte-scale CSV does not need.
    private static func coordinatedRead(_ url: URL, options: Data.ReadingOptions) throws -> Data {
        var coordError: NSError?
        var ioError: Error?
        var out = Data()
        var ran = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            ran = true
            do { out = try Data(contentsOf: readURL, options: options) } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        // A coordinator that neither ran the accessor nor reported why would otherwise look exactly like
        // an empty file — the one confusion this whole file exists to remove. Read directly instead, and
        // let its own error be the one that surfaces.
        guard ran else { return try Data(contentsOf: url, options: options) }
        return out
    }

    /// Whether iCloud says the contents are not on this device yet.
    ///
    /// Read off the URL's resource values rather than through `NSMetadataQuery`: a metadata query over
    /// the ubiquitous scopes needs an iCloud container entitlement this app does not have, while a
    /// resource-value read on a URL the picker handed us needs nothing at all. A non-iCloud URL simply
    /// has no such value, and answers false.
    private static func isDownloadPending(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                       .isUbiquitousItemKey])
        guard let values else { return false }
        if let status = values.ubiquitousItemDownloadingStatus {
            return status != .current
        }
        // An iCloud item with no readable status is treated as pending; anything else is not.
        return values.isUbiquitousItem ?? false
    }

    /// Bounded, cancellable wait for the download to land. Polls the downloading status rather than
    /// spinning on the file's existence, and gives up on the deadline — an import must never hang.
    private static func waitForDownload(_ url: URL, upTo seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return }
            if !isDownloadPending(url) { return }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }  // cancelled
        }
    }
    #endif
}
