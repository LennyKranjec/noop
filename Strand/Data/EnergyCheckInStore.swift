import Combine
import Foundation
import StrandAnalytics
import WhoopStore

// EnergyCheckInStore.swift — the wearer's own word on their energy, and the verdict built from it.
//
// A one-tap 1–5 check-in, at most once in the morning (the morning flow) and once in the afternoon (the
// Today tile). Each is stored with the EXACT inputs the energy model saw at that moment, so the model
// can be judged against it — and refitted to it — under any weights (`EnergyCalibration`).
//
// A MORNING-FLOW CHECK-IN HAS NO INPUTS YET. The flow runs before Today has computed the day's balance,
// so the check-in is stored pending and matched to the first balance Today computes within
// `matchWindow` (the tile calls `attach` whenever it is handed a balance). A check-in never matched is
// kept but never counted: pairing a feeling with a balance from hours later would test nothing.
//
// LOCAL ONLY, in UserDefaults like the daily mission. Not in the `.noopbak` whitelist (yet), so a
// restore to a new phone starts calibration again — slower, never wrong.

@MainActor
final class EnergyCheckInStore: ObservableObject {

    static let shared = EnergyCheckInStore()

    /// The persisted check-ins (JSON array of `EnergyCheckIn`).
    nonisolated static let key = "energy.checkIns.v1"
    /// The wearer chose to hide the tile after it was found not to track them.
    nonisolated static let hiddenKey = "energy.tileHidden"
    /// Oldest check-ins beyond this are dropped. The verdict only reads the latest `EnergyCalibration.window`.
    nonisolated static let cap = 400
    /// How long after a check-in its inputs may still be attached.
    nonisolated static let matchWindow: TimeInterval = 3 * 3600
    /// The hour (local) the afternoon slot opens.
    nonisolated static let afternoonHour = 12

