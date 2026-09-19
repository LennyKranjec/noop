import Foundation
import StrandAnalytics

// LiveStressMonitor.swift — stress right now, for the warning beside the level.
//
// The last ten minutes against the day's own calm reference (`WindowStress.now`), read every five
// minutes while the app is in front. The reading is already motion-gated — ten minutes spent moving
// give no reading at all — so a high value here is stress at rest, not a walk up the stairs.
//
// THE DAY'S REFERENCE IS KEPT FOR A QUARTER OF AN HOUR. Re-scoring a whole day of heart rate every five
// minutes to measure ten of them would be the expensive half of the read; the calm reference barely moves
// within fifteen minutes.

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
    var foreground = true

    private var running = false
    private var hours: [DaytimeStress.HourPoint] = []
    private var hoursAt: Date = .distantPast

    /// Every five minutes. Two readings in a row decide a warning, so a spell is flagged after ~10 min.
    private static let every: UInt64 = 5 * 60
    private static let hoursFor: TimeInterval = 15 * 60

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

    func start(repo: Repository) {
        guard !running else { return }
        running = true
        Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.foreground { await self.read(repo: repo) }
                try? await Task.sleep(nanoseconds: Self.every * 1_000_000_000)
            }
        }
    }

    private func read(repo: Repository) async {
        if hours.isEmpty || Date().timeIntervalSince(hoursAt) > Self.hoursFor {
            hours = await StressDayCurve.today(repo: repo)?.result.hours ?? []
            hoursAt = Date()
        }
        let value = await WindowStress.now(repo: repo, dayHours: hours)
        consecutiveHigh = Self.nextConsecutiveHigh(consecutiveHigh, reading: value)
        level = value
        at = value == nil ? nil : Date()
    }
}
