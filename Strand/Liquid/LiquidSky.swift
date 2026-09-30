//  LiquidSky.swift
//  NOOP · Liquid design language → Telos 2.0 (INS)
//
//  The time-of-day ground behind the header: in Telos 2.0 the DARK BIOLUMINESCENT background of the
//  reference — a near-black gradient with a whisper of green-teal, a faint green-teal vignette glow at
//  the top, and a faint dotted depth field (deterministic seeded dots whose size and opacity follow
//  their depth), with brighter stars at night (dark scheme only, ≤ 0.35 opacity). The hour tints the
//  keyframes subtly (deeper at night, a faint teal horizon by day, a warmer dusk).
//
//  STATIC (§7.4 "backgrounds and the sky never animate"): one Canvas, drawn once; when it follows the
//  live hour it re-evaluates every 900 s through a periodic TimelineView (a label-tick clock, not a
//  per-frame loop). `LiquidSky` is a thin wrapper over `LiquidSkyStatic`. The bottom settles into the
//  `TelosColor.canvas` token (resolved by the Canvas for the current scheme — no literal RGB copies).

import SwiftUI
import StrandDesign

struct LiquidSkyStop {
    let h: Double
    let top: Color, mid: Color, hor: Color
    let stars: Double, warm: Double
}

private func hx(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255, opacity: 1)
}

/// Dark keyframes: the bioluminescent ground (#05090A → #0B1214 family), tinted by the hour.
/// `stars` scales the brighter night stars (the faint depth field is always there in dark).
let liquidSkyKeys: [LiquidSkyStop] = [
    .init(h: 0,    top: hx(0x030608), mid: hx(0x05090B), hor: hx(0x07100F), stars: 1.00, warm: 0),
    .init(h: 5.5,  top: hx(0x04070A), mid: hx(0x070B0F), hor: hx(0x0A1214), stars: 0.55, warm: 0),
    .init(h: 7,    top: hx(0x05090B), mid: hx(0x081012), hor: hx(0x0D1A18), stars: 0,    warm: 0.25),
    .init(h: 12,   top: hx(0x05090A), mid: hx(0x0A1213), hor: hx(0x0E1B1A), stars: 0,    warm: 0),
    .init(h: 18.5, top: hx(0x06080B), mid: hx(0x0A0F12), hor: hx(0x10161A), stars: 0,    warm: 0.35),
    .init(h: 21,   top: hx(0x04070A), mid: hx(0x06090C), hor: hx(0x081010), stars: 0.70, warm: 0),
    .init(h: 24,   top: hx(0x030608), mid: hx(0x05090B), hor: hx(0x07100F), stars: 1.00, warm: 0),
]

/// Light keyframes: the pale green-grey Telos ground, the same hour movement. No stars in light.
private let liquidLightSkyKeys: [LiquidSkyStop] = [
    .init(h: 0,    top: hx(0xDDE6E3), mid: hx(0xE6EDEA), hor: hx(0xEEF3F1), stars: 0, warm: 0),
    .init(h: 5.5,  top: hx(0xE0E6E6), mid: hx(0xE9EDEC), hor: hx(0xF1F2EF), stars: 0, warm: 0),
    .init(h: 7,    top: hx(0xE4E9E6), mid: hx(0xECF0EE), hor: hx(0xF3F4F1), stars: 0, warm: 0.25),
    .init(h: 12,   top: hx(0xE3ECE9), mid: hx(0xEBF1EF), hor: hx(0xF1F5F3), stars: 0, warm: 0),
    .init(h: 18.5, top: hx(0xE6E6E6), mid: hx(0xEDEDEB), hor: hx(0xF3F2EF), stars: 0, warm: 0.35),
    .init(h: 21,   top: hx(0xDDE5E3), mid: hx(0xE6ECEA), hor: hx(0xEEF3F1), stars: 0, warm: 0),
    .init(h: 24,   top: hx(0xDDE6E3), mid: hx(0xE6EDEA), hor: hx(0xEEF3F1), stars: 0, warm: 0),
]

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let x = a.liquidComponents(), y = b.liquidComponents()
    return Color(.sRGB, red: lerp(x.r, y.r, t), green: lerp(x.g, y.g, t), blue: lerp(x.b, y.b, t), opacity: 1)
}

