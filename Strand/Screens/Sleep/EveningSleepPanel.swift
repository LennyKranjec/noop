import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics

// EveningSleepPanel.swift — the compact "tonight" panel for the TOP of Today in the evening
// (coordinator decision 15: a dynamic Today). TODAY decides WHEN it shows (18:00 or the plan's wind-down
// start if earlier, until the morning); this file decides WHAT it shows:
//
//   · lights out + asleep by, from `SleepScheduleProvider` (the one sleep schedule, HEALTH_V2 S2);
//   · tonight's need (`needLine`) and the sleep-debt payback (`paybackLine`), the model's own words;
//   · the evening's steps — caffeine cutoff, wind-down start, lights out, wake — with the next one lit;
//   · the insomnia note when the plan withholds payback;
//   · the bedroom, when a sensor has actually reported: temperature · humidity judged for the window of the
//     day, plus the window advice phrase when there is one;
//   · a tap-through to the Sleep screen (which carries the full "Tonight" card under its Rest hero).
//
// ABSENT IS ABSENT: no plan → "—" plus the provider's reason; no room reading → no room row (never an
// invented "probably fine").
//
// OBSERVATION (§2.1 rule 5): no AppModel / LiveState / Repository. The schedule provider publishes only
// its plan and its abstention; the room reading arrives through a de-duplicated publisher into @State.
//
// Cost (§2.1 rule 8): shapes and text; no glow, no gradient edge (decision 19), no blur, no shadow;
// a `TimelineView(.everyMinute)` so "next step" and the room window follow the clock — a periodic minute
// tick, not a frame clock.
//
// Hosting (TODAY): `EveningSleepPanel()` inside Today's NavigationStack (it pushes `TabRoute.sleep`).

struct EveningSleepPanel: View {
    @ObservedObject private var provider = SleepScheduleProvider.shared
    /// The last room reading, fed by `BedroomClimate.shared.$latest.removeDuplicates()` so the scanner's
    /// other publishes (scan state, heard list) never re-render Today.
    @State private var room: ClimateReading?

    init() {}

    var body: some View {
        NavigationLink(value: TabRoute.sleep) {
            TimelineView(.everyMinute) { timeline in
                panel(now: timeline.date)
            }
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityHint(Text("Opens Sleep"))
        .onReceive(BedroomClimate.shared.$latest.removeDuplicates()) { room = $0 }
    }

    private func panel(now: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: TelosSpace.s) {
            TonightCardContent(provider: provider, now: now, compact: true, navigates: true)
            if let room {
                Rectangle()
                    .fill(TelosColor.lineSoft)
                    .frame(height: TelosStroke.hair)
                    .accessibilityHidden(true)
                EveningRoomRow(reading: room, now: now)
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The plain faux-glass card (decision 19: no violet glow behind it, no luminous gradient edge).
        .background(FrostedCardSurface(tint: TelosColor.violet, cornerRadius: TelosRadius.card))
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// The bedroom now, judged for the window the evening is in, plus the window advice when there is any.
/// Only drawn for a real reading.
private struct EveningRoomRow: View {
    let reading: ClimateReading
    let now: Date

    var body: some View {
        let context = RoomClimatePlan.context(for: reading, now: now)
        let advice = WindowAdvicePlan.advice(for: reading, now: now)
        let ink: Color = context.isGood ? TelosColor.restInk : TelosColor.warning
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                Image(systemName: "thermometer.medium")
                    .font(TelosType.footnote)
                    .foregroundStyle(ink)
                    .accessibilityHidden(true)
                Text(verbatim: String(format: "%.1f °C · %.0f %%", reading.temperatureC, reading.humidityPct))
                    .font(TelosType.numeralXS)
                    .foregroundStyle(TelosColor.textPrimary)
                Text(verbatim: context.hint)
                    .font(TelosType.footnote)
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let phrase = advice.chipPhrase(now: now) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "wind")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: phrase)
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.accent)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
