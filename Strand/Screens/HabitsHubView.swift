import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitsHubView.swift — the Habits hub (HEALTH_V2 §S1-A.7, DESIGN_V2 §6.8). Reached from Today, the Coach and
// More (coordinator decision 3: the Focus tab stays). Every figure here comes from `HabitAnalysisStore` /
// `HabitTrialStore`; nothing is computed or invented in the view.
//
// TELOS 2.0 LAYOUT (PROGRESS package), in order:
//   1. TODAY — the running trial's card (today's assignment first), or the empty state with "Ask the coach";
//      "Log tonight" stays one tap away.
//   2. MEDITATION — the practice card (the same view the Focus tab carries).
//   3. PROPOSED BY THE COACH — the trial proposals (only while no trial runs), each a card into setup.
//   4. YOUR HABITS — one glass row per habit: the association sentence with an ASSOCIATION tag, its
//      estimate and interval against the meaningful band, or TRIAL-TESTED + the verdict word when a finished
//      trial covers it. "Also logged" keeps its toggle.
//   5. FINISHED TRIALS — result rows (verdict tag, effect line), newest first, into the full result.
//   6. GO DEEPER — What moves you, Insights (journal), Lab Book, Compare.
//   Footer: what gets logged.
//
// COST: static; one refresh on appear (`refreshIfDue`, once a day). The header texture is one still frame.

