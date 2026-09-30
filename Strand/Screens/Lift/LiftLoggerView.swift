#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandAnalytics
import StrandImport

/// Telos Lift — the in-workout strength logger (DESIGN_V2 decision 16), hosted inside `LiveWorkoutView` for a
/// strength sport so HR, zones and Effort keep running underneath.
///
/// Anatomy, top to bottom (the Alphaprog reference, in the Telos language):
///   header — the day template ("Lower A (Di)", tap to switch before the first set), why it was picked, a wrench
///            (program editor) and FINISH, always reachable, prominent once every planned set is done;
///   strip  — the day's exercises as glyph chips with a progress ring each;
///   card   — the exercise: title + "…" menu, equipment and rep target (editable), the step size and where it
///            came from, the progression proposal (before the first working set, never applied by itself),
///            the collapsible warm-up pill, the set table # · KG · REPS · e1RM · ✓, "+ set", "Last time".
/// The rest pill floats above the host's bottom bar (`LiftRestTimerPill`).
struct LiftLoggerView: View {
    @ObservedObject var recorder: LiftSessionRecorder
    @ObservedObject var programs: LiftProgramStore
    /// Finish (after the early-finish confirmation when needed). The host finishes the recorder and the workout.
    let onFinish: () -> Void

    @State private var selectedExerciseId: String?
    @State private var showEarlyFinishConfirm = false
    @State private var showProgramEditor = false
    @State private var showAddExercise = false
    @State private var editingExerciseId: String?
    @State private var expandedWarmups: Set<String> = []
    @State private var picker: LiftValuePicker.Target?
    @State private var showHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            switch recorder.phase {
            case .idle:
                ProgressView().frame(maxWidth: .infinity)
            case .choosing:
                emptyState
            case .logging, .finished:
                if let session = recorder.session {
                    header(session)
                    if session.exercises.isEmpty {
                        freehandPrompt
                    } else {
                        exerciseStrip(session)
                        if let ex = currentExercise(session) {
                            exerciseCard(ex, session: session)
                        }
                    }
                    helpLink
                }
            }
            if let problem = recorder.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.warning)
            }
        }
        .sheet(isPresented: $showProgramEditor) {
            LiftProgramEditorView(programs: programs)
                .presentationBackground(TelosColor.canvas)
        }
        .sheet(isPresented: $showAddExercise) {
            LiftAddExerciseSheet(canSaveToPlan: recorder.session?.templateId != nil) { name, equipment, reps, save in
                recorder.addExercise(name: name, equipment: equipment, targetReps: reps, saveToPlan: save)
            }
            .presentationDetents([.medium])
            .presentationBackground(TelosColor.canvas)
        }
        .sheet(item: Binding(get: { editingExerciseId.map(IdentifiedString.init) },
                             set: { editingExerciseId = $0?.id })) { target in
            if let ex = recorder.session?.exercises.first(where: { $0.id == target.id }) {
                LiftSessionExerciseSheet(exercise: ex, defaultRest: programs.library.defaultRestSeconds,
                                         canSaveToPlan: recorder.session?.templateId != nil) { equipment, reps, rest, save in
                    recorder.updateExercise(exerciseId: ex.id, equipment: equipment, targetReps: reps,
                                            restSeconds: rest, saveToPlan: save)
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(TelosColor.canvas)
            }
        }
        .sheet(item: $picker) { target in
            LiftValuePicker(target: target, recorder: recorder)
                .presentationDetents([.height(340)])
                .presentationBackground(TelosColor.canvas)
        }
        .alert("Finish early?", isPresented: $showEarlyFinishConfirm) {
            Button("Keep going", role: .cancel) { }
            Button("Finish") { onFinish() }
        } message: {
            Text("\(recorder.session?.pendingCount ?? 0) planned sets are not checked. They will be recorded as not done — never as zero.")
        }
    }

    // MARK: - Header

    private func header(_ session: LiftLoggedSession) -> some View {
        HStack(alignment: .center, spacing: TelosSpace.s) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                templateMenu(session)
                if let reason = recorder.pickReason {
                    Text(pickReasonText(reason)).font(TelosType.caption).foregroundStyle(TelosColor.textTertiary)
                }
            }
            Spacer(minLength: TelosSpace.s)
            Button { showProgramEditor = true } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(TelosColor.textSecondary)
                    .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Edit plan"))
            finishButton(session)
        }
    }

    @ViewBuilder
    private func templateMenu(_ session: LiftLoggedSession) -> some View {
        let title = Text(verbatim: session.templateName ?? String(localized: "Freehand session"))
            .font(TelosType.title2)
            .foregroundStyle(TelosColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        if recorder.canSwitchTemplate, !recorder.templates.isEmpty {
            Menu {
                ForEach(recorder.templates) { t in
                    Button(t.name) { recorder.start(templateId: t.id) }
                }
                Divider()
                Button("Freehand session") { recorder.start(templateId: nil) }
            } label: {
                HStack(spacing: TelosSpace.xs) {
                    title
                    Image(systemName: "chevron.down").font(TelosType.glyphChevron).foregroundStyle(TelosColor.textTertiary)
                }
            }
            .accessibilityHint(Text("Choose another day of your plan"))
        } else {
            title
        }
    }

    private func pickReasonText(_ reason: LiftTemplatePicker.Reason) -> String {
        switch reason {
        case .weekday: return String(localized: "Today's day in your plan")
        case .rotation: return String(localized: "Next in your rotation")
        case .first: return String(localized: "First day of your plan")
        }
    }

    @ViewBuilder
    private func finishButton(_ session: LiftLoggedSession) -> some View {
        let prominent = session.allPlannedDone
        Button {
            if session.pendingCount > 0 { showEarlyFinishConfirm = true } else { onFinish() }
        } label: {
            HStack(spacing: TelosSpace.xs) {
                if prominent { Image(systemName: "flag.checkered").accessibilityHidden(true) }
                Text("Finish")
            }
                .font(TelosType.headline)
                .foregroundStyle(prominent ? TelosColor.onAccent : TelosColor.mint)
                .padding(.horizontal, TelosSpace.m)
                .frame(minHeight: TelosSpace.hitTarget)
                .background {
                    Capsule().fill(prominent ? TelosColor.mint : Color.clear)
                }
                .overlay {
                    Capsule().strokeBorder(TelosColor.mint.opacity(prominent ? 0 : TelosOpacity.border),
                                           lineWidth: TelosStroke.line)
                }
                .shadow(color: prominent ? TelosColor.glow.opacity(0.5) : .clear, radius: 8)
        }
        .buttonStyle(TelosPressButtonStyle())
        .animation(TelosMotion.gated(TelosMotion.settle, reduced: reduceMotion), value: prominent)
    }

    // MARK: - Exercise strip

    private func currentExercise(_ session: LiftLoggedSession) -> LiftLoggedExercise? {
        if let id = selectedExerciseId, let ex = session.exercises.first(where: { $0.id == id }) { return ex }
        return session.exercises.first { !$0.isComplete } ?? session.exercises.first
    }

    private func exerciseStrip(_ session: LiftLoggedSession) -> some View {
        let current = currentExercise(session)?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TelosSpace.s) {
                    ForEach(session.exercises) { ex in
                        stripChip(ex, selected: ex.id == current)
                            .id(ex.id)
                            .onTapGesture {
                                selectedExerciseId = ex.id
                                TelosHaptics.play(.select)
                            }
                    }
                    Button { showAddExercise = true } label: {
                        Image(systemName: "plus")
                            .font(TelosType.glyphRow)
                            .foregroundStyle(TelosColor.mint)
                            .frame(width: 52, height: 52)
                            .liftGlass(radius: TelosRadius.tile)
                    }
                    .accessibilityLabel(Text("Add exercise"))
                }
                .padding(.vertical, TelosSpace.xxs)
            }
            .onChangeCompat(of: current) { id in
                guard let id else { return }
                withAnimation(TelosMotion.select) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func stripChip(_ ex: LiftLoggedExercise, selected: Bool) -> some View {
        let total = max(1, ex.sets.count)
        let done = ex.sets.filter { $0.status != .pending }.count
        return ZStack {
            Circle().stroke(TelosColor.line, lineWidth: TelosStroke.strong)
            // The exercise's progress ring settles to each new check (≈0.45 s, then rest; instant under
            // Reduce Motion). A completed exercise lights with one halo stroke — no blur, no shadow.
            Circle()
                .trim(from: 0, to: CGFloat(done) / CGFloat(total))
                .rotation(.degrees(-90))
                .telosLuminousStroke(ex.isComplete ? TelosColor.mint : TelosColor.teal,
                                     lineWidth: TelosStroke.strong,
                                     haloOpacity: ex.isComplete ? 0.3 : 0)
                .animation(TelosMotion.gated(TelosMotion.settle, reduced: reduceMotion), value: done)
            Image(systemName: LiftCopy.glyph(for: ex.name))
                .font(TelosType.glyphRow)
                .foregroundStyle(selected ? TelosColor.mint : TelosColor.textSecondary)
        }
        .frame(width: 36, height: 36)
        .frame(width: 52, height: 52)
        .liftGlass(radius: TelosRadius.tile, raised: selected)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: TelosRadius.tile, style: .continuous)
                    .strokeBorder(TelosColor.mint.opacity(TelosOpacity.secondary), lineWidth: TelosStroke.line)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ex.name))
        .accessibilityValue(Text("\(done) of \(ex.sets.count) sets"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Exercise card

    private func exerciseCard(_ ex: LiftLoggedExercise, session: LiftLoggedSession) -> some View {
        let ctx = recorder.context[ex.id]
        let firstWorkDone = ex.workSets.contains { $0.status == .done }
        return VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: ex.name)
                    .font(TelosType.headline)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: TelosSpace.s)
                exerciseMenu(ex)
            }
            HStack(spacing: TelosSpace.s) {
                TelosChip(verbatim: ex.equipment ?? String(localized: "Equipment"), isOn: ex.equipment != nil) {
                    editingExerciseId = ex.id
                }
                TelosChip(verbatim: ex.targetReps.map { String(localized: "\($0) reps") } ?? String(localized: "Rep target"),
                          isOn: ex.targetReps != nil) {
                    editingExerciseId = ex.id
                }
                Spacer(minLength: 0)
            }
            Text(ex.increment.observed
                 ? String(localized: "Step \(LiftCopy.kg(ex.increment.kg)) kg · from your history")
                 : String(localized: "Step \(LiftCopy.kg(ex.increment.kg)) kg · default, no history yet"))
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)

            if !firstWorkDone, let ctx, let line = LiftCopy.proposalLine(ctx.proposal) {
                proposalCard(ex, proposal: ctx.proposal, line: line)
            } else if !firstWorkDone, let ctx, ctx.proposal.kind == .none, let reason = ctx.proposal.reasons.first {
                Text(verbatim: LiftCopy.reason(reason).prefix(1).uppercased() + LiftCopy.reason(reason).dropFirst())
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            }

            if !ex.warmupSets.isEmpty { warmupPill(ex) }
            setTableHeader
            ForEach(Array(ex.workSets.enumerated()), id: \.element.id) { index, set in
                setRow(ex, set: set, index: index + 1, active: set.id == ex.activeSetId)
            }
            Button { recorder.addSet(exerciseId: ex.id) } label: {
                Label("Set", systemImage: "plus")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.mint)
                    .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(TelosPressButtonStyle())
            if let ctx, !ctx.lastTime.isEmpty { lastTimeCard(ctx) }
        }
        .padding(TelosSpace.cardPadding)
        .liftGlass()
    }

    private func exerciseMenu(_ ex: LiftLoggedExercise) -> some View {
        Menu {
            Button { editingExerciseId = ex.id } label: { Label("Edit exercise", systemImage: "slider.horizontal.3") }
            Button { recorder.addSet(exerciseId: ex.id, kind: .warmup) } label: {
                Label("Add warm-up set", systemImage: "thermometer.low")
            }
            Button { recorder.addSet(exerciseId: ex.id, kind: .drop) } label: {
                Label("Add drop set", systemImage: "arrow.down.right")
            }
            Button { recorder.addSet(exerciseId: ex.id, kind: .failure) } label: {
                Label("Add set to failure", systemImage: "bolt.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(TelosType.glyphControl)
                .foregroundStyle(TelosColor.textSecondary)
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Exercise options"))
    }

    private func proposalCard(_ ex: LiftLoggedExercise, proposal: LiftProposal.Result, line: String) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            HStack {
                proposalTitle(proposal.kind).liftOverline()
                Spacer()
                if proposal.weightKg != nil || proposal.reps != nil {
                    Button("Use") { recorder.applyProposal(exerciseId: ex.id) }
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.mint)
                        .accessibilityHint(Text("Copies the suggestion into the sets still to do"))
                }
            }
            Text(verbatim: line).font(TelosType.body).foregroundStyle(TelosColor.textPrimary)
            ForEach(Array(proposal.reasons.enumerated()), id: \.offset) { _, r in
                Text(verbatim: LiftCopy.reason(r)).font(TelosType.caption).foregroundStyle(TelosColor.textSecondary)
            }
            Text("A suggestion — nothing changes unless you tap Use.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
        }
        .padding(TelosSpace.m)
        .background {
            RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                .fill(TelosColor.mintMuted)
                .overlay {
                    RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [TelosColor.mint.opacity(0.7), TelosColor.mint.opacity(0.1)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: TelosStroke.line)
                }
        }
    }

    private func proposalTitle(_ kind: LiftProposal.Kind) -> Text {
        switch kind {
        case .progress: return Text("Progression")
        case .hold: return Text("Hold")
        case .deload: return Text("Deload")
        case .none: return Text(verbatim: "")
        }
    }

    /// Open when the wearer opened it — and, while a warm-up is the active set, open unless they closed it.
    private func warmupPill(_ ex: LiftLoggedExercise) -> some View {
        let warmupActive = ex.warmupSets.contains { $0.id == ex.activeSetId }
        let open = expandedWarmups.contains(ex.id) != warmupActive
        let done = ex.warmupSets.filter { $0.status == .done }.count
        return VStack(alignment: .leading, spacing: TelosSpace.xs) {
            Button {
                withAnimation(TelosMotion.settle) {
                    if open { expandedWarmups.remove(ex.id) } else { expandedWarmups.insert(ex.id) }
                }
            } label: {
                HStack(spacing: TelosSpace.xs) {
                    Image(systemName: "thermometer.low")
                    Text("\(ex.warmupSets.count) warm-up sets")
                    if done > 0 { Text(verbatim: "· \(done)/\(ex.warmupSets.count)") }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(TelosType.glyphChevron)
                }
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
                .padding(.horizontal, TelosSpace.m)
                .frame(minHeight: 36)
                .liftGlass(radius: TelosRadius.pill)
            }
            .buttonStyle(TelosPressButtonStyle())
            if open {
                ForEach(Array(ex.warmupSets.enumerated()), id: \.element.id) { index, set in
                    setRow(ex, set: set, index: index + 1, active: set.id == ex.activeSetId)
                }
            }
        }
    }

    private var setTableHeader: some View {
        HStack(spacing: TelosSpace.s) {
            Text(verbatim: "#").frame(width: 30, alignment: .leading)
            Text("kg").frame(maxWidth: .infinity)
            Text("Reps").frame(maxWidth: .infinity)
            Text(verbatim: "e1RM").frame(width: 48)
            Color.clear.frame(width: TelosSpace.hitTarget, height: 1)
        }
        .liftOverline()
    }

    private func setRow(_ ex: LiftLoggedExercise, set: LiftLoggedSet, index: Int, active: Bool) -> some View {
        let done = set.status == .done
        return HStack(spacing: TelosSpace.s) {
            Text(verbatim: LiftCopy.rowLabel(kind: set.kind, index: index))
                .font(TelosType.numeralXS)
                .foregroundStyle(set.kind == .working ? TelosColor.textSecondary : TelosColor.amber)
                .frame(width: 30, alignment: .leading)
            valueCell(text: LiftCopy.kg(set.weightKg), active: active, done: done, prefilled: set.prefilled,
                      minus: { recorder.stepWeight(exerciseId: ex.id, setId: set.id, by: -1) },
                      plus: { recorder.stepWeight(exerciseId: ex.id, setId: set.id, by: 1) },
                      open: { picker = .init(exerciseId: ex.id, setId: set.id, field: .weight) })
                .accessibilityLabel(Text("Weight"))
            valueCell(text: set.reps.map(String.init) ?? TelosType.absent, active: active, done: done,
                      prefilled: set.prefilled,
                      minus: { recorder.stepReps(exerciseId: ex.id, setId: set.id, by: -1) },
                      plus: { recorder.stepReps(exerciseId: ex.id, setId: set.id, by: 1) },
                      open: { picker = .init(exerciseId: ex.id, setId: set.id, field: .reps) })
                .accessibilityLabel(Text("Repetitions"))
            Text(verbatim: LiftCopy.e1rm(ex.e1rm(set)))
                .font(TelosType.numeralXS)
                .foregroundStyle(TelosColor.textTertiary)
                .frame(width: 48)
                .accessibilityLabel(Text("Estimated one-rep max"))
            checkButton(ex, set: set, active: active)
        }
        .padding(.vertical, TelosSpace.xxs)
        .opacity(set.status == .notDone ? TelosOpacity.disabled : 1)
        .contextMenu {
            ForEach(LiftSetKind.allCases, id: \.self) { kind in
                Button(LiftCopy.setKind(kind)) { recorder.setKind(exerciseId: ex.id, setId: set.id, to: kind) }
            }
            if set.status == .pending {
                Button(role: .destructive) { recorder.removePendingSet(exerciseId: ex.id, setId: set.id) } label: {
                    Label("Delete set", systemImage: "trash")
                }
            }
        }
    }

    /// A value pill. The ACTIVE row shows filled pills with − / + steppers (the wearer's own step); every row
    /// opens the wheel on tap. A prefilled value is secondary ink until it is touched or checked.
    private func valueCell(text: String, active: Bool, done: Bool, prefilled: Bool,
                           minus: @escaping () -> Void, plus: @escaping () -> Void,
                           open: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            if active {
                Button(action: minus) {
                    Image(systemName: "minus").font(TelosType.glyphRow).frame(width: 30, height: 40)
                }
                .buttonStyle(TelosPressButtonStyle())
                .accessibilityLabel(Text("Decrease"))
            }
            Button(action: open) {
                Text(verbatim: text)
                    .font(TelosType.numeralS)
                    .foregroundStyle(done ? TelosColor.textSecondary
                                     : (prefilled ? TelosColor.textSecondary : TelosColor.textPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TelosPressButtonStyle())
            if active {
                Button(action: plus) {
                    Image(systemName: "plus").font(TelosType.glyphRow).frame(width: 30, height: 40)
                }
                .buttonStyle(TelosPressButtonStyle())
                .accessibilityLabel(Text("Increase"))
            }
        }
        .foregroundStyle(TelosColor.mint)
        .background {
            RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                .fill(active ? TelosColor.mintMuted : TelosColor.glassFill)
        }
        .frame(maxWidth: .infinity)
    }

    private func checkButton(_ ex: LiftLoggedExercise, set: LiftLoggedSet, active: Bool) -> some View {
        let done = set.status == .done
        return Button {
            // The phone haptic (`commit`) is played ONCE by the recorder's `check` — never a second pattern here.
            if done { recorder.uncheck(exerciseId: ex.id, setId: set.id) }
            else if set.status == .pending { recorder.check(exerciseId: ex.id, setId: set.id) }
        } label: {
            LiftCheckMark(status: set.status, active: active)
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .disabled(set.status == .notDone)
        .accessibilityLabel(done ? Text("Set done — tap to undo") : Text("Mark set done"))
    }

    private func lastTimeCard(_ ctx: LiftSessionRecorder.ExerciseContext) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(spacing: TelosSpace.xs) {
                Text(lastTimeHeading(ctx)).liftOverline()
                Spacer()
            }
            let work = ctx.lastTime.filter { !$0.isWarmup }
            ForEach(Array(work.enumerated()), id: \.offset) { index, s in
                HStack(spacing: TelosSpace.s) {
                    Text(verbatim: "\(index + 1)").frame(width: 30, alignment: .leading)
                    Text(verbatim: LiftCopy.kg(s.weightKg) + " kg").frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: s.reps.map { "× \($0)" } ?? TelosType.absent).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: LiftCopy.e1rm(s.e1rmKg)).frame(width: 48)
                    Color.clear.frame(width: TelosSpace.hitTarget, height: 1)
                }
                .font(TelosType.numeralXS)
                .foregroundStyle(TelosColor.textSecondary)
            }
        }
        .padding(TelosSpace.s)
        .background(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous).fill(TelosColor.glassFill))
    }

    private func lastTimeHeading(_ ctx: LiftSessionRecorder.ExerciseContext) -> String {
        let title = ctx.lastTimeTitle?.split(separator: "·").first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        switch ctx.prefillSource {
        case .sameTemplate(let d), .sameExercise(let d):
            let day = relativeDay(d)
            if let title { return "\(day) · \(title)" }
            return day
        case .none:
            return String(localized: "Last time")
        }
    }

    private func relativeDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Today") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Empty / freehand / help

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            Text("No training plan yet").font(TelosType.title2).foregroundStyle(TelosColor.textPrimary)
            Text("Import your Alphaprog plan export to get your days, exercises, sets and rep targets — or log this session without a plan.")
                .font(TelosType.callout)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LiftPlanImportButton(programs: programs) {
                recorder.restartAfterPlanImport()
            }
            Button {
                recorder.start(templateId: nil)
                showAddExercise = true
            } label: {
                Text("Log without a plan").frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
        .padding(TelosSpace.cardPadding)
        .liftGlass()
    }

    private var freehandPrompt: some View {
        Button { showAddExercise = true } label: {
            Label("Add the first exercise", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
        }
        .buttonStyle(NoopButtonStyle(.primary))
    }

    private var helpLink: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            Button {
                withAnimation(TelosMotion.settle) { showHelp.toggle() }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            if showHelp {
                Text("Rows start from what you did last time on this day (or on this exercise). Tap a number for the wheel; the − / + step is your own weight step for this machine. Check a set to start the rest timer — your strap buzzes at zero. e1RM is an Epley estimate for 1–12 reps; outside that it shows —. Finish records unchecked sets as not done.")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Check mark (the logger's reward micro-moment)

/// The set's check — the logger's most-pressed control, made to feel like a commit. On pending → done it
/// POPS (scale 1 → 1.22 → 1, a short spring: the wearer's own press, so the gentle overshoot is allowed)
/// and throws ONE luminous ripple ring outward that fades (≈0.5 s), then rests. The phone haptic is the
/// recorder's single `commit` for the same tap — nothing is added here.
///
/// Cost (§2.1 rule 8): two transforms on a ≤ 40 pt element, only on the change; nothing runs between
/// checks, nothing loops. Reduce Motion / Low Power / "Reduce motion in NOOP" (`NoopMotionState.poseStill`):
/// no pop and no ripple — the fill change alone.
private struct LiftCheckMark: View {
    let status: LiftSetStatus
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    /// Bumped once per pending → done change; drives the two one-shot phase animations.
    @State private var celebrate = 0

    private enum Ripple: CaseIterable { case idle, lit, out }

    var body: some View {
        let done = status == .done
        let size: CGFloat = (active || done) ? 40 : 30
        ZStack {
            if done {
                Circle().fill(TelosColor.mintMuted)
                Circle().strokeBorder(TelosColor.mint.opacity(TelosOpacity.secondary), lineWidth: TelosStroke.line)
                Image(systemName: "checkmark")
                    .font(TelosType.glyphRow.weight(.bold))
                    .foregroundStyle(TelosColor.mint)
            } else if active {
                // The next set to do glows: ONE static radial gradient (no shadow on a table row).
                TelosRadialGlow(color: TelosColor.glow, intensity: 0.45, radius: 30)
                    .frame(width: 64, height: 64)
                Circle().fill(TelosColor.mint)
                Image(systemName: "checkmark")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(TelosColor.onAccent)
            } else if status == .notDone {
                Image(systemName: "minus").font(TelosType.glyphRow).foregroundStyle(TelosColor.textTertiary)
            } else {
                Circle().strokeBorder(TelosColor.lineStrong, lineWidth: TelosStroke.strong)
            }
        }
        .frame(width: size, height: size)
        .background {
            Circle()
                .stroke(TelosColor.mint, lineWidth: TelosStroke.data)
                .phaseAnimator(Ripple.allCases, trigger: celebrate) { ring, phase in
                    ring
                        .scaleEffect(phase == .out ? 1.9 : 1)
                        .opacity(phase == .lit ? 0.9 : 0)
                } animation: { phase in
                    phase == .out ? Animation.easeOut(duration: 0.5) : Animation.linear(duration: 0.01)
                }
        }
        .phaseAnimator([CGFloat(1), CGFloat(1.22)], trigger: celebrate) { mark, scale in
            mark.scaleEffect(scale)
        } animation: { scale in
            scale > 1 ? Animation.spring(response: 0.16, dampingFraction: 0.6) : TelosMotion.release
        }
        .onChangeCompat(of: done) { nowDone in
            if nowDone && !motion.poseStill(reduceMotion) { celebrate &+= 1 }
        }
    }
}

/// A String wrapper so an optional id can drive `.sheet(item:)`.
struct IdentifiedString: Identifiable, Hashable {
    let id: String
    init(_ id: String) { self.id = id }
}

// MARK: - Plan import button (shared by the logger's empty state and the program editor)

struct LiftPlanImportButton: View {
    @ObservedObject var programs: LiftProgramStore
    var onImported: () -> Void = {}
    @State private var working = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            Button { pick() } label: {
                Label(working ? "Importing…" : "Import plan from Alphaprog…", systemImage: "list.bullet.clipboard")
                    .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(working)
            if let message {
                Text(verbatim: message)
                    .font(TelosType.footnote)
                    .foregroundStyle(failed ? TelosColor.warning : TelosColor.positive)
            }
        }
    }

    private func pick() {
        working = true
        Task {
            defer { working = false }
            guard let url = await DocumentPicker.importFile([.commaSeparatedText, .plainText, .text, .data]) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let read = try? await ImportFileRead.read(url), !read.data.isEmpty else {
                message = String(localized: "That file is empty or not downloaded yet — open it once in Files, then try again.")
                failed = true
                return
            }
            guard let outcome = programs.importAlphaprogPlan(data: read.data), outcome.programs > 0 else {
                message = String(localized: "No training plan found in that file.")
                failed = true
                return
            }
            message = String(localized: "Imported \(outcome.programs) programs · \(outcome.days) days · \(outcome.exercises) exercises")
            failed = false
            onImported()
        }
    }
}

// MARK: - Wheel picker

/// Weight / reps wheel. The weight wheel steps by the wearer's own increment for this exercise, anchored at
/// the current value; "No weight" clears it (a bodyweight set is honest as "—", not as 0).
struct LiftValuePicker: View {
    struct Target: Identifiable, Hashable {
        enum Field: Hashable { case weight, reps }
        let exerciseId: String
        let setId: String
        let field: Field
        var id: String { "\(exerciseId)/\(setId)/\(field == .weight ? "w" : "r")" }
    }

    let target: Target
    @ObservedObject var recorder: LiftSessionRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double = 0
    @State private var reps: Int = 10

    private var exercise: LiftLoggedExercise? {
        recorder.session?.exercises.first { $0.id == target.exerciseId }
    }
    private var currentSet: LiftLoggedSet? { exercise?.sets.first { $0.id == target.setId } }

    var body: some View {
        VStack(spacing: TelosSpace.s) {
            HStack {
                Text(target.field == .weight ? "Weight (kg)" : "Repetitions").font(TelosType.headline)
                Spacer()
                Button("Done") { commit(); dismiss() }.font(TelosType.headline).foregroundStyle(TelosColor.mint)
            }
            if target.field == .weight {
                let values = LiftIncrement.wheelValues(around: currentSet?.weightKg,
                                                       incrementKg: exercise?.increment.kg ?? LiftIncrement.defaultKg)
                Picker("Weight", selection: $weight) {
                    ForEach(values, id: \.self) { v in Text(verbatim: LiftCopy.kg(v)).tag(v) }
                }
                .pickerStyle(.wheel)
                Button("No weight (bodyweight)") {
                    recorder.setWeight(exerciseId: target.exerciseId, setId: target.setId, to: nil)
                    dismiss()
                }
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
            } else {
                Picker("Repetitions", selection: $reps) {
                    ForEach(1...60, id: \.self) { r in Text(verbatim: "\(r)").tag(r) }
                }
                .pickerStyle(.wheel)
            }
        }
        .padding(TelosSpace.l)
        .onAppear {
            let inc = exercise?.increment.kg ?? LiftIncrement.defaultKg
            weight = currentSet?.weightKg ?? inc
            reps = currentSet?.reps ?? exercise?.targetReps ?? 10
        }
    }

    private func commit() {
        switch target.field {
        case .weight: recorder.setWeight(exerciseId: target.exerciseId, setId: target.setId, to: weight)
        case .reps: recorder.setReps(exerciseId: target.exerciseId, setId: target.setId, to: reps)
        }
    }
}

// MARK: - Session exercise sheet (equipment, rep target, rest)

struct LiftSessionExerciseSheet: View {
    let exercise: LiftLoggedExercise
    let defaultRest: Int
    let canSaveToPlan: Bool
    let onSave: (_ equipment: String?, _ reps: Int?, _ rest: Int?, _ saveToPlan: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var equipment = ""
    @State private var reps = 10
    @State private var hasReps = true
    @State private var customRest = false
    @State private var rest = LiftRestTimer.defaultSeconds
    @State private var saveToPlan = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    TextField("Machine, cable, bodyweight…", text: $equipment)
                }
                Section("Rep target") {
                    Toggle("Has a rep target", isOn: $hasReps)
                    if hasReps { Stepper("\(reps) reps", value: $reps, in: 1...50) }
                }
                Section {
                    Toggle("Own rest time", isOn: $customRest)
                    if customRest {
                        Stepper(value: $rest, in: 0...900, step: 15) {
                            Text(verbatim: LiftRestTimer.clock(TimeInterval(rest)))
                        }
                    } else {
                        Text("Default \(LiftRestTimer.clock(TimeInterval(defaultRest)))")
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                } header: { Text("Rest after each set") }
                if canSaveToPlan {
                    Section { Toggle("Also change the plan", isOn: $saveToPlan) }
                }
            }
            .navigationTitle(Text(verbatim: exercise.name))
            .liftFormChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let e = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(e.isEmpty ? nil : e, hasReps ? reps : nil, customRest ? rest : nil,
                               canSaveToPlan && saveToPlan)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            equipment = exercise.equipment ?? ""
            hasReps = exercise.targetReps != nil
            reps = exercise.targetReps ?? 10
            customRest = exercise.restSeconds != nil
            rest = exercise.restSeconds ?? defaultRest
        }
    }
}

// MARK: - Add exercise sheet

struct LiftAddExerciseSheet: View {
    let canSaveToPlan: Bool
    let onAdd: (_ name: String, _ equipment: String?, _ reps: Int?, _ saveToPlan: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var equipment = ""
    @State private var reps = 10
    @State private var saveToPlan = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name, as you call it", text: $name)
                    TextField("Equipment (optional)", text: $equipment)
                    Stepper("\(reps) reps target", value: $reps, in: 1...50)
                }
                if canSaveToPlan {
                    Section { Toggle("Also add to the plan", isOn: $saveToPlan) }
                }
            }
            .navigationTitle(Text("Add exercise"))
            .liftFormChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let e = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(name, e.isEmpty ? nil : e, reps, canSaveToPlan && saveToPlan)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
