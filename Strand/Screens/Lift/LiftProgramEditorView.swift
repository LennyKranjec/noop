#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The program editor (the wrench in the logger's header): programs → day templates → exercises → sets.
///
/// Everything decision 16 lists is editable here: add / remove / reorder exercises, equipment, number of sets,
/// rep target, the type of each set (working / warm-up / drop / failure), rest per exercise, plus the global
/// rest default. Every change goes through `LiftProgramStore.mutate` (saved at once); the edit logic itself is
/// the tested value-type code in `StrandAnalytics/Lift/LiftProgram.swift`.
struct LiftProgramEditorView: View {
    @ObservedObject var programs: LiftProgramStore
    @Environment(\.dismiss) private var dismiss

    struct TemplateRoute: Hashable { let id: String }
    struct ExerciseRoute: Hashable { let templateId: String; let exerciseId: String }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: Binding(
                        get: { programs.library.defaultRestSeconds },
                        set: { v in programs.mutate { $0.defaultRestSeconds = max(0, v) } }),
                            in: 0...900, step: 15) {
                        HStack {
                            Text("Default rest")
                            Spacer()
                            Text(verbatim: LiftRestTimer.clock(TimeInterval(programs.library.defaultRestSeconds)))
                                .monospacedDigit()
                                .foregroundStyle(TelosColor.textSecondary)
                        }
                    }
                } footer: {
                    Text("Used for every exercise without its own rest time. Adjust a running rest with ±15 s.")
                }

                ForEach(programs.library.programs) { program in
                    Section {
                        ForEach(program.days) { day in
                            NavigationLink(value: TemplateRoute(id: day.id)) {
                                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                                    Text(verbatim: day.name)
                                    Text("\(day.exercises.count) exercises · \(day.plannedSetCount) sets")
                                        .font(TelosType.caption)
                                        .foregroundStyle(TelosColor.textSecondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { program.days[$0].id }
                            programs.mutate { lib in ids.forEach { lib.removeTemplate(id: $0) } }
                        }
                        Button {
                            let day = LiftDayTemplate(name: String(localized: "New day"), exercises: [])
                            programs.mutate { lib in
                                if let i = lib.programs.firstIndex(where: { $0.id == program.id }) {
                                    lib.programs[i].days.append(day)
                                }
                            }
                        } label: {
                            Label("Add day", systemImage: "plus")
                        }
                    } header: {
                        Text(verbatim: program.name)
                    }
                }

                Section {
                    LiftPlanImportButton(programs: programs)
                    Button {
                        programs.mutate { lib in
                            let day = LiftDayTemplate(name: String(localized: "Day 1"), exercises: [])
                            lib.programs.append(LiftProgram(name: String(localized: "My program"), days: [day]))
                        }
                    } label: {
                        Label("New program", systemImage: "plus.rectangle.on.rectangle")
                    }
                } footer: {
                    Text("Importing a plan replaces a program of the same name; your rest times and history links are kept.")
                }
            }
            .navigationTitle(Text("Training plan"))
            .liftFormChrome()
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TemplateRoute.self) { route in
                LiftTemplateEditorView(programs: programs, templateId: route.id)
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                LiftExerciseEditorView(programs: programs, templateId: route.templateId, exerciseId: route.exerciseId)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Day template

struct LiftTemplateEditorView: View {
    @ObservedObject var programs: LiftProgramStore
    let templateId: String
    @State private var name = ""

    private var template: LiftDayTemplate? { programs.library.template(id: templateId) }

    var body: some View {
        List {
            Section {
                TextField("Day name, e.g. Lower A (Di)", text: $name)
                    .onSubmit(commitName)
                if let t = template {
                    Text(t.weekday == nil
                         ? String(localized: "No weekday tag — add one in brackets, e.g. (Di) or (Tue), to have this day picked on that weekday.")
                         : String(localized: "Picked automatically on its weekday."))
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textSecondary)
                }
            }
            Section {
                ForEach(template?.exercises ?? []) { ex in
                    NavigationLink(value: LiftProgramEditorView.ExerciseRoute(templateId: templateId, exerciseId: ex.id)) {
                        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                            Text(verbatim: ex.name)
                            Text(verbatim: summary(ex))
                                .font(TelosType.caption)
                                .foregroundStyle(TelosColor.textSecondary)
                        }
                    }
                }
                .onMove { from, to in
                    programs.mutate { lib in lib.updateTemplate(id: templateId) { $0.exercises.move(fromOffsets: from, toOffset: to) } }
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { template?.exercises[$0].id }
                    programs.mutate { lib in lib.updateTemplate(id: templateId) { day in ids.forEach { day.removeExercise(id: $0) } } }
                }
                Button {
                    var ex = LiftExercisePlan(name: String(localized: "New exercise"), sets: [], targetReps: 10)
                    ex.setWorkingSetCount(3)
                    programs.mutate { lib in lib.updateTemplate(id: templateId) { $0.addExercise(ex) } }
                } label: {
                    Label("Add exercise", systemImage: "plus")
                }
            } header: {
                Text("Exercises")
            }
        }
        .navigationTitle(Text(verbatim: template?.name ?? ""))
        .liftFormChrome()
        .toolbar { EditButton() }
        .onAppear { name = template?.name ?? "" }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != template?.name else { return }
        programs.mutate { lib in lib.updateTemplate(id: templateId) { $0.name = trimmed } }
    }

    private func summary(_ ex: LiftExercisePlan) -> String {
        var parts: [String] = []
        if let e = ex.equipment { parts.append(e) }
        var sets = String(localized: "\(ex.workingSetCount) sets")
        if ex.warmupSetCount > 0 { sets += " + " + String(localized: "\(ex.warmupSetCount) warm-up") }
        parts.append(sets)
        if let r = ex.targetReps {
            if let h = ex.targetRepsHigh, h != r { parts.append("\(r)–\(h) " + String(localized: "reps")) }
            else { parts.append(String(localized: "\(r) reps")) }
        }
        if let rest = ex.restSeconds { parts.append(String(localized: "rest \(LiftRestTimer.clock(TimeInterval(rest)))")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Exercise

struct LiftExerciseEditorView: View {
    @ObservedObject var programs: LiftProgramStore
    let templateId: String
    let exerciseId: String
    @State private var name = ""
    @State private var equipment = ""

    private var exercise: LiftExercisePlan? {
        programs.library.template(id: templateId)?.exercises.first { $0.id == exerciseId }
    }

    private func update(_ change: @escaping (inout LiftExercisePlan) -> Void) {
        programs.mutate { lib in
            lib.updateTemplate(id: templateId) { day in day.updateExercise(id: exerciseId, change) }
        }
    }

    var body: some View {
        Form {
            Section("Exercise") {
                TextField("Name", text: $name).onSubmit(commitText)
                TextField("Equipment (machine, cable, bodyweight…)", text: $equipment).onSubmit(commitText)
            }
            if let ex = exercise {
                Section {
                    Stepper(value: Binding(get: { ex.workingSetCount }, set: { n in update { $0.setWorkingSetCount(n) } }),
                            in: 0...12) {
                        Text("\(ex.workingSetCount) working sets")
                    }
                    Stepper(value: Binding(get: { ex.warmupSetCount }, set: { n in update { $0.setWarmupCount(n) } }),
                            in: 0...6) {
                        Text("\(ex.warmupSetCount) warm-up sets")
                    }
                    ForEach(Array(ex.sets.enumerated()), id: \.element.id) { index, planned in
                        Picker(selection: Binding(get: { planned.kind },
                                                  set: { k in update { $0.setKind(setId: planned.id, to: k) } })) {
                            ForEach(LiftSetKind.allCases, id: \.self) { kind in
                                Text(verbatim: LiftCopy.setKind(kind)).tag(kind)
                            }
                        } label: {
                            Text("Set \(index + 1)")
                        }
                    }
                } header: {
                    Text("Sets")
                }
                Section("Rep target") {
                    Toggle("Has a rep target", isOn: Binding(
                        get: { ex.targetReps != nil },
                        set: { on in update { $0.targetReps = on ? ($0.targetReps ?? 10) : nil; if !on { $0.targetRepsHigh = nil } } }))
                    if let reps = ex.targetReps {
                        Stepper(value: Binding(get: { reps }, set: { v in update { $0.targetReps = v } }), in: 1...50) {
                            Text("\(reps) reps")
                        }
                        Toggle("Range", isOn: Binding(
                            get: { ex.targetRepsHigh != nil },
                            set: { on in update { $0.targetRepsHigh = on ? max(reps + 2, $0.targetRepsHigh ?? 0) : nil } }))
                        if let high = ex.targetRepsHigh {
                            Stepper(value: Binding(get: { high }, set: { v in update { $0.targetRepsHigh = max(v, reps) } }),
                                    in: reps...60) {
                                Text("up to \(high) reps")
                            }
                        }
                    }
                }
                Section {
                    Toggle("Own rest time", isOn: Binding(
                        get: { ex.restSeconds != nil },
                        set: { on in
                            let fallback = programs.library.defaultRestSeconds
                            update { $0.restSeconds = on ? ($0.restSeconds ?? fallback) : nil }
                        }))
                    if let rest = ex.restSeconds {
                        Stepper(value: Binding(get: { rest }, set: { v in update { $0.restSeconds = max(0, v) } }),
                                in: 0...900, step: 15) {
                            Text(verbatim: LiftRestTimer.clock(TimeInterval(rest))).monospacedDigit()
                        }
                    } else {
                        Text("Default \(LiftRestTimer.clock(TimeInterval(programs.library.defaultRestSeconds)))")
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                } header: {
                    Text("Rest after each set")
                }
            }
        }
        .navigationTitle(Text(verbatim: exercise?.name ?? ""))
        .liftFormChrome()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = exercise?.name ?? ""
            equipment = exercise?.equipment ?? ""
        }
        .onDisappear(perform: commitText)
    }

    private func commitText() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ex = exercise else { return }
        let newName = n.isEmpty ? ex.name : n
        let newEquipment: String? = e.isEmpty ? nil : e
        guard newName != ex.name || newEquipment != ex.equipment else { return }
        update { $0.name = newName; $0.equipment = newEquipment }
    }
}
#endif
