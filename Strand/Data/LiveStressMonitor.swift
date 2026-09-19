import Foundation
import StrandAnalytics

// LiveStressMonitor.swift — stress right now, for the warning beside the level.
//
// The last ten minutes against the day's own calm reference (`WindowStress.now`), read every five
// minutes while the app is in front. The reading is already motion-gated — ten minutes spent moving
// give no reading at all — so a high value here is stress at rest, not a walk up the stairs.
//
// THE DAY'S REFERENCE IS KEPT FOR A QUARTER OF AN HOUR, in `StressDayCurve.cachedToday`, shared with the
// Today stress tile. Re-scoring a whole day of heart rate every five minutes to measure ten of them would
// be the expensive half of the read; the calm reference barely moves within fifteen minutes.

@MainActor
final class LiveStressMonitor: ObservableObject {
    static let shared = LiveStressMonitor()

    /// At or above this, on the 0–3 scale, the level strip shows a red warning: the top third of the
    /// scale, where the stress ramp turns amber.
    static let highThreshold = 2.0

    @Published private(set) var level: Double?
    @Published private(set) var at: Date?
    /// E9: how many readings IN A ROW have been at or above `highThreshold` (a nil reading, or one under
    /// the line, resets it). One ten-minute window over the line is a phone call; two in a row — ten
    /// minutes apart, overlapping eight — is a state.
    @Published private(set) var consecutiveHigh = 0

    /// Set by the shell from the scene phase: nothing is read while the app is in the background.
    ///
    /// LEAVING THE FOREGROUND ENDS THE STREAK. Two high readings hours apart — one before the phone went
    /// in a pocket, one after it came out — are not "two in a row"; the warning needs a sustained spell.
    /// COMING BACK reads at once and restarts the five-minute cadence from there, so the strip is not
    /// showing a reading from before the app was left.
    var foreground = true {
        didSet {
            guard foreground != oldValue else { return }
            if foreground {
                restartLoop()
            } else {
                loop?.cancel()
                loop = nil
                consecutiveHigh = 0
            }
        }
    }

    private var repo: Repository?
    private var loop: Task<Void, Never>?

    /// Every five minutes. Two readings in a row decide a warning, so a spell is flagged after ~10 min.
    private static let every: UInt64 = 5 * 60
    static let everySeconds = TimeInterval(every)
    /// A reading further back than this is not the "previous" one of a streak: one and a half cadences,
    /// so a late tick still counts but a skipped one (or a suspended app) does not.
    static let streakGap = 1.5 * everySeconds

    /// Consecutive high readings needed before `isHigh` warns (E9).
    static let highReadingsRequired = 2

    /// The reading, while it is recent enough to warn about. Still the LATEST value, whatever came before
    /// it — for display and for the coach. Whether to WARN is `isHigh`.
    var current: Double? {
        guard let level, let at, Date().timeIntervalSince(at) < 15 * 60 else { return nil }
        return level
    }

    /// E9: whether to show the red warning — the current reading is high AND so was the one before it.
    /// A single high window no longer trips it.
    var isHigh: Bool {
        guard let current else { return false }
        return Self.isSustainedHigh(latest: current, consecutiveHigh: consecutiveHigh)
    }

    /// The warning rule, pure so it is testable without the five-minute loop.
    static func isSustainedHigh(latest: Double, consecutiveHigh: Int) -> Bool {
        latest >= highThreshold && consecutiveHigh >= highReadingsRequired
    }

    /// The streak after a new reading: +1 when it is at or above the line, else back to 0.
    static func nextConsecutiveHigh(_ streak: Int, reading: Double?) -> Int {
        guard let reading, reading >= highThreshold else { return 0 }
        return streak + 1
    }

    /// The streak after a new reading taken at `now`, when the previous one was taken at `previousAt`.
    /// A previous reading older than `streakGap` (or none) does not continue the streak: the new one
    /// starts it afresh.
    static func nextConsecutiveHigh(_ streak: Int, reading: Double?, previousAt: Date?, now: Date) -> Int {
        let continuing: Int
        if let previousAt, now.timeIntervalSince(previousAt) <= streakGap {
            continuing = streak
        } else {
            continuing = 0
        }
        return nextConsecutiveHigh(continuing, reading: reading)
    }

    func start(repo: Repository) {
        guard self.repo == nil else { return }
        self.repo = repo
        if foreground { restartLoop() }
    }

    /// Reads NOW, then every five minutes, until cancelled by leaving the foreground.
    private func restartLoop() {
        loop?.cancel()
        guard let repo else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.read(repo: repo)
                try? await Task.sleep(nanoseconds: Self.every * 1_000_000_000)
            }
        }
    }

    private func read(repo: Repository) async {
        // The day's calm reference: the SHARED curve (`StressDayCurve.cachedToday`), at most a quarter of
        // an hour old — the Today tile reads the same one, so the day is scored once for both.
        let hours = await StressDayCurve.cachedToday(repo: repo)?.result.hours ?? []
        let value = await WindowStress.now(repo: repo, dayHours: hours)
        // Cancelled mid-read (the app left the foreground): the streak was just reset; do not add to it.
        guard !Task.isCancelled, foreground else { return }
        let now = Date()
        consecutiveHigh = Self.nextConsecutiveHigh(consecutiveHigh, reading: value, previousAt: at, now: now)
        level = value
        at = value == nil ? nil : now
    }
}
