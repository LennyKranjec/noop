import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitTrialResultView.swift — a finished trial's verdict (HEALTH_V2 §S1-B.6, DESIGN_V2 §5.15 "Result card").
// Logic only; the PROGRESS package restyles it. Colour never encodes the verdict; exploratory numbers sit
// in their own section and never beside the verdict as if they were one.

struct HabitTrialResultView: View {
    let record: HabitTrialRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if let result = record.result {
                    content(result)
                } else {
                    Text(HealthAbsence.notLogged.line).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(record.entry?.title ?? record.registration.interventionId)
    }

    @ViewBuilder
    private func content(_ r: HabitTrialResult) -> some View {
        let outcome = r.primaryOutcome
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("RESULT").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                if let verdict = r.verdict {
                    Text(verdict.headline).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(HabitTrialCopy.body(verdict: verdict, habit: record.entry?.title ?? "This habit", result: r))
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text(HabitTrialCopy.altered).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                if let e = r.estimate, let lo = r.lower, let hi = r.upper {
                    Text("\(HabitTrialCopy.signed(e, outcome: outcome)) · 95% interval \(HabitTrialCopy.bare(lo, outcome: outcome)) to \(HabitTrialCopy.bare(hi, outcome: outcome))")
                        .font(StrandFont.mono(13)).foregroundStyle(StrandPalette.textPrimary)
                    Text("Meaningful change set before the start: \(HabitTrialCopy.bare(outcome.betterDirection.sign * r.mcid, outcome: outcome))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("SAMPLE").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                row("Valid nights", "ON \(r.nOn) · OFF \(r.nOff) of \(r.plannedPerArm) each")
                row("Missing", "ON \(r.missingOn) · OFF \(r.missingOff)")
                if r.washoutDays > 0 { row("Washout days (not analysed)", "\(r.washoutDays)") }
                row("Followed on ON days", percent(r.adherenceOn))
                row("Did it anyway on OFF days", percent(r.contaminationOff))
                if r.illnessDays > 0 { row("Days with an illness heads-up", "\(r.illnessDays)") }
                if let m1 = r.meanOn, let m0 = r.meanOff {
                    row("Average, ON / OFF", "\(display(m1, outcome)) / \(display(m0, outcome))")
                }
                if let rho = r.residualLag1 {
                    row("Night-to-night link", String(format: "%.2f", rho))
                    if rho > 0.3 {
                        Text("Your nights are strongly linked day to day — a trial like this needs more days.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        let exploratory = [r.perProtocol, r.alcoholExcluded].compactMap { $0 } + r.secondaries
        if !exploratory.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("EXPLORATORY — NOT PART OF THE VERDICT").font(StrandFont.overline)
                        .foregroundStyle(StrandPalette.textTertiary)
                    ForEach(Array(exploratory.enumerated()), id: \.offset) { _, x in
                        row(x.name, x.estimate.map { "\(HabitTrialCopy.signed($0, outcome: x.outcome)) (ON \(x.nOn) · OFF \(x.nOff))" }
                                ?? HealthAbsence.tooFewNights(have: min(x.nOn, x.nOff), need: 3).line)
                    }
                }
            }
        }
        Text(HabitTrialCopy.blinding).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func display(_ v: Double, _ outcome: HabitOutcome) -> String {
        if outcome.isLogScale { return String(format: "%.0f ms", exp(v)) }
        if outcome == .onsetClockMin {
            let m = Int(v.rounded()) % 1440
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        return String(format: "%.1f", v) + " " + outcome.displayUnit
    }
}
