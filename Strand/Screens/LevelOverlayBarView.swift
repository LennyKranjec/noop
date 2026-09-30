import SwiftUI
import StrandAnalytics
import StrandDesign

// LevelOverlayBarView.swift — the level, above every screen.
//
// SwiftUI twin of the Android `LevelOverlayBar`. One strip under the status bar, on every destination.
//
// THREE THINGS, IN THE ORDER THEY ARE READ. The RADAR sits in the middle because the level is the thing
// and its five parts are why it is what it is; the TREND sits left because "68, and up 4 since Monday"
// is the sentence; the LEVERS sit right because they are what to do about it.
//
// THE TREND SAYS HOW MANY POINTS, and says nothing when nothing moved. An arrow alone answers "better
// or worse" and leaves "by how much" to the imagination; a "0" beside a flat dash fills the row with
// the news that there is no news. An unmoved span keeps its place and shows a dash, so "unchanged" and
// "not computed" stay distinguishable.
//
// A LEVER NAMES ITS METRIC, not its part. A heart glyph could be asking for sleep, for caffeine or for
// an easier week; "rhr" under it says which figure is actually short.
//
// THE RADAR HANGS BELOW THE STRIP. Two thirds of it sit inside the bar and a third overhangs the screen
// under it, which is why this is an OVERLAY on the tab shell rather than a toolbar: a bar that clipped
// its own content would cut the plate in half.

/// The strip's own height, without the status-bar inset it sits under.
///
/// 46, not 52. Once the strip stopped hiding under the status bar it sat noticeably low, and six points
/// is the difference between the chips reading as part of the chrome and as a band floating under it.
let levelBarHeight: CGFloat = 46

/// The radar's full diameter. Two thirds of it live in the bar; the rest overhangs.
let levelRadarDiameter: CGFloat = 86

/// How far the radar sits below the top of the strip. NEGATIVE: it is lifted INTO the strip.
///
/// The drop used to be clearance for the notch, and once the strip itself was inset below the safe area
/// any of it pushed the pentagon down a second time. At zero it still hung further into the screen than
/// it needed to — the plate reads as part of the bar when its top edge is level with the bar's own, not
/// when it starts where the bar starts. -9 is as far as it goes before the pentagon's point starts to
/// crop against the strip's own top edge.
let levelRadarDrop: CGFloat = -9

/// How much of the radar hangs below the strip, and therefore how far content must clear it.
var levelRadarOverhang: CGFloat { levelRadarDiameter / 3 + levelRadarDrop }

/// How many levers fit. Two: a third glyph makes the row a toolbar and nobody acts on three.
let levelLeverCount = 2

/// TELOS 2.0 (§6.1): the strip's text is the V2 type at 11 pt minimum — deltas `numeralXS` + the label voice,
/// the step multiplier `scaleNumber`, levers the label voice in each part's identity colour. The strip is a
/// FIXED 46 pt band of chrome, so its text is capped at the Large size (as the tab bar's is); from
/// `.accessibility1` the strip shows only the radar and its number, and the trends and levers move into the
/// level sheet's header (`LevelTimelineSheetView`), where there is room for them to grow.
let levelStripTextCap: DynamicTypeSize = .large

struct LevelOverlayBarView: View {
    let trend: LevelTrendSnapshot?
    /// Flipped once per launch by the shell, so the count-up runs on opening and not on every tab change.
    let countUpKey: Int
    let onOpenTimeline: () -> Void
    /// Stress at rest right now, when it is high enough to warn about; nil otherwise.
    var stressAlert: Double? = nil
    /// Tapping the warning: somewhere to bring it down — the breathing exercise.
    var onStressAlert: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var breakdown: LevelBreakdown? { trend?.now }

