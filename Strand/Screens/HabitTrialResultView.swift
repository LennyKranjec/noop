import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitTrialResultView.swift — a finished trial's verdict (HEALTH_V2 §S1-B.6, DESIGN_V2 §5.15 "Result card").
// Colour never encodes the verdict; exploratory numbers sit in their own section and never beside the
// verdict as if they were one.
//
// TELOS 2.0: the RESULT card — overline + outline verdict tag, the verdict word in `title2`, its sentence,
// the effect line (estimate · 95 % CI) in mono, and the effect-interval plot drawn exactly as given against
// zero and the meaningful band (identical styling for every verdict). Then the sample, then exploratory.
// COST: static.

struct HabitTrialResultView: View {
    let record: HabitTrialRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.sectionGap) {
                if let result = record.result {
                    content(result)
                } else {
                    AbsentValue(verbatimReason: HealthAbsence.notLogged.text)
                }
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.vertical, TelosSpace.l)
        }
        .background(TelosColor.groundGradient.ignoresSafeArea())
        .navigationTitle(record.entry?.title ?? record.registration.interventionId)
    }

    @ViewBuilder
    private func content(_ r: HabitTrialResult) -> some View {
        let outcome = r.primaryOutcome
        StrandCard(tint: TelosColor.teal) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                HStack(spacing: TelosSpace.s) {
                    PGOverline("Result", ink: TelosColor.teal)
                    Spacer(minLength: TelosSpace.s)
                    HabitVerdictTag(verdict: r.verdict)
                }
                Text(record.entry?.title ?? record.registration.interventionId)
                    .font(TelosType.headline)
                    .foregroundStyle(TelosColor.textSecondary)
                Text("Outcome: \(outcome.label)")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textTertiary)
                if let verdict = r.verdict {
                    Text(verdict.headline)
                        .font(TelosType.title2)
                        .foregroundStyle(TelosColor.textPrimary)
                    Text(HabitTrialCopy.body(verdict: verdict, habit: record.entry?.title ?? "This habit", result: r))
                        .font(TelosType.body)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(HabitTrialCopy.altered)
                        .font(TelosType.title2)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let e = r.estimate, let lo = r.lower, let hi = r.upper {
                    Text(verbatim: "\(HabitTrialCopy.signed(e, outcome: outcome)) · 95% CI \(HabitTrialCopy.bare(lo, outcome: outcome)) to \(HabitTrialCopy.bare(hi, outcome: outcome))")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textPrimary)
                    EffectIntervalPlot(estimate: outcome.display(e), lower: outcome.display(lo), upper: outcome.display(hi),
                                       meaningfulLow: outcome.display(-r.mcid), meaningfulHigh: outcome.display(r.mcid),
                                       betterIsHigher: outcome.betterDirection == .increase,
                                       format: HabitsHubView.signedDisplay,
                                       claimsHelped: r.verdict == .helped)
                    Text("Meaningful change set before the start: \(HabitTrialCopy.bare(outcome.betterDirection.sign * r.mcid, outcome: outcome))")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "ON \(r.nOn) · OFF \(r.nOff) VALID NIGHTS · \(r.missingOn + r.missingOff) EXCLUDED")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
            }
        }
        StrandCard {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                PGOverline("Sample")
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
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        let exploratory = [r.perProtocol, r.alcoholExcluded].compactMap { $0 } + r.secondaries
        if !exploratory.isEmpty {
            StrandCard {
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    PGOverline("Exploratory — not part of the verdict")
                    ForEach(Array(exploratory.enumerated()), id: \.offset) { _, x in
                        row(x.name, x.estimate.map { "\(HabitTrialCopy.signed($0, outcome: x.outcome)) (ON \(x.nOn) · OFF \(x.nOff))" }
                                ?? HealthAbsence.tooFewNights(have: min(x.nOn, x.nOff), need: 3).line)
                    }
                }
            }
        }
        Text(HabitTrialCopy.blinding)
            .font(TelosType.caption)
            .foregroundStyle(TelosColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: TelosSpace.s)
            Text(value)
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
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
