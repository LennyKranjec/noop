import Foundation

// MeditationLog.swift — the meditation log's storage contract.
//
// Swift twin of the Android `MeditationStore`. One row per local day holding the MINUTES meditated on
// it, on the same generic metric-series seam hydration uses — same table, same (source, day, key)
// uniqueness, no schema change.
//
// THE KEYS ARE PART OF THE PARITY CONTRACT. A wearer who exports on one platform and imports on the
// other must land on the same rows, so the source id and the series key are spelled out here and must
// match `MeditationStore.SOURCE_ID` / `MeditationStore.KEY` byte for byte.
//
// MINUTES, NOT A TICK. The level only asks whether a day had a meditation, but the Focus screen shows
// the total ever sat, and a boolean cannot be summed into one. Storing the duration gives both: the sum
// is the headline, and "was there one" is "is the figure above zero".
//
// THE THREE-DAY WINDOW IS A WINDOW, NOT A STREAK. `daysInWindow` counts the days in the last three that
// have any minutes at all, which is exactly the figure the level's focus term multiplies by. It slides:
// a day drops out when it falls past the third, which is what makes the three circles on screen fill
// and empty rather than fill and stay.

enum MeditationLog {

    /// The generic metric-series key the day's minutes are banked under.
    static let key = "meditation_min"

    /// Its own local-only source, so it is never confused with an imported or computed metric.
    static let source = "meditation"

    /// How many days the level's focus term looks back over. Three, matching every other window.
    static let windowDays = 3

    /// A session shorter than this is not logged: a mis-tap should not light the day's circle.
    static let minSessionSeconds = 30

    /// Whether a session of `seconds` is long enough to store.
    ///
    /// Pure, and separate from any write, so the threshold can be tested without a database behind it —
    /// this is the decision that once made the Android button look broken, and it is worth its own test.
    static func isLoggable(seconds: Int) -> Bool { seconds >= minSessionSeconds }

    /// How many days in a window carried a meditation.
    static func countDays(window: [Double]) -> Int { window.filter { $0 > 0 }.count }
}