func liquidSkyAt(_ hour: Double, light: Bool = false) -> (top: Color, mid: Color, hor: Color, stars: Double, warm: Double) {
    let keys = light ? liquidLightSkyKeys : liquidSkyKeys
    let hh = hour.isFinite ? min(max(hour, 0), 24) : 0
    var i = 0
    while i < keys.count - 2 && keys[i + 1].h <= hh { i += 1 }
    let a = keys[i], b = keys[i + 1]
    let t = max(0, min(1, (hh - a.h) / (b.h - a.h)))
    return (lerpColor(a.top, b.top, t), lerpColor(a.mid, b.mid, t), lerpColor(a.hor, b.hor, t),
            lerp(a.stars, b.stars, t), lerp(a.warm, b.warm, t))
}

/// One dot of the depth field: unit position, depth 0 (far) … 1 (near), and whether it is a brighter
/// night star.
private struct LiquidSkyDot { let x, y, z: Double; let star: Bool }

/// The deterministic dotted depth field (SplitMix64, fixed seed): the same dots on every launch, so the
/// static frame never shimmers between renders.
private let liquidSkyDots: [LiquidSkyDot] = {
    var state: UInt64 = 0x7E1_05_5C1
    func next() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
    return (0..<96).map { _ in
        let x = next(), y = next() * 0.82, z = next(), star = next() < 0.22
        return LiquidSkyDot(x: x, y: y, z: z, star: star)
    }
}()

/// The pale green-white of the depth field and the vignette hue.
private let liquidSkyDotInk = Color(.sRGB, red: 191 / 255, green: 1, blue: 230 / 255, opacity: 1)

/// The one sky renderer (static). Pure drawing into a GraphicsContext.
private func liquidSkyRender(_ base: GraphicsContext, _ size: CGSize, hour: Double, light: Bool,
                             settleStrength: Double) {
    let S = liquidSkyAt(hour, light: light)
    let w = size.width, h = size.height
    guard w > 0, h > 0 else { return }
    var ctx = base
    // The gradient IS the ground.
    ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
             with: .linearGradient(Gradient(stops: [
                .init(color: S.top, location: 0),
                .init(color: S.mid, location: 0.5),
                .init(color: S.hor, location: 0.9)]),
                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
    // The faint green-teal vignette glow at the top (pre-composited radial — no blur).
    let glowCentre = CGPoint(x: w * 0.5, y: h * 0.14)
    let glowRadius = max(w, h) * 0.75
    ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
             with: .radialGradient(Gradient(colors: [TelosColor.glow.opacity(light ? 0.05 : 0.09),
                                                     TelosColor.glow.opacity(light ? 0.015 : 0.03), .clear]),
                                   center: glowCentre, startRadius: 0, endRadius: glowRadius))
    // Dusk / dawn: a whisper of warmth low down.
    if S.warm > 0.01 {
        ctx.fill(Path(CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45)),
                 with: .linearGradient(Gradient(colors: [TelosColor.amber.opacity(0),
                                                         TelosColor.amber.opacity(S.warm * (light ? 0.04 : 0.06))]),
                                       startPoint: CGPoint(x: 0, y: h * 0.55), endPoint: CGPoint(x: 0, y: h)))
    }
    // The dotted depth field (dark only): faint always, brighter stars at night. Two paths, two fills.
    if !light {
        var field = Path()
        var stars = Path()
        for d in liquidSkyDots {
            let sz = 0.5 + d.z * 1.1
            let rect = CGRect(x: d.x * w, y: d.y * h, width: sz, height: sz)
            if d.star && S.stars > 0.05 {
                stars.addEllipse(in: rect.insetBy(dx: -0.3, dy: -0.3))
            } else {
                field.addEllipse(in: rect)
            }
        }
        ctx.fill(field, with: .color(liquidSkyDotInk.opacity(0.12)))
        if S.stars > 0.05 {
            ctx.fill(stars, with: .color(liquidSkyDotInk.opacity(min(0.35, 0.10 + 0.25 * S.stars))))
        }
    }
    // Settle into the page canvas (the token, resolved for the current scheme) — no hard seam.
    ctx.fill(Path(CGRect(x: 0, y: h * 0.45, width: w, height: h * 0.55)),
             with: .linearGradient(Gradient(colors: [TelosColor.canvas.opacity(0),
                                                     TelosColor.canvas.opacity(settleStrength)]),
                                   startPoint: CGPoint(x: 0, y: h * 0.45), endPoint: CGPoint(x: 0, y: h)))
}

