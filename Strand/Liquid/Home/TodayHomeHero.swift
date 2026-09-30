import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics

// TodayHomeHero.swift — the Telos hero at the top of Today, 1:1 with docs/design-ref/telos-v2-today.jpg,
// adapted to the app's real data (DESIGN_V2 VISUAL DIRECTION + decision 18).
//
// Pieces, top to bottom (the header row and the trio / strip / mission live in LiquidTodayView,
// TodayTrioHeroView and StateTileViews):
//   • `HomeLevelOrbRow`       — LEVEL block · the life orb · today's quest-progress ring.
//   • `HomeContextPillRow`    — "☼ Today · date | temperature | humidity".
//   • `HomeWindowAdvicePill`  — the glowing window-advice pill with dotted light trails.
//   • `HomeVitalsStrip`       — the glass strip of three compact metrics.
//
// NARROW OBSERVATION (§2.1 rule 5). Each leaf observes only the store it draws: the Level row the
// `LevelBarModel` (publishes a few times a day), the ring the `QuestStore`, the pills only the room
// reading (`BedroomClimate.$latest`, de-duplicated).
// Nothing here observes AppModel, LiveState or Repository — the slow per-day figures come in as values.
//
// COST (§2.1 rule 8): ONE frame clock on the whole screen — the orb's, `.whileVisible` (owner direction),
// ≤ 30 fps, paused offscreen / under a sheet / Reduce Motion / Low Power, and absent entirely for the
// neutral orb. Everything else is static shapes; rings animate only when their value changes. The window
// pill re-evaluates once a minute (a `.periodic` label clock, not a frame clock). No material, no blur, one
// small shadow on the active pill.

// MARK: - The orb's per-day feed

/// The slow, per-day figures the orb reads besides the Level. Built by Today from values it already holds.
/// Every field optional: a missing one rests that channel at its calm neutral (`TelosOrbAppearance`).
struct HomeOrbFeed: Equatable {
    /// Daily stress, 0–3.
    var stress: Double?
    /// Resting heart rate (a slow signal — never the 1 Hz stream).
    var restingHeartRate: Double?
    /// Today's Charge, only when it was MEASURED today (never a carried figure).
    var chargeToday: Double?
    /// Today's Effort ÷ today's target, unbounded.
    var effortRatio: Double?
}

// MARK: - Level · orb · progress ring

struct HomeLevelOrbRow: View {
    let feed: HomeOrbFeed
    /// The store the Level loads from (not observed — the refresh tick below is the trigger).
    let repo: Repository
    let refreshTick: Int
    let onOpenLevel: () -> Void

    @ObservedObject private var levelBar = LevelBarModel.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let orbSide: CGFloat = 214
    private static let ringSide: CGFloat = 100

    var body: some View {
        let trend = levelBar.trend
        let breakdown = trend?.now
        let pending = trend?.pendingToday == true
        let confidence = HomeHeroMapping.levelConfidence(pendingToday: pending, coverage: breakdown?.coverage)
        let inputs = TelosOrbInputs(
            level: breakdown?.level,
            partShares: breakdown.map { HomeHeroMapping.partShares($0.components) } ?? [:],
            stress: feed.stress,
            heartRateBpm: feed.restingHeartRate,
            charge: feed.chargeToday,
            effortRatio: feed.effortRatio,
            confidence: confidence)
        let block = HomeLevelBlock(breakdown: breakdown,
                                   yesterday: trend?.yesterdayLevel,
                                   pending: pending,
                                   onOpen: onOpenLevel)
        Group {
            if typeSize.isAccessibilitySize {
                // Large text: the orb on its own line, the Level and the ring beneath — no overlap.
                VStack(alignment: .leading, spacing: TelosSpace.m) {
                    orb(inputs).frame(height: Self.orbSide * 0.8).frame(maxWidth: .infinity)
                    block
                    HomeQuestProgressRing(diameter: Self.ringSide)
                }
            } else {
                ZStack {
                    orb(inputs).frame(width: Self.orbSide, height: Self.orbSide)
                    HStack(alignment: .center, spacing: 0) {
                        block
                        Spacer(minLength: 0)
                        HomeQuestProgressRing(diameter: Self.ringSide)
                    }
                }
                .frame(height: Self.orbSide)
            }
        }
        // Deduplicated by the tick inside the model: the shell asks for the same tick, so this is a no-op
        // on iOS and the only trigger on a host (macOS) whose shell never asks.
        .task(id: refreshTick) { await levelBar.refresh(repo: repo, tick: refreshTick) }
    }

