import SwiftUI
import StrandAnalytics
import StrandDesign

// EnergyTileView.swift — the energy bank, on Today.
//
// The day's available energy as a running balance, drawn as a tick bar: what is left in yellow, what
// the day opened with behind it in grey, the empty track beyond.
//
// THREE NUMBERS, NOT ONE. The balance alone says how much is left and nothing about why. The spends
// underneath name where it went, which is the only part a wearer can act on.
//
// THE BAR FILLS AGAINST THE DAY'S OWN OPENING, not against 100 — see `EnergyTicks`.
//
// IT ONLY CALLS ITSELF "ENERGY" ONCE IT HAS EARNED IT. The balance is a model of a feeling, so the tile
// asks for the feeling — one tap, 1 to 5 — and `EnergyCalibration` judges the model against the answers
// (`EnergyCheckInStore`). Until there are enough, the figure is an estimate: rounded, marked "≈", with
// the `calibrating` tier and a "Tell me how you feel" prompt. Once there are enough and it tracks the
// wearer, it is drawn under the wearer's own fitted weights and named energy. If it does not track them
// even after fitting, it says so, renames itself a load estimate and offers to hide — it never argues
// with a person about how tired they are.
//
// UNKNOWN IS DRAWN AS UNKNOWN. No recovery and no sleep score is an empty track and a dash.

struct EnergyTileView: View {
    let balance: EnergyBalance?
    var onOpen: (() -> Void)? = nil

    @ObservedObject private var store = EnergyCheckInStore.shared
    @AppStorage(EnergyCheckInStore.hiddenKey) private var hidden = false

