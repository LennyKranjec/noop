import SwiftUI
import StrandAnalytics
import StrandDesign

// EnergyTileView.swift — the energy bank, on Today.
//
// The day's available energy as a running balance, drawn as a tick bar: what is left in yellow, what
// the day opened with behind it in grey, the empty track beyond. Discrete ticks rather than one solid
// rail so the two greys stay legible against each other at a glance — the same instrument the Android
// energy bar uses.
//
// THREE NUMBERS, NOT ONE. The balance alone says how much is left and nothing about why. The spends
// underneath name where it went, which is the only part a wearer can act on: a day at 40 because of
// strain and a day at 40 because of stress call for opposite things.
//
// THE BAR FILLS AGAINST THE DAY'S OWN OPENING, not against 100. A day that woke at 55 % recovery and
// has spent nothing is FULL — it is full of what it had — and drawing it half-empty against a hundred
// would tell that wearer they were behind before they got up.
//
// UNKNOWN IS DRAWN AS UNKNOWN. No recovery and no sleep score is an empty track and a dash, never a
// bank drawn from an assumed middle.

struct EnergyTileView: View {
    let balance: EnergyBalance?
    var onOpen: (() -> Void)? = nil

    var body: some View {
        let tile = StrandCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.signalYellow)
                    Text("ENERGY")
                        .font(StrandFont.overline)
                        .tracking(1.2)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Text(balance.map { "\(Int($0.balance.rounded()))" } ?? "–")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(balance == nil
                                         ? StrandPalette.textTertiary
                                         : StrandPalette.textPrimary)
                    if let balance {
                        Text(EnergyBank.state(balance.balance))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }

                EnergyTicks(opening: (balance?.opening ?? 0) / 100,
                            remaining: (balance?.balance ?? 0) / 100)

                if let balance {
                    // WHERE IT WENT. Only the spends that actually happened — a day with no stress read
                    // should not carry a "stress 0" that reads as a measured calm.
                    HStack(spacing: 12) {
                        if balance.strainSpend > 0.5 {
                            spendLabel("strain", balance.strainSpend, StrandPalette.effortColor)
                        }
                        if balance.stressSpend > 0.5 {
                            spendLabel("stress", balance.stressSpend, StrandPalette.statusWarning)
                        }
                        if balance.restReturn > 0.5 {
                            spendLabel("rest", -balance.restReturn, StrandPalette.statusPositive)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Needs an overnight recovery or sleep score to open a balance.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }

        if let onOpen {
            Button(action: onOpen) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }

    /// One spend, signed. A negative one is a return, which is the only way rest appears in this row.
    private func spendLabel(_ name: String, _ points: Double, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(points < 0 ? "+\(Int((-points).rounded()))" : "−\(Int(points.rounded()))")
                .font(StrandFont.caption)
                .foregroundStyle(tint)
            Text(name)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
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