    /// Cost: TelosOrb — one async Canvas, ≤ 30 fps only while visible (see the file header).
    private func orb(_ inputs: TelosOrbInputs) -> some View {
        // The glow the orb sits in: one pre-composited radial gradient, no blur. Brighter with today's
        // Charge (0.10 → 0.30), the dim floor without one.
        let glow: Double = inputs.charge.map { (c: Double) -> Double in
            let clamped: Double = min(max(c, 0), 100)
            return 0.10 + 0.20 * clamped / 100
        } ?? 0.10
        return ZStack {
            TelosRadialGlow(color: TelosColor.glow, intensity: glow, radius: Self.orbSide * 0.62)
            TelosOrb(inputs: inputs, tint: .green, style: .hero, clock: .whileVisible)
        }
    }
}

/// LEVEL · the big number · the tier word · ↑ +N pts · the step multiplier.
private struct HomeLevelBlock: View {
    let breakdown: LevelBreakdown?
    let yesterday: Double?
    let pending: Bool
    let onOpen: () -> Void

    var body: some View {
        let level = breakdown?.level
        let tier = HomeHeroMapping.tier(level: level)
        let delta = HomeHeroMapping.levelDelta(now: level, yesterday: yesterday)
        Button {
            TelosHaptics.play(.select)
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                Text("Level")
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                if let level {
                    // UNBOUNDED: printed as it is, never clamped. The stand-in day (today's not written yet)
                    // is dimmed like the level strip dims it, and says why below.
                    Text(verbatim: TelosFormat.integer(level))
                        .telosNumeral(.hero)
                        .foregroundStyle(pending ? TelosColor.textSecondary : TelosColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Text(verbatim: TelosType.absent)
                        .telosNumeral(.hero)
                        .foregroundStyle(TelosColor.textTertiary)
                    Text("Not enough data yet")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tier {
                    Text(tier.label)
                        .font(TelosType.scale)
                        .tracking(TelosType.Tracking.scale)
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.mint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let delta {
                    deltaRow(delta)
                }
                if let breakdown {
                    // The step multiplier the Level was taken with — the reference's "◇ × 1.00", named
                    // honestly by its glyph: the one factor that scales the whole figure.
                    HStack(spacing: TelosSpace.xs) {
                        Image(systemName: "shoeprints.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbatim: String(format: "×%.2f", breakdown.stepPenalty))
                            .font(TelosType.numeralXS)
                    }
                    .foregroundStyle(breakdown.stepPenalty < 0.995 ? TelosColor.warning : TelosColor.textSecondary)
                }
                if pending {
                    Text("Waiting for today's night")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 124, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText(level: level, tier: tier, delta: delta)))
        .accessibilityHint(Text("Opens the level timeline"))
    }

    private func deltaRow(_ delta: Double) -> some View {
        let flat = abs(delta) < 0.5
        let tint: Color = flat ? TelosColor.textTertiary : (delta > 0 ? TelosColor.positive : TelosColor.critical)
        return HStack(spacing: TelosSpace.xs) {
            if !flat {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    .font(TelosType.glyphDelta)
            }
            Text(verbatim: HomeHeroMapping.deltaText(delta))
                .font(TelosType.numeralXS)
        }
        .foregroundStyle(tint)
    }

    private func accessibilityText(level: Double?, tier: HomeHeroMapping.Tier?, delta: Double?) -> String {
        guard let level else { return String(localized: "Level, no data yet") }
        var parts = [String(localized: "Level \(TelosFormat.integer(level))")]
        if let tier { parts.append(tier.label) }
        if let delta { parts.append(String(localized: "\(HomeHeroMapping.deltaText(delta)) since yesterday")) }
        if pending { parts.append(String(localized: "Waiting for today's night")) }
        return parts.joined(separator: ", ")
    }
}

/// The reference's "87 % OPTIMAL" ring, bound to a real figure: the share of TODAY'S QUESTS the wearer
/// took on that the data has already closed. Labelled for exactly that ("QUESTS", "2 of 3 done"); with
/// nothing taken on it shows the honest empty ring, never "0 %".
struct HomeQuestProgressRing: View {
    let diameter: CGFloat
    @ObservedObject private var store = QuestStore.shared

    var body: some View {
        let progress = HomeHeroMapping.questProgress(store.quests, dayKey: DailyMissionStore.dayKey())
        VStack(spacing: TelosSpace.xs) {
            ZStack {
                // Static tick bezel around the thin ring (Canvas, redrawn only when the value changes).
                TelosBezel(value: progress?.percent, range: 0...100, color: TelosColor.mint)
                TelosRing(value: progress?.percent, color: TelosColor.mint, diameter: diameter * 0.78,
                          unit: "%", caption: Text("Quests"),
                          accessibilityLabel: Text("Today's quests"))
            }
            .frame(width: diameter, height: diameter)
            Group {
                if let progress {
                    Text("\(progress.done) of \(progress.total) done")
                } else {
                    Text("None taken on yet")
                }
            }
            .font(TelosType.caption)
            .foregroundStyle(TelosColor.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(width: diameter)
    }
}

// MARK: - The pill row

/// "☼ Today · Tue, Sep 29 | 22.0° | 50 %". The day segment is the day picker (the old title's job). The
/// temperature and humidity are the ROOM's when a sensor is set up; without one the temperature is the
/// outdoor forecast's (its own glyph says so) and the humidity is "—" — the app has no other humidity.
struct HomeContextPillRow: View {
    let dayTitle: String
    let dateText: String
    let weather: WeatherNow?
    let onPickDay: () -> Void

    /// The last room reading, through a de-duplicated publisher: the sensor's other publishes (scan state,
    /// the heard list) never re-render this row.
    @State private var room: ClimateReading?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPickDay) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "sun.max")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(TelosColor.amber)
                    Text(verbatim: dayTitle)
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.mint)
                        .lineLimit(1)
                    Text(verbatim: dateText)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(minHeight: TelosSpace.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(dayTitle), \(dateText). Tap to pick a day."))
            Spacer(minLength: TelosSpace.s)
            divider
            temperature
                .padding(.horizontal, TelosSpace.m)
            divider
            humidity
                .padding(.leading, TelosSpace.m)
        }
        .padding(.horizontal, TelosSpace.l)
        .frame(maxWidth: .infinity)
        .background(NoopPanelSurface(cornerRadius: 24))
        .onReceive(BedroomClimate.shared.$latest.removeDuplicates()) { room = $0 }
    }

    private var divider: some View {
        Rectangle().fill(TelosColor.line).frame(width: TelosStroke.line, height: 20)
    }

    @ViewBuilder
    private var temperature: some View {
        if let r = room {
            segment(glyph: "thermometer.medium", tint: TelosColor.amber, text: String(format: "%.1f°", r.temperatureC))
                .accessibilityLabel(Text(String(format: String(localized: "Room %.1f degrees"), r.temperatureC)))
        } else if let w = weather {
            segment(glyph: w.symbol, tint: TelosColor.amber, text: "\(Int(w.temperatureC.rounded()))°")
                .accessibilityLabel(Text("Outside \(Int(w.temperatureC.rounded())) degrees"))
        } else {
            segment(glyph: "thermometer.medium", tint: TelosColor.textTertiary, text: TelosType.absent)
                .accessibilityLabel(Text("Temperature, no reading"))
        }
    }

    @ViewBuilder
    private var humidity: some View {
        if let r = room {
            segment(glyph: "humidity.fill", tint: TelosColor.amber, text: String(format: "%.0f%%", r.humidityPct))
                .accessibilityLabel(Text(String(format: String(localized: "Room humidity %.0f percent"), r.humidityPct)))
        } else {
            segment(glyph: "humidity", tint: TelosColor.textTertiary, text: TelosType.absent)
                .accessibilityLabel(Text("Humidity, no room sensor"))
        }
    }

    private func segment(glyph: String, tint: Color, text: String) -> some View {
        HStack(spacing: TelosSpace.xs) {
            Image(systemName: glyph)
                .font(TelosType.glyphRow)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(TelosType.numeralS)
                .foregroundStyle(TelosColor.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
    }
}

// MARK: - The window-advice pill

/// "Open now · shut 10:35 ›" — the room's window advice (`WindowAdvicePlan`, the same advice the old room
/// chip carried), as the reference's glowing pill with dotted light trails. It glows only when there is
/// something to do; otherwise it is a quiet pill that says so. Tap → the room screen. Without a sensor it
/// is a quiet "Set up a room sensor" pill that opens the sensor setup.
struct HomeWindowAdvicePill: View {
    let onSetUp: () -> Void

    /// The last room reading, de-duplicated (see `HomeContextPillRow`).
    @State private var room: ClimateReading?
    @State private var showRoom = false

    var body: some View {
        HStack(spacing: TelosSpace.s) {
            HomeDottedTrail(leading: true)
            // Read, not observed: it changes only in the sensor setup, and a reading follows it.
            if BedroomClimate.shared.isConfigured {
                Button { showRoom = true } label: {
                    // Once a minute: the advice counts down and flips at its boundary without a new reading.
                    // A `.periodic` label clock, not a frame clock.
                    TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                        face(now: timeline.date)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showRoom) { BedroomHistoryView() }
            } else {
                Button(action: onSetUp) {
                    pill(text: String(localized: "Set up a room sensor"), active: false)
                }
                .buttonStyle(.plain)
            }
            HomeDottedTrail(leading: false)
        }
        .onReceive(BedroomClimate.shared.$latest.removeDuplicates()) { room = $0 }
    }

    private func face(now: Date) -> some View {
        let advice = WindowAdvicePlan.advice(for: room, now: now)
        let phrase = advice.chipPhrase(now: now)
        return pill(text: phrase ?? String(localized: "No window action now"), active: phrase != nil)
            .accessibilityLabel(Text(advice.actionLine(now: now)))
            .accessibilityHint(Text("Opens the room screen"))
    }

    private func pill(text: String, active: Bool) -> some View {
        HStack(spacing: TelosSpace.s) {
            Image(systemName: "wind")
                .font(TelosType.glyphRow)
            Text(verbatim: text)
                .font(TelosType.subhead.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: TelosSpace.s)
            Image(systemName: "chevron.right")
                .font(TelosType.glyphChevron)
        }
        .foregroundStyle(active ? TelosColor.mint : TelosColor.textSecondary)
        .frame(maxWidth: .infinity)
        // Cost: the active pill carries ONE small shadow (a static capsule, never in a list).
        .telosGlowingPill(TelosColor.mint, isActive: active)
    }
}

/// The dotted light trail either side of the window pill: static dots fading toward the pill.
private struct HomeDottedTrail: View {
    let leading: Bool

    var body: some View {
        HomeTrailLine()
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
            .foregroundStyle(LinearGradient(colors: [TelosColor.mint.opacity(0), TelosColor.mint.opacity(0.7)],
                                            startPoint: leading ? .leading : .trailing,
                                            endPoint: leading ? .trailing : .leading))
            .frame(width: 22, height: 2)
            .accessibilityHidden(true)
    }
}

private struct HomeTrailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - The compact metric strip

/// One of the strip's three compact metrics.
struct HomeStripItem: Identifiable {
    let id: String
    let label: String
    /// The formatted value, or `TelosType.absent`.
    let value: String
    /// A second short line under the value (the UV peak), optional.
    var detail: String? = nil
    let glyph: String
    let tint: Color
    /// Where a tap goes; nil = not a link.
    var route: TabRoute? = nil
}

/// The glass strip of three compact metrics (skin temperature · HRV · UV index). Absent values read "—".
struct HomeVitalsStrip: View {
    let items: [HomeStripItem]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TelosSpace.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 0))
        layout {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 && !typeSize.isAccessibilitySize {
                    Rectangle().fill(TelosColor.line).frame(width: TelosStroke.line, height: 30)
                }
                cell(item)
            }
        }
        .padding(.vertical, TelosSpace.m)
        .padding(.horizontal, TelosSpace.s)
        .frame(maxWidth: .infinity)
        .background(NoopPanelSurface(cornerRadius: TelosRadius.card))
    }

    @ViewBuilder
    private func cell(_ item: HomeStripItem) -> some View {
        if let route = item.route {
            NavigationLink(value: route) { cellBody(item) }
                .buttonStyle(.plain)
        } else {
            cellBody(item)
        }
    }

    private func cellBody(_ item: HomeStripItem) -> some View {
        HStack(spacing: TelosSpace.s) {
            Image(systemName: item.glyph)
                .font(TelosType.glyphField)
                .foregroundStyle(item.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.label)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: item.value)
                    .font(TelosType.numeralS)
                    .foregroundStyle(item.value == TelosType.absent ? TelosColor.textTertiary : TelosColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail = item.detail {
                    Text(verbatim: detail)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TelosSpace.s)
        .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
