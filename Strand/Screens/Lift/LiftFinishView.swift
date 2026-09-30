#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport

/// The finish screen — Telos Lift's full-screen moment (DESIGN_V2 decisions 7, 16, 17).
///
/// It REPLACES the logger inside the live-workout host rather than presenting a cover of its own (decision 7:
/// no screen attaches its own `.fullScreenCover` for a moment; the live workout is already full screen, so the
/// moment is drawn in place and there is nothing to stack or tear down).
///
/// Every figure comes from `LiftSessionSummary` and is honest by construction: a PR has a previous best, an e1RM
/// change has a previous session, a muscle's % change has a previous session of the SAME day — otherwise "—".
///
/// LOOK (decision 19 — clinical restraint): a calm, factual card. The session number sits in a thin neutral
/// ring (no star, no burst, no glow, no gold halo); a personal record is stated in a flat neutral pill with a
/// small gold medal mark — gold is only ever a small flat mark for a PR. MOTION: the content fades and rises
/// once (`TelosMotion.screen`), then rests; Reduce Motion / Low Power / "Reduce motion in NOOP" get a
/// cross-fade. The strap reward buzz AND the phone `reward`
/// haptic for a PR are fired by the recorder once per session (`StrapCueEngine.fire(.reward, eventId:
/// "pr:<session>")`); a session without a PR gets one `success` haptic here, keyed on the session so a
/// re-appear never repeats it.
struct LiftFinishView: View {
    let summary: LiftSessionSummary
    let session: LiftLoggedSession
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var entered = false

