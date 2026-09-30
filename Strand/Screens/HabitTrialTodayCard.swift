import SwiftUI
import StrandAnalytics
import StrandDesign

// HabitTrialTodayCard.swift — today's trial assignment and its single answer (HEALTH_V2 §S1-B.7, DESIGN_V2
// §5.15 "Trial card"). Logic only; the PROGRESS design package restyles it. Hosted by Today's quest area
// and the Habits hub. Shows today's arm only — never the schedule ahead, never an interim estimate.

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
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("TRIAL").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                Text(entry.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Outcome: \(entry.primaryOutcome.label)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    Text(on ? "ON" : "OFF").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(on ? entry.onInstruction : "Normal evening — nothing to change. " + entry.offInstruction + ".")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                }
                .padding(NoopMetrics.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if let p = progress {
                    Text("Day \(p.dayNumber) of \(p.lengthDays) · valid nights ON \(p.validOn)/\(p.plannedPerArm) · OFF \(p.validOff)/\(p.plannedPerArm)")
                        .font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textTertiary)
                    Text(HealthAbsence.sealedUntil(day: p.sealedUntil).line)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Text(on ? "Did you do it today?" : "Did you keep to your normal evening?")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.space2) {
                    Button(on ? "Did it" : "Kept to normal") { respond(record: record, did: on) }
                        .buttonStyle(.noopSecondary)
                    Button(on ? "Didn't" : "Did it anyway") { respond(record: record, did: !on) }
                        .buttonStyle(.noopSecondary)
                }
                if answer != .unknown {
                    Text("Logged. Either answer counts the same.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// `did` is whether the ON behaviour happened (OFF: "did it anyway").
    private func respond(record: HabitTrialRecord, did: Bool) {
        bridge.answer(questId: HabitTrialQuestId.make(trialId: record.id, day: today), did: did)
    }
}
