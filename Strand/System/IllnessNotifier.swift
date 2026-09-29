import Foundation
import StrandAnalytics
import UserNotifications

/// Surfaces the illness heads-up as a user notification when the banner transitions from clear to
/// raised — today it is silent unless the window is open (the menu-bar extra keeps NOOP alive).
/// Rate-limited to once per local calendar day; the in-app banner stays the live surface. On-device only;
/// the summary is APPROXIMATE — informational, not a diagnosis.
///
/// HEALTH_V2 H7c / H8:
///   * ONLY THE `raised` LEVEL PUSHES. A wearer who logged feeling unwell already knows; a "rest up" push
///     on the `alreadyUnwell` path told them something they had just told us. The banner may still show.
///   * "Body off baseline", not "Early warning": the engine compares recent nights with the wearer's own
///     baseline — it does not predict anything. The body names the signals that fired and says no logged
///     confounder explains them (a logged one would have suppressed the alert), and keeps "not a
///     diagnosis".
enum IllnessNotifier {
    private static let lastDayKey = "behavior.illnessLastNotifiedDay"

    /// The notification's title (H8).
    static let title = "Body off baseline"
    static let subtitle = "On-device estimate (approximate), not a diagnosis."

    /// Ask up front (called when the user enables the watch) so the system dialog appears at a
    /// predictable moment, not on the first 3 a.m. transition.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// What to post for `result`, or nil when nothing may be pushed (anything but `raised`). Pure.
    static func content(for result: IllnessSignalEngine.Result) -> (title: String, subtitle: String, body: String)? {
        guard result.level == .raised else { return nil }
        var body = ""
        if !result.firedSignals.isEmpty {
            body = "Off your baseline: " + result.firedSignals.joined(separator: ", ") + ". "
        }
        body += "Nothing you logged (alcohol, stress, sauna, a hard or late workout) explains it. "
        body += "Consider taking it easy."
        return (title, subtitle, body)
    }

    /// Post the heads-up for `result`, at most once per local calendar day. Does nothing for any level but
    /// `raised` (H7c).
    static func post(_ result: IllnessSignalEngine.Result) {
        guard let payload = Self.content(for: result) else { return }
        let day = dayKey(Date())
        let d = UserDefaults.standard
        guard d.string(forKey: lastDayKey) != day else { return }
        // Mark the day up front so the once-per-day limit holds even if the user declined
        // notifications or delivery is deferred — the in-app banner stays the live surface either
        // way, and we never re-prompt or retry on every transition.
        d.set(day, forKey: lastDayKey)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the watch is enabled;
        // here we only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let note = UNMutableNotificationContent()
            // Literals, so the string catalog picks them up; `content(for:)` carries the same words.
            note.title = String(localized: "Body off baseline")
            note.subtitle = String(localized: "On-device estimate (approximate), not a diagnosis.")
            note.body = payload.body
            note.sound = .default
            center.add(UNNotificationRequest(identifier: "illness-watch",
                                             content: note, trigger: nil))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - HEALTH_V2 H7: what the illness engine is fed

/// The illness engine's INPUTS, cleaned. Pure, so the fixes are pinned without a store
/// (`IllnessSkinTempFilterTests`).
///
///   * SKIN TEMPERATURE: `skinTempDevC` is bimodal — a live night stores a signed DEVIATION, an imported
///     one an ABSOLUTE wrist °C (#111/#622). Dividing an absolute ~33 °C by the 0.3 °C spread gave z ≈ 110
///     and a heads-up out of nothing. An absolute value is dropped: a night without a deviation is absent.
///   * CONFOUNDERS by exact starter-question identity (`JournalCatalogStore.starterQuestions`), not by
///     substring — "ill" matched "pill". Stress and sauna are now set too.
///   * HARD OR LATE WORKOUT from the workout table, not the journal: a session in the top quartile of the
///     wearer's own efforts, or one ending less than three hours before sleep onset.
enum IllnessInputFilter {

    /// The deviations only: absolute °C values (`VitalBands.isAbsoluteSkinTemp`) and non-numbers dropped.
    static func skinDeviations(_ values: [Double?]) -> [Double] {
        values.compactMap { v in
            guard let v, v.isFinite, !VitalBands.isAbsoluteSkinTemp(v) else { return nil }
            return v
        }
    }

    /// One personal spread of skin-temperature deviation, °C (matches `skin_temp` floorSpread).
    static let skinSpreadC = 0.3

    /// The illness-ward skin z from the recent nights, or nil when none of them carries a deviation.
    static func skinZ(recent: [Double?]) -> Double? {
        let xs = skinDeviations(recent)
        guard !xs.isEmpty else { return nil }
        return (xs.reduce(0, +) / Double(xs.count)) / skinSpreadC
    }

    /// The mean recent deviation for the banner's label, or nil (same filter as `skinZ`).
    static func recentSkinDeviation(recent: [Double?]) -> Double? {
        let xs = skinDeviations(recent)
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    // The starter questions whose answers are confounders. Verbatim `JournalCatalogStore.starterQuestions`
    // entries — the stored journal key, never localised.
    static let alcoholQuestion = "Did you drink any alcohol?"
    static let stressQuestion = "Did you feel stressed?"
    static let saunaQuestion = "Did you use a sauna?"
    static let unwellQuestion = "Did you feel sick or ill?"

    struct JournalFlags: Equatable {
        var alcohol = false
        var stress = false
        var sauna = false
        var alreadyUnwell = false
    }

    /// Confounder flags from `(question, answeredYes)` rows, by exact (normalised) identity.
    static func journalFlags(_ rows: [(question: String, answeredYes: Bool)]) -> JournalFlags {
        let key = JournalCatalogStore.norm
        let alcohol = key(alcoholQuestion), stress = key(stressQuestion)
        let sauna = key(saunaQuestion), unwell = key(unwellQuestion)
        var f = JournalFlags()
        for row in rows where row.answeredYes {
            switch key(row.question) {
            case alcohol: f.alcohol = true
            case stress: f.stress = true
            case sauna: f.sauna = true
            case unwell: f.alreadyUnwell = true
            default: break
            }
        }
        return f
    }

    /// A workout ending less than this long before sleep onset is "late".
    static let lateWorkoutSeconds = 3 * 3600
    /// A quartile needs at least this many of the wearer's own sessions behind it.
    static let minSessionsForQuartile = 8

    /// The 75th percentile of the wearer's own session efforts, or nil with too few sessions.
    static func topQuartileEffort(_ efforts: [Double]) -> Double? {
        let xs = efforts.filter { $0.isFinite }.sorted()
        guard xs.count >= minSessionsForQuartile else { return nil }
        let pos = 0.75 * Double(xs.count - 1)
        let lo = Int(pos), hi = Swift.min(lo + 1, xs.count - 1)
        return xs[lo] + (pos - Double(lo)) * (xs[hi] - xs[lo])
    }

    /// Whether any workout was hard (top quartile of `historyEfforts`) and ended within the day before a
    /// recent night's onset, or ended less than three hours before one.
    static func hardOrLateWorkout(workouts: [(endTs: Int, effort: Double?)], historyEfforts: [Double],
                                  nightOnsets: [Int]) -> Bool {
        let quartile = topQuartileEffort(historyEfforts)
        for onset in nightOnsets {
            for w in workouts where w.endTs <= onset {
                if onset - w.endTs < lateWorkoutSeconds { return true }
                if let q = quartile, let e = w.effort, e >= q, onset - w.endTs < 24 * 3600 { return true }
            }
        }
        return false
    }
}