struct HabitsHubView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @ObservedObject var analysis: HabitAnalysisStore = .shared
    @ObservedObject var trials: HabitTrialStore = .shared
    @State private var showTonight = false
    @State private var showAlsoLogged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.sectionGap) {
                hero
                todaySection
                MeditationCardView()
                tryOneSection
                suggestsSection
                finishedSection
                goDeeper
                footer
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.top, TelosSpace.s)
            .padding(.bottom, TelosSpace.tabBarClearance)
        }
        .background(TelosColor.groundGradient.ignoresSafeArea())
        .navigationTitle("Habits")
        .sheet(isPresented: $showTonight) { TonightLogSheet().environmentObject(model) }
        .task { await analysis.refreshIfDue(repo: model.repo) }
    }

    // MARK: Hero — what the hub holds, in three numbers

    private var hero: some View {
        let patterns = analysis.report?.rows.count
        return HStack(alignment: .center, spacing: TelosSpace.m) {
            ZStack {
                // Cost: one still Canvas frame (animated: false).
                TelosParticleField(color: TelosColor.teal, count: 48, seed: 0x4AB175, sizes: 0.6...1.8,
                                   drift: 0, animated: false)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                Image(systemName: "flask")
                    .font(TelosType.title2)
                    .foregroundStyle(TelosColor.teal)
            }
            .background(TelosRadialGlow(color: TelosColor.teal, intensity: 0.25, radius: 44))
            .accessibilityHidden(true)
            HStack(spacing: TelosSpace.l) {
                heroFigure(trials.running == nil ? "0" : "1", "Running")
                heroFigure(patterns.map { String($0) } ?? TelosType.absent, "Patterns")
                heroFigure(String(trials.finished.count), "Finished")
            }
            Spacer(minLength: 0)
        }
    }

    private func heroFigure(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            Text(verbatim: value)
                .telosNumeral(.numeralM)
                .foregroundStyle(TelosColor.textPrimary)
            PGOverline(label)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 1. Today's trial

    @ViewBuilder
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Today", overline: "Trial")
            if trials.running != nil {
                HabitTrialTodayCard()
            } else {
                StrandCard(tint: TelosColor.teal) {
                    TelosEmptyState(systemImage: "flask",
                                    title: "No trial running",
                                    message: "A trial tests one habit on your own nights, ON and OFF days side by side. Pick a proposal below, or ask the coach for one.",
                                    actionTitle: "Ask the coach",
                                    action: {
                                        TelosHaptics.play(.select)
                                        router.openCoach()
                                    })
                }
            }
            Button {
                TelosHaptics.play(.select)
                showTonight = true
            } label: {
                Label("Log tonight", systemImage: "moon.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopSecondary)
        }
    }

    // MARK: 3. Proposed by the coach

    @ViewBuilder
    private var tryOneSection: some View {
        let proposals = analysis.proposals
        if trials.running == nil, !proposals.isEmpty {
            VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
                SectionHeader("Proposed by the coach", overline: "Try one")
                ForEach(proposals, id: \.entryId) { p in
                    if let entry = HabitTrialCatalog.entry(p.entryId) {
                        NavigationLink(destination: HabitTrialSetupView(entry: entry).environmentObject(model)) {
                            proposalCard(entry: entry, reason: p.reason)
                        }
                        .buttonStyle(TelosPressButtonStyle())
                    }
                }
            }
        }
    }

    private func proposalCard(entry: HabitTrialEntry, reason: String) -> some View {
        StrandCard(tint: TelosColor.teal) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: TelosSpace.s)
                    Image(systemName: "chevron.right")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(reason)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: TelosSpace.s) {
                    TelosTag(text: Text("Outcome: \(entry.primaryOutcome.label)"), ink: TelosColor.teal)
                    if let first = entry.allowedLengths.first {
                        Text(verbatim: "\(first)+ DAYS")
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                }
                Text("Start trial")
                    .font(TelosType.subhead.weight(.semibold))
                    .foregroundStyle(TelosColor.teal)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the trial setup"))
    }

    // MARK: 4. Your habits (associations)

    @ViewBuilder
    private var suggestsSection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Your habits", overline: "What your data suggests")
            if let report = analysis.report {
                Text("Nights \(report.windowStart) to \(report.windowEnd). Patterns, not proof — only a trial can say a habit helped.")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if report.rows.isEmpty {
                    AbsentValue(verbatimReason: HealthAbsence.notLogged.text)
                }
                ForEach(report.rows, id: \.habit) { row in habitRow(row) }
                if !report.alsoLogged.isEmpty {
                    Button(showAlsoLogged ? "Hide also logged" : "Also logged (\(report.alsoLogged.count))") {
                        TelosHaptics.play(.select)
                        withAnimation(TelosMotion.fade) { showAlsoLogged.toggle() }
                    }
                    .buttonStyle(.noopGhost)
                    if showAlsoLogged {
                        StrandCard {
                            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                                ForEach(report.alsoLogged, id: \.habit) { r in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(r.habitLabel)
                                            .font(TelosType.subhead)
                                            .foregroundStyle(TelosColor.textPrimary)
                                        Spacer(minLength: TelosSpace.s)
                                        Text(verbatim: "\(r.yesCount) YES · \(r.noCount) NO")
                                            .font(TelosType.scaleNumber)
                                            .foregroundStyle(TelosColor.textSecondary)
                                    }
                                }
                                Text("Recorded, not tested.")
                                    .font(TelosType.caption)
                                    .foregroundStyle(TelosColor.textTertiary)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            } else {
                AbsentValue(reason: "The habit analysis runs once a day, after the morning's data lands.")
            }
        }
    }

    /// The finished trial that tested `habit`, newest first.
    private func trialCovering(_ habit: HabitId) -> HabitTrialRecord? {
        trials.finished.first { $0.entry?.linkedHabits.contains(habit) == true && $0.result?.verdict != nil }
    }

    private func habitRow(_ row: HabitAssociationRow) -> some View {
        HabitAssociationCard(row: row, tested: trialCovering(row.habit))
    }

    /// A display-unit number with a true sign ("+4", "−12", "0").
    static func signedDisplay(_ v: Double) -> String {
        let m = HabitTrialCopy.format(abs(v), digits: abs(v) < 10 ? 1 : 0)
        if v > 0 { return "+" + m }
        if v < 0 { return TelosType.minus + m }
        return m
    }

    // MARK: 5. Finished trials

    @ViewBuilder
    private var finishedSection: some View {
        let done = trials.finished
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
                SectionHeader("Finished trials", overline: "Result")
                StrandCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(done.enumerated()), id: \.element.id) { i, rec in
                            if i > 0 { TelosListDivider(leadingInset: TelosSpace.m) }
                            NavigationLink(destination: HabitTrialResultView(record: rec)) {
                                finishedRow(rec)
                            }
                            .buttonStyle(TelosRowButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func finishedRow(_ rec: HabitTrialRecord) -> some View {
        HStack(alignment: .center, spacing: TelosSpace.m) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(rec.entry?.title ?? rec.registration.interventionId)
                    .font(TelosType.body)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = rec.result, let e = r.estimate, let lo = r.lower, let hi = r.upper {
                    Text(verbatim: "\(HabitTrialCopy.signed(e, outcome: r.primaryOutcome)) · 95% CI \(HabitTrialCopy.bare(lo, outcome: r.primaryOutcome)) to \(HabitTrialCopy.bare(hi, outcome: r.primaryOutcome))")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                }
                if let ended = rec.endedOn {
                    Text(verbatim: ended)
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                }
            }
            Spacer(minLength: TelosSpace.s)
            HabitVerdictTag(verdict: rec.result?.verdict)
            Image(systemName: "chevron.right")
                .font(TelosType.glyphChevron)
                .foregroundStyle(TelosColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, TelosSpace.m)
        .padding(.vertical, TelosSpace.rowVertical)
        .frame(minHeight: TelosSpace.rowMinHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: 6. Go deeper

    private var goDeeper: some View {
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Go deeper", overline: "Your data")
            StrandCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { InsightsHubView() } label: {
                        TelosListRow("What moves you", subtitle: "Habit patterns across your nights",
                                     systemImage: "wand.and.sparkles", iconTint: TelosColor.teal, showsChevron: true)
                    }
                    .buttonStyle(TelosRowButtonStyle())
                    TelosListDivider()
                    NavigationLink { InsightsView() } label: {
                        TelosListRow("Insights", subtitle: "Journal, mood and caffeine",
                                     systemImage: "book.closed", iconTint: TelosColor.violetInk, showsChevron: true)
                    }
                    .buttonStyle(TelosRowButtonStyle())
                    TelosListDivider()
                    NavigationLink { LabBookView() } label: {
                        TelosListRow("Lab Book", subtitle: "Your logged health numbers",
                                     systemImage: "testtube.2", iconTint: TelosColor.amber, showsChevron: true)
                    }
                    .buttonStyle(TelosRowButtonStyle())
                    TelosListDivider()
                    NavigationLink { CompareView() } label: {
                        TelosListRow("Compare", subtitle: "Two periods side by side",
                                     systemImage: "square.split.2x1", iconTint: TelosColor.effortInk, showsChevron: true)
                    }
                    .buttonStyle(TelosRowButtonStyle())
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let counts = analysis.report?.sourceCounts {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                PGOverline("What gets logged (last 90 nights)")
                ForEach(HabitsHubView.sources, id: \.0) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.1)
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textSecondary)
                        Spacer(minLength: TelosSpace.s)
                        Text(counts[item.0].map { "\($0) NIGHTS" } ?? HealthAbsence.notLogged.text)
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                }
                Text("A night without an entry is not a \"no\" — it is left out.")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let sources: [(String, String)] = [
        ("journal", "Journal"), ("dream", "Dream journal"), ("caffeineLog", "Caffeine log (days with an intake)"),
        ("workouts", "Workouts"), ("climate", "Bedroom sensor"), ("breathLog", "Breathing sessions"),
        ("wiz", "Wind-down lights"),
    ]
}

/// One habit's association (Habits hub + What moves you): the sentence with an ASSOCIATION tag — or
/// TRIAL-TESTED + the verdict word when a finished trial covers the habit — the yes/no nights, and the
/// estimate with its interval against the meaningful band (display units), drawn exactly as given.
struct HabitAssociationCard: View {
    let row: HabitAssociationRow
    let tested: HabitTrialRecord?

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Text(row.habitLabel)
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: TelosSpace.s)
                    if let tested {
                        TelosTag("Trial-tested", ink: TelosColor.teal)
                        HabitVerdictTag(verdict: tested.result?.verdict)
                    } else {
                        TelosTag("Association", ink: TelosColor.textSecondary)
                    }
                }
                HStack(spacing: TelosSpace.s) {
                    Text(row.label.title.uppercased())
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                    Text(verbatim: "· \(row.yesCount) YES · \(row.noCount) NO NIGHTS · \(row.outcome.label.uppercased())")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                }
                Text(HabitAssociationCopy.sentence(row))
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lo = row.lower, let hi = row.upper, let mcid = row.mcid, let est = row.estimate {
                    let o = row.outcome
                    EffectIntervalPlot(estimate: o.display(est), lower: o.display(lo), upper: o.display(hi),
                                       meaningfulLow: o.display(-mcid), meaningfulHigh: o.display(mcid),
                                       betterIsHigher: o.betterDirection == .increase,
                                       format: HabitsHubView.signedDisplay)
                }
                if let note = HabitAssociationCopy.cooccurrence(row.cooccurLabels) {
                    Text(note)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.secondaries.isEmpty {
                    Text("Other outcomes: exploratory")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                }
            }
        }
    }
}
