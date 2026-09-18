import SwiftUI
import StrandAnalytics
import StrandDesign

// RitualSheetView.swift — what a ritual produced, and the one thing it asks back.
//
// The briefing, the quest it raised, and — in the evening — a field to answer the question it ended on.
//
// THE EVENING ASKS A QUESTION AND WAITS FOR IT. The other two slots tell the wearer something; this one
// wants something the data cannot see, which is the whole reason it exists. A journal that is a blank
// page every night gets written in for a week; a journal that asks one specific question about the day
// you just had gets written in.
//
// THE ANSWER IS THE JOURNAL ENTRY. Not a separate note kept beside it — it lands on the same journal
// seam every other entry uses, so it counts toward the journal streak and reaches the coach's context
// like anything else the wearer has written.

struct RitualSheetView: View {
    let result: RitualResult
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var answer = ""
    @State private var saved = false
    /// The questionnaire's three readings. Only the evening asks them.
    @State private var mood: Int?
    @State private var soreness: Int?
    @State private var motivation: Int?
    /// The day's journal, logged right here under the revisit rather than on another screen.
    @State private var importedQuestions: [String] = []
    @State private var journalAnswers: [String: Bool] = [:]
    @State private var journalNumeric: [String: Double] = [:]
    @State private var journalDayOffset = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(result.text)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let quest = result.quest { questCard(quest) }
                    if result.ritual == .evening {
                        journalCard
                        // THE WHOLE JOURNAL, not only tonight's question. The revisit is where the day
                        // is looked back on, and the behaviours the journal asks about — caffeine,
                        // alcohol, screens — are exactly what that look back turns up.
                        JournalLogCard(importedQuestions: importedQuestions,
                                       answers: journalAnswers,
                                       numericAnswers: journalNumeric,
                                       dayOffset: $journalDayOffset,
                                       onChanged: { Task { await loadJournal() } })
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(result.ritual.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetentsCompat()
        .task(id: journalDayOffset) {
            if result.ritual == .evening { await loadJournal() }
        }
    }

    /// The question the revisit ended on, if it ended on one — the prompt tonight's entry answers.
    private var closingQuestion: String? {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("?") else { return nil }
        let body = text.dropLast()
        let start = body.lastIndex(where: { ".!?\n".contains($0) }).map { body.index(after: $0) }
            ?? body.startIndex
        let q = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    private func loadJournal() async {
        let imported = await repo.importedJournalEntries()
        importedQuestions = NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
        let day = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -journalDayOffset, to: Date()) ?? Date())
        journalAnswers = await repo.nativeJournalAnswers(day: day)
        journalNumeric = await repo.nativeJournalNumeric(day: day)
    }

    /// The quest this slot raised, as a read-only card — accepting it happens in the pop-up the shell
    /// puts over every tab, so this does not offer a second, competing button for the same decision.
    private func questCard(_ quest: Quest) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR DIRECTIVE")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.accent)
                Text(quest.title.uppercased())
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(quest.target)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var journalCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("TONIGHT'S ENTRY")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let closingQuestion {
                    Text(closingQuestion)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextEditor(text: $answer)
                    .font(StrandFont.body)
                    .frame(minHeight: 96)
                    .scrollContentBackgroundHiddenCompat()
                    .padding(8)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                // THREE READINGS, ALL OPTIONAL. A questionnaire that must be completed is one that gets
                // answered carelessly to be got rid of; each of these is skippable and a skipped one is
                // stored as nothing rather than as a middle value.
                scale("Mood", $mood)
                scale("Soreness", $soreness)
                scale("Motivation", $motivation)

                HStack {
                    if saved {
                        Label("Saved", systemImage: "checkmark")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusPositive)
                    }
                    Spacer()
                    Button("Save entry") { Task { await save() } }
                        .font(StrandFont.footnote)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && mood == nil && soreness == nil && motivation == nil)
                }
            }
        }
    }

    private func scale(_ label: String, _ binding: Binding<Int?>) -> some View {
        HStack {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        // A second tap CLEARS it. Without that there is no way back to "I would rather
                        // not say" once a value has been touched by accident.
                        binding.wrappedValue = binding.wrappedValue == value ? nil : value
                        SystemHaptics.play(.select)
                    } label: {
                        Circle()
                            .fill(binding.wrappedValue == value
                                  ? StrandPalette.accent
                                  : StrandPalette.surfaceInset)
                            .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text("\(value)")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(binding.wrappedValue == value
                                                     ? StrandPalette.surfaceBase
                                                     : StrandPalette.textTertiary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func save() async {
        let day = DailyMissionStore.dayKey()
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // The question travels WITH the answer, so the entry still makes sense read back a month
            // later, when the revisit that asked it is long gone.
            let notes = closingQuestion.map { "\($0)\n\n\(text)" } ?? text
            await repo.saveJournalAnswer(day: day, question: "Evening revisit",
                                         answeredYes: true, notes: notes)
        }
        // Each reading is its own numeric entry, so the behaviour engine can correlate them separately
        // — a single blended "how was today" number correlates with nothing.
        if let mood { await repo.saveJournalNumeric(day: day, question: "Mood", value: Double(mood)) }
        if let soreness {
            await repo.saveJournalNumeric(day: day, question: "Soreness", value: Double(soreness))
        }
        if let motivation {
            await repo.saveJournalNumeric(day: day, question: "Motivation", value: Double(motivation))
        }
        saved = true
        SystemHaptics.play(.confirm)
    }
}

private extension View {
    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationDetentsCompat() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}
