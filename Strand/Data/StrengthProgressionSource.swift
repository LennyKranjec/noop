import Foundation
import StrandImport
import WhoopStore

// StrengthProgressionSource.swift — the one read that turns stored sets into progression.
//
// ONE PLACE, because two surfaces need the same answer: the Progression section on the Health tab and the
// coach's strength context. If each built its own the coach would eventually quote a number the screen does
// not show, which is the failure the wearer notices fastest — they read the screen, then ask about it.
//
// THE WHOLE HISTORY, not a window. Best-ever is by definition unbounded, and the trend windows are cut out
// of the same rows afterwards; a 12-week read would make "best ever" mean "best this quarter" and quietly
// reset it every season. It is one indexed query served by `idx_liftSession_natural`, so the cost is the
// row count and not the span.

enum StrengthProgressionSource {

    /// Every exercise's progression from the stored lift log, sorted stalled-first then most-recent-first.
    ///
    /// Returns an empty array when nothing is stored — which is the state for a wearer whose only lifting
    /// history was imported before sets were persisted. That is NOT the same as "no lifting history", and
    /// the screen distinguishes them by asking `hasStoredSets`.
    static func load(store: WhoopStore,
                     now: Date = Date(),
                     calendar: Calendar = .current) async -> [StrengthProgression.Exercise] {
        // `toTs` is now, not `Int.max`: a session stamped in the future is a corrupt import and must not
        // drag a trend window forward by a decade. `fromTs` is 0 because there is no honest floor on
        // "best ever".
        let rows = (try? await store.liftSetsWithSessionStart(
            deviceId: ImportedLiftSets.deviceId,
            fromTs: 0,
            toTs: Int(now.timeIntervalSince1970))) ?? []
        guard !rows.isEmpty else { return [] }

        // Grouped in ARRIVAL ORDER, which the query already sorted by session then position, so a session's
        // sets keep the order the export listed them in without a second sort.
        var order: [Int] = []
        var byStart: [Int: [LiftingSetRecord]] = [:]
        for row in rows {
            if byStart[row.sessionStartTs] == nil { order.append(row.sessionStartTs) }
            byStart[row.sessionStartTs, default: []].append(ImportedLiftSets.record(from: row.set))
        }
        let sessions = order.map { start in
            StrengthProgression.Session(
                start: Date(timeIntervalSince1970: Double(start)),
                sets: byStart[start] ?? [])
        }
        return StrengthProgression.build(sessions: sessions, calendar: calendar)
    }

    /// Charge below which the suggestion carries a "this can wait" caution.
    ///
    /// 34 is the app's own low-charge line — the same boundary `StateCoach` uses and the same one the
    /// coach's own guidance is written around ("0-33 = active recovery only"). A second threshold here
    /// would have the screen and the coach disagree about whether today is a day to add weight.
    static let lowChargeThreshold: Double = 34
}
