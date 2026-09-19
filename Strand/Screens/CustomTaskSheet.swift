import SwiftUI
import StrandAnalytics
import StrandDesign

// CustomTaskSheet.swift — the coach's task desk.
//
// Opened from the checklist button in the coach's title row. The wearer describes a task in their own
// words; the coach turns it into a structured one (`CustomTaskWriter` → `CustomTaskParser`); the preview
// shows exactly what will be added, title editable; "Add to Today" puts it on the quest strip as a
// `QuestKind.custom` quest. Below, every task the wearer has asked for, with delete.
//
// NOTHING IS ADDED WITHOUT THE PREVIEW. A model that misread "10 min stretch" as a training goal must be
// caught before it is on Today, not after.

struct CustomTaskSheet: View {
    let onClose: () -> Void

    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var store = QuestStore.shared

    @State private var request = ""
    @State private var working = false
    @State private var draft: CustomTaskDraft?

    private var canSend: Bool {
        !working && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Describe what you want to get done. The coach turns it into a task on Today — it closes itself when it is something your data can see, otherwise you tick it off.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    composer

                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("The coach is writing it…")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }

                    if draft != nil { preview }

                    taskList
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Your tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    // MARK: - Asking

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("e.g. walk 8,000 steps today, stretch 10 min after lunch",
                      text: $request, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .onSubmit(send)
                .accessibilityLabel("Describe a task")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(canSend ? StrandPalette.accent : StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Create task")
        }
    }

    private func send() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        SystemHaptics.play(.tap)
        working = true
        draft = nil
        Task {
            let written = await CustomTaskWriter.draft(for: text, coach: coach)
            draft = written
            working = false
        }
    }

    // MARK: - The preview

    @ViewBuilder
    private var preview: some View {
        if let current = draft {
            VStack(alignment: .leading, spacing: 10) {
                Text("PREVIEW")
                    .font(StrandFont.overline)
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textTertiary)

                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Task title")

                if !current.detail.isEmpty {
                    Text(current.detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                detailRow("clock", dueText(current.dueAtMs))
                detailRow(current.goal == nil ? "hand.tap" : "gauge.with.dots.needle.33percent",
                          goalText(current.goal))

                if !current.fromCoach {
                    detailRow("exclamationmark.circle",
                              "The coach could not be reached, so this is your own wording.")
                }

                HStack(spacing: 10) {
                    NoopButton("Add to Today", systemImage: "plus", kind: .primary) { add(current) }
                        .disabled(current.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    NoopButton("Discard", kind: .secondary) {
                        SystemHaptics.play(.tap)
                        draft = nil
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft?.title ?? "" },
            set: { draft?.title = String($0.prefix(QuestNaming.maxTitleChars)) })
    }

    private func add(_ current: CustomTaskDraft) {
        SystemHaptics.play(.tap)
        store.addCustom(CustomTaskParser.makeQuest(current, now: Date()))
        draft = nil
        request = ""
    }

    private func detailRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 16)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The wearer's tasks

    @ViewBuilder
    private var taskList: some View {
        let tasks = store.customTasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR TASKS")
                    .font(StrandFont.overline)
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textTertiary)
                ForEach(tasks, id: \.id) { task in
                    taskRow(task)
                }
            }
        }
    }

    private func taskRow(_ task: Quest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: stateIcon(task.state))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(stateTint(task.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(task.state == .active ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .strikethrough(task.state == .completed, color: StrandPalette.textTertiary)
                    .lineLimit(1)
                if task.state == .active {
                    QuestCountdownView(quest: task, fontSize: 11, showIcon: false)
                } else {
                    Text(task.state == .completed ? "Done" : "Closed")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if task.state == .active {
                Button {
                    SystemHaptics.play(.tap)
                    store.checkOff(id: task.id)
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(task.title) done")
            }
            Button {
                SystemHaptics.play(.tap)
                store.removeCustom(id: task.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(task.title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stateIcon(_ state: QuestState) -> String {
        switch state {
        case .active, .offered: return "circle"
        case .completed: return "checkmark.circle.fill"
        case .declined: return "xmark.circle"
        }
    }

    private func stateTint(_ state: QuestState) -> Color {
        switch state {
        case .active, .offered: return StrandPalette.accent
        case .completed: return StrandPalette.statusPositive
        case .declined: return StrandPalette.textTertiary
        }
    }

    // MARK: - Words for the preview

    private func dueText(_ ms: Int64?) -> String {
        guard let ms = ms else { return "No set time — it runs for the next 24 hours." }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Due today at \(time)." }
        if Calendar.current.isDateInTomorrow(date) { return "Due tomorrow at \(time)." }
        return "Due \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func goalText(_ goal: QuestGoal?) -> String {
        guard let goal = goal else { return "You tick it off yourself." }
        func n(_ v: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = v < 100 ? 1 : 0
            return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
        }
        let what: String
        switch goal.metric {
        case .steps: what = "\(n(goal.threshold)) steps"
        case .workoutMinutes: what = "\(n(goal.threshold)) minutes of logged training"
        case .meditationMinutes: what = "\(n(goal.threshold)) minutes of meditation"
        case .waterMl: what = "\(n(goal.threshold / 1000)) L of water"
        case .strain: what = "a day strain of \(n(goal.threshold))"
        case .sleepHours: what = "\(n(goal.threshold)) hours of sleep tonight"
        case .bedtimeBy:
            let m = Int(goal.threshold)
            what = "asleep by " + String(format: "%02d:%02d", m / 60, m % 60)
        case .bedtimeEarlier: what = "asleep \(n(goal.threshold)) minutes earlier than last night"
        case .journal: what = "a journal entry"
        }
        return "Closes itself at \(what) — or tick it off yourself."
    }
}
