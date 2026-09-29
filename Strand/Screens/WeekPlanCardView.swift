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

struct WeekPlanCardView: View {
    @ObservedObject var source: WeekPlanSource
    @State private var showDetail = false

    var body: some View {
        StrandCard(padding: 16) {
            if let plan = source.currentPlan {
                content(plan)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "This week")).strandOverline()
                    Text("\u{2014} " + String(localized: "Not enough data yet"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(plan.type == .build ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.range(plan))
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textTertiary)
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
        let scaleTop: Double
        if let target = plan.aerobicTarget {
            value = "\(done) / \(Self.whole(target)) min"
            caption = String(localized: "vigorous counts double")
            scaleTop = max(target, 1)
        } else {
            value = "\(done) min"
            caption = String(localized: "Calibrating (\(plan.validBaselineWeeks) of \(WeekPlanEngine.minValidWeeks) weeks) · WHO range 150–300 min")
            scaleTop = WeekPlanEngine.whoLow
        }
        return VStack(alignment: .leading, spacing: 4) {
            line(String(localized: "Aerobic"), value, caption: caption)
            if let p { bar(fraction: p.aerobicDone / scaleTop) }
            if let p, p.unmeasuredSessions > 0 {
                Text(String(localized: "\(p.unmeasuredSessions) session(s) without heart rate — counted, no minutes"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
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
        return line(String(localized: "Strength"), "\(done) / \(target) sessions",
                    caption: parts.isEmpty ? nil : parts.joined(separator: "; "))
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
        return line(String(localized: "Steps"), "\(mean) / day target \(Int(target).formatted())",
                    caption: caption.isEmpty ? nil : caption)
    }

    private func todayRow(_ g: DayGuidance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            line(String(localized: "Today"), g.line, caption: nil)
            ForEach(g.qualifiers, id: \.self) { q in
                Text(q)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
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
                    .font(StrandFont.mono(12))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                Text(caption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, 74)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A plain track with a measured fill (clamped to the track). Only called with a real figure.
    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                Capsule().fill(StrandPalette.accent)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .padding(.leading, 74)
        .accessibilityHidden(true)
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