    var body: some View {
        // The balance under the weights the verdict chose (the wearer's fitted set once earned).
        let shown = store.calibrated(balance)
        let mode = EnergyCalibration.tileMode(balance: shown, verdict: store.verdict)
        if hidden && mode == .loadEstimate {
            EmptyView()
        } else {
            StrandCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    summary(shown, mode)
                    footer(mode)
                    // The inputs are the ones this figure was drawn from, so the answer is compared with
                    // exactly what the wearer was looking at.
                    EnergyCheckInPrompt(inputs: balance?.inputs)
                }
            }
            // Pair a check-in taken in the morning flow (before any balance existed) with this one.
            .task(id: balance) {
                if let inputs = balance?.inputs { store.attach(inputs) }
            }
        }
    }

    // MARK: - The figure

    @ViewBuilder
    private func summary(_ shown: EnergyBalance?, _ mode: EnergyCalibration.TileMode) -> some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.signalYellow)
                Text(mode == .loadEstimate ? "LOAD ESTIMATE" : "ENERGY")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(EnergyCalibration.displayValue(shown?.balance, mode: mode))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(mode == .unknown ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                // The plain-words band only where the figure is the wearer's energy; on an estimate it
                // would dress a guess in a verdict.
                if mode == .energy, let shown {
                    Text(EnergyBank.state(shown.balance))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            if case let .calibrating(done, needed, _, _) = mode {
                ScoreStatePill(.calibrating, text: "Calibrating · \(done) of \(needed) check-ins")
            }

            EnergyTicks(opening: (shown?.opening ?? 0) / 100,
                        remaining: (shown?.balance ?? 0) / 100)

            if let shown {
                // WHERE IT WENT. Only the spends that actually happened.
                HStack(spacing: 12) {
                    if shown.strainSpend > 0.5 {
                        spendLabel("strain", shown.strainSpend, StrandPalette.effortColor)
                    }
                    if shown.stressSpend > 0.5 {
                        spendLabel("stress", shown.stressSpend, StrandPalette.statusWarning)
                    }
                    if shown.awakeSpend > 0.5 {
                        spendLabel("awake", shown.awakeSpend, StrandPalette.textSecondary)
                    }
                    if shown.restReturn > 0.5 {
                        spendLabel("calm", -shown.restReturn, StrandPalette.statusPositive)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Needs today's Charge or Rest score to open a balance.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        if let onOpen {
            Button(action: onOpen) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// One spend, signed. A negative one is a return.
    private func spendLabel(_ name: LocalizedStringKey, _ points: Double, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(points < 0 ? "+\(Int((-points).rounded()))" : "−\(Int(points.rounded()))")
                .font(StrandFont.caption)
                .foregroundStyle(tint)
            Text(name)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - What the figure may be called

    @ViewBuilder
    private func footer(_ mode: EnergyCalibration.TileMode) -> some View {
        let v = store.verdict
        switch mode {
        case .unknown:
            EmptyView()
        case let .calibrating(_, _, days, neededDays):
            Text("An estimate from Charge, Rest, Effort and stress, not yet checked against how you feel (\(days) of \(neededDays) days).")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .energy:
            if let a = v.decidingAgreement {
                Text(agreementLine(a, before: v.fitted ? v.before : nil, usable: v.usable))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loadEstimate:
            VStack(alignment: .leading, spacing: 6) {
                Text(weakLine(v))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hide this tile") { hidden = true }
                    .font(StrandFont.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private func agreementLine(_ a: EnergyCalibration.Agreement,
                               before: EnergyCalibration.Agreement?, usable: Int) -> String {
        let now = String(format: "%.2f", a.rho)
        if let before {
            let then = String(format: "%.2f", before.rho)
            return String(localized: "Fitted to your \(usable) check-ins: agreement \(then) → \(now).")
        }
        return String(localized: "Matches your \(usable) check-ins: agreement \(now).")
    }

    private func weakLine(_ v: EnergyCalibration.Verdict) -> String {
        let rho = v.decidingAgreement.map { String(format: "%.2f", $0.rho) } ?? TelosType.absent
        return String(localized: "This doesn't track how you say you feel (agreement \(rho) over \(v.usable) check-ins, even after fitting), so it is a load estimate from your data, not your energy.")
    }

}

// MARK: - Tell me how you feel

/// The one-tap 1–5 energy check-in. Used by the Today tile (the current slot, with the inputs the tile
/// is drawing) and by the morning flow (`slot: .morning`, no inputs yet — matched to the first balance
/// Today computes). Renders nothing once its slot is answered for the day.
struct EnergyCheckInPrompt: View {
    /// The slot to ask about; nil asks about the current wall-clock slot.
    var slot: EnergyCheckIn.Slot? = nil
    /// The model inputs the wearer is looking at, when there are any.
    var inputs: EnergyInputs? = nil
    var question: LocalizedStringKey = "Tell me how you feel"

    @ObservedObject private var store = EnergyCheckInStore.shared
    /// Set for a moment after a tap, so the answer is acknowledged rather than simply vanishing.
    @State private var justLogged = false

    var body: some View {
        let asking = slot ?? EnergyCheckInStore.slot(at: Date())
        if justLogged {
            Text("Logged. Thank you.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if store.checkIn(slot: asking) == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(question)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            store.record(felt: level, slot: asking, inputs: inputs)
                            justLogged = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                justLogged = false
                            }
                        } label: {
                            Text("\(level)")
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Energy \(level) of 5"))
                    }
                }
                HStack {
                    Text("empty")
                    Spacer()
                    Text("full")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

/// The three-state tick bar: yellow to `remaining`, the lighter "what the day opened with" grey on to
/// `opening`, the empty track beyond it.
private struct EnergyTicks: View {
    let opening: Double
    let remaining: Double

    private let ticks = 34

    var body: some View {
        Canvas { context, size in
            let gap = size.width / (Double(ticks) * 2 - 1)
            for i in 0..<ticks {
                let t = Double(i + 1) / Double(ticks)
                let colour: Color
                if t <= remaining {
                    colour = StrandPalette.signalYellow
                } else if t <= opening {
                    colour = StrandPalette.textSecondary.opacity(0.55)
                } else {
                    colour = StrandPalette.hairlineStrong
                }
                let x = Double(i) * gap * 2
                let rect = CGRect(x: x, y: 0, width: gap, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: gap / 2), with: .color(colour))
            }
        }
        .frame(height: 18)
    }
}
