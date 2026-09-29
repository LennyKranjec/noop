import Foundation
import WhoopProtocol

// BreathSessionOutcome.swift — an honest before/after for a breathing session (HEALTH_V2 S4 §4.2).
//
// WHAT WAS WRONG (H10). The old outcome was "+X % vs start · peak Y ms": an UNCLEANED 30-beat RMSSD,
// compared with whatever value existed when Start was tapped (sometimes 2 beats), with the session's
// highest rolling value cherry-picked as "peak". Slow breathing raises RMSSD mechanically while it is
// being done (respiratory sinus arrhythmia), so an in-session figure is mostly the breathing pattern
// itself (Laborde 2022), not an effect.
//
// WHAT THIS DOES INSTEAD:
//   * Two QUIET windows, before and after, with normal breathing and no pacer: 90 s each, the first 30 s
//     dropped as settling, so each reading is a 60 s window.
//   * Each window is cleaned by the shared pipeline (`HRVAnalyzer`: range filter 300–2000 ms, Malik 20 %
//     local-median ectopic rejection, gap-aware RMSSD — a difference across a dropped beat is skipped).
//   * Each window has its own gate: ≥ 40 clean beats AND ≤ 20 % rejected. Stricter than the spot
//     reading's 35 %, because two short windows are being compared and noise in either one is doubled
//     in the difference.
//   * The change is reported only when BOTH windows pass: deltaPct = 100 × (exp(ln post − ln pre) − 1),
//     computed in the log domain (so +x % one way and the reverse are symmetric in ln), plus Δ HR.
//   * DURING: the mean per-cycle HR swing (`ResonanceEngine.scorePace` RSA over the paced beats), always
//     labelled as the breathing itself and NEVER mixed into the change.
//   * No peak, ever.
//   * Personal comparison only after ≥ 5 stored sessions: larger / similar / smaller than the wearer's
//     own interquartile range of past changes. Descriptive, not a test.
//
// Pure, deterministic, DB-free. Swift-only engine.

public enum BreathSessionOutcome {

    // MARK: - Constants

    /// Length of each quiet reading (s).
    public static let quietSeconds: Int = 90
    /// Leading settling time dropped from each quiet window (s) — the same 30 s transient
    /// `ResonanceEngine` drops from each paced candidate.
    public static let settleSeconds: Int = 30
    /// Clean beats a quiet window needs. At a resting 60 bpm a 60 s window holds ~60 beats; 40 leaves room
    /// for a few rejections while refusing a window that lost a third of its beats.
    public static let minCleanBeats: Int = 40
    /// Rejected share (range + ectopic) above which a window is too noisy to compare.
    public static let maxRejectedFraction: Double = 0.20
    /// HR samples needed to report the window's mean HR from the HR stream; otherwise from the clean beats.
    public static let minHrSamples: Int = 10
    /// Stored sessions needed before the personal comparison line appears.
    public static let minSessionsForComparison: Int = 5

    // MARK: - Types

    /// Why a quiet window has no reading.
    public enum Abstention: String, Codable, Equatable, Sendable {
        /// The strap sent no beat-to-beat data during the window.
        case noLiveRR
        /// The window ended before its 90 s (the session was stopped early).
        case windowTooShort
        /// Fewer than 40 clean beats survived.
        case tooFewBeats
        /// More than 20 % of the beats were rejected as artefacts.
        case tooManyArtifacts

        public var text: String {
            switch self {
            case .noLiveRR:
                return "The strap isn't sending beat-to-beat data right now — on a 5/MG this happens while the "
                    + "WHOOP app is also connected."
            case .windowTooShort:
                return "The quiet reading was stopped before its 90 seconds."
            case .tooFewBeats:
                return "Too few clean beats — the strap's beat-to-beat signal dropped out."
            case .tooManyArtifacts:
                return "Too many irregular beats to trust this reading — sit still and try again."
            }
        }
    }

    /// One quiet window's raw input.
    public struct QuietWindow: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let rr: [ResonanceEngine.RrBeat]
        public let hr: [HRSample]

