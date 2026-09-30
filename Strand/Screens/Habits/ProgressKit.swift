import SwiftUI
import StrandDesign
import StrandAnalytics

// ProgressKit.swift — the small shared pieces of the PROGRESS package (Habits, trials, quests, goals,
// meditation) in the Telos 2.0 look: the small-caps overline, the verdict tag, the trial pips and the
// effect-interval plot (DESIGN_V2 §5.15). View-only: every figure comes from the caller, nothing is
// computed here that a store or engine already owns.
//
// COST: all static shapes / one Canvas per plot, redrawn only when their inputs change. No clocks.

// MARK: - Overline (the label voice)

/// SF Pro semibold, UPPERCASE, +1.6 tracking — the reference's wide small caps ("TRIAL", "RESULT").
struct PGOverline: View {
    private let text: Text
    private let ink: Color

    init(_ key: LocalizedStringKey, ink: Color = TelosColor.textTertiary) {
        self.text = Text(key)
        self.ink = ink
    }

    init(verbatim: String, ink: Color = TelosColor.textTertiary) {
        self.text = Text(verbatim: verbatim)
        self.ink = ink
    }

    init(text: Text, ink: Color = TelosColor.textTertiary) {
        self.text = text
        self.ink = ink
    }

    var body: some View {
        text
            .telosScale()
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A thin glyph beside an overline — the reference's card headers ("⚡ Recommendation", "◎ Mind & Focus").
/// The glyph defaults to a neutral ink (decision 19: no decorative green); pass a part's hue when the
/// header names a measured part.
struct PGGlyphHeader: View {
    let systemImage: String
    let title: Text
    var tint: Color = TelosColor.textSecondary
    var trailing: Text? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            Image(systemName: systemImage)
                .font(TelosType.glyphChevron)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            PGOverline(text: title, ink: TelosColor.textSecondary)
            Spacer(minLength: TelosSpace.s)
            if let trailing {
                trailing
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Verdict tag (§5.15: colour never encodes the verdict beyond the tag's outline)

/// The trial verdict word as an OUTLINE tag: helped → positive outline (never filled); no meaningful
/// effect and inconclusive → the same neutral tag (they must look identical); an altered record → neutral.
struct HabitVerdictTag: View {
    let verdict: HabitTrialVerdict?

    var body: some View {
        switch verdict {
        case .some(.helped):
            TelosTag(verbatim: verdict?.headline ?? "", ink: TelosColor.positive, filled: false)
        case .some(let v):
            TelosTag(verbatim: v.headline, ink: TelosColor.textSecondary, filled: false)
        case .none:
            TelosTag(verbatim: HabitTrialCopy.altered, ink: TelosColor.textSecondary, filled: false, dashed: true)
        }
    }
}

// MARK: - Trial pips (§5.15 "Progress")

/// One arm's analysable nights as cells: valid = filled, not yet = an empty track. The store exposes
/// counts only (the schedule stays sealed), so no per-day pattern is drawn — only how many are in.
struct TrialPipRow: View {
    let arm: Text
    let valid: Int
    let planned: Int
    var tint: Color = TelosColor.textPrimary

    var body: some View {
        let cells = max(planned, 1)
        HStack(alignment: .center, spacing: TelosSpace.s) {
            arm
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)
                .frame(minWidth: 34, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<cells, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(i < valid ? tint : TelosColor.lineSoft)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(i < valid ? Color.clear : TelosColor.line, lineWidth: TelosStroke.hair)
                        )
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: .infinity)
            Text("\(valid) / \(planned) VALID")
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arm)
        .accessibilityValue(Text("\(valid) of \(planned) valid nights"))
    }
}

// MARK: - Effect-interval plot (§5.15)

/// The estimate and its 95 % interval against zero and the meaningful band — drawn EXACTLY as given,
/// with identical styling for every verdict (colour never encodes the verdict).
///
/// All inputs are in DISPLAY units (`HabitOutcome.display`), so a log-scale outcome reads in %:
/// `meaningfulHigh` = display(+MCID), `meaningfulLow` = display(−MCID) (negative). `betterIsHigher` says
/// which side of zero is better in those units.
///
/// Geometry: symmetric around 0 with half-width max(|lo|, |hi|, 2·MID) × 1.15; the zero line 1 pt
/// `lineStrong`; the better side's region beyond ±MID shaded `positive` @ 0.10 behind a dashed 1 pt line;
/// the interval a 2 pt line with 1.5 pt × 12 pt whiskers and a 9 pt point in a 2 pt ring.
struct EffectIntervalPlot: View {
    let estimate: Double
    let lower: Double
    let upper: Double
    let meaningfulLow: Double
    let meaningfulHigh: Double
    let betterIsHigher: Bool
    /// Formats an axis value ("+4", "−12").
    let format: (Double) -> String
    /// The verdict the model reported — only for the Debug honesty guard below.
    var claimsHelped: Bool = false

    private var halfWidth: Double {
        let mid = Swift.max(abs(meaningfulLow), abs(meaningfulHigh))
        let raw = Swift.max(abs(lower), abs(upper), 2 * mid) * 1.15
        return raw.isFinite && raw > 0 ? raw : 1
    }

    var body: some View {
        #if DEBUG
        // Honesty guard (§5.15): a "helped" verdict whose interval still crosses zero is a model bug —
        // the plot keeps drawing the interval truthfully, and Debug says so loudly.
        if claimsHelped && lower < 0 && upper > 0 {
            assertionFailure("EffectIntervalPlot: 'helped' with an interval that crosses zero")
        }
        #endif
        return VStack(alignment: .leading, spacing: TelosSpace.xs) {
            Canvas { ctx, size in
                draw(&ctx, size)
            }
            .frame(height: 64)
            HStack {
                Text(verbatim: format(-halfWidth / 1.15))
                Spacer(minLength: 0)
                Text(verbatim: "0")
                Spacer(minLength: 0)
                Text(verbatim: format(halfWidth / 1.15))
            }
            .font(TelosType.scaleNumber)
            .foregroundStyle(TelosColor.textTertiary)
            HStack {
                if betterIsHigher { Spacer(minLength: 0) }
                Text(betterIsHigher ? "BETTER \u{2192}" : "\u{2190} BETTER")
                    .telosScale()
                    .foregroundStyle(TelosColor.textTertiary)
                if !betterIsHigher { Spacer(minLength: 0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effect interval"))
        .accessibilityValue(Text("Estimate \(format(estimate)), 95% interval \(format(lower)) to \(format(upper)). Meaningful beyond \(format(betterIsHigher ? meaningfulHigh : meaningfulLow))."))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w: CGFloat = size.width
        let h: CGFloat = size.height
        let half: Double = halfWidth
        func x(_ v: Double) -> CGFloat {
            let t: Double = (v + half) / (2 * half)
            return CGFloat(Swift.min(Swift.max(t, 0), 1)) * w
        }
        let midY: CGFloat = h / 2

        // The meaningful region on the better side.
        let edge: CGFloat = betterIsHigher ? x(meaningfulHigh) : x(meaningfulLow)
        let band = betterIsHigher
            ? CGRect(x: edge, y: 0, width: Swift.max(0, w - edge), height: h)
            : CGRect(x: 0, y: 0, width: Swift.max(0, edge), height: h)
        ctx.fill(Path(band), with: .color(TelosColor.positive.opacity(TelosOpacity.wash)))
        ctx.draw(Text("MEANINGFUL").font(TelosType.scale).foregroundColor(TelosColor.positive),
                 at: CGPoint(x: betterIsHigher ? w - 4 : 4, y: 8),
                 anchor: betterIsHigher ? .topTrailing : .topLeading)

        // ±MID dashed lines.
        for v in [meaningfulLow, meaningfulHigh] {
            var p = Path()
            p.move(to: CGPoint(x: x(v), y: 0))
            p.addLine(to: CGPoint(x: x(v), y: h))
            ctx.stroke(p, with: .color(TelosColor.line), style: StrokeStyle(lineWidth: TelosStroke.line, dash: [3, 3]))
        }

        // Zero line.
        var zero = Path()
        zero.move(to: CGPoint(x: x(0), y: 0))
        zero.addLine(to: CGPoint(x: x(0), y: h))
        ctx.stroke(zero, with: .color(TelosColor.lineStrong), lineWidth: TelosStroke.line)

        // The interval: line, whiskers, point — identical for every verdict.
        let lo = x(lower)
        let hi = x(upper)
        var line = Path()
        line.move(to: CGPoint(x: lo, y: midY))
        line.addLine(to: CGPoint(x: hi, y: midY))
        ctx.stroke(line, with: .color(TelosColor.textPrimary),
                   style: StrokeStyle(lineWidth: TelosStroke.data, lineCap: .round))
        for wx in [lo, hi] {
            var whisker = Path()
            whisker.move(to: CGPoint(x: wx, y: midY - 6))
            whisker.addLine(to: CGPoint(x: wx, y: midY + 6))
            ctx.stroke(whisker, with: .color(TelosColor.textPrimary),
                       style: StrokeStyle(lineWidth: TelosStroke.strong, lineCap: .round))
        }
        let px = x(estimate)
        let ring = CGRect(x: px - 6.5, y: midY - 6.5, width: 13, height: 13)
        ctx.fill(Path(ellipseIn: ring), with: .color(TelosColor.surface))
        let dot = CGRect(x: px - 4.5, y: midY - 4.5, width: 9, height: 9)
        ctx.fill(Path(ellipseIn: dot), with: .color(TelosColor.textPrimary))
    }
}

// MARK: - A glass sub-panel (inset band inside a card)

extension View {
    /// The inset band used inside glass cards (today's assignment, a debt sub-block): a darker well with
    /// a hairline, radius `control`. Static fills only.
    func pgInsetBand(tint: Color? = nil, radius: CGFloat = TelosRadius.control) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(tint.map { $0.opacity(TelosOpacity.whisper) } ?? TelosColor.surfaceInset.opacity(0.55)))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(TelosOpacity.border) } ?? TelosColor.line,
                                        lineWidth: TelosStroke.hair))
    }
}
