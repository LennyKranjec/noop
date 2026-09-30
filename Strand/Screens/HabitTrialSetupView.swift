import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitTrialSetupView.swift — the draft → Start step of a habit trial (HEALTH_V2 §S1-B.1/B.2/B.6 point 5/B.8).
// Logic only; the PROGRESS package restyles it. Shows the catalogue entry and its evidence line, the design
// in plain words, the contrast question, the minimum detectable effect (with a plain warning when the chosen
// length is too short), and the length choice. Start freezes everything; nothing here can be edited after.

struct HabitTrialSetupView: View {
    let entry: HabitTrialEntry
    @EnvironmentObject var model: AppModel
    @ObservedObject var trials: HabitTrialStore = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var usualPerWeek = 4
    @State private var lengthDays: Int
    @State private var coolRoomConfirmed = UserDefaults.standard.bool(forKey: HabitTrialStore.coolRoomConfirmedKey)
    @State private var baseline: [String: Double]?
    @State private var error: String?
    @State private var starting = false

    init(entry: HabitTrialEntry) {
        self.entry = entry
        _lengthDays = State(initialValue: entry.allowedLengths.first ?? 28)
    }

    private var today: String { Repository.localDayKey(Date()) }

    /// The registration the current choices would freeze (seed irrelevant to the power figures).
    private var preview: Result<HabitTrialRegistration, HabitTrialRegistrationError>? {
        guard let baseline else { return nil }
        return HabitTrialRegistration.register(entry: entry, registeredOn: today, lengthDays: lengthDays, seed: 0,
                                               baseline: baseline)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text(entry.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(entry.evidence).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Text(designText).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("How adherence is seen: \(entry.autoAdherence)")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text(entry.contrastQuestion).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Stepper("\(usualPerWeek) of 7", value: $usualPerWeek, in: 0...7)
                        if !HabitTrialCatalog.hasContrast(entry, usualPerWeek: usualPerWeek) {
                            Text(HabitTrialIneligibility.noContrast.text)
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        if entry.needsClimateSensor {
                            Toggle("My bedroom can reach about 18 °C", isOn: $coolRoomConfirmed)
                        }
                    }
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Picker("Length", selection: $lengthDays) {
                            ForEach(entry.allowedLengths, id: \.self) { Text("\($0) days").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        powerText
                    }
                }
                if let error {
                    Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text(HabitTrialCopy.blinding).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Button(starting ? "Starting…" : "Start trial tomorrow") { start() }
                    .buttonStyle(.noopPrimary)
                    .disabled(starting || trials.running != nil
                              || !HabitTrialCatalog.hasContrast(entry, usualPerWeek: usualPerWeek))
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle("New trial")
        .task { await loadBaseline() }
    }

    private var designText: String {
        let weeks = lengthDays / 7
        switch entry.design {
        case .weekdayBalanced:
            return "For \(weeks) weeks, each day the app will tell you whether today is an ON day (\(entry.onInstruction.lowercased())) "
                + "or a normal day. Half are each, balanced across weekdays. We'll compare your \(entry.primaryOutcome.label) "
                + "after the two kinds of days. You won't see results until the end, so you can't accidentally steer it."
        case .blocked:
            return "For \(lengthDays) days, the app switches between ON and normal stretches of 4 days, chosen at random. "
                + "The first night of each stretch is not counted, because this habit takes a few days to act. "
                + "We'll compare your \(entry.primaryOutcome.label). Results stay sealed until the end."
        }
    }

    @ViewBuilder
    private var powerText: some View {
        switch preview {
        case .none:
            Text(HealthAbsence.dash).foregroundStyle(StrandPalette.textTertiary)
        case .some(.failure(let e)):
            Text(HabitTrialStartError.registration(e).text)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        case .some(.success(let reg)):
            let o = reg.primaryOutcome
            let mde = reg.mde.map { HabitTrialCopy.bare($0 * o.betterDirection.sign, outcome: o) } ?? HealthAbsence.dash
            Text("Smallest change this length can reliably detect: \(mde) \(o.displayUnit). Meaningful change: \(HabitTrialCopy.bare(reg.mcid * o.betterDirection.sign, outcome: o)) \(o.displayUnit).")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if reg.isUnderpowered {
                Text(reg.recommendedLength().map { "This is likely too short to tell. \($0) days would give it a fair chance." }
                     ?? "Even the longest trial may be too short to tell for your nights. You can still run it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func loadBaseline() async {
        let snapshot = await HabitLedgerSource.build(repo: model.repo, asOf: today)
        baseline = snapshot.inputs.outcomes[entry.primaryOutcome] ?? [:]
    }

    private func start() {
        starting = true
        UserDefaults.standard.set(coolRoomConfirmed, forKey: HabitTrialStore.coolRoomConfirmedKey)
        Task {
            let result = await trials.start(entry: entry, lengthDays: lengthDays, usualPerWeek: usualPerWeek,
                                            repo: model.repo)
            starting = false
            switch result {
            case .success:
                HabitTrialQuestBridge.shared.sync()
                dismiss()
            case .failure(let e):
                error = e.text
            }
        }
    }
}