    @Published private(set) var checkIns: [EnergyCheckIn]
    @Published private(set) var verdict: EnergyCalibration.Verdict

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.read(defaults)
        checkIns = stored
        verdict = EnergyCalibration.evaluate(stored)
    }

    // MARK: - Slots

    /// Which slot a moment falls in: before `afternoonHour` is the morning.
    static func slot(at date: Date, calendar: Calendar = .current) -> EnergyCheckIn.Slot {
        calendar.component(.hour, from: date) < afternoonHour ? .morning : .afternoon
    }

    /// The day a check-in belongs to: the same logical day (04:00 rollover) Today resolves.
    static func dayKey(at date: Date) -> String { Repository.logicalDayKey(date) }

    /// The check-in already recorded for `slot` on the day of `now`, if any.
    func checkIn(slot: EnergyCheckIn.Slot, now: Date = Date()) -> EnergyCheckIn? {
        let day = Self.dayKey(at: now)
        return checkIns.last { $0.day == day && $0.slot == slot }
    }

    /// The slot the tile may ask about right now, or nil when the current one is already answered.
    func openSlot(now: Date = Date()) -> EnergyCheckIn.Slot? {
        let slot = Self.slot(at: now)
        return checkIn(slot: slot, now: now) == nil ? slot : nil
    }

    // MARK: - Writing

    /// Record a report. One per slot per day: a second answer in the same slot REPLACES the first (a
    /// correction, not a second data point — two taps a minute apart are not two observations).
    func record(felt: Int, slot: EnergyCheckIn.Slot? = nil, at: Date = Date(), inputs: EnergyInputs? = nil) {
        guard (1...5).contains(felt) else { return }
        let resolvedSlot = slot ?? Self.slot(at: at)
        let day = Self.dayKey(at: at)
        var next = checkIns.filter { !($0.day == day && $0.slot == resolvedSlot) }
        next.append(EnergyCheckIn(at: at, day: day, slot: resolvedSlot, felt: felt, inputs: inputs))
        commit(next)
    }

    /// Give pending check-ins (no inputs yet, taken at most `matchWindow` before `now`) these inputs.
    func attach(_ inputs: EnergyInputs, now: Date = Date()) {
        var changed = false
        var next = checkIns
        for i in next.indices where next[i].inputs == nil {
            let age = now.timeIntervalSince(next[i].at)
            guard age >= 0, age <= Self.matchWindow else { continue }
            next[i].inputs = inputs
            changed = true
        }
        if changed { commit(next) }
    }

    /// Every check-in, forgotten. For a settings reset.
    func clear() {
        commit([])
    }

    private func commit(_ next: [EnergyCheckIn]) {
        let trimmed = Array(next.sorted { $0.at < $1.at }.suffix(Self.cap))
        checkIns = trimmed
        verdict = EnergyCalibration.evaluate(trimmed)
        if let data = try? JSONEncoder().encode(trimmed) { defaults.set(data, forKey: Self.key) }
    }

    private static func read(_ defaults: UserDefaults) -> [EnergyCheckIn] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([EnergyCheckIn].self, from: data) else { return [] }
        return decoded
    }

    // MARK: - Reading

    /// The balance under the weights the verdict chose (the wearer's fitted set once it earned it).
    func balance(_ inputs: EnergyInputs) -> EnergyBalance? {
        EnergyBank.balance(inputs, params: verdict.params)
    }

    /// `balance` redrawn under the current weights when it carries its inputs; as given otherwise.
    func calibrated(_ balance: EnergyBalance?) -> EnergyBalance? {
        guard let balance else { return nil }
        guard let inputs = balance.inputs else { return balance }
        return self.balance(inputs) ?? balance
    }

    /// Today's reports, oldest first.
    func today(now: Date = Date()) -> [EnergyCheckIn] {
        let day = Self.dayKey(at: now)
        return checkIns.filter { $0.day == day }
    }

    // MARK: - For the coach

    /// The energy line for a coach prompt, worded by what the verdict allows the figure to be called, plus
    /// what the wearer reported today. Nil when there is neither a balance nor a report.
    ///
    /// THE REPORT OUTRANKS THE MODEL. When the wearer has said how they feel, the coach is told so and
    /// told to prefer it; a model that disagrees with the person it models is the one that is wrong.
    func coachLine(_ energy: EnergyBalance?, now: Date = Date()) -> String? {
        var parts: [String] = []
        if let e = calibrated(energy) {
            let figures = String(format: "%d of the %d it opened with — %d spent on strain, %d on stress, %d back from calm",
                                 Int(e.balance.rounded()), Int(e.opening.rounded()),
                                 Int(e.strainSpend.rounded()), Int(e.stressSpend.rounded()),
                                 Int(e.restReturn.rounded()))
            let v = verdict
            switch v.status {
            case .calibrating:
                parts.append("Energy ESTIMATE (a model not yet checked against the wearer: \(v.usable) of "
                             + "\(EnergyCalibration.minCheckIns) check-ins): about " + figures
                             + ". Treat it as rough; never quote it as a measurement.")
            case .tracks:
                let rho = v.decidingAgreement.map { String(format: "ρ %.2f", $0.rho) } ?? "ρ –"
                parts.append("Energy bank: " + figures + " (\(EnergyBank.state(e.balance))). It tracks the wearer's own "
                             + "check-ins (\(rho) over \(v.usable)).")
            case .weak:
                let rho = v.decidingAgreement.map { String(format: "ρ %.2f", $0.rho) } ?? "no measurable agreement"
                parts.append("Physiological-load estimate (NOT the wearer's energy — it does not track how they "
                             + "report feeling, \(rho) over \(v.usable) check-ins): " + figures
                             + ". Do not call it energy or tell the wearer how tired they are from it.")
            }
        }
        let reports = today(now: now)
        if !reports.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let said = reports.map { "\($0.felt)/5 at \(f.string(from: $0.at))" }.joined(separator: ", ")
            parts.append("Energy the wearer REPORTED today (1 empty – 5 full): " + said
                         + ". Where this and any model figure disagree, go by the report.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Measured calm, banked beside the high-stress minutes

extension Repository {

    /// The generic metric-series key a day's MEASURED calm minutes are banked under (iOS-only for now).
    nonisolated static let calmMinutesKey = "stress_calm_min"

    /// Write the day's measured calm (`EnergyBank.calmMinutes(hours:)`), replacing the day's row.
    /// Same seam, same source and the same replace-don't-accumulate rule as `bankStressMinutes`.
    func bankCalmMinutes(day: String, minutes: Int) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: day, key: Repository.calmMinutesKey, value: Double(minutes))],
            deviceId: StressDailyLog.source)
    }

    /// Every banked day's measured calm, keyed by local day. Empty when nothing has been banked — and
    /// then the energy bank returns nothing for resting, rather than a calm nobody measured.
    func bankedCalmMinutes(lookbackDays: Int = 7) async -> [String: Double] {
        let rows = await series(key: Repository.calmMinutesKey, source: StressDailyLog.source, days: lookbackDays)
        var out: [String: Double] = [:]
        for row in rows { out[row.day] = row.value }
        return out
    }
}
