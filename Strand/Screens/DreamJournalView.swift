import SwiftUI
import StrandDesign

// DreamJournalView.swift — every morning's dream and answers, newest first.
//
// Written by the morning flow on the day's first open; read and corrected here. The answers are mirrored
// into the journal as they are saved, so "What moves you" can put them against the nights they describe.

struct DreamJournalView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = DreamJournalStore.shared
    @State private var editing: DreamEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                Text("Your dream and a few answers about the night, every morning. The answers join the journal, so Insights can set them against your sleep and recovery.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    let today = Repository.localDayKey(Date())
                    editing = store.entry(day: today)
                        ?? DreamEntry(day: today, text: "", answers: [:], updatedAt: Date())
                } label: {
                    Label(store.entry(day: Repository.localDayKey(Date())) == nil
                          ? "Write today's entry" : "Edit today's entry",
                          systemImage: "square.and.pencil")
                        .font(StrandFont.subhead)
                }
                .buttonStyle(.noopPrimary)

                if store.entries.isEmpty {
                    // §5.13 empty state: symbol, one line — the action is the button above.
                    HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                        Image(systemName: "moon.stars")
                            .font(TelosType.glyphEmpty)
                            .foregroundStyle(TelosColor.violetInk)
                            .accessibilityHidden(true)
                        Text("No entries yet. Tomorrow's first open asks for the night's dream.")
                            .font(TelosType.subhead)
                            .foregroundStyle(TelosColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, TelosSpace.s)
                }
                ForEach(store.entries) { entry in
                    Button { editing = entry } label: { row(entry) }
                        .buttonStyle(.plain)
                }
            }
            .padding(TelosSpace.pageGutter)
        }
        .background(TelosColor.canvas)
        .navigationTitle("Dream Journal")
        .sheet(item: $editing) { entry in
            DreamEntryEditor(entry: entry)
        }
    }

    private func row(_ entry: DreamEntry) -> some View {
        StrandCard(tint: TelosColor.violet) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                Text(Self.dateText(entry.day))
                    .telosScale()
                    .foregroundStyle(TelosColor.violetInk)
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(text.isEmpty ? "No dream written down." : text)
                    .font(StrandFont.body)
                    .foregroundStyle(text.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let answers = DreamQuestions.all.compactMap { q -> String? in
                    guard let i = entry.answers[q.id], q.options.indices.contains(i) else { return nil }
                    return q.options[i].title
                }
                if !answers.isEmpty {
                    Text(answers.joined(separator: " · "))
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func dateText(_ day: String) -> String {
        guard let date = LevelWiring.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()
    }
}

/// One morning's entry, to read in full or to correct.
struct DreamEntryEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var entry: DreamEntry

    init(entry: DreamEntry) {
        _entry = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dream") {
                    TextEditor(text: $entry.text)
                        .frame(minHeight: 160)
                }
                Section("The night") {
                    ForEach(DreamQuestions.all) { q in
                        Picker(q.title, selection: Binding(
                            get: { entry.answers[q.id] ?? -1 },
                            set: { entry.answers[q.id] = $0 < 0 ? nil : $0 })) {
                            Text("Not answered").tag(-1)
                            ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                                Text(option.title).tag(index)
                            }
                        }
                    }
                }
            }
            .navigationTitle(DreamJournalView.dateText(entry.day).capitalized)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = entry
                        saved.updatedAt = Date()
                        Task {
                            await DreamJournalStore.shared.save(saved, repo: repo)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
