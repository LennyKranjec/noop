import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitTrialTodayCard.swift — today's trial assignment and its single answer (HEALTH_V2 §S1-B.7, DESIGN_V2
// §5.15 "Trial card"). Hosted by Today's quest area and the Habits hub. Shows today's arm only — never the
// schedule ahead, never an interim estimate.
//
// TELOS 2.0: a glass card in the habits teal. Header "TRIAL" + the arm-schedule tag, the habit, the outcome;
// TODAY'S ASSIGNMENT is the hero — a 56 pt band with ON / OFF as a large light word (ON carries a 3 pt
// accent rail) and today's instruction beside it; the two arms' valid nights as pip rows; the one answer as
// two chips; the provenance row (started · planned end). Nothing animates except the assignment band's
// cross-fade when the day rolls.

struct HabitTrialTodayCard: View {
    @ObservedObject var trials: HabitTrialStore = .shared
    @ObservedObject var bridge: HabitTrialQuestBridge = .shared
    var now: Date = Date()

    private var today: String { Repository.localDayKey(now) }

    var body: some View {
        if let assignment = trials.todayAssignment(today: today), let entry = assignment.record.entry {
            card(record: assignment.record, entry: entry, on: assignment.on)
        }
    }

    @ViewBuilder
    private func card(record: HabitTrialRecord, entry: HabitTrialEntry, on: Bool) -> some View {
        let progress = trials.runningProgress(today: today)
        let answer = trials.dayRecord(today)?.answer ?? .unknown
        StrandCard(tint: TelosColor.teal) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                header(record: record, entry: entry, progress: progress)
                assignmentBand(entry: entry, on: on)
                    .id(today)
                    .transition(.opacity)
                if let p = progress {
                    VStack(alignment: .leading, spacing: TelosSpace.xs) {
                        TrialPipRow(arm: Text("ON"), valid: p.validOn, planned: p.plannedPerArm, tint: TelosColor.teal)
                        TrialPipRow(arm: Text("OFF"), valid: p.validOff, planned: p.plannedPerArm)
                        Text(HealthAbsence.sealedUntil(day: p.sealedUntil).line)
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                answerRow(record: record, on: on, answer: answer)
                ProvenanceRow(source: "Trial",
                              window: Text(verbatim: "\(record.registration.startDay) → \(record.registration.endDay)"))
            }
        }
        .animation(TelosMotion.fade, value: today)
    }

    private func header(record: HabitTrialRecord, entry: HabitTrialEntry, progress: HabitTrialProgress?) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(spacing: TelosSpace.s) {
                PGOverline("Trial", ink: TelosColor.teal)
                TelosTag(record.registration.design == .weekdayBalanced ? "Randomised" : "Alternating",
                         ink: TelosColor.textSecondary)
                Spacer(minLength: TelosSpace.s)
                if let p = progress {
                    Text(verbatim: "DAY \(p.dayNumber) / \(p.lengthDays)")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                }
            }
            Text(entry.title)
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Outcome: \(entry.primaryOutcome.label)")
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
        }
    }

    /// The hero: today's arm as a word, the instruction beside it.
    private func assignmentBand(entry: HabitTrialEntry, on: Bool) -> some View {
        HStack(alignment: .center, spacing: TelosSpace.m) {
            Text(on ? "ON" : "OFF")
                .telosNumeral(.numeralL)
                .foregroundStyle(on ? TelosColor.teal : TelosColor.textPrimary)
                .frame(minWidth: 64, alignment: .leading)
            Text(on ? entry.onInstruction : "Normal evening — nothing to change. " + entry.offInstruction + ".")
                .font(TelosType.body)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, TelosSpace.s)
        .padding(.horizontal, TelosSpace.m)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .overlay(alignment: .leading) {
            if on {
                Capsule(style: .continuous)
                    .fill(TelosColor.teal)
                    .frame(width: TelosStroke.rail)
                    .padding(.vertical, TelosSpace.s)
            }
        }
        .pgInsetBand()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(on ? "Today is an ON day" : "Today is an OFF day"))
    }

    @ViewBuilder
    private func answerRow(record: HabitTrialRecord, on: Bool, answer: HabitTrialBehaviour) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            Text(on ? "Did you do it today?" : "Did you keep to your normal evening?")
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
            HStack(spacing: TelosSpace.s) {
                TelosChip(on ? "Did it" : "Kept to normal", isOn: answer == (on ? .did : .didNot)) {
                    respond(record: record, did: on)
                }
                TelosChip(on ? "Didn't" : "Did it anyway", isOn: answer == (on ? .didNot : .did)) {
                    respond(record: record, did: !on)
                }
            }
            if answer != .unknown {
                Text("Logged. Either answer counts the same.")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
    }

    /// `did` is whether the ON behaviour happened (OFF: "did it anyway").
    private func respond(record: HabitTrialRecord, did: Bool) {
        bridge.answer(questId: HabitTrialQuestId.make(trialId: record.id, day: today), did: did)
    }
}
