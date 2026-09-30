//  LiveSessionView.swift
//  NOOP · Live Sessions (silent guardian) — the in-session screen + summary sheet.
//
//  Deliberately near-empty: one breathing ring, one line of intent, one honest Charge
//  sentence that fades, an End button. The ring is the whole language — lit teal and
//  breathing in band, dimmed below, hot above, grey when the stream is stale (coaching
//  paused, nothing claimed). NO live HR number by default; a long-press on the ring
//  reveals the engine's smoothed bpm. A thin outer arc fills with time held in band,
//  toward an hour. Every value on screen is the engine's `Output`, verbatim — this
//  file renders, it never decides.
//
//  TELOS 2.0 (DESIGN_V2 §6.7): the live register of the Live Workout screen — plain canvas, the
//  session ring drawn on a `TelosBezel` (240° open dial across [floor−20, ceiling+20] with the
//  band as a teal arc and the caret at the smoothed position) plus a thin luminous position arc,
//  the guidance line in `title2`, and the End control on an OPAQUE `surface` band pinned to the
//  bottom safe area. No material, no blur.
//
//  PERFORMANCE: the screen observes only the runner (≈1 Hz) and the quiet-motion gate. `AppModel`,
//  `Repository` and `ProfileStore` are reached through the non-observing `\.appModelRef` (the
//  model owns the same `repo` / `profile` instances the environment carried) — nothing here needs
//  their other published fields.
//
//  Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

