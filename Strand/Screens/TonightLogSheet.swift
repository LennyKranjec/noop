import SwiftUI
import StrandAnalytics
import StrandDesign

// TonightLogSheet.swift — log tonight's behaviours under an EXPLICIT night key (HEALTH_V2 §S1-A.2/A.7).
//
// The journal table has no write timestamp, so an evening entry logged under "Today" attaches to the wrong
// night. This sheet writes under the key of the night about to start (tomorrow's wake day; before 04:00,
// the night already under way). "Not now" leaves the question unanswered — never a "no".
// Telos 2.0 (SLEEP): the answers are Yes / No `TelosChip`s on the canvas; the model is held WITHOUT
// observing it (§2.1 rule 5) — the sheet only calls its repository.

struct TonightLogSheet: View {
    @Environment(\.appModelRef) private var appModelRef
    private var model: AppModel { requireAppModel(appModelRef) }
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
                            HStack(spacing: TelosSpace.s) {
                                Text(q)
                                    .font(TelosType.body)
                                    .foregroundStyle(TelosColor.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: TelosSpace.s)
                                answerButton(q, key: key, yes: true)
                                answerButton(q, key: key, yes: false)
                            }
                            .listRowBackground(TelosColor.glassFill)
                        }
                    }
                } else {
                    Text(HealthAbsence.dash)
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(TelosColor.canvas)
            .navigationTitle("Tonight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
    }

    /// One answer chip. Tapping the selected chip again clears the answer (unanswered, never a "no").
    private func answerButton(_ q: String, key: String, yes: Bool) -> some View {
        let selected = answers[q] == yes
        return TelosChip(yes ? "Yes" : "No", isOn: selected) {
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
    }

    private func load() async {
        guard let key = nightKey else { return }
        answers = await model.repo.nativeJournalAnswers(day: key)
    }
}