    /// At the accessibility sizes the clusters leave the strip (they move into the level sheet's header).
    private var compact: Bool { dynamicTypeSize >= .accessibility1 }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if !compact {
                    trendCluster
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                // Only the radar's WIDTH is reserved here, so the two clusters never slide under it.
                Color.clear.frame(width: levelRadarDiameter, height: 1)
                if !compact {
                    leverCluster
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .dynamicTypeSize(...levelStripTextCap)
            .padding(.horizontal, TelosSpace.pageGutter)
            .frame(maxWidth: .infinity)
            .frame(height: levelBarHeight)
            // THE FILL BLEEDS UP BEHIND THE STATUS BAR, the content does not. That split is the whole
            // fix: the strip reads as part of the chrome with no seam above it, while the trend chips,
            // the levers and the pentagon all start below the clock, the battery and the notch.
            // Opaque `canvas` (§6.1): chrome that content scrolls under is never see-through.
            .background(TelosColor.canvas.ignoresSafeArea(edges: .top))

            LevelRadarView(
                breakdown: breakdown,
                diameter: levelRadarDiameter,
                countUpKey: countUpKey
            )
            .offset(y: levelRadarDrop)
            // Last written day held up while today's night syncs: dimmed, so it does not read as today's.
            .opacity(trend?.pendingToday == true ? 0.55 : 1)
            .contentShape(PentagonShape())
            .onTapGesture {
                guard breakdown != nil else { return }
                TelosHaptics.play(.select, action: "level.strip.open")
                onOpenTimeline()
            }
            .accessibilityAddTraits(breakdown != nil ? .isButton : [])
            .accessibilityHint(breakdown != nil ? Text("Opens the level over time") : Text(verbatim: ""))
            .accessibilityAction {
                guard breakdown != nil else { return }
                onOpenTimeline()
            }
        }
        // THE STRESS WARNING, beside the pentagon in the overhang: red, because it is the one thing on
        // this strip that asks for something now. Tapping it opens a breathing exercise.
        .overlay(alignment: .top) {
            if let stressAlert {
                StressAlertPillView(level: stressAlert, action: onStressAlert)
                    .offset(x: levelRadarDiameter / 2 + 50, y: levelBarHeight - 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: stressAlert == nil)
        // The overhang is drawn OUTSIDE the strip's own height, which is the whole point of it.
        .frame(height: levelBarHeight, alignment: .top)
    }

    /// Where the level sits against its own recent mean: the three days before, then the month before.
    ///
    /// Both, because they answer different questions — three days is "did last night help", a month is
    /// "am I actually getting anywhere". A single figure would hide whichever one the wearer needed.
    private var trendCluster: some View {
        LevelTrendCluster(trend: trend)
    }

    /// What would move the level most: the glyph, and the metric's own short name.
    ///
    /// Ranked by what they are WORTH, not by which score is lowest — a lungs score of 20 looks worse
    /// than a sleep score of 60 and is worth a third as much level.
    private var leverCluster: some View {
        LevelLeverCluster(trend: trend, alignment: .trailing)
    }
}

/// The trend chips (three-day and month means) and the step multiplier — the strip's left cluster, reused in
/// the level sheet's header at the accessibility sizes.
struct LevelTrendCluster: View {
    let trend: LevelTrendSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeltaChipView(delta: trend?.deltaThreeDays, span: "Ø3d")
            DeltaChipView(delta: trend?.deltaMonth, span: "Ø1mo")
            if let breakdown = trend?.now {
                StepMultiplierChipView(multiplier: breakdown.stepPenalty)
            }
        }
    }
}

/// What would move the level most — the strip's right cluster, reused in the level sheet's header at the
/// accessibility sizes.
///
/// MEDITATION IS NEVER A CONTRIBUTOR (coordinator decision 10): it only ever deducts, so a lever never names
/// it; a focus lever whose driver is meditation names its part instead.
struct LevelLeverCluster: View {
    let trend: LevelTrendSnapshot?
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        let levers = Array((trend?.now?.levers() ?? []).prefix(levelLeverCount))
        let top = levers.first?.headroom ?? 0
        return VStack(alignment: alignment, spacing: 1) {
            ForEach(Array(levers.enumerated()), id: \.offset) { _, lever in
                let share = top > 0 ? lever.headroom / top : 0
                let driver = trend?.drivers[lever.part]
                LeverRowView(
                    part: lever.part,
                    driver: driver == .meditation ? nil : driver,
                    share: share
                )
            }
        }
    }
}

/// One arrow, the points behind it, and the span it covers.
private struct DeltaChipView: View {
    let delta: Double?
    let span: LocalizedStringKey