    private var hasRecords: Bool { summary.recordCount > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: TelosSpace.l) {
                badge
                    .padding(.top, TelosSpace.l)
                if hasRecords { recordsPill }
                statsRow
                exercisesSection
                musclesSection
                workoutRow
                if !summary.achievements.isEmpty { achievementsSection }
                actions
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.bottom, TelosSpace.xxl)
            .opacity(entered ? 1 : 0)
            .offset(y: entered || reduceMotion ? 0 : TelosMomentStyle.entranceRise)
        }
        .background {
            // The plain ground — no pooled celebration light (decision 19).
            TelosColor.canvas.ignoresSafeArea()
        }
        .onAppear {
            let still = motion.poseStill(reduceMotion)
            withAnimation(still ? TelosMotion.fade : TelosMotion.screen) { entered = true }
            // One phone haptic per finished session: a PR's `reward` is the recorder's; otherwise `success`.
            if !hasRecords { TelosHaptics.play(.success, action: "lift.finish.\(session.id)") }
        }
    }

    // MARK: - Session read-out

    /// The session number in a thin neutral ring — an instrument read-out, not a trophy (decision 19).
    private var badge: some View {
        ZStack {
            Circle()
                .stroke(TelosColor.lineStrong, lineWidth: TelosStroke.line)
            VStack(spacing: TelosSpace.xxs) {
                Text("Session").liftOverline()
                Text(verbatim: "\(summary.templateSessionNumber)")
                    .font(TelosType.numeralFont(size: 40, weight: .light))
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, TelosSpace.m)
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(badgeAccessibility))
    }

    private var badgeAccessibility: String {
        if let name = session.templateName {
            return String(localized: "Session \(summary.templateSessionNumber) of \(name)")
        }
        return String(localized: "Session \(summary.templateSessionNumber)")
    }

    /// "3 personal records" — a flat neutral pill; gold only on the small medal mark (decision 19).
    private var recordsPill: some View {
        HStack(spacing: TelosSpace.xs) {
            Image(systemName: "medal.fill")
                .foregroundStyle(TelosColor.bestGold)
                .accessibilityHidden(true)
            Text("\(summary.recordCount) personal records")
                .foregroundStyle(TelosColor.textPrimary)
        }
        .font(TelosType.headline)
        .telosGlowingPill(TelosColor.line, isActive: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: TelosSpace.s) {
            statTile(label: Text("Workouts"), value: "\(summary.totalSessions).")
            statTile(label: Text("Duration"), value: LiftCopy.duration(summary.durationSec))
            statTile(label: Text("Streak"),
                     value: String(localized: "\(summary.streakWeeks) wk"),
                     caption: Text("weeks in a row"))
        }
    }

    private func statTile(label: Text, value: String, caption: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            label.liftOverline()
            Text(verbatim: value)
                .font(TelosType.numeralFont(size: 24))
                .foregroundStyle(TelosColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                caption.font(TelosType.caption).foregroundStyle(TelosColor.textTertiary)
            }
        }
        .padding(TelosSpace.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftGlass(radius: TelosRadius.tile)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Exercises

    private var exercisesSection: some View {
        let trained = summary.exercises.filter { $0.setsDone > 0 }.count
        return VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack {
                Text("\(trained) exercises").font(TelosType.headline)
                Spacer()
                if summary.recordCount > 0 {
                    Label("\(summary.recordCount)", systemImage: "medal.fill")
                        .foregroundStyle(TelosColor.bestGold)
                        .accessibilityLabel(Text("\(summary.recordCount) personal records"))
                }
                if summary.improvedCount > 0 {
                    Label("\(summary.improvedCount)", systemImage: "arrow.up")
                        .foregroundStyle(TelosColor.positive)
                        .accessibilityLabel(Text("\(summary.improvedCount) exercises up on last time"))
                }
            }
            .font(TelosType.subhead)
            .foregroundStyle(TelosColor.textPrimary)
            ForEach(Array(summary.exercises.enumerated()), id: \.offset) { _, line in
                exerciseLine(line)
            }
            if summary.setsNotDone > 0 {
                Text("\(summary.setsNotDone) planned sets not done")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
        .padding(TelosSpace.cardPadding)
        .liftGlass()
    }

    private func exerciseLine(_ line: LiftSessionSummary.ExerciseLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            Image(systemName: LiftCopy.glyph(for: line.name))
                .font(TelosType.glyphRow)
                .foregroundStyle(TelosColor.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(verbatim: line.name).font(TelosType.body).foregroundStyle(TelosColor.textPrimary)
                HStack(spacing: TelosSpace.s) {
                    Text("\(line.setsDone) sets")
                    if line.setsNotDone > 0 { Text("\(line.setsNotDone) not done") }
                    if !line.records.isEmpty {
                        Label("\(line.records.count)", systemImage: "medal.fill").foregroundStyle(TelosColor.bestGold)
                    }
                }
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textSecondary)
                ForEach(Array(line.records.enumerated()), id: \.offset) { _, record in
                    Text(verbatim: recordText(record))
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.bestGold)
                }
            }
            Spacer(minLength: TelosSpace.s)
            VStack(alignment: .trailing, spacing: TelosSpace.xxs) {
                Text(verbatim: LiftCopy.e1rm(line.bestE1rmKg)).font(TelosType.numeralS).foregroundStyle(TelosColor.textPrimary)
                if let d = line.e1rmDeltaKg {
                    Text(verbatim: LiftCopy.signedKg(d))
                        .font(TelosType.caption)
                        .foregroundStyle(d >= LiftSessionSummary.improvementEpsilonKg ? TelosColor.positive
                                         : (d <= -LiftSessionSummary.improvementEpsilonKg ? TelosColor.warning
                                            : TelosColor.textTertiary))
                } else {
                    Text("e1RM").font(TelosType.caption).foregroundStyle(TelosColor.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func recordText(_ r: LiftSessionSummary.Record) -> String {
        switch r {
        case .e1rm(let new, let prev):
            return String(localized: "Best e1RM: \(LiftCopy.e1rm(new)) kg (was \(LiftCopy.e1rm(prev)))")
        case .heaviest(let new, let prev):
            return String(localized: "Heaviest: \(LiftCopy.kg(new)) kg (was \(LiftCopy.kg(prev)))")
        }
    }

    // MARK: - Muscles

    private var musclesSection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            Text("Muscle groups").font(TelosType.headline).foregroundStyle(TelosColor.textPrimary)
            if let prev = summary.comparableSessionStart {
                Text("Volume change vs. \(prev.formatted(date: .abbreviated, time: .omitted)), the last time you did this day")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            } else {
                Text("No earlier session of this day to compare with — changes show —.")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            if summary.muscles.isEmpty {
                Text("None of today's exercises could be placed on a muscle group.")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
            }
            ForEach(summary.muscles, id: \.group) { m in
                HStack(spacing: TelosSpace.s) {
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        Text(verbatim: LiftCopy.muscleName(m.group)).font(TelosType.body).foregroundStyle(TelosColor.textPrimary)
                        Text("\(Int((m.shareOfSets * 100).rounded())) % · \(m.sets) sets")
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                    Spacer()
                    Text(verbatim: LiftCopy.percentChange(m.changePct))
                        .font(TelosType.numeralS)
                        .foregroundStyle(changeInk(m.changePct))
                }
                .accessibilityElement(children: .combine)
                // The group's share of today's sets (the "%" in the line above), drawn: a static bar.
                shareBar(m.shareOfSets)
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftGlass()
    }

    private func shareBar(_ share: Double) -> some View {
        let f: Double = share.isFinite ? min(max(share, 0), 1) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(TelosColor.muscle.opacity(TelosOpacity.fill))
                Capsule().fill(TelosColor.muscle).frame(width: max(0, CGFloat(f) * geo.size.width))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func changeInk(_ c: Double?) -> Color {
        guard let c else { return TelosColor.textTertiary }
        if c > 0.005 { return TelosColor.positive }
        if c < -0.005 { return TelosColor.warning }
        return TelosColor.textSecondary
    }

    // MARK: - Workout row, achievements, actions

    private var workoutRow: some View {
        HStack(spacing: TelosSpace.s) {
            Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(TelosColor.effort)
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text("Workout · \(dayWord(session.start))").font(TelosType.body).foregroundStyle(TelosColor.textPrimary)
                Text(verbatim: timeRange).font(TelosType.caption).foregroundStyle(TelosColor.textSecondary)
            }
            Spacer()
            Text(verbatim: "\(LiftingImporter.groupedKg(summary.volumeKg)) kg")
                .font(TelosType.numeralS)
                .foregroundStyle(TelosColor.textPrimary)
                .accessibilityLabel(Text("Volume load \(LiftingImporter.groupedKg(summary.volumeKg)) kilograms"))
        }
        .padding(TelosSpace.cardPadding)
        .liftGlass()
    }

    private func dayWord(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? String(localized: "Today") : d.formatted(date: .abbreviated, time: .omitted)
    }

    private var timeRange: String {
        let start = session.start.formatted(date: .omitted, time: .shortened)
        guard let end = session.end else { return start }
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            Text("Achievements").font(TelosType.headline).foregroundStyle(TelosColor.textPrimary)
            ForEach(Array(summary.achievements.enumerated()), id: \.offset) { _, a in
                let copy = LiftCopy.achievement(a)
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: copy.icon)
                        .font(TelosType.glyphRow)
                        .foregroundStyle(TelosColor.textSecondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        Text(verbatim: copy.title).font(TelosType.body).foregroundStyle(TelosColor.textPrimary)
                        Text(verbatim: copy.rule).font(TelosType.caption).foregroundStyle(TelosColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftGlass()
    }

    private var actions: some View {
        VStack(spacing: TelosSpace.s) {
            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(NoopButtonStyle(.secondary))
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(NoopButtonStyle(.primary))
        }
    }

    /// Plain text, figures only — what the wearer chooses to send, nothing else (no health data beyond the lift).
    private var shareText: String {
        var lines: [String] = []
        lines.append("\(session.templateName ?? String(localized: "Strength session")) · #\(summary.templateSessionNumber)")
        lines.append(String(localized: "\(LiftCopy.duration(summary.durationSec)) · \(summary.setsDone) sets · \(LiftingImporter.groupedKg(summary.volumeKg)) kg"))
        for line in summary.exercises where line.setsDone > 0 {
            var l = "\(line.name): \(line.setsDone) × · e1RM \(LiftCopy.e1rm(line.bestE1rmKg))"
            if !line.records.isEmpty { l += " 🏅" }
            lines.append(l)
        }
        if summary.recordCount > 0 { lines.append(String(localized: "\(summary.recordCount) personal records")) }
        lines.append("Telos Lift")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Star shape (no longer drawn on the finish screen — decision 19; kept for any other caller)

struct LiftStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.5
        var p = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

#endif
