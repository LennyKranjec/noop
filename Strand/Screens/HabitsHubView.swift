import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitsHubView.swift — the Habits hub (HEALTH_V2 §S1-A.7). Reached from Today, the Coach and More (DESIGN_V2
// coordinator decision 3: the Focus tab stays). Logic only; the PROGRESS package restyles it and may move it
// behind its own `HabitsViewModels` adapter. Every figure here comes from `HabitAnalysisStore` /
// `HabitTrialStore`; nothing is computed or invented in the view.
//
// Sections: 1 today's trial · 2 what your data suggests (associations, always labelled as such) · 3 try one
// (≤ 2 proposals) · 4 finished trials · footer: what gets logged.

struct HabitsHubView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var analysis: HabitAnalysisStore = .shared
    @ObservedObject var trials: HabitTrialStore = .shared
    @State private var showTonight = false
    @State private var showAlsoLogged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                todaySection
                suggestsSection
                tryOneSection
                finishedSection
                footer
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle("Habits")
        .sheet(isPresented: $showTonight) { TonightLogSheet().environmentObject(model) }
        .task { await analysis.refreshIfDue(repo: model.repo) }
    }

    // MARK: 1. Today's trial

    @ViewBuilder
    private var todaySection: some View {
        if trials.running != nil {
            HabitTrialTodayCard()
        } else {
            Text("No trial running — try one").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        Button("Log tonight") { showTonight = true }.buttonStyle(.noopSecondary)
    }

    // MARK: 2. What your data suggests

    @ViewBuilder
    private var suggestsSection: some View {
        SectionHeader("What your data suggests", overline: "ASSOCIATION")
        if let report = analysis.report {
            Text("Nights \(report.windowStart) to \(report.windowEnd). Patterns, not proof — only a trial can say a habit helped.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            if report.rows.isEmpty {
                Text(HealthAbsence.notLogged.line).foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(report.rows, id: \.habit) { row in habitRow(row) }
            if !report.alsoLogged.isEmpty {
                Button(showAlsoLogged ? "Hide also logged" : "Also logged (\(report.alsoLogged.count))") {
                    showAlsoLogged.toggle()
                }
                .buttonStyle(.noopGhost)
                if showAlsoLogged {
                    ForEach(report.alsoLogged, id: \.habit) { r in
                        Text("\(r.habitLabel): \(r.yesCount) yes · \(r.noCount) no — recorded, not tested")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        } else {
            Text(HealthAbsence.dash + " The habit analysis runs once a day, after the morning's data lands.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func habitRow(_ row: HabitAssociationRow) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack {
                    Text(row.habitLabel).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(row.label.title.uppercased()).font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                }
                Text(HabitAssociationCopy.sentence(row)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                if let lo = row.lower, let hi = row.upper, let mcid = row.mcid {
                    EffectBandBar(lower: lo, upper: hi, estimate: row.estimate ?? 0, mcid: mcid)
                        .frame(height: 20)
                }
                if let note = HabitAssociationCopy.cooccurrence(row.cooccurLabels) {
                    Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if !row.secondaries.isEmpty {
                    Text("Other outcomes: exploratory").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: 3. Try one

    @ViewBuilder
    private var tryOneSection: some View {
        let proposals = analysis.proposals
        if trials.running == nil, !proposals.isEmpty {
            SectionHeader("Try one", overline: "TRIAL")
            ForEach(proposals, id: \.entryId) { p in
                if let entry = HabitTrialCatalog.entry(p.entryId) {
                    NavigationLink(destination: HabitTrialSetupView(entry: entry).environmentObject(model)) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(entry.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            Text(p.reason).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 4. Finished trials

    @ViewBuilder
    private var finishedSection: some View {
        let done = trials.finished
        if !done.isEmpty {
            SectionHeader("Finished trials", overline: "RESULT")
            ForEach(done) { rec in
                NavigationLink(destination: HabitTrialResultView(record: rec)) {
                    HStack {
                        Text(rec.entry?.title ?? rec.registration.interventionId)
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(rec.result?.verdict?.headline ?? HabitTrialCopy.altered)
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let counts = analysis.report?.sourceCounts {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("WHAT GETS LOGGED (LAST 90 NIGHTS)").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                ForEach(HabitsHubView.sources, id: \.0) { item in
                    Text("\(item.1): \(counts[item.0].map { "\($0) nights" } ?? HealthAbsence.notLogged.text)")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Text("A night without an entry is not a \"no\" — it is left out.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    static let sources: [(String, String)] = [
        ("journal", "Journal"), ("dream", "Dream journal"), ("caffeineLog", "Caffeine log (days with an intake)"),
        ("workouts", "Workouts"), ("climate", "Bedroom sensor"), ("breathLog", "Breathing sessions"),
        ("wiz", "Wind-down lights"),
    ]
}

/// The estimate and its interval against a shaded ±MCID band — drawn exactly as given, identical styling
/// for every label. Placeholder until the PROGRESS package's `EffectIntervalPlot`.
struct EffectBandBar: View {
    let lower: Double
    let upper: Double
    let estimate: Double
    let mcid: Double

    var body: some View {
        GeometryReader { geo in
            let half = Swift.max(abs(lower), abs(upper), 2 * mcid) * 1.15
            let w = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat((($0 + half) / (2 * half))) * w }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(StrandPalette.surfaceInset)
                    .frame(width: x(mcid) - x(-mcid), height: geo.size.height)
                    .offset(x: x(-mcid))
                Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: geo.size.height).offset(x: x(0))
                Rectangle().fill(StrandPalette.textPrimary)
                    .frame(width: Swift.max(1, x(upper) - x(lower)), height: 2)
                    .offset(x: x(lower), y: geo.size.height / 2 - 1)
                Circle().fill(StrandPalette.textPrimary).frame(width: 8, height: 8)
                    .offset(x: x(estimate) - 4, y: geo.size.height / 2 - 4)
            }
        }
    }
}
