import SwiftUI
import StrandAnalytics
import StrandDesign

// GoalCoachPanel.swift — the short coach panel on the Goals screen (DESIGN_V2 decision 14): one compact
// prompt row and the latest answer. NOT a second chat: it reuses the coach engine (`AICoachEngine`), its
// context blocks and its token budget (`generateOneShotResult(budget:build:)`, one retry at half), and asks
// ONE thing — plan toward the goals as fast as is realistic, and judge each goal's ambition honestly.
//
// THE GOALS BLOCK rides the same budgeted assembly as every other block (`CoachContextBudget.fit`), at the
// top value (it is the subject of the request), with its short form. Once the Strand/AI owner registers
// the goals block in `contextBlocks()` (hand-off), this panel drops that copy by name before adding its
// own, so the goals are never sent twice.
//
// The latest answer is kept in UserDefaults with its day, so reopening the screen does not spend a request.
// Nothing is sent without the wearer tapping Ask; consent and key failures come back as the engine's own
// sentences (`AICoachError`), never guessed.

/// The stored latest answer.
struct GoalCoachAnswer: Codable, Equatable {
    let day: String
    let text: String

    static let key = "goals.coach.latestAnswer.v1"

    static func load(_ d: UserDefaults = .standard) -> GoalCoachAnswer? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GoalCoachAnswer.self, from: data)
    }

    static func save(_ a: GoalCoachAnswer, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(a) { d.set(data, forKey: key) }
    }
}

enum GoalCoachPrompt {
    /// The block's name in the context budget. Must match the name the Strand/AI hand-off registers.
    static let blockName = "the wearer's goals"

    static let defaultQuestion =
        "Plan my next weeks toward my goals as fast as is realistic. Tell me honestly which goals are too ambitious and what would make them realistic."

    /// The framing. Short on purpose: the verdicts and their numbers are computed, the model only plans.
    static let systemPrompt = """
    You are the wearer's coach, answering from the Goals screen in at most 6 short lines.
    The GOALS block below lists each active goal with its target, date, current value, the weekly change it \
    needs, the projected range at the date and a computed verdict (on track / ambitious but plausible / \
    unrealistic at this date / can't judge yet). Those verdicts are computed from the wearer's own trend and \
    documented rates of change — never contradict their numbers, never invent new ones.
    Plan toward the goals as fast as is REALISTIC: name concrete sessions, minutes, bedtimes or loads that fit \
    this week's plan and today's state. For a goal marked unrealistic, say so plainly and give the realistic \
    date or value from the block. Never promise an outcome: say "projection", never "you will". Goals are \
    aspirations — never mention penalties.
    """
}

@MainActor
struct GoalCoachPanel: View {
    /// NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    /// actions. Observing it re-rendered the whole view per chunk while any generation ran.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    let assessments: [GoalAssessment]
    let today: String

    @State private var question = GoalCoachPrompt.defaultQuestion
    @State private var answer: GoalCoachAnswer? = GoalCoachAnswer.load()
    @State private var asking = false
    @State private var failure: String?

    var body: some View {
        StrandCard(tint: TelosColor.mint) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                PGGlyphHeader(systemImage: "sparkles", title: Text("Coach"), tint: TelosColor.mint,
                              trailing: answer.map { Text(verbatim: "ANSWERED \($0.day)") })
                if let a = answer {
                    Text(a.text)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Ask the coach to plan toward your goals and to judge how realistic they are.")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: TelosSpace.s) {
                    TextField("Ask about your goals", text: $question, axis: .vertical)
                        .lineLimit(1...3)
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textPrimary)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, TelosSpace.m)
                        .padding(.vertical, TelosSpace.s)
                        .frame(minHeight: TelosSpace.hitTarget)
                        .pgInsetBand()
                    if asking {
                        ProgressView().controlSize(.small)
                            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                    } else {
                        Button {
                            TelosHaptics.play(.commit)
                            Task { await ask() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(TelosType.glyphControl)
                                .foregroundStyle(TelosColor.onAccent)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(TelosColor.mint))
                                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                                .contentShape(Circle())
                        }
                        .buttonStyle(TelosPressButtonStyle())
                        .accessibilityLabel(Text("Ask"))
                        .disabled(assessments.isEmpty || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(assessments.isEmpty ? TelosOpacity.disabled : 1)
                    }
                }
                if let failure {
                    Text(failure)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func ask() async {
        guard !asking else { return }
        asking = true
        failure = nil
        defer { asking = false }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = GoalCoachSummary.block(assessments, asOf: today, maxChars: 900)
        let short = GoalCoachSummary.shortBlock(assessments, asOf: today, maxChars: 320)
        let engine = coach
        let result = await engine.generateOneShotResult(budget: .brief) { budget in
            let reserved = engine.reservedTokens(framing: GoalCoachPrompt.systemPrompt, question: q)
            var blocks = await engine.contextBlocks().filter { $0.name != GoalCoachPrompt.blockName }
            blocks.append(CoachContextBlock(name: GoalCoachPrompt.blockName, value: 100, full: full, short: short))
            let fit = CoachContextBudget.fit(blocks, budget: budget, reserved: reserved)
            return (systemPrompt: GoalCoachPrompt.systemPrompt + "\n\n" + fit.text, question: q)
        }
        switch result {
        case .success(let text):
            let a = GoalCoachAnswer(day: today, text: text)
            GoalCoachAnswer.save(a)
            answer = a
        case .failure(let error):
            failure = error.errorDescription ?? "The coach could not answer."
        }
    }
}
