import Foundation
import StrandAnalytics

// LiveStressMonitor.swift — stress right now, for the warning beside the level.
//
// The last ten minutes against the day's own calm reference (`WindowStress.now`), read every two
// minutes while the app is in front. The reading is already motion-gated — ten minutes spent moving
// give no reading at all — so a high value here is stress at rest, not a walk up the stairs.
//
// THE DAY'S REFERENCE IS KEPT FOR A QUARTER OF AN HOUR. Re-scoring a whole day of heart rate every two
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

    /// Set by the shell from the scene phase: nothing is read while the app is in the background.
    var foreground = true

    private var running = false
    private var hours: [DaytimeStress.HourPoint] = []
    private var hoursAt: Date = .distantPast

    private static let every: UInt64 = 120
    private static let hoursFor: TimeInterval = 15 * 60

    /// The reading, while it is recent enough to warn about.
    var current: Double? {
        guard let level, let at, Date().timeIntervalSince(at) < 15 * 60 else { return nil }
        return level
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
        level = value
        at = value == nil ? nil : Date()
    }
}