        public init(startTs: Int, endTs: Int, rr: [ResonanceEngine.RrBeat], hr: [HRSample] = []) {
            self.startTs = startTs
            self.endTs = endTs
            self.rr = rr
            self.hr = hr
        }
    }

    /// One quiet window's result: a reading or an abstention, never both.
    public struct QuietReading: Codable, Equatable, Sendable {
        public let rmssd: Double?
        public let meanHr: Double?
        public let cleanBeats: Int
        public let inputBeats: Int
        /// Rejected share in percent (0–100), nil with no input.
        public let rejectedPct: Double?
        public let abstention: Abstention?

        public var passed: Bool { abstention == nil && rmssd != nil }
    }

    public struct Change: Codable, Equatable, Sendable {
        public let deltaPct: Double
        public let deltaHr: Double?
    }

    public enum ComparisonLabel: String, Codable, Equatable, Sendable {
        case larger, similar, smaller
    }

    public struct PersonalComparison: Codable, Equatable, Sendable {
        public let label: ComparisonLabel
        /// Median of past changes (%).
        public let usualDeltaPct: Double
        public let q1: Double
        public let q3: Double
        public let sessions: Int
    }

    /// A whole session's outcome.
    public struct Result: Codable, Equatable, Sendable {
        public let pre: QuietReading
        public let post: QuietReading
        /// Present only when both quiet windows passed their gates.
        public let change: Change?
        /// Mean per-cycle HR swing during the paced part (bpm). Mechanical; never part of `change`.
        public let duringSwingBpm: Double?
        public let paceBpm: Double
    }

    // MARK: - One quiet window

    /// Clean and gate one quiet window. Only beats inside `[startTs + 30, endTs]` are read, so beats from
    /// the paced phase can never enter a quiet reading, whatever the caller passes.
    public static func reading(_ w: QuietWindow) -> QuietReading {
        guard w.endTs - w.startTs >= quietSeconds else {
            return QuietReading(rmssd: nil, meanHr: nil, cleanBeats: 0, inputBeats: 0, rejectedPct: nil,
                                abstention: .windowTooShort)
        }
        let from = w.startTs + settleSeconds
        // Stable order by ts (RMSSD is successive differences; same-second beats keep arrival order).
        let beats = w.rr.enumerated()
            .filter { $0.element.ts >= from && $0.element.ts <= w.endTs }
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
            .map { Double($0.element.rrMs) }
        guard !beats.isEmpty else {
            return QuietReading(rmssd: nil, meanHr: nil, cleanBeats: 0, inputBeats: 0, rejectedPct: nil,
                                abstention: .noLiveRR)
        }
        let clean = HRVAnalyzer.cleanRRGapAware(beats).nn.count
        let rejected = 1.0 - Double(clean) / Double(beats.count)
        let rejectedPct = rejected * 100
        guard clean >= minCleanBeats else {
            return QuietReading(rmssd: nil, meanHr: nil, cleanBeats: clean, inputBeats: beats.count,
                                rejectedPct: rejectedPct, abstention: .tooFewBeats)
        }
        guard rejected <= maxRejectedFraction else {
            return QuietReading(rmssd: nil, meanHr: nil, cleanBeats: clean, inputBeats: beats.count,
                                rejectedPct: rejectedPct, abstention: .tooManyArtifacts)
        }
        let result = HRVAnalyzer.analyze(rawRR: beats)
        guard let rmssd = result.rmssd, rmssd > 0 else {
            return QuietReading(rmssd: nil, meanHr: nil, cleanBeats: clean, inputBeats: beats.count,
                                rejectedPct: rejectedPct, abstention: .tooFewBeats)
        }
        let hrIn = w.hr.filter { $0.ts >= from && $0.ts <= w.endTs && $0.bpm > 0 }
        let meanHr: Double?
        if hrIn.count >= minHrSamples {
            meanHr = Double(hrIn.reduce(0) { $0 + $1.bpm }) / Double(hrIn.count)
        } else {
            meanHr = SpotHrvReading.meanHrFromNN(result.meanNN)
        }
        return QuietReading(rmssd: rmssd, meanHr: meanHr, cleanBeats: clean, inputBeats: beats.count,
                            rejectedPct: rejectedPct, abstention: nil)
    }

    // MARK: - Change

    /// Percent change computed in the log domain: 100 × (exp(ln post − ln pre) − 1).
    public static func deltaPct(pre: Double, post: Double) -> Double? {
        guard pre > 0, post > 0, pre.isFinite, post.isFinite else { return nil }
        return 100 * (exp(log(post) - log(pre)) - 1)
    }

    /// Evaluate a whole session.
    ///
    /// - Parameters:
    ///   - pacedRR: beats from the paced phase only; used for the DURING swing and nothing else.
    ///   - pacedStartTs / pacedEndTs: bounds of the paced phase.
    public static func evaluate(pre: QuietWindow, pacedRR: [ResonanceEngine.RrBeat], pacedStartTs: Int,
                                pacedEndTs: Int, post: QuietWindow, paceBpm: Double) -> Result {
        let a = reading(pre)
        let b = reading(post)
        var change: Change? = nil
        if a.passed, b.passed, let r0 = a.rmssd, let r1 = b.rmssd, let d = deltaPct(pre: r0, post: r1) {
            var dHr: Double? = nil
            if let h0 = a.meanHr, let h1 = b.meanHr { dHr = h1 - h0 }
            change = Change(deltaPct: d, deltaHr: dHr)
        }
        var swing: Double? = nil
        if paceBpm > 0, pacedEndTs > pacedStartTs {
            let score = ResonanceEngine.scorePace(ResonanceEngine.PaceSample(
                bpm: paceBpm, rr: pacedRR, startTs: pacedStartTs, endTs: pacedEndTs))
            swing = score.rsaAmplitude
        }
        return Result(pre: a, post: b, change: change, duringSwingBpm: swing, paceBpm: paceBpm)
    }

    // MARK: - Personal comparison

    /// Linear-interpolated quantile (type 7) of a sorted, non-empty array.
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let h = Double(sorted.count - 1) * p
        let lo = Int(h.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// larger / similar / smaller than the wearer's own past changes, or nil below 5 past sessions.
    public static func compare(deltaPct: Double, past: [Double]) -> PersonalComparison? {
        let xs = past.filter { $0.isFinite }.sorted()
        guard xs.count >= minSessionsForComparison else { return nil }
        let q1 = quantile(xs, 0.25), med = quantile(xs, 0.5), q3 = quantile(xs, 0.75)
        let label: ComparisonLabel = deltaPct > q3 ? .larger : (deltaPct < q1 ? .smaller : .similar)
        return PersonalComparison(label: label, usualDeltaPct: med, q1: q1, q3: q3, sessions: xs.count)
    }

    // MARK: - Lines

    /// "RMSSD 38 ms · HR 66", or "—" with the reason.
    public static func line(_ r: QuietReading) -> String {
        guard r.passed, let rmssd = r.rmssd else { return "— " + (r.abstention?.text ?? "") }
        let hr = r.meanHr.map { " · HR \(Int($0.rounded()))" } ?? ""
        return "RMSSD \(Int(rmssd.rounded())) ms" + hr
    }

    /// "(+15 %, −4 bpm)", nil when either window failed.
    public static func changeLine(_ c: Change?) -> String? {
        guard let c else { return nil }
        let pct = Int(c.deltaPct.rounded())
        var s = "(\(pct >= 0 ? "+" : "−")\(abs(pct)) %"
        if let d = c.deltaHr {
            let bpm = Int(d.rounded())
            s += ", \(bpm >= 0 ? "+" : "−")\(abs(bpm)) bpm"
        }
        return s + ")"
    }

    public static func duringLine(_ swing: Double?) -> String {
        guard let swing else { return "During — not enough clean beats to measure the breathing swing" }
        return "During  breathing-driven swing \(Int(swing.rounded())) bpm — this is expected to be high; it is "
            + "the breathing itself"
    }

    public static func comparisonLine(_ c: PersonalComparison?) -> String? {
        guard let c else { return nil }
        let usual = Int(c.usualDeltaPct.rounded())
        let word: String
        switch c.label {
        case .larger: word = "a larger"
        case .similar: word = "a similar"
        case .smaller: word = "a smaller"
        }
        return "\(word) change than your usual (\(usual >= 0 ? "+" : "−")\(abs(usual)) %)"
    }
}
