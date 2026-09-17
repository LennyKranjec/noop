import SwiftUI
import StrandDesign

// RoutinesView.swift — the fixed points of the day, as the coach plans around them.
//
// Replaces Goals under More. Every field here reaches the coach on every session and every directive
// it writes, as a constraint rather than as background — see `CoachRoutines`.
//
// SAVES AS YOU EDIT. A routine is a handful of times and a line or two, and a Save button on a form
// this short is a button people forget to press and then wonder why the coach still thinks they train
// at six.

struct RoutinesView: View {
    @State private var routines = CoachRoutines.read()

    var body: some View {
        ScreenScaffold(title: "Routines",
                       subtitle: "Your day's fixed points. The coach plans inside them.",
                       topBackground: liquidScaffoldSky()) {
            StrandCard {
                VStack(alignment: .leading, spacing: 14) {
                    header("THE DAY")
                    TimeRow(label: "Wake up", minutes: $routines.wake, fallback: 6 * 60 + 30)
                    TimeRow(label: "Bedtime", minutes: $routines.bed, fallback: 22 * 60 + 30)
                    TimeRow(label: "Work starts", minutes: $routines.workStart, fallback: 8 * 60)
                    TimeRow(label: "Work ends", minutes: $routines.workEnd, fallback: 17 * 60)
                    TimeRow(label: "Last caffeine", minutes: $routines.caffeineCutoff, fallback: 14 * 60)
                }
            }

            StrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    header("TRAINING")
                    field("e.g. Gym Mon/Wed/Fri 18:00, long run Sunday morning", text: $routines.training)
                    header("MEALS")
                    field("e.g. Breakfast 07:00, lunch 12:30, dinner 19:00", text: $routines.meals)
                }
            }

            StrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    header("ANYTHING ELSE")
                    Text("School runs, shifts, commutes, a standing appointment — whatever a plan has to fit around.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach($routines.entries) { $entry in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 6) {
                                field("What", text: $entry.title)
                                field("When / details", text: $entry.detail)
                            }
                            Button {
                                routines.entries.removeAll { $0.id == entry.id }
                                SystemHaptics.play(.select)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(StrandPalette.statusCritical)
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove routine")
                        }
                    }
                    Button {
                        routines.entries.append(CoachRoutineEntry(title: "", detail: ""))
                        SystemHaptics.play(.tap)
                    } label: {
                        Label("Add a routine", systemImage: "plus.circle.fill")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("The coach receives all of this at the start of every session, and every quest and "
                 + "briefing it writes is planned inside it.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onChangeCompat(of: routines) { CoachRoutines.write($0) }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.overline)
            .tracking(1.2)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .font(StrandFont.body)
            .lineLimit(1...4)
            .padding(10)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One optional time of day: a switch that turns it on, and the time once it is.
private struct TimeRow: View {
    let label: String
    @Binding var minutes: Int?
    /// What the picker starts at when the row is switched on.
    let fallback: Int

    private var enabled: Binding<Bool> {
        Binding(get: { minutes != nil }, set: { minutes = $0 ? (minutes ?? fallback) : nil })
    }

    private var date: Binding<Date> {
        Binding(
            get: {
                let m = minutes ?? fallback
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        HStack {
            Toggle(isOn: enabled) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .fixedSize()
            Spacer(minLength: 8)
            if minutes != nil {
                DatePicker("", selection: date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }
}
