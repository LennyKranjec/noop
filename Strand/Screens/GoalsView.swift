import SwiftUI
import StrandDesign

// GoalsView.swift — what the wearer is actually training for.
//
// SwiftUI twin of the Android Goals screen, over the same `CoachGoals` store.
//
// FREE TEXT, NOT A GOAL MODEL. The things people actually want are sentences — "get back under 20 min
// for 5k without wrecking my sleep", "stop skipping legs" — and a schema with a target, a deadline and
// a progress bar would force those into fields that lose the point. There is nothing here to tick off,
// because a goal that can be ticked off is a task.
//
// IT IS THE ONLY PLACE THE COACH LEARNS ANYTHING THE NUMBERS CANNOT TELL IT. Charge, effort and sleep
// say how the body is; this says what it is FOR, and advice without it is generic by construction. It
// rides in the system prompt on every session, which is why it is bounded: every character there is
// prompt-processing time the wearer waits through.

struct GoalsView: View {
    @State private var draft = CoachGoals.read()
    @State private var saved = false

    private var remaining: Int { CoachGoals.maxChars - draft.count }

    var body: some View {
        ScreenScaffold(title: "Goals",
                       subtitle: "What you are training for, in your own words.",
                       topBackground: liquidScaffoldSky()) {
            StrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("THE COACH READS THIS EVERY TIME")
                        .font(StrandFont.overline)
                        .tracking(1.2)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Text("Your numbers say how your body is. This says what it is for — without it, "
                         + "every suggestion is generic by construction.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $draft)
                        .font(StrandFont.body)
                        .frame(minHeight: 160)
                        .scrollContentBackgroundHiddenCompat()
                        .padding(8)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChangeCompat(of: draft) { text in
                            // Trimmed at the source rather than on save: a field that silently drops
                            // the end of a sentence when you press Save is worse than one that stops
                            // accepting characters where the limit is.
                            if text.count > CoachGoals.maxChars {
                                draft = String(text.prefix(CoachGoals.maxChars))
                            }
                            saved = false
                        }

                    HStack {
                        Text("\(remaining) characters left")
                            .font(StrandFont.caption)
                            .foregroundStyle(remaining < 40
                                             ? StrandPalette.statusWarning
                                             : StrandPalette.textTertiary)
                        Spacer()
                        if saved {
                            Label("Saved", systemImage: "checkmark")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.statusPositive)
                        }
                        Button("Save") {
                            CoachGoals.write(draft)
                            draft = CoachGoals.read()
                            saved = true
                            SystemHaptics.play(.confirm)
                        }
                        .font(StrandFont.footnote)
                        .disabled(draft == CoachGoals.read())
                    }

                    // Said out loud: an empty goal is a valid state, and the app should not nag about
                    // it. What it costs is worth knowing, though.
                    if CoachGoals.read().isEmpty {
                        Text("Empty is fine. The coach will just have less to go on, and it shows.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }

            StrandCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXAMPLES")
                        .font(StrandFont.overline)
                        .tracking(1.2)
                        .foregroundStyle(StrandPalette.textSecondary)
                    ForEach(Self.examples, id: \.self) { example in
                        Text("· " + example)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static let examples = [
        "Back under 20 minutes for 5k, without wrecking my sleep to get there.",
        "Stop skipping legs. Two lower sessions a week, every week.",
        "Sleep before midnight on work nights — I do not care about the weekends.",
        "Put on 3 kg without losing the running.",
    ]
}

private extension View {
    /// Hide the editor's own backdrop so the card's surface shows through. iOS 16 / macOS 13.
    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