struct LiveSessionView: View {
    /// NOT observed — used for `runner.start` only (see PERFORMANCE above).
    @Environment(\.appModelRef) private var modelRef
    private var model: AppModel { requireAppModel(modelRef) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A sheet (the summary) over this screen pauses the breath.
    @Environment(\.noopBackgroundCovered) private var covered
    /// Low Power Mode / the in-app quiet-motion toggle. The guardian breath never settles, so it
    /// belongs behind the same gate as the liquid surfaces. The Android twin gated
    /// `LiveSessionScreen`'s breath under battery saver in #911.
    @ObservedObject private var motion = NoopMotionState.shared

    /// One runner per presentation — created here, started on appear, never restarted.
    @StateObject private var runner = LiveSessionRunner()
    let onClose: () -> Void

    /// Long-press reveal for the live (smoothed) bpm — off by default, per the contract.
    @State private var showBpm = false
    /// The one Charge sentence: shown for 6 s, then fades and stays gone.
    @State private var chargeLineVisible = true
    /// Caller-owned draw for the position arc: eases to each new smoothed position. HOLDS the last
    /// position while stale — the grey tint says "no reading"; snapping to zero would invent a collapse.
    @State private var ringFraction: Double = 0
    /// The last smoothed bpm the engine produced — the bezel caret HOLDS it while stale (grey), never
    /// guessing a new one. nil until the first reading: no caret at all.
    @State private var heldBpm: Double?
    /// The thin outer "time held in band" arc, filling toward an hour.
    @State private var heldFraction: Double = 0
    /// The slow in-band breathing scale (the only motion on screen).
    @State private var breathe = false
    @State private var showSummary = false
    /// "N sessions guarded" for the summary streak line, read from the store when the session ends.
    @State private var guardedCount: Int?

    private let ringDiameter: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, TelosSpace.xl)
            Spacer(minLength: TelosSpace.l)
            ring
            Text(guardianLine)
                .font(TelosType.title2)
                .foregroundStyle(TelosColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, TelosSpace.xl)
            chargeSentence
                .padding(.top, TelosSpace.m)
            Spacer(minLength: TelosSpace.l)
        }
        .padding(.horizontal, TelosSpace.pageGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // §4.9 role 3: the End control sits on an OPAQUE band in the bottom safe area — reachable
        // one-handed, never over moving content.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NoopButton("End session", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                endSession()
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.top, TelosSpace.m)
            .padding(.bottom, TelosSpace.m)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                TelosColor.surface
                    .overlay(alignment: .top) {
                        Rectangle().fill(TelosColor.line).frame(height: TelosStroke.line)
                    }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(TelosColor.canvas.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
        .onAppear {
            let m = model
            runner.start(model: m, repo: m.repo, ble: m.ble, profile: m.profile)
        }
        // Left without ending (a dismissed sheet on macOS, a shell teardown): end cleanly so the
        // realtime-HR arm is balanced and the row's totals are banked. Guarded — a normal End already set
        // finalRow, so this only catches the escape paths.
        .onDisappear {
            if runner.finalRow == nil { runner.end() }
        }
        // Both end paths (the End tap and the 10-min stale auto-end) land here: load the streak count,
        // then raise the summary.
        .onChangeCompat(of: runner.finalRow) { row in
            guard row != nil else { return }
            loadGuardedCount()
            showSummary = true
        }
        .onChangeCompat(of: runner.output) { out in advance(to: out) }
        .task { await fadeChargeSentenceLater() }
        .sheet(isPresented: $showSummary, onDismiss: { onClose() }) {
            if let row = runner.finalRow {
                LiveSessionSummarySheet(row: row, guardedCount: guardedCount) {
                    showSummary = false   // onDismiss closes the whole session screen
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            Text("SILENT GUARDIAN")
                .telosScale()
                .foregroundStyle(TelosColor.lungsInk)
            HStack(spacing: TelosSpace.s) {
                Text("Live Session")
                    .font(TelosType.title).foregroundStyle(TelosColor.textPrimary)
                TelosTag("BETA")
                    .accessibilityLabel("Beta feature")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ring

    /// The bezel's scale: the engine's band ±20 bpm (the same span the position arc maps over). nil until
    /// a band exists.
    private var bezelRange: ClosedRange<Double>? {
        guard let band = runner.output?.band ?? runner.baseBand else { return nil }
        let lo = band.floorBpm - 20
        let hi = band.ceilingBpm + 20
        return hi > lo ? lo...hi : nil
    }

    /// The whole instrument: a `TelosBezel` across [floor−20, ceiling+20] with the band as a teal arc and
    /// the caret at the held smoothed bpm, a thin luminous arc of the position inside it, and a thin outer
    /// arc of time held in band — tinted by the engine's position, breathing only while in band and
    /// active. Long-press toggles the bpm read-out.
    ///
    /// Cost (§2.1 rule 8): the bezel is one Canvas redrawn only when the reading changes (≈1 Hz); the arcs
    /// are shapes that ease to each new reading and rest; the breath is the one loop (see `setBreathing`).
    private var ring: some View {
        ZStack {
            // The position's bioluminescence: ONE static radial gradient, recoloured on a position change.
            TelosRadialGlow(color: ringTint, intensity: 0.18, radius: ringDiameter * 0.55)
                .frame(width: ringDiameter * 1.2, height: ringDiameter * 1.2)
            // Thin outer arc: time held in band this session, filling toward 60 min. Same 240° open
            // geometry as the dial (start 150°, span 240°) so the two read as one instrument.
            Circle()
                .trim(from: 0, to: heldFraction * (240.0 / 360.0))
                .rotation(.degrees(150))
                .stroke(TelosColor.lungs.opacity(0.55),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: ringDiameter + 26, height: ringDiameter + 26)
            if let range = bezelRange {
                TelosBezel(value: heldBpm,
                           range: range,
                           color: ringTint,
                           majorCount: 4,
                           minorPerMajor: 5,
                           startDegrees: 150,
                           spanDegrees: 240,
                           bands: bandArcs(range: range))
                    .frame(width: ringDiameter, height: ringDiameter)
            } else {
                TelosBezel(value: nil, range: 0...1, startDegrees: 150, spanDegrees: 240)
                    .frame(width: ringDiameter, height: ringDiameter)
            }
            // The luminous position arc (one halo stroke under the core — no blur).
            Circle()
                .trim(from: 0, to: max(0.001, ringFraction) * (240.0 / 360.0))
                .rotation(.degrees(150))
                .telosLuminousStroke(ringTint, lineWidth: 6, haloOpacity: 0.22)
                .frame(width: ringDiameter - 34, height: ringDiameter - 34)
                .opacity(heldBpm == nil ? 0 : 1)
            if showBpm {
                VStack(spacing: TelosSpace.xxs) {
                    Text(verbatim: bpmText)
                        .telosNumeral(.geometryBound(size: 56, cap: 1.2))
                        .foregroundStyle(runner.output?.smoothedBpm == nil ? TelosColor.textTertiary : TelosColor.textPrimary)
                    Text("bpm")
                        .telosScale()
                        .foregroundStyle(TelosColor.textSecondary)
                }
                .transition(.opacity)
            }
        }
        .frame(width: ringDiameter + 30, height: ringDiameter + 30)
        .scaleEffect(breathe ? 1.03 : 1.0)
        .contentShape(Circle())
        .onLongPressGesture {
            TelosHaptics.play(.select)
            withAnimation(TelosMotion.fade) { showBpm.toggle() }
        }
        .onAppear { setBreathing(isBreathing) }
        .onChangeCompat(of: isBreathing) { on in setBreathing(on) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ringAccessibilityLabel))
        .accessibilityHint(Text("Long press to show or hide your heart rate."))
    }

    private func bandArcs(range: ClosedRange<Double>) -> [TelosBezel.Band] {
        guard let band = runner.output?.band ?? runner.baseBand, band.ceilingBpm > band.floorBpm else { return [] }
        return [TelosBezel.Band(range: band.floorBpm...band.ceilingBpm, color: TelosColor.lungs)]
    }

    /// Breathing is the "on track" signal: only in band, only once active, never when anything is
    /// asking for quiet (Reduce Motion, Low Power Mode, or "Reduce motion in NOOP"), and never behind a
    /// sheet.
    private var isBreathing: Bool {
        !motion.poseStill(reduceMotion)
            && !covered
            && runner.output?.status == .active
            && runner.output?.position == .inBand
    }

    /// The guardian breath — the one loop on this screen (§7.3 "LiveSessionView guidance ring"). Gated by
    /// `isBreathing`: `NoopMotionState.poseStill` (Reduce Motion ‖ Low Power ‖ "Reduce motion in NOOP"),
    /// `noopBackgroundCovered`, and the engine's in-band + active state; anything else settles it to rest
    /// in 0.5 s. Cost: one scale transform on the ring, 2.6 s half-cycle.
    private func setBreathing(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        } else {
            withAnimation(.easeOut(duration: 0.5)) { breathe = false }
        }
    }

    /// The engine's smoothed bpm, only when revealed and only when it exists — a stale stream shows a
    /// dash, never a held or guessed number.
    private var bpmText: String {
        guard let s = runner.output?.smoothedBpm else { return TelosType.absent }
        return "\(Int(s.rounded()))"
    }

    private var ringTint: Color {
        guard let out = runner.output, out.smoothedBpm != nil else {
            return TelosColor.textTertiary   // stale / no reading yet: grey, no coaching claims
        }
        switch out.position {
        case .inBand: return TelosColor.lungs                 // lit: on track
        case .below:  return TelosColor.lungs.opacity(0.4)    // dim: too easy for today
        case .above:  return TelosColor.critical              // hot: today can't pay for this
        }
    }

    private var ringAccessibilityLabel: String {
        guard let out = runner.output, out.smoothedBpm != nil else {
            return String(localized: "No live reading. Coaching is paused.")
        }
        switch out.position {
        case .inBand: return String(localized: "In your band. On track.")
        case .below:  return String(localized: "Below your band.")
        case .above:  return String(localized: "Above your band.")
        }
    }

    /// Ease the arc to each new smoothed position across [floor−20, ceiling+20]; hold while stale.
    private func advance(to out: LiveSessionEngine.Output?) {
        guard let out else { return }
        let still = motion.poseStill(reduceMotion)
        if let s = out.smoothedBpm {
            let lo = out.band.floorBpm - 20
            let hi = out.band.ceilingBpm + 20
            heldBpm = s
            if hi > lo {
                let f = min(max((s - lo) / (hi - lo), 0), 1)
                withAnimation(TelosMotion.gated(TelosMotion.flow, reduced: still)) { ringFraction = f }
            }
        }
        withAnimation(TelosMotion.gated(.linear(duration: 1.0), reduced: still)) {
            heldFraction = min(out.inBandSeconds / 3600, 1)
        }
    }

    // MARK: - Lines

    /// The screen's one line of intent, honest per engine status — a stale stream never claims guarding.
    private var guardianLine: String {
        switch runner.output?.status {
        case .stale, .none:
            return String(localized: "No live reading. Coaching is paused until the strap comes back.")
        case .warmup:
            return String(localized: "Warming up. Cues stay quiet for the first minute.")
        case .active:
            return String(localized: "Guarding your session. Silence means you're on track.")
        }
    }

    /// The one honest Charge sentence — what the band is and why — shown for 6 s, then gone.
    private var chargeSentence: some View {
        Text(chargeLineText)
            .font(TelosType.footnote)
            .foregroundStyle(TelosColor.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(chargeLineVisible ? 1 : 0)
            .accessibilityHidden(!chargeLineVisible)
    }

    private var chargeLineText: String {
        guard let band = runner.baseBand else { return "" }
        let floor = Int(band.floorBpm.rounded()), ceiling = Int(band.ceilingBpm.rounded())
        if let charge = runner.chargeAtStart {
            return String(localized: "Charge \(Int(charge.rounded())) today, so your band is \(floor)–\(ceiling) bpm.")
        }
        return String(localized: "No Charge banked today, so your band takes a careful middle course: \(floor)–\(ceiling) bpm.")
    }

    /// 6 s on screen, then a slow fade — the sentence said its piece; the ring carries it from here.
    /// Runs inside `.task`, so a torn-down screen cancels the sleep and skips the (now moot) fade.
    private func fadeChargeSentenceLater() async {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 1.2)) { chargeLineVisible = false }
    }

    // MARK: - End

    private func endSession() {
        TelosHaptics.play(.commit)
        runner.end()   // finalRow lands via onChangeCompat → summary sheet
    }

    /// "N sessions guarded" — completed sessions in the recent look-back, this one included (its final
    /// row is upserted before `finalRow` publishes).
    private func loadGuardedCount() {
        let repo = model.repo
        let deviceId = repo.deviceId
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = (try? await store.recentLiveSessions(deviceId: deviceId, limit: 50)) ?? []
            guardedCount = rows.filter { $0.endTs != nil }.count
        }
    }
}