    var body: some View {
        // A change under half a point is noise on a 0–100 scale, and so is one that rounds away to
        // nothing; both are shown as flat rather than as a number the wearer would read meaning into.
        // §5.5: "no delta computed" is an em dash, "unchanged" is ±0 — the two must stay distinguishable.
        let points = delta.map { Int($0.rounded()) } ?? 0
        let absent = delta == nil
        let flat = absent || abs(delta ?? 0) < 0.5 || points == 0
        let up = (delta ?? 0) > 0
        let tint: Color = flat
            ? TelosColor.textTertiary
            : (up ? TelosColor.positive : TelosColor.critical)
        let figure: String = absent ? TelosType.absent
            : (flat ? "\u{00B1}0" : (points > 0 ? "+\(points)" : TelosType.minus + "\(abs(points))"))

        return HStack(spacing: TelosSpace.xxs) {
            // NO ARROW WHEN THERE IS NOTHING TO POINT AT.
            if !flat {
                Image(systemName: up ? "arrow.up" : "arrow.down")
                    .font(TelosType.glyphDelta)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(verbatim: figure)
                .font(TelosType.numeralXS)
                .foregroundStyle(tint)
            Text(span)
                .telosScale()
                .foregroundStyle(TelosColor.textTertiary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The step multiplier the level was taken with: the one factor that scales the whole figure rather
/// than one part of it.
///
/// ALWAYS SHOWN, not only when it bites. At ×1.00 it says the steps are covered and costing nothing;
/// the moment the week's average drops under the floor it turns amber and says by how much — which is
/// the one lever on the level that a walk after dinner moves by tomorrow morning.
/// "Stress 2.4" in red, with a warning glyph. A button: it leads to the breathing exercise.
private struct StressAlertPillView: View {
    let level: Double
    let action: () -> Void

    var body: some View {
        // §6.1: a WORD ("Stress high"), not a decimal — the band from the same cut-points as the stress
        // screen. `critical` fill, white ink, the `raised` elevation (one shadow), a 44 pt hit area.
        let word = LiveStressMonitor.bandWord(level).lowercased()
        return Button {
            TelosHaptics.play(.tap, action: "level.strip.stress")
            action()
        } label: {
            HStack(spacing: TelosSpace.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Stress \(word)")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "wind")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(TelosColor.onDarkPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(TelosColor.critical, in: Capsule())
            .telosElevation(.raised)
            .frame(minHeight: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text("Stress is \(word) at rest. Opens a breathing exercise."))
    }
}

private struct StepMultiplierChipView: View {
    let multiplier: Double

    var body: some View {
        let biting = multiplier < 0.995
        let tint = biting ? TelosColor.warning : TelosColor.textTertiary
        return HStack(spacing: TelosSpace.xxs) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(String(format: "×%.2f", multiplier))
                .font(TelosType.scaleNumber)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(biting
            ? "Steps multiply the level by \(String(format: "%.2f", multiplier))"
            : "Steps cost the level nothing"))
    }
}

private struct LeverRowView: View {
    let part: LevelPart
    let driver: LevelDriver?
    let share: Double

    var body: some View {
        // Opacity carries the relative impact. Size would too, but a row this short cannot afford the
        // layout shift when the ranking changes between renders.
        let alpha = 0.45 + 0.55 * min(max(share, 0), 1)
        let tint = levelPartTint(part).opacity(alpha)
        return HStack(spacing: TelosSpace.xs) {
            Image(systemName: levelPartSymbol(part))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            // The glyph carries the part, so the word only has to carry the metric — which is what lets
            // "consistency" stand next to a moon without also saying "sleep". The label voice (§6.1).
            Text(driver.map { levelDriverLabel($0) } ?? LocalizedStringKey(part.rawValue))
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// The level now and at two earlier points, plus which metric is behind each part today.
///
/// A view-layer mirror of the Android `LevelTrend`: the repository half that assembles it reads the
/// store, which is the app's job rather than the analytics package's.
struct LevelTrendSnapshot {
    let now: LevelBreakdown?
    let threeDaysAgo: LevelBreakdown?
    let monthAgo: LevelBreakdown?
    /// The mean level over the three days before the one shown, and over the thirty before it.
    ///
    /// THE CHIPS COMPARE AGAINST THESE, not against a single day. One day three days back is one night's
    /// sleep and one day's training; a bad night there made today read as a gain it was not. The mean
    /// asks the question the wearer meant — am I above or below where I have been sitting.
    let threeDayMean: Double?
    let monthMean: Double?
    /// Yesterday's level, for the morning brief's arrow.
    let yesterdayLevel: Double?
    let drivers: [LevelPart: LevelDriver]
    /// What is shown is not today's level: the current day is not in the ledger yet (its night is still
    /// syncing, or was never recorded), or this morning's flow has not run and the current day is still
    /// yesterday. `now` is then the stand-in written day — one day, picked once for this level day and
    /// held until the level day's own entry lands (`LevelDayFreeze.standIn`), so the figure does not move
    /// while it waits. Nothing should present it as today's.
    let pendingToday: Bool

    init(
        now: LevelBreakdown?,
        threeDaysAgo: LevelBreakdown?,
        monthAgo: LevelBreakdown?,
        threeDayMean: Double? = nil,
        monthMean: Double? = nil,
        yesterdayLevel: Double? = nil,
        drivers: [LevelPart: LevelDriver] = [:],
        pendingToday: Bool = false
    ) {
        self.pendingToday = pendingToday
        self.yesterdayLevel = yesterdayLevel
        self.now = now
        self.threeDaysAgo = threeDaysAgo
        self.monthAgo = monthAgo
        self.threeDayMean = threeDayMean
        self.monthMean = monthMean
        self.drivers = drivers
    }

    /// Points above or below the three-day mean, or nil when too few of those days could be scored.
    var deltaThreeDays: Double? { delta(threeDayMean) }

    /// Points above or below the month's mean, or nil when too few of those days could be scored.
    var deltaMonth: Double? { delta(monthMean) }

    private func delta(_ mean: Double?) -> Double? {
        guard let a = now?.level, let b = mean else { return nil }
        return a - b
    }
}
