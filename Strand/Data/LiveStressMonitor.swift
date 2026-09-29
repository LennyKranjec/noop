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
//
// HEALTH_V2 H1 — "AT REST" ONLY WHEN IT WAS OBSERVED. `DaytimeStress.live` masks a window the wearer was
// MOVING in, but with no gravity at all for the window (a 4.0's coarse motion bank not synced yet) it had
// nothing to mask with and scored the window as if the wearer were still. The monitor now ABSTAINS when
// less than half of the ten minutes carries motion data (`minMotionCoverage`): no level, reason
// `noMotionEvidence`. No reading means no warning and no screen, so the full-screen alert's "while you
// were still" is only ever said when stillness was seen.
//
// THE FULL-SCREEN ALERT IS OFF BY DEFAULT (owner decision, 2026-09-29: "turn off the stress alerts").
// Measurement goes on — the level strip's warning, the Today tile, the widget, the coach all still read
// `current` — but the interruptive screen only pops up on its own for a wearer who switched it back on
// (`alertScreenEnabledKey`), at most `maxScreensPerDay` times a day on top of the shell's hourly cooldown.
// The diagnostic stays reachable by tapping the stress tile (`openDiagnostic()`).

@MainActor
final class LiveStressMonitor: ObservableObject {
    static let shared = LiveStressMonitor()

    /// Why the latest read produced no level even though the app was reading.
    enum Abstention: String, Equatable {
        /// Under half of the window has motion data, so "at rest" could not be observed.
        case noMotionEvidence
    }

    /// The least share of the ten-minute window that must carry motion data before a reading may claim
    /// the wearer was still (HEALTH_V2 H1a).
    static let minMotionCoverage = 0.5

    /// Set by the latest read: why it abstained, or nil when it produced a level (or had too little heart
    /// rate, which `WindowStress` already reports as nil).
    @Published private(set) var abstention: Abstention?

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
        let to = Int(Date().timeIntervalSince1970)
        let from = to - WindowStress.liveWindowSeconds
        var value = await WindowStress.level(repo: repo, from: from, to: to, dayHours: hours)
        var why: Abstention?
        // H1a: only a reading that exists needs its stillness checked — the gravity read is skipped
        // entirely when there is nothing to qualify.
        if value != nil {
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 6_000)
            if Self.motionCoverage(gravityTs: gravity.map(\.ts), from: from, to: to) < Self.minMotionCoverage {
                value = nil
                why = .noMotionEvidence
            }
        }
        // Cancelled mid-read (the app left the foreground): the streak was just reset; do not add to it.
        guard !Task.isCancelled, foreground else { return }
        let now = Date()
        consecutiveHigh = Self.nextConsecutiveHigh(consecutiveHigh, reading: value, previousAt: at, now: now)
        level = value
        abstention = why
        at = value == nil ? nil : now
    }

    // MARK: - H1a: motion coverage

    /// The share of whole minutes in `[from, to)` that hold at least one gravity sample, 0–1. Pure.
    static func motionCoverage(gravityTs: [Int], from: Int, to: Int) -> Double {
        let minutes = (to - from) / 60
        guard minutes > 0 else { return 0 }
        var covered = Set<Int>()
        for ts in gravityTs where ts >= from && ts < to {
            covered.insert((ts - from) / 60)
        }
        return Double(covered.count) / Double(minutes)
    }

    // MARK: - H1b: the words on the screen

    /// The band a reading falls in, in words — the same cut-points as the stress screen's bands
    /// (`StressBand`: under 1 low, under 2 moderate, else high).
    static func bandWord(_ level: Double) -> String {
        switch level {
        case ..<1.0: return "Low"
        case ..<2.0: return "Moderate"
        default: return "High"
        }
    }

    /// The alert's subtitle: the band in words and what it is measured from — never "2.3 of 3". Absent
    /// reading: an em dash and the reason.
    static func alertSubtitle(level: Double?) -> String {
        guard let level, level.isFinite else { return "— · no reading in the last ten minutes" }
        return "\(bandWord(level)) · heart-rate based"
    }

    // MARK: - The full-screen alert: off by default, at most twice a day (owner decision + H1c)

    /// The Settings switch for the full-screen alert. Copy for it: "Full-screen stress alert — interrupts
    /// you when two ten-minute readings in a row are high while you are still. Off by default; the stress
    /// reading itself keeps running."
    static let alertScreenEnabledKey = "stress.alertScreen.enabled"
    /// Set once this build has turned the alert off, so a wearer who switches it back on keeps it on.
    static let alertScreenMigratedKey = "stress.alertScreen.offMigration.v1"
    /// How many times a day the screen may present itself, on top of the shell's hourly cooldown.
    static let maxScreensPerDay = 2
    private static let screensDayKey = "stress.alertScreen.day"
    private static let screensCountKey = "stress.alertScreen.count"

    /// Whether the full-screen alert may present itself. OFF on a fresh install, and switched off ONCE on
    /// an install that had it on by default before this build.
    static func alertScreenEnabled(_ d: UserDefaults = .standard) -> Bool {
        if !d.bool(forKey: alertScreenMigratedKey) {
            d.set(false, forKey: alertScreenEnabledKey)
            d.set(true, forKey: alertScreenMigratedKey)
        }
        return d.object(forKey: alertScreenEnabledKey) as? Bool ?? false
    }

    static func setAlertScreenEnabled(_ on: Bool, _ d: UserDefaults = .standard) {
        d.set(true, forKey: alertScreenMigratedKey)
        d.set(on, forKey: alertScreenEnabledKey)
    }

    /// The daily cap, pure: whether another screen may be shown given what was recorded.
    static func screenAllowed(storedDay: String?, count: Int, today: String) -> Bool {
        storedDay != today || count < maxScreensPerDay
    }

    /// Take one of today's screen slots, or refuse. Refuses outright while the alert is switched off.
    /// Check and record in one step, so two passes cannot both present.
    func claimScreenSlot(now: Date = Date(), _ d: UserDefaults = .standard) -> Bool {
        guard Self.alertScreenEnabled(d) else { return false }
        let today = Repository.localDayKey(now)
        let storedDay = d.string(forKey: Self.screensDayKey)
        let count = storedDay == today ? d.integer(forKey: Self.screensCountKey) : 0
        guard Self.screenAllowed(storedDay: storedDay, count: count, today: today) else { return false }
        d.set(today, forKey: Self.screensDayKey)
        d.set(count + 1, forKey: Self.screensCountKey)
        return true
    }

    /// The diagnostic, opened by the wearer from the stress tile — never counted against the cap, and
    /// available whether or not the automatic alert is on. The shell presents it while this is true.
    @Published private(set) var diagnosticRequested = false

    func openDiagnostic() { diagnosticRequested = true }
    func closeDiagnostic() { diagnosticRequested = false }
}
