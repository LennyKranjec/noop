import SwiftUI
import StrandAnalytics
import StrandDesign

// TonightLogSheet.swift — log tonight's behaviours under an EXPLICIT night key (HEALTH_V2 §S1-A.2/A.7).
//
// The journal table has no write timestamp, so an evening entry logged under "Today" attaches to the wrong
// night. This sheet writes under the key of the night about to start (tomorrow's wake day; before 04:00,
// the night already under way). "Not now" leaves the question unanswered — never a "no".
// Logic only; the PROGRESS package restyles it.

struct TonightLogSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: Bool] = [:]
    var now: Date = Date()

    /// Evening behaviours worth logging tonight (journal starters that are behaviours).
    static let questions: [String] = HabitCatalog.journalStarters
        .filter { HabitCatalog.definition($0.value)?.kind == .behaviour }
        .map { $0.key }
        .sorted()

    private var nightKey: String? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return HabitNightKey.fallback(localDay: Repository.localDayKey(now),
                                      localMinute: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    var body: some View {
        NavigationStack {
            List {
                if let key = nightKey {
                    Section(header: Text("Tonight (night of \(key))")) {
                        ForEach(Self.questions, id: \.self) { q in
                            HStack {
                                Text(q).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                answerButton(q, key: key, yes: true)
                                answerButton(q, key: key, yes: false)
                            }
                        }
                    }
                } else {
                    Text(HealthAbsence.dash)
                }
            }
            .navigationTitle("Tonight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func answerButton(_ q: String, key: String, yes: Bool) -> some View {
        let selected = answers[q] == yes
        return Button(yes ? "Yes" : "No") {
            Task {
                if selected {
                    await model.repo.clearJournalAnswer(day: key, question: q)
                    answers[q] = nil
                } else {
                    await model.repo.saveJournalAnswer(day: key, question: q, answeredYes: yes)
                    answers[q] = yes
                }
            }
        }
        .buttonStyle(.noopSecondary)
        .opacity(selected ? 1 : 0.55)
    }

    private func load() async {
        guard let key = nightKey else { return }
        answers = await model.repo.nativeJournalAnswers(day: key)
    }
}
