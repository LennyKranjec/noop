import Foundation
import StrandAnalytics
import WhoopStore

// HabitTrialStore.swift — the source of truth for N-of-1 habit trials.
//
// HEALTH_V2 §S1-B.10. One JSON file, `habit-trials.json`, in the store directory, written atomically. It
// holds each trial's frozen registration and its FNV-1a hash, the per-day records, and the life-cycle
// state `running → completed | stoppedEarly` (a draft lives only on the setup screen until Start).
//
// SEALED BY CONSTRUCTION. While a trial runs, the only read paths are `runningProgress` (counts and dates:
// `HabitTrialProgress` has no field that could hold an estimate) and `todayAssignment` (today's arm only).
// `HabitTrialAnalysis.analyse` is called from exactly one place, `complete(_:…)`, which `tick` reaches
// only once the trial's last night is scored; `result(trialId:)` returns nil for anything not finished.
// Stopping early records `HabitTrialAnalysis.stoppedEarly` — Inconclusive, no numbers, no analysis.
//
// ADHERENCE, HONESTLY. Per day: the wearer's tap and the app's own evidence are kept apart and combined by
// fixed rules (`HabitTrialDayRecord.effective`): on an ON day, evidence that the behaviour did NOT happen is
// final and "I didn't" always wins — a tap can only move the record toward honesty. On an OFF day only the
// wearer's own "did it anyway" counts as contamination: that the behaviour happens naturally on some normal
// evenings is exactly the usual life the OFF arm stands for, not a crossover.
//
// Not on the `.noopbak` whitelist in 2.0 (Android codec parity, HEALTH_V2 §4.3) — a known follow-up.

/// One trial day as stored.
struct HabitTrialDayRecord: Codable, Equatable {
    let day: String
    let assigned: Bool
    /// The wearer's answer. `.unknown` until tapped.
    var answer: HabitTrialBehaviour
    /// The app's own evidence. `.unknown` when it cannot see the behaviour.
    var auto: HabitTrialBehaviour
    var answeredAt: Date?
    /// The illness heads-up was raised on this day.
    var illness: Bool

    /// What the analysis uses.
    var effective: HabitTrialBehaviour {
        if assigned {
            if auto == .didNot || answer == .didNot { return .didNot }
            if auto == .did || answer == .did { return .did }
            return .unknown
        }
        return answer
    }

    /// Where the effective value came from.
    var source: String {
        if answer != .unknown { return "tap" }
        return auto != .unknown ? "auto" : "none"
    }
}

/// One trial as stored.
struct HabitTrialRecord: Codable, Equatable, Identifiable {
    var id: String { registration.trialId }
    let registration: HabitTrialRegistration
    /// FNV-1a 64 of the registration's canonical JSON, written once at Start.
    let hash: String
    var state: HabitTrialState
    var days: [HabitTrialDayRecord]
    /// Set only when the trial is completed or stopped early.
    var result: HabitTrialResult?
    var endedOn: String?
    /// The wearer's answer to the contrast question at setup.
    let usualPerWeek: Int?

    var entry: HabitTrialEntry? { HabitTrialCatalog.entry(registration.interventionId) }
}

/// Why a trial could not start.
enum HabitTrialStartError: Error, Equatable {
    case alreadyRunning
    case noContrast
    case ineligible(HabitTrialIneligibility)
    case registration(HabitTrialRegistrationError)

    var text: String {
        switch self {
        case .alreadyRunning: return "A trial is already running. One at a time, so the two never mix."
        case .noContrast: return HabitTrialIneligibility.noContrast.text
        case .ineligible(let why): return why.text
        case .registration(.tooFewBaselineNights(let have, let need)):
            return "Needs \(need) measured nights in the last 4 weeks to set what counts as a meaningful change "
                + "(\(have) so far)."
        case .registration(.invalidLength(let allowed)):
            return "Choose \(allowed.map { String($0) }.joined(separator: ", ")) days."
        case .registration: return "This trial could not be set up."
        }
    }
}

@MainActor
final class HabitTrialStore: ObservableObject {

    static let shared = HabitTrialStore()
    static let fileName = "habit-trials.json"
    /// Set by the setup screen when the wearer confirms the bedroom can reach ~18 °C.
    static let coolRoomConfirmedKey = "habits.bedroom18.confirmed"

    private struct File: Codable {
        var version: Int
        var trials: [HabitTrialRecord]
    }

    @Published private(set) var trials: [HabitTrialRecord] = []
    /// Outcome keys of the running trial's primary outcome that have a value. Counts only.
    @Published private(set) var scoredOutcomeKeys: Set<String> = []

