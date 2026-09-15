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
let levelBarHeight: CGFloat = 52

/// The radar's full diameter. Two thirds of it live in the bar; the rest overhangs.
let levelRadarDiameter: CGFloat = 86

/// How far the radar sits below the top of the strip — clearance for the notch / Dynamic Island.
let levelRadarDrop: CGFloat = 8

/// How much of the radar hangs below the strip, and therefore how far content must clear it.
var levelRadarOverhang: CGFloat { levelRadarDiameter / 3 + levelRadarDrop }

/// How many levers fit. Two: a third glyph makes the row a toolbar and nobody acts on three.
private let leverCount = 2

struct LevelOverlayBarView: View {
    let trend: LevelTrendSnapshot?
    /// Flipped once per launch by the shell, so the count-up runs on opening and not on every tab change.
    let countUpKey: Int
    let onOpenTimeline: () -> Void

    private var breakdown: LevelBreakdown? { trend?.now }

    var body: some View {
        ZStack(alignment: .top) {
            StrandPalette.surfaceBase
                .frame(height: levelBarHeight)

            HStack(spacing: 0) {
                trendCluster
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Only the radar's WIDTH is reserved here, so the two clusters never slide under it.
                Color.clear.frame(width: levelRadarDiameter, height: 1)
                leverCluster
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: levelBarHeight)

            LevelRadarView(
                breakdown: breakdown,
                diameter: levelRadarDiameter,
                countUpKey: countUpKey
            )
            .padding(.top, levelRadarDrop)
            .contentShape(PentagonShape())
            .onTapGesture {
                guard breakdown != nil else { return }
                StrandHaptic.selection.play()
                onOpenTimeline()
            }
        }
        // The overhang is drawn OUTSIDE the strip's own height, which is the whole point of it.
        .frame(height: levelBarHeight, alignment: .top)
    }

    /// Where the level has come from: three days, then a month.
    ///
    /// Both, because they answer different questions — three days is "did last night help", a month is
    /// "am I actually getting anywhere". A single figure would hide whichever one the wearer needed.
    private var trendCluster: some View {
        VStack(alignment: .leading, spacing: 1) {
            DeltaChipView(delta: trend?.deltaThreeDays, span: "3d")
            DeltaChipView(delta: trend?.deltaMonth, span: "1mo")
        }
    }

    /// What would move the level most: the glyph, and the metric's own short name.
    ///
    /// Ranked by what they are WORTH, not by which score is lowest — a lungs score of 20 looks worse
    /// than a sleep score of 60 and is worth a third as much level.
    private var leverCluster: some View {
        let levers = Array((breakdown?.levers() ?? []).prefix(leverCount))
        let top = levers.first?.headroom ?? 0
        return VStack(alignment: .trailing, spacing: 1) {
            ForEach(Array(levers.enumerated()), id: \.offset) { _, lever in
                let share = top > 0 ? lever.headroom / top : 0
                LeverRowView(
                    part: lever.part,
                    driver: trend?.drivers[lever.part],
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
        let points = delta.map { Int($0.rounded()) } ?? 0
        let flat = delta == nil || abs(delta!) < 0.5 || points == 0
        let tint: Color = flat
            ? StrandPalette.textTertiary
            : (delta! > 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical)

        return HStack(spacing: 2) {
            // NO ARROW WHEN THERE IS NOTHING TO POINT AT. The flat glyph is a dash and the flat label is
            // a dash, and the two side by side read as a rendering fault rather than as "unchanged".
            if !flat {
                Image(systemName: delta! > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(flat ? "–" : (points > 0 ? "+\(points)" : "\(points)"))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(span)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
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
        return HStack(spacing: 3) {
            Image(systemName: levelPartSymbol(part))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            // The glyph carries the part, so the word only has to carry the metric — which is what lets
            // "consistency" stand next to a moon without also saying "sleep".
            Text(driver.map { levelDriverLabel($0) } ?? LocalizedStringKey(part.rawValue))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
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
    let drivers: [LevelPart: LevelDriver]

    init(
        now: LevelBreakdown?,
        threeDaysAgo: LevelBreakdown?,
        monthAgo: LevelBreakdown?,
        drivers: [LevelPart: LevelDriver] = [:]
    ) {
        self.now = now
        self.threeDaysAgo = threeDaysAgo
        self.monthAgo = monthAgo
        self.drivers = drivers
    }

    /// Points gained or lost since three days ago, or nil when that day cannot be scored.
    var deltaThreeDays: Double? { delta(threeDaysAgo) }

    /// Points gained or lost since a month ago, or nil when that day cannot be scored.
    var deltaMonth: Double? { delta(monthAgo) }

    private func delta(_ then: LevelBreakdown?) -> Double? {
        guard let a = now?.level, let b = then?.level else { return nil }
        return a - b
    }
}
