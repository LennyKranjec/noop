import Foundation
import WhoopStore
import StrandAnalytics

/// Collects everything the app knows about one workout into a `WorkoutFeedbackDossier.Input`.
///
/// Reads the SAME sources the workout detail screen does (HR buckets over the exact window, imported zone
/// split else zones from the strap's own samples, heart-rate recovery, the on-device GPS route), plus the
/// day's scores and the 14 days before it. Nothing here performs a network request.
@MainActor
enum WorkoutFeedbackGatherer {

    static func input(for row: WorkoutRow, repo: Repository, profile: ProfileStore,
                      stressStart: Double?, stressEnd: Double?) async -> WorkoutFeedbackDossier.Input {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let dayKey = Repository.localDayKey(start)

        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let hr = buckets.map { WorkoutFeedbackDossier.HRPoint(ts: $0.ts, bpm: $0.bpm) }

        // Zones exactly as WorkoutDetailView resolves them: a real imported split wins over the on-device
        // approximation.
        let zoneSet = profile.hrZoneSet
        var zoneMinutes: [Double]?
        var fromImport = false
        if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 {
                zoneMinutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        if zoneMinutes == nil {
            zoneMinutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: zoneSet,
                                                        source: row.source)
        }
        let hrr = await repo.workoutHeartRateRecovery(from: row.startTs, to: row.endTs,
                                                      maxHR: Double(profile.hrMax), source: row.source)

        let route = RouteStore.load(startTs: row.startTs, sport: row.sport)
        let routePoints = route.map { RouteMath.decode($0.polyline).count } ?? 0

        // The tile only reads the stress change of a recovery session; fill it in if the tile had not yet.
        var sStart = stressStart
        var sEnd = stressEnd
        if sStart == nil, WorkoutCatalog.isRecovery(row.sport),
           let d = await WorkoutStressDelta.compute(repo: repo, row: row) {
            sStart = d.start
            sEnd = d.end
        }

        // The day, and the band the day's recovery recommends (the same rule as Today's hero ring).
        let ageDays = Int(max(0, Date().timeIntervalSince(start)) / 86_400)
        let daysBack = max(7, min(60, ageDays + 2))
        let noop = await repo.noopRecentDays(days: daysBack).first { $0.day == dayKey }
        let whoop = await repo.whoopRecentDays(days: daysBack).first { $0.day == dayKey }
        let metric = repo.days.last { $0.day == dayKey }
        let recovery = whoop?.recovery ?? metric?.recovery ?? noop?.charge
        let band = CoupledView.optimalStrainRange(recovery: recovery)
        let day = WorkoutFeedbackDossier.DayContext(
            dayKey: dayKey,
            charge: noop?.charge ?? metric?.recovery,
            dayEffort: noop?.effort ?? metric?.strain,
            rest: noop?.rest,
            whoopRecovery: whoop?.recovery,
            effortTargetLow: band.map { StrainCalibration.effort100(strain21: Double($0.lowerBound)) },
            effortTargetHigh: band.map { StrainCalibration.effort100(strain21: Double($0.upperBound)) },
            sleepMin: metric?.totalSleepMin,
            deepMin: metric?.deepMin,
            remMin: metric?.remMin,
            sleepEfficiency: metric?.efficiency,
            hrv: metric?.avgHrv,
            restingHr: metric?.restingHr)

        let recent = await repo.workoutRows(days: daysBack + 14)
            .filter { $0.startTs >= row.startTs - 14 * 86_400 && $0.startTs < row.startTs }

        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")

        return WorkoutFeedbackDossier.Input(
            sport: WorkoutSource.displaySport(row.sport),
            source: row.source,
            startTs: row.startTs,
            endTs: row.endTs,
            durationS: row.durationS,
            energyKcal: row.energyKcal,
            avgHr: row.avgHr,
            maxHr: row.maxHr,
            effort: row.strain,
            distanceM: row.distanceM,
            steps: row.steps,
            notes: row.notes,
            isRecovery: WorkoutCatalog.isRecovery(row.sport),
            hr: hr,
            zoneMinutes: zoneMinutes,
            zonesFromImport: fromImport,
            zoneSet: zoneSet,
            effortHRmax: profile.hrMax,
            hrRecovery: hrr,
            stressStart: sStart,
            stressEnd: sEnd,
            routeDistanceM: route?.distanceM,
            routePointCount: routePoints,
            day: day,
            recent: recent,
            imperial: distanceSystem == .imperial,
            timeZone: .current)
    }
}

extension AICoachEngine {

    /// Hand a workout to the coach: park its dossier as the thread's subject and the short question for
    /// `CoachView` to send (the same `pendingPrompt` handoff the Today launcher uses). Performs NO network
    /// request; the send happens in the Coach screen, which owns consent, streaming and errors. The
    /// dossier is biometric data, so `buildFullContext` only includes it when data access is granted.
    func beginWorkoutFeedback(dossier: String, prompt: String) {
        activeWorkoutDossier = dossier
        pendingPrompt = prompt
    }

    /// Formatting for a phone-sized chat bubble. Appended to the chat's system prompt on every request
    /// (see `withMobileFormatting`), so it also reaches a wearer who edited their own instructions.
    static let mobileFormattingRule = """
    FORMATTING (mobile screen): the reply is read in a narrow chat bubble on a phone. Do NOT use Markdown \
    tables; use short paragraphs and bullet lists instead. Only if a table is truly unavoidable, use at \
    most one very small table (3 columns or fewer, 4 rows or fewer).
    """

    /// `base` with the mobile formatting rule appended once.
    static func withMobileFormatting(_ base: String) -> String {
        base.contains(mobileFormattingRule) ? base : base + "\n\n" + mobileFormattingRule
    }
}
