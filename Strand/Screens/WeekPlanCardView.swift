import SwiftUI
import StrandAnalytics
import StrandDesign

// WeekPlanCardView.swift — the "This week" card (HEALTH_V2 S3 §3.1; placement DESIGN_V2 §6.14: top of the
// Health tab, with the day's line in Today's State card). Built from existing tokens only; the BODY design
// package restyles it (TelosLinearScale, pips, caret) without changing what it says.
//
// HONESTY: a nil target renders as "—" plus its reason (calibrating n of 3 weeks, steps not calibrated),
// never as 0; a bar is drawn only from a measured figure against a real target or the WHO range; minutes
// partly from imported zones carry "≈"; sessions without heart rate are named, not scored.
//
// COST: static. No animation, no timer; it re-renders only when `WeekPlanSource` publishes.
//
// TELOS (BODY): a glass card; aerobic minutes on a thin linear scale with the WHO range hatched and the
// week's target as a caret; strength sessions as pips; the step target as a caret over the measured daily
// mean; the day's guidance line as the card's closing word. The scales GROW to hold the value (a week past
// its target shows past the caret, never clipped at the end of the track).

struct WeekPlanCardView: View {
    @ObservedObject var source: WeekPlanSource
    @State private var showDetail = false

    var body: some View {
        StrandCard(tint: TelosColor.mint) {
            if let plan = source.currentPlan {
                content(plan)
            } else {
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    Text(String(localized: "This week"))
                        .telosScale()
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.textTertiary)
                    AbsentValue(reasonText: Text(String(localized: "Not enough data yet")), arrangement: .inline)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            header(plan)
            if plan.easyOffer == .offered { offer(plan) }
            aerobicRow(plan)
            if plan.hardSessionTarget > 0 { hardRow(plan) }
            strengthRow(plan)
            stepsRow(plan)
            if let g = source.todayGuidance { todayRow(g) }
            if source.progress?.midWeekLoadNote == true {
                Text(WeekPlanEngine.midWeekLoadLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let review = source.lastReview {
                if Self.isMonday(Date()) {
                    WeekReviewView(review: review)
                } else {
                    DisclosureGroup(String(localized: "Last week's review")) {
                        WeekReviewView(review: review)
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            DisclosureGroup(String(localized: "How this plan is made"), isExpanded: $showDetail) {
                detail(plan)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func header(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WeekPlanEngine.header(plan))
                .telosScale()
                .foregroundStyle(plan.type == .build ? TelosColor.mint : TelosColor.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.range(plan))
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textTertiary)
        }
    }

    private func offer(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Three build weeks met in a row. Take a lighter week? A lighter week is common coaching practice; direct evidence that it improves results is limited. Keeping the plan costs nothing."))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NoopButton("Take an easy week", kind: .secondary) { source.respondToEasyOffer(accept: true) }
                NoopButton("Keep building", kind: .tertiary) { source.respondToEasyOffer(accept: false) }
            }
        }
    }

    // MARK: - Rows

    private func aerobicRow(_ plan: WeekPlan) -> some View {
        let p = source.progress
        let approx = p?.approximate == true ? "≈" : ""
        let done = p.map { approx + Self.whole($0.aerobicDone) } ?? "\u{2014}"
        let value: String
        let caption: String
        if let target = plan.aerobicTarget {
            value = "\(done) / \(Self.whole(target)) min"
            caption = String(localized: "vigorous counts double")
        } else {
            value = "\(done) min"
            caption = String(localized: "Calibrating (\(plan.validBaselineWeeks) of \(WeekPlanEngine.minValidWeeks) weeks) · WHO range 150–300 min")
        }
        return VStack(alignment: .leading, spacing: 4) {
            line(String(localized: "Aerobic"), value, caption: caption)
            // Measured minutes against the WHO range (hatched) and the week's target (caret). Drawn only
            // from a measured figure; with no progress read yet the row stays text + "—".
            if let p {
                PlanScale(value: p.aerobicDone, target: plan.aerobicTarget,
                          band: WeekPlanEngine.whoLow...WeekPlanEngine.whoHigh, tint: TelosColor.mint)
                    .padding(.leading, 74)
            }
            if let p, p.unmeasuredSessions > 0 {
                Text(String(localized: "\(p.unmeasuredSessions) session(s) without heart rate — counted, no minutes"))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
    }

    private func hardRow(_ plan: WeekPlan) -> some View {
        let done = source.progress.map { String($0.hardSessionsDone) } ?? "\u{2014}"
        let caption = plan.hardSessionOptional ? String(localized: "optional") : String(localized: "moved by your HRV trend")
        return line(String(localized: "Hard"), "\(done) / \(plan.hardSessionTarget)", caption: caption)
    }

    private func strengthRow(_ plan: WeekPlan) -> some View {
        let done = source.progress.map { String($0.strengthDone) } ?? "\u{2014}"
        let target = plan.strength.minSessions == plan.strength.maxSessions
            ? "\(plan.strength.minSessions)"
            : "\(plan.strength.minSessions)–\(plan.strength.maxSessions)"
        var parts: [String] = []
        if let last = source.lastLiftSession {
            parts.append(String(localized: "last import \(last.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"))
        }
        if plan.strength.holdLoads {
            parts.append(String(localized: "about two-thirds of your usual sets, loads held"))
        } else if let s = source.strengthLine {
            parts.append(s)
        }
        return VStack(alignment: .leading, spacing: 4) {
            line(String(localized: "Strength"), "\(done) / \(target) sessions",
                 caption: parts.isEmpty ? nil : parts.joined(separator: "; "))
            // Sessions as pips (one cell per planned session); only with a measured count.
            if let p = source.progress, plan.strength.maxSessions > 0 {
                TelosSegmentedBar(value: Double(p.strengthDone),
                                  scale: Double(plan.strength.maxSessions),
                                  segments: plan.strength.maxSessions,
                                  color: TelosColor.muscle)
                    .frame(maxWidth: 120, alignment: .leading)
                    .padding(.leading, 74)
            }
        }
    }

    private func stepsRow(_ plan: WeekPlan) -> some View {
        guard let target = plan.stepsTarget else {
            return line(String(localized: "Steps"), "\u{2014}",
                        caption: String(localized: "Steps not calibrated — calibrate with a walk to get a step target"))
        }
        let mean = source.progress?.stepsMeanReliable.map { Int($0.rounded()).formatted() } ?? "\u{2014}"
        var caption = plan.stepsMedian.map { String(localized: "your median \(Int($0.rounded()).formatted())") } ?? ""
        if !plan.ageKnown && target >= plan.stepsPlateau {
            caption += (caption.isEmpty ? "" : " · ")
                + String(localized: "\(Int(plan.stepsPlateau).formatted()) — the lower end of where benefits level off")
        }
        return VStack(alignment: .leading, spacing: 4) {
            line(String(localized: "Steps"), "\(mean) / day target \(Int(target).formatted())",
                 caption: caption.isEmpty ? nil : caption)
            // The day target as a caret over the reliable daily mean (drawn only when that mean exists).
            if let reliable = source.progress?.stepsMeanReliable {
                PlanScale(value: reliable, target: target, band: nil, tint: TelosColor.teal)
                    .padding(.leading, 74)
            }
        }
    }

    private func todayRow(_ g: DayGuidance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(localized: "Today"))
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
                    .frame(width: 64, alignment: .leading)
                Text(g.line)
                    .font(TelosType.headline)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(g.qualifiers, id: \.self) { q in
                Text(q)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .padding(.leading, 74)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.reasons.compactMap { $0.evidenceNote }, id: \.self) { note in
                Text(note)
            }
            Text(SessionIntensity.limitNote)
            Text(String(localized: "Aerobic minutes are moderate (40–59 % of heart-rate reserve) plus vigorous (60 % and above) counted double, toward the WHO range of 150–300 minutes a week. Targets rise from your own baseline by at most 30 % a week. VO₂max is shown only as a monthly trend with its ±5 error band, never as a target."))
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Pieces

    private func line(_ label: String, _ value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textSecondary)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .font(TelosType.numeralS)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                Text(caption)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .padding(.leading, 74)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    static func whole(_ x: Double) -> String { String(Int(x.rounded())) }

    static func date(_ ymd: String) -> Date? {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(ymd) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    static func range(_ plan: WeekPlan) -> String {
        guard let a = date(plan.weekStart), let b = date(plan.weekEnd) else { return plan.weekStart }
        let f = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        return a.formatted(f) + " – " + b.formatted(f)
    }

    static func isMonday(_ d: Date) -> Bool { Calendar.current.component(.weekday, from: d) == 2 }
}

// MARK: - Plan scale

/// A thin linear scale (§6.14): the track, an optional HATCHED range (the WHO band), the measured fill and
/// an optional hollow-topped caret at the target. The top of the scale grows to hold the value and the
/// target, so overflow is visible rather than clipped. Only built from a measured figure. Static.
private struct PlanScale: View {
    let value: Double
    let target: Double?
    let band: ClosedRange<Double>?
    let tint: Color

    private let track: CGFloat = 6
    private let caretHeight: CGFloat = 14

    var body: some View {
        let candidates: [Double] = [value, target, band?.upperBound].compactMap { $0 }.filter { $0.isFinite }
        let top: Double = max((candidates.max() ?? 1) * 1.08, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { v in CGFloat(min(max(v / top, 0), 1)) * w }
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(TelosColor.surfaceInset)
                    .frame(height: track)
                if let band {
                    let bx = x(band.lowerBound)
                    let bw = max(0, x(band.upperBound) - bx)
                    DiagonalHatch(spacing: 4)
                        .stroke(TelosColor.lineStrong, lineWidth: TelosStroke.hair)
                        .frame(width: bw, height: track)
                        .clipShape(Rectangle())
                        .offset(x: bx)
                }
                if value > 0 {
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: max(track, x(value)), height: track)
                }
                if let target, target.isFinite {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .strokeBorder(TelosColor.textPrimary, lineWidth: 1)
                        .frame(width: 3, height: caretHeight)
                        .offset(x: min(max(0, x(target) - 1.5), max(0, w - 3)))
                }
            }
            .frame(width: w, height: caretHeight)
        }
        .frame(height: caretHeight)
        .accessibilityHidden(true)
    }
}