// MARK: - Summary sheet

/// The end-of-session read-out: time in / below / above the band, the cues sent, a plain verdict, and
/// the streak line. Everything comes off the banked `LiveSessionRow` — the same record the look-back
/// reads, so this sheet and history can never disagree.
struct LiveSessionSummarySheet: View {
    let row: LiveSessionRow
    let guardedCount: Int?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.l) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text("LIVE SESSION")
                    .telosScale()
                    .foregroundStyle(TelosColor.lungsInk)
                Text("Session summary")
                    .font(TelosType.title).foregroundStyle(TelosColor.textPrimary)
            }
            .padding(.top, TelosSpace.xl)

            Text(Self.verdict(row: row))
                .font(TelosType.body)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            summaryCard {
                bandRow(String(localized: "In band"), seconds: row.inBandSec, tint: TelosColor.lungs)
                bandRow(String(localized: "Below band"), seconds: row.belowSec, tint: TelosColor.textTertiary)
                bandRow(String(localized: "Above band"), seconds: row.aboveSec, tint: TelosColor.critical)
            }

            summaryCard {
                HStack {
                    Text("Cues sent").font(TelosType.subhead).foregroundStyle(TelosColor.textSecondary)
                    Spacer()
                    Text(cueLine).font(TelosType.numeralXS).foregroundStyle(TelosColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Band").font(TelosType.subhead).foregroundStyle(TelosColor.textSecondary)
                    Spacer()
                    Text("\(Int(row.floorBpm.rounded()))–\(Int(row.ceilingBpm.rounded())) bpm")
                        .font(TelosType.numeralXS).foregroundStyle(TelosColor.textPrimary)
                }
            }

            if let n = guardedCount, n > 0 {
                Text(n == 1 ? String(localized: "1 session guarded")
                            : String(localized: "\(n) sessions guarded"))
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Spacer(minLength: TelosSpace.m)
            NoopButton("Done", kind: .primary, fullWidth: true) { onDone() }
        }
        .padding(.horizontal, TelosSpace.pageGutter)
        .padding(.vertical, TelosSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TelosColor.canvas.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    // MARK: Rows

    private func bandRow(_ label: String, seconds: Double, tint: Color) -> some View {
        HStack(spacing: TelosSpace.s) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(label).font(TelosType.subhead).foregroundStyle(TelosColor.textSecondary)
            Spacer()
            Text(Self.clock(seconds))
                .font(TelosType.numeralS)
                .foregroundStyle(TelosColor.textPrimary)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    /// A compact glass card (`FrostedCardSurface` reads the root card-opacity environment — no per-card
    /// `@AppStorage`).
    private func summaryCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) { content() }
            .padding(TelosSpace.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card))
    }

    private var cueLine: String {
        if row.pushCount == 0 && row.easeCount == 0 {
            return String(localized: "None — silence, start to finish")
        }
        var parts: [String] = []
        if row.pushCount > 0 { parts.append(String(localized: "\(row.pushCount) push")) }
        if row.easeCount > 0 { parts.append(String(localized: "\(row.easeCount) ease-off")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Verdict (pure + honest — fractions of the banked totals, no editorialising beyond them)

    static func verdict(row: LiveSessionRow) -> String {
        let total = row.inBandSec + row.belowSec + row.aboveSec
        guard total >= 300 else {
            return String(localized: "Too short to judge — the band needs a few minutes to mean anything.")
        }
        let inFrac = row.inBandSec / total
        if inFrac >= 0.7 {
            return String(localized: "You held the band. Right where today wanted you.")
        }
        if inFrac >= 0.4 {
            return String(localized: "In and out, but the band won more than it lost.")
        }
        return row.belowSec >= row.aboveSec
            ? String(localized: "Mostly under the band — there was more in the tank today.")
            : String(localized: "Mostly over the band — harder than today's Charge could pay for.")
    }

    /// m:ss off the banked seconds (sessions are an hour-scale affair; no hour arithmetic needed).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
