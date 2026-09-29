import Foundation
import StrandAnalytics

/// A body-evaluation census for the Display & Performance test mode.
///
/// WHY THIS EXISTS. "It feels laggy" has two very different causes in this app, and reading the source
/// cannot tell them apart: a body that is EXPENSIVE, and a body that is cheap but re-evaluated far more
/// often than anybody intended. The second is the one this codebase keeps producing — a high-rate
/// publisher (`LiveState` at the frame cadence, `AppModel` on the 1 Hz HR tick, `Repository` on every
/// refresh) reaching a screen-sized body through an `@EnvironmentObject` — and the fix for it is always
/// "move the observation into a leaf", which is only worth doing where it is actually happening.
///
/// The existing `DisplayPerformanceMonitor` reports FRAME times, and only while the Test Centre screen is
/// itself on screen, so it can say that Today stuttered but never which body ran 60 times a second while
/// it did. This fills exactly that gap and nothing more: a count of how many times each named body was
/// evaluated, summarised once a second into the SAME `.display` trace the Display & Performance report
/// already collects.
///
/// COST WHEN OFF: one `UserDefaults` Bool read per body pass (`TestCentre.active`), the same zero-cost
/// gate every other tagged emitter in the app checks before building anything. No timer, no allocation,
/// no retained state — the window is flushed by the next `note` that finds it expired, so nothing keeps
/// ticking once rendering stops.
///
/// IT MEASURES ONLY. Nothing here feeds a rendered value, so a body that calls it draws the same pixels
/// whether the mode is on or off.
@MainActor
enum RenderTrace {

    /// How long a window of counts is summarised over. One second, so a line reads directly as "passes
    /// per second" against the 60 Hz the frame trace is quoted in.
    private static let window: TimeInterval = 1

    private static var counts: [String: Int] = [:]
    private static var windowStart: Date?

    /// Record one evaluation of the body named `name`, and emit the window's summary when it is due.
    ///
    /// Call it as the FIRST thing in a `body`, as `let _ = RenderTrace.note(...)` — a `body` is a
    /// `@ViewBuilder`, which takes declarations but not bare calls.
    ///
    /// `name` is a `StaticString` so a call site cannot pass an interpolated string and make the gated-off
    /// path pay to build one; keying the window costs an allocation, but only while the mode is on.
    ///
    /// Returns this body's count so far in the current window, which makes the `let _ =` bind something
    /// (a `Void` binding warns) and is occasionally useful in a debugger. Nothing reads it.
    @discardableResult
    static func note(_ name: StaticString) -> Int {
        guard TestCentre.active(.display) else {
            // Leaving the mode drops whatever was banked, so turning it back on starts a clean window
            // rather than reporting a count accumulated across an untimed gap.
            if windowStart != nil { counts.removeAll(); windowStart = nil }
            return 0
        }
        let now = Date()
        let key = "\(name)"
        guard let start = windowStart else {
            windowStart = now
            counts[key] = 1
            return 1
        }
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        guard now.timeIntervalSince(start) >= window else { return n }
        flush(elapsed: now.timeIntervalSince(start))
        windowStart = now
        return n
    }

    /// One line per window, busiest body first, so the worst offender is the first thing read.
    ///
    /// Emitted through `LiveState.append(log:domain:)` — the single log sink the Test Centre export reads
    /// and the only place PII redaction happens. A body name is a Swift type name, so there is nothing
    /// here for the scrub to find; it goes through the sink anyway because every tagged line does.
    private static func flush(elapsed: TimeInterval) {
        defer { counts.removeAll() }
        guard !counts.isEmpty, let live = AppModel.shared?.live else { return }
        // Descending by count, then by name, so two equally busy bodies print in a stable order rather
        // than in the dictionary's.
        let ordered = counts.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        let bodies = ordered.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        live.append(log: String(format: "renderPasses window=%.2fs ", elapsed) + bodies, domain: .display)
    }
}