private func liquidLiveHour(_ date: Date = Date()) -> Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
}

/// The header sky. Telos 2.0: a thin wrapper over the static renderer — no per-frame clock at all (the
/// old twinkle / breath loop is gone; §7.4). Kept as its own type so existing call sites compile.
struct LiquidSky: View {
    /// Hour of day 0...24. Defaults to live time when nil (re-evaluated every 900 s).
    var hour: Double?
    /// How fully the sky dissolves into the canvas at the bottom (1 = the default seamless fade; <1 holds
    /// the atmosphere so the sky still reads under a full-height "sky behind cards" backdrop).
    var settleStrength: Double = 1

    var body: some View {
        LiquidSkyStatic(hour: hour, settleStrength: settleStrength)
    }
}

/// A subtle full-bleed time-of-day sky for any `ScreenScaffold.topBackground`, so the liquid
/// atmosphere carries across EVERY tab. Same live sky as Today at a modest header height, so the
/// charts/cards below sit on the dark canvas — the redesign's "the options change, not the page"
/// feel. Non-interactive + accessibility-hidden (pure decoration).
///
/// Honours the SAME two Appearance gates as Today and the metric-detail screens, so every scaffold
/// that passes this reads them for free (Trends / Sleep / More / the hub screens previously ignored
/// both — the sky stayed a fixed band there while Today filled the viewport):
/// - "Day-cycle background" OFF renders nothing, leaving the scaffold's plain `surfaceBase` canvas
///   (the same visual as passing no topBackground at all).
/// - "Sky behind cards" ON fills the scaffold's whole backdrop (the ZStack already spans the scroll
///   view; only this frame capped it) with the held-atmosphere settle, so the Card-transparency
///   setting reveals the sky under every card — the LiquidTodayView treatment.
/// A real View (not a one-shot read) so @AppStorage keeps it reactive: toggling either setting
/// updates every mounted tab in place. Mirrors the Android `LiquidScreenSky(fillHeight:)` +
/// `fullBleedBackground` pairing.
struct LiquidScaffoldSky: View {
    var height: CGFloat = 240
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    // The custom-background store (#custom-background). A custom image OVERRIDES the sky and always fills
    // the viewport, so every scaffold that passes `liquidScaffoldSky()` reads the SAME cached image and
    // draws it identically — seamless across tabs including More.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    var body: some View {
        if backgroundStore.isActive {
            BackgroundImageBackdrop()
        } else if showDayCycleBackground {
            LiquidSkyStatic(hour: nil, settleStrength: skyBehindCards ? 0.78 : 1)
                .frame(maxWidth: .infinity, maxHeight: skyBehindCards ? .infinity : nil)
                .frame(height: skyBehindCards ? nil : height, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

func liquidScaffoldSky(height: CGFloat = 240) -> AnyView {
    AnyView(LiquidScaffoldSky(height: height))
}

/// The STATIC sky, rendered once (no per-frame clock → Core Animation caches it as a stable layer).
/// When it follows the live hour (`hour == nil`) a periodic TimelineView re-evaluates it every 900 s —
/// a quarter-hour tick, not an animation.
struct LiquidSkyStatic: View {
    var hour: Double?
    /// See `LiquidSky.settleStrength` — 1 = default seamless fade; <1 holds the atmosphere for the
    /// full-height "sky behind cards" backdrop.
    var settleStrength: Double = 1
    @Environment(\.colorScheme) private var scheme

    /// How often a live-hour sky re-evaluates.
    static let reevaluationInterval: TimeInterval = 900

    var body: some View {
        if let hour {
            canvas(hour: hour)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: Self.reevaluationInterval)) { tl in
                canvas(hour: liquidLiveHour(tl.date))
            }
        }
    }

    private func canvas(hour: Double) -> some View {
        let light = scheme == .light
        let settle = settleStrength
        return Canvas { ctx, size in
            liquidSkyRender(ctx, size, hour: hour, light: light, settleStrength: settle)
        }
    }
}
