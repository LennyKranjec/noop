import SwiftUI
import StrandDesign
import StrandImport
import WhoopStore

// StrengthProgressionCardView.swift — the PROGRESSION section, one row per exercise.
//
// WHAT IT ANSWERS that the muscle card above it cannot. That card says where the volume WENT this week —
// which is about distribution, and moves with the plan. This says whether each lift is getting STRONGER,
// which is the question a wearer actually asks in the gym and is per-exercise by nature: a rising bench
// press and a stalled leg press are one week's volume either way.
//
// HONESTY IS THE WHOLE DESIGN HERE, because every figure on this card is an ESTIMATE of a one-rep max
// nobody performed. So:
//   • An exercise with fewer than `minSessions` readable sessions shows its name, the count it has and the
//     count it needs, and NO number at all — not a greyed-out figure, not a provisional one.
//   • A sparkline is drawn only from sessions that produced an estimate. A session whose sets were all
//     bodyweight-added or all above twelve reps leaves no point, and the line simply does not pass through
//     it rather than being interpolated across a gap that would read as data.
//   • The suggestion never exceeds one of the wearer's OWN observed increments, and where no increment can
//     be inferred it offers reps or nothing.
//   • With low charge today, the suggestion keeps a caution beside it. It is not withheld — the wearer may
//     be reading this on a rest day for a session two days out — but it does not sit there unqualified.
//
// WHAT A WEARER WITH ONLY PRE-CHANGE HISTORY SEES. Sets were never stored before this change, so a log
// imported last month has totals and no sets, and this card can read nothing from it. It says exactly that
// and names the fix (re-import), rather than showing an empty list that reads as "you have not trained".

/// How far a sparkline looks back, in sessions. Enough to see the shape of a block, short enough that a
/// row's line is not a year compressed into 90 points.
private let sparklineSessions = 16

struct StrengthProgressionCardView: View {
    @EnvironmentObject var repo: Repository

    /// Nil until the first load finishes — which is what distinguishes "still reading" from "nothing there".
    @State private var exercises: [StrengthProgression.Exercise]?
    /// Today's charge, when today has one. Nil means unknown, which is NOT the same as good.
    @State private var todayCharge: Double?

    private var scored: [StrengthProgression.Exercise] { (exercises ?? []).filter { $0.abstained == nil } }
    private var abstaining: [StrengthProgression.Exercise] { (exercises ?? []).filter { $0.abstained != nil } }

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Progression").strandOverline()
            Text("Estimated one-rep max per exercise, from your logged sets")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if exercises == nil {
            Text("Reading your sets…")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if (exercises ?? []).isEmpty {
            // THE EMPTY STATE NAMES THE CAUSE. Sets have only been stored since this change, so a wearer
            // who imported months ago has a full workout history and nothing here — and "no data" would
            // read as the app losing their training rather than as one re-import away.
            Text("No set-by-set history stored yet. Sessions imported before this update kept only their totals, so progression can only read imports made after it — re-import your log from Data Sources.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(scored, id: \.name) { exercise in
                    NavigationLink {
                        StrengthProgressionDetailView(exercise: exercise, todayCharge: todayCharge)
                    } label: {
                        ProgressionRow(exercise: exercise, lowCharge: isLowCharge)
                    }
                    .buttonStyle(.plain)
                }
                if !abstaining.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    thinDataFootnote
                }
            }
        }
    }

    /// The exercises that report nothing, as ONE line rather than a list of blanks.
    ///
    /// Each of them individually has nothing to show, and a row per exercise saying so would bury the lifts
    /// that DO have a reading under the ones that do not. Naming them keeps the information — a wearer can
    /// see the app knows about the lift and is waiting for sessions, not ignoring it.
    private var thinDataFootnote: some View {
        let names = abstaining.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Text("Waiting on more sessions (\(StrengthProgression.minSessions) needed): \(names.joined(separator: ", "))")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isLowCharge: Bool {
        guard let charge = todayCharge else { return false }
        return charge < StrengthProgressionSource.lowChargeThreshold
    }

    private func load() async {
        // TODAY'S charge specifically, matched on the day key rather than taken as the last row: the last
        // row is whatever day history ends on, and a caution drawn from a low day three weeks ago would be
        // a warning about a day the wearer is not in.
        let todayKey = Repository.localDayKey(Date())
        todayCharge = repo.days.first { $0.day == todayKey }?.recovery

        guard let store = await repo.storeHandle() else {
            exercises = []
            return
        }
        exercises = await StrengthProgressionSource.load(store: store)
    }
}

// MARK: - One exercise's row

/// Name, current estimate, trend arrow, sparkline, the stall marker and the suggestion.
///
/// EVERY FIELD IS INDEPENDENTLY ABSENT-ABLE. A lift can have a current estimate and no trend (one session
/// in every window), a trend and no suggestion (rep range topped out with no inferable step), or a stall and
/// no suggestion. Each is drawn only when its own value exists, so nothing here is a placeholder.
private struct ProgressionRow: View {
    let exercise: StrengthProgression.Exercise
    /// Whether today's charge is low, which qualifies the suggestion rather than withholding it.
    let lowCharge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if exercise.stall != nil { stalledPill }
                Spacer(minLength: 8)
                trailingFigure
            }
            if !exercise.e1rmSeries.isEmpty {
                Sparkline(values: Array(exercise.e1rmSeries.map(\.value).suffix(sparklineSessions)),
                          gradient: StrandPalette.recoveryGradient,
                          lineWidth: 1.5,
                          showsArea: false,
                          showsHover: false,
                          valueFormat: { StrengthProgressionCopy.kgUnit($0) })
                    .frame(height: 22)
            }
            if let stall = exercise.stall {
                Text(StrengthProgressionCopy.stalledLine(stall))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let suggestion = exercise.suggestion {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.forward.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Text(StrengthProgressionCopy.suggestion(suggestion))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if lowCharge {
                    Text("Charge is low today — this step can wait for a better day.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var stalledPill: some View {
        Text("Stalled")
            .font(StrandFont.overline)
            .foregroundStyle(StrandPalette.recovery030)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(StrandPalette.recovery030.opacity(0.14), in: Capsule(style: .continuous))
    }

    /// The current estimate and the arrow, or an em dash when there is no estimate to show.
    @ViewBuilder
    private var trailingFigure: some View {
        HStack(spacing: 4) {
            if let trend = exercise.headlineTrend {
                Image(systemName: StrengthProgressionCopy.arrow(trend.direction))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint(for: trend.direction))
                    .accessibilityLabel(Text(StrengthProgressionCopy.directionLabel(trend.direction)))
            }
            Text(exercise.currentE1rmKg.map { StrengthProgressionCopy.kgUnit($0) } ?? "—")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func tint(for direction: StrengthProgression.Direction) -> Color {
        switch direction {
        case .up: return StrandPalette.recovery100
        case .flat: return StrandPalette.textTertiary
        case .down: return StrandPalette.recovery030
        }
    }
}