    private let fileURL: URL?
    private let defaults: UserDefaults
    private var ticking = false

    init(fileURL: URL? = HabitTrialStore.defaultFileURL(), defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let file = try? Self.decoder.decode(File.self, from: data) {
            trials = file.trials
        }
    }

    static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private func save() {
        guard let url = fileURL, let data = try? Self.encoder.encode(File(version: 1, trials: trials)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Reading (sealed while running)

    var running: HabitTrialRecord? { trials.first { $0.state == .running } }

    /// Finished trials, newest first.
    var finished: [HabitTrialRecord] {
        trials.filter { $0.state == .completed || $0.state == .stoppedEarly }
            .sorted { ($0.endedOn ?? "") > ($1.endedOn ?? "") }
    }

    /// The running trial's counts. No estimate exists anywhere before the trial ends.
    func runningProgress(today: String) -> HabitTrialProgress? {
        guard let rec = running else { return nil }
        var behaviour: [String: HabitTrialBehaviour] = [:]
        for d in rec.days { behaviour[d.day] = d.effective }
        return HabitTrialProgress.make(registration: rec.registration, today: today, behaviour: behaviour,
                                       scoredOutcomeKeys: scoredOutcomeKeys)
    }

    /// Today's arm of the running trial — revealed on the day itself only.
    func todayAssignment(today: String) -> (record: HabitTrialRecord, on: Bool)? {
        guard let rec = running, let idx = HabitDay.days(from: rec.registration.startDay, to: today),
              idx >= 0, idx < rec.registration.schedule.count else { return nil }
        return (record: rec, on: rec.registration.schedule[idx])
    }

    /// The day record for `day` of the running trial.
    func dayRecord(_ day: String) -> HabitTrialDayRecord? {
        running?.days.first { $0.day == day }
    }

    /// A finished trial's result. Nil for a running trial — the only result path there is.
    func result(trialId: String) -> HabitTrialResult? {
        guard let rec = trials.first(where: { $0.id == trialId }),
              rec.state == .completed || rec.state == .stoppedEarly else { return nil }
        return rec.result
    }

    /// Finished trials in the coach's shape.
    func finishedForCoach() -> [HabitCoachFinishedTrial] {
        finished.compactMap { rec in
            guard let r = rec.result, let ended = rec.endedOn else { return nil }
            return HabitCoachFinishedTrial(result: r, endedOn: ended)
        }
    }

    /// What the catalogue needs to decide eligibility.
    func eligibilityContext(inputs: HabitLedgerInputs?, today: String) -> HabitTrialEligibilityContext {
        var last: [String: String] = [:]
        for rec in trials where rec.state != .running {
            let day = rec.endedOn ?? rec.registration.endDay
            if (last[rec.registration.interventionId] ?? "") < day { last[rec.registration.interventionId] = day }
        }
        for rec in trials where rec.state == .running { last[rec.registration.interventionId] = today }
        var drinking: Int? = nil
        if let inputs, let from = HabitDay.adding(-27, to: today) {
            let alcohol = inputs.observations.filter { $0.habit == HabitCatalog.alcohol && $0.nightKey >= from }
            if !alcohol.isEmpty {
                drinking = Set(alcohol.filter { $0.state == .yes }.map { $0.nightKey }).count
            }
        }
        let sensor = BedroomClimate.shared.latest != nil
            || !ClimateHistory.since(Date().addingTimeInterval(-14 * 86_400)).isEmpty
        return HabitTrialEligibilityContext(climateSensorPaired: sensor,
                                            coolRoomConfirmed: defaults.bool(forKey: Self.coolRoomConfirmedKey),
                                            drinkingEveningsLast28: drinking, lastTrialledDay: last, today: today)
    }

    // MARK: Starting and stopping

    /// Freeze and start a trial (pure inputs; `start(entry:…repo:)` gathers them).
    func start(entry: HabitTrialEntry, lengthDays: Int, usualPerWeek: Int, baseline: [String: Double],
               today: String, seed: UInt64,
               context: HabitTrialEligibilityContext? = nil) -> Result<HabitTrialRecord, HabitTrialStartError> {
        guard running == nil else { return .failure(.alreadyRunning) }
        guard HabitTrialCatalog.hasContrast(entry, usualPerWeek: usualPerWeek) else { return .failure(.noContrast) }
        if let context, let why = HabitTrialCatalog.ineligibility(entry, context: context) {
            return .failure(.ineligible(why))
        }
        switch HabitTrialRegistration.register(entry: entry, registeredOn: today, lengthDays: lengthDays,
                                               seed: seed, baseline: baseline) {
        case .failure(let e):
            return .failure(.registration(e))
        case .success(let reg):
            let days = (0..<reg.lengthDays).compactMap { i -> HabitTrialDayRecord? in
                guard let day = HabitDay.adding(i, to: reg.startDay) else { return nil }
                return HabitTrialDayRecord(day: day, assigned: reg.schedule[i], answer: .unknown, auto: .unknown,
                                           answeredAt: nil, illness: false)
            }
            let rec = HabitTrialRecord(registration: reg, hash: reg.hash, state: .running, days: days, result: nil,
                                       endedOn: nil, usualPerWeek: usualPerWeek)
            trials.append(rec)
            scoredOutcomeKeys = []
            save()
            return .success(rec)
        }
    }

    /// Start with the baseline read from the store and a fresh random seed.
    func start(entry: HabitTrialEntry, lengthDays: Int, usualPerWeek: Int, repo: Repository,
               now: Date = Date()) async -> Result<HabitTrialRecord, HabitTrialStartError> {
        let today = Repository.localDayKey(now)
        let snapshot = await HabitLedgerSource.build(repo: repo, asOf: today)
        let baseline = snapshot.inputs.outcomes[entry.primaryOutcome] ?? [:]
        let seed = DeterministicRNG.registrationSeed(from: UInt64.random(in: 0...UInt64.max))
        return start(entry: entry, lengthDays: lengthDays, usualPerWeek: usualPerWeek, baseline: baseline,
                     today: today, seed: seed, context: eligibilityContext(inputs: snapshot.inputs, today: today))
    }

    /// End the running trial early: Inconclusive (stopped early), no analysis, no numbers.
    func stop(trialId: String, today: String) {
        guard let i = trials.firstIndex(where: { $0.id == trialId && $0.state == .running }) else { return }
        let rec = trials[i]
        trials[i].state = .stoppedEarly
        trials[i].endedOn = today
        trials[i].result = HabitTrialAnalysis.stoppedEarly(registration: rec.registration, storedHash: rec.hash)
        scoredOutcomeKeys = []
        save()
    }

    // MARK: Day records

    /// The wearer's single tap for `day` of the running trial. `did`: ON → "Did it", OFF → "Did it anyway".
    func recordAnswer(trialId: String, day: String, did: Bool, at: Date = Date()) {
        guard let i = trials.firstIndex(where: { $0.id == trialId && $0.state == .running }),
              let j = trials[i].days.firstIndex(where: { $0.day == day }) else { return }
        trials[i].days[j].answer = did ? .did : .didNot
        trials[i].days[j].answeredAt = at
        save()
    }

    /// The app's own evidence for `day`.
    func recordAuto(trialId: String, day: String, evidence: HabitTrialBehaviour) {
        guard evidence != .unknown,
              let i = trials.firstIndex(where: { $0.id == trialId && $0.state == .running }),
              let j = trials[i].days.firstIndex(where: { $0.day == day }),
              trials[i].days[j].auto != evidence else { return }
        trials[i].days[j].auto = evidence
        save()
    }

    // MARK: The daily tick

    /// Record today's illness flag, gather automatic adherence evidence, refresh the scored-night count,
    /// and complete the trial the morning after its last night has been scored (or a day later without it).
    func tick(now: Date = Date(), repo: Repository, illnessRaised: Bool) async {
        guard !ticking, let rec = running else { return }
        ticking = true
        defer { ticking = false }
        let today = Repository.localDayKey(now)
        let reg = rec.registration

        if illnessRaised, let i = trials.firstIndex(where: { $0.id == rec.id }),
           let j = trials[i].days.firstIndex(where: { $0.day == today }), !trials[i].days[j].illness {
            trials[i].days[j].illness = true
            save()
        }

        let timings = await repo.sleepTimingsByDay(days: 90)
        let (outcomes, effort) = await HabitLedgerSource.outcomeSeries(repo: repo, timings: timings)
        await gatherAutoEvidence(rec, repo: repo, today: today)

        let primary = outcomes[reg.primaryOutcome] ?? [:]
        var scored = Set<String>()
        for d in rec.days {
            if let key = reg.lag.outcomeKey(for: d.day), primary[key] != nil { scored.insert(key) }
        }
        scoredOutcomeKeys = scored

        // Completion: the last night is scored, or a full day has passed after it without a score.
        guard today >= reg.lastOutcomeKey else { return }
        let lastScored = primary[reg.lastOutcomeKey] != nil
        let overdue = (HabitDay.days(from: reg.lastOutcomeKey, to: today) ?? 0) >= 1
        guard lastScored || overdue else { return }
        await complete(rec.id, repo: repo, outcomes: outcomes, effort: effort, today: today)
    }

    /// THE one call site of `HabitTrialAnalysis.analyse`.
    private func complete(_ trialId: String, repo: Repository, outcomes: [HabitOutcome: [String: Double]],
                          effort: [String: Double], today: String) async {
        guard let i = trials.firstIndex(where: { $0.id == trialId && $0.state == .running }) else { return }
        let rec = trials[i]
        let reg = rec.registration
        var behaviour: [String: HabitTrialBehaviour] = [:]
        var illness = Set<String>()
        for d in rec.days {
            behaviour[d.day] = d.effective
            if d.illness { illness.insert(d.day) }
        }
        var secondaries: [HabitOutcome: [String: Double]] = [:]
        for o in reg.secondaryOutcomes { secondaries[o] = outcomes[o] ?? [:] }
        let snapshot = await HabitLedgerSource.build(repo: repo, asOf: today)
        let observations = HabitTrialObservations(
            outcomes: outcomes[reg.primaryOutcome] ?? [:], effort: effort, behaviour: behaviour,
            illnessRaisedDays: illness, alcoholNights: HabitLedgerSource.alcoholNights(snapshot.inputs),
            secondaryOutcomes: secondaries)
        let hash = rec.hash
        // Off the main actor: 10,000 permutations are pure arithmetic.
        let result = await Task.detached(priority: .utility) {
            HabitTrialAnalysis.analyse(registration: reg, storedHash: hash, observations: observations)
        }.value
        guard let k = trials.firstIndex(where: { $0.id == trialId && $0.state == .running }) else { return }
        trials[k].state = .completed
        trials[k].endedOn = today
        trials[k].result = result
        scoredOutcomeKeys = []
        save()
    }

    /// Automatic evidence where the app can see the behaviour (HEALTH_V2 §B.1 table).
    private func gatherAutoEvidence(_ rec: HabitTrialRecord, repo: Repository, today: String) async {
        let reg = rec.registration
        guard let from = HabitDay.adding(-3, to: today) else { return }
        let recent = rec.days.filter { $0.day >= from && $0.day <= today && $0.assigned }
        guard !recent.isEmpty else { return }
        switch reg.interventionId {
        case "caffeineCutoff14":
            // Only days with a logged intake: "no coffee" and "didn't log" look the same.
            let points = await repo.series(key: CaffeineDailySummary.lastMinuteKey,
                                           source: HabitLedgerSource.habitsSource, from: from, to: today)
            var last: [String: Double] = [:]
            for p in points { last[p.day] = p.value }
            for d in recent {
                guard let m = last[d.day] else { continue }
                recordAuto(trialId: rec.id, day: d.day, evidence: m <= Double(HabitRules.lateCaffeineMinute) ? .did : .didNot)
            }
        case "bedroom18":
            guard let toKey = HabitDay.adding(1, to: today) else { return }
            let points = await repo.series(key: BedroomNightSummary.tempKey,
                                           source: HabitLedgerSource.habitsSource, from: from, to: toKey)
            var temps: [String: Double] = [:]
            for p in points { temps[p.day] = p.value }
            for d in recent {
                guard let key = reg.lag.outcomeKey(for: d.day), let t = temps[key] else { continue }
                if t <= 18.5 { recordAuto(trialId: rec.id, day: d.day, evidence: .did) }
                if t > HabitRules.warmBedroomC { recordAuto(trialId: rec.id, day: d.day, evidence: .didNot) }
            }
        case "breathing10":
            // Positive evidence only: a session the app did not see may still have happened.
            var ends: [Int64: Double] = [:]
            for s in BreathSessionLog.shared.sessions {
                ends[Int64(s.startTs) + Int64(s.pacedMinutes * 60)] = s.pacedMinutes
            }
            let meditations = await repo.meditationSessions(days: 5)
            for w in meditations {
                ends[Int64(w.endTs)] = (w.durationS ?? Double(w.endTs - w.startTs)) / 60
            }
            for d in recent {
                guard let start = HabitLedgerSource.localDate(day: d.day, minute: 17 * 60),
                      let end = HabitLedgerSource.localDate(day: d.day, minute: 24 * 60 - 1) else { continue }
                let s = Int64(start.timeIntervalSince1970), e = Int64(end.timeIntervalSince1970) + 4 * 3600
                if ends.contains(where: { $0.key >= s && $0.key <= e && $0.value >= 10 }) {
                    recordAuto(trialId: rec.id, day: d.day, evidence: .did)
                }
            }
        default:
            // screensOff60, dinner3h, morningDaylight, alcoholFree: the tap only. walkAfterDinner10: the tap
            // until the S3 step-reliability gate is available here.
            break
        }
    }
}
