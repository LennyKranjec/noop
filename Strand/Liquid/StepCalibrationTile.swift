//  StepCalibrationTile.swift
//  NOOP · Today
//
//  TEMPORARY step-calibration tile. Start → walk while counting in your head → Pause → type the real count
//  → Apply. The count NOOP shows is read from the store over exactly the walked interval(s) with the SAME
//  kernel the day total uses (5/MG: `StepsCounter.stepsInWindow` ÷ `stepTicksPerStep`; 4.0:
//  `StepsEstimateEngine.dayMotionIntensity` × k), so it is what the day total attributes to that walk.
//  Apply feeds the existing calibration parameter (see `StepCalibrationWalks.swift`) and re-scores the recent
//  days. Hidden with the × (or the Settings toggle); visible by default.
//
//  Motion data may reach the store only after an offload (a WHOOP 4.0 without a live motion stream), so a
//  window whose data is not in yet reads "Waiting for strap data…" instead of a wrong number, and the tile
//  re-reads every 10 s and on every `repo.refreshSeq` bump until it is.

import SwiftUI
import StrandDesign
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// What the store holds for a session's segments.
struct StepCalibrationReading: Equatable {
    var kind: StepCalibrationKind
    /// Counter ticks or motion volume, summed over every segment.
    var raw: Double
    /// Every segment has data reaching both of its edges (within `edgeTolerance`).
    var covered: Bool
    /// Any sample at all in any segment.
    var hasAnyData: Bool
}

@MainActor
enum StepCalibrationReader {
    /// How close to a segment's edges the first/last sample must sit for the segment to count as "in".
    /// Gravity on a 4.0 is roughly one record a minute, so two minutes of slack.
    static let edgeTolerance = 120

    static func read(repo: Repository, segments: [StepCalibrationSession.Segment],
                     fallbackKind: StepCalibrationKind) async -> StepCalibrationReading {
        // 1) The @57 counter (5/MG). The day total prefers it, so it wins whenever it has samples.
        var ticks = 0.0
        var counterCovered = true
        var counterAny = false
        if let store = await repo.storeHandle() {
            for seg in segments {
                var segSamples: [StepSample] = []
                for id in repo.importedReadIds {   // active strap first, never merged (see strapStepTicks)
                    let s = (try? await store.stepSamples(deviceId: id, from: seg.start, to: seg.end,
                                                          limit: 200_000)) ?? []
                    if s.count >= 2 { segSamples = s; break }
                }
                if segSamples.count >= 2 {
                    counterAny = true
                    ticks += Double(StepsCounter.stepsInWindow(segSamples) ?? 0)
                    if !edgesCovered(segSamples.map(\.ts), seg) { counterCovered = false }
                } else {
                    counterCovered = false
                }
            }
        }
        if counterAny {
            return StepCalibrationReading(kind: .counter, raw: ticks, covered: counterCovered, hasAnyData: true)
        }
        // 2) Gravity motion volume (4.0), the estimator's own fold over the same union the calibration reads.
        var motion = 0.0
        var gravCovered = true
        var gravAny = false
        for seg in segments {
            let g = await repo.gravitySamplesUnion(from: seg.start, to: seg.end)
            if g.count >= 2 {
                gravAny = true
                motion += StepsEstimateEngine.dayMotionIntensity(g)
                if !edgesCovered(g.map(\.ts), seg) { gravCovered = false }
            } else {
                gravCovered = false
            }
        }
        if gravAny {
            return StepCalibrationReading(kind: .motion, raw: motion, covered: gravCovered, hasAnyData: true)
        }
        return StepCalibrationReading(kind: fallbackKind, raw: 0, covered: false, hasAnyData: false)
    }

    private static func edgesCovered(_ ts: [Int], _ seg: StepCalibrationSession.Segment) -> Bool {
        guard let lo = ts.min(), let hi = ts.max() else { return false }
        return lo <= seg.start + edgeTolerance && hi >= seg.end - edgeTolerance
    }
}

struct StepCalibrationTile: View {
    static let visibleKey = "stepCalibrationTile.visible"

    @AppStorage(StepCalibrationTile.visibleKey) private var visible = true
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.appModelRef) private var appModelRef

    @State private var session = StepCalibrationSession.load()
    @State private var calState = StepCalibrationState.load()
    @State private var reading: StepCalibrationReading?
    @State private var countedText = ""
    @State private var showHistory = false

    private var fallbackKind: StepCalibrationKind {
        selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue ? .counter : .motion
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    var body: some View {
        if visible {
            StrandCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    content
                    footer
                }
            }
            // Re-read on every data refresh and whenever the session changes; keep polling while running or
            // while the paused window's data has not arrived yet.
            .task(id: "\(repo.refreshSeq)-\(session.segments.count)-\(session.runningSince ?? 0)") {
                while !Task.isCancelled {
                    await refreshReading()
                    let waiting = !session.isEmpty && !(reading?.covered ?? false)
                    guard session.isRunning || waiting else { break }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
            Text("STEP CALIBRATION")
                .font(StrandFont.overline)
                .tracking(1.2)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Button { visible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide step calibration")
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.isEmpty {
            // IDLE
            HStack(alignment: .firstTextBaseline) {
                bigNumber("0")
                Text("steps").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                pillButton("Start", systemImage: "play.fill") { start() }
            }
            Text("Press Start, walk while counting your steps in your head, then press Pause and enter your count.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if session.isRunning {
            // RUNNING
            HStack(alignment: .firstTextBaseline) {
                stepsFigure
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(session.elapsed(now: Int(ctx.date.timeIntervalSince1970))))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                pillButton("Pause", systemImage: "pause.fill") { pause() }
            }
            waitingLine
        } else {
            // PAUSED
            HStack(alignment: .firstTextBaseline) {
                stepsFigure
                Spacer()
                Text(Self.clock(session.elapsed(now: now)))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            waitingLine
            HStack(spacing: 8) {
                TextField("Your counted steps", text: $countedText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .font(StrandFont.bodyNumber)
                    .onChange(of: countedText) { v in
                        let digits = String(v.filter(\.isNumber).prefix(6))
                        if digits != v { countedText = digits }
                    }
            }
            HStack(spacing: 8) {
                pillButton("Apply", systemImage: "checkmark", prominent: true) { apply() }
                    .disabled(!canApply)
                    .opacity(canApply ? 1 : 0.45)
                pillButton("Resume", systemImage: "play.fill") { resume() }
                pillButton("Discard", systemImage: "trash") { discard() }
                Spacer(minLength: 0)
            }
            if let hint = applyHint {
                Text(hint).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// NOOP's count for the session so far, or a dash while the strap has nothing for it yet.
    @ViewBuilder
    private var stepsFigure: some View {
        if let r = reading, r.hasAnyData {
            if let est = StepCalibrationMath.estimatedSteps(kind: r.kind, raw: r.raw, parameter: parameter(for: r.kind)) {
                bigNumber("\(est)")
                Text("steps (NOOP)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                // A 4.0 with no k yet: there is no step number to show, but the motion is measured and the
                // walk can still set k.
                bigNumber("–")
                Text("not calibrated yet").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            bigNumber("–")
            Text("steps").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    @ViewBuilder
    private var waitingLine: some View {
        if !(reading?.covered ?? false) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(reading?.hasAnyData == true
                     ? "Waiting for the rest of the strap data…"
                     : "Waiting for strap data…")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
                if !session.isRunning {
                    Button("Sync now") { ble.syncNow() }
                        .font(StrandFont.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Text(currentCalibrationText)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 4)
                if !calState.walks.isEmpty {
                    Button(showHistory ? "Hide walks" : "\(calState.walks.count) walk\(calState.walks.count == 1 ? "" : "s")") {
                        showHistory.toggle()
                    }
                    .font(StrandFont.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    Button("Reset") { reset() }
                        .font(StrandFont.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
            if showHistory {
                ForEach(Array(calState.walks.suffix(8).reversed())) { w in
                    HStack(spacing: 6) {
                        Text(w.date, format: .dateTime.day().month().hour().minute())
                        Spacer(minLength: 4)
                        Text("NOOP \(w.estimated.map { "\($0)" } ?? "–") · you \(w.counted)")
                        Text(w.factor.map { String(format: "×%.2f", $0) } ?? "")
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: - Derived

    /// The estimator parameter currently in force for `kind`.
    private func parameter(for kind: StepCalibrationKind) -> Double {
        switch kind {
        case .counter: return profile.stepTicksPerStep
        // The engine mirrors whichever k is in force (manual or phone-fitted) into this field.
        case .motion:  return profile.stepsManualCoefficient > 0 ? profile.stepsManualCoefficient
                                                                  : profile.stepsCalibrationCoefficient
        }
    }

    private var currentCalibrationText: String {
        let kind = reading?.kind ?? calState.walks.last?.kind ?? fallbackKind
        switch kind {
        case .counter:
            return String(format: "Now: %.2f counter ticks per step", profile.stepTicksPerStep)
        case .motion:
            let k = parameter(for: .motion)
            if k <= 0 { return "Now: not calibrated" }
            let how = profile.stepsManualCoefficient > 0 ? "manual" : "phone fit"
            return String(format: "Now: k = %.1f steps/motion", k) + " (\(how))"
        }
    }

    private var countedValue: Int? { Int(countedText) }

    private var canApply: Bool {
        guard let r = reading, r.covered, r.raw > 0, let c = countedValue else { return false }
        return c >= StepCalibrationMath.minCountedSteps
    }

    private var applyHint: String? {
        if let c = countedValue, c > 0, c < StepCalibrationMath.minCountedSteps {
            return "Walk at least \(StepCalibrationMath.minCountedSteps) steps for a usable calibration."
        }
        if let r = reading, r.covered, r.raw <= 0 {
            return "The strap saw no walking movement in this window."
        }
        if reading?.kind == .motion {
            return "Tunes NOOP's own motion estimate only; days your phone counted keep the phone's steps."
        }
        return nil
    }

    // MARK: - Actions

    private func refreshReading() async {
        guard !session.isEmpty else { reading = nil; return }
        reading = await StepCalibrationReader.read(repo: repo, segments: session.allSegments(now: now),
                                                   fallbackKind: fallbackKind)
    }

    private func start() {
        session = StepCalibrationSession()
        session.start(now: now)
        session.save()
        countedText = ""
        reading = nil
    }

    private func pause() { session.pause(now: now); session.save() }

    private func resume() { session.start(now: now); session.save() }

    private func discard() {
        session = StepCalibrationSession()
        session.save()
        countedText = ""
        reading = nil
    }

    private func apply() {
        guard canApply, let r = reading, let counted = countedValue else { return }
        let est = StepCalibrationMath.estimatedSteps(kind: r.kind, raw: r.raw, parameter: parameter(for: r.kind))
        guard let walk = StepCalibrationMath.makeWalk(kind: r.kind, raw: r.raw, estimated: est,
                                                      counted: counted) else { return }
        var st = StepCalibrationState.load()
        st.walks.append(walk)
        switch r.kind {
        case .counter:
            if st.originalTicksPerStep == nil { st.originalTicksPerStep = profile.stepTicksPerStep }
            if let p = StepCalibrationMath.combinedParameter(st.walks, kind: .counter) {
                profile.stepTicksPerStep = p
            }
        case .motion:
            if st.originalManualK == nil {
                st.originalManualK = profile.stepsManualCoefficient
                if !profile.stepsCalibrationManual && profile.stepsCalibrationCoefficient > 0 {
                    st.referenceK = profile.stepsCalibrationCoefficient
                }
            }
            if let p = StepCalibrationMath.combinedParameter(st.walks, kind: .motion, referenceK: st.referenceK) {
                profile.stepsManualCoefficient = p
            }
        }
        st.save()
        calState = st
        discard()
        rescore()
    }

    private func reset() {
        let st = StepCalibrationState.load()
        if let o = st.originalTicksPerStep { profile.stepTicksPerStep = o }
        if let o = st.originalManualK { profile.stepsManualCoefficient = o }
        StepCalibrationState().save()
        calState = StepCalibrationState()
        showHistory = false
        rescore()
    }

    /// Re-score the recent days with the new parameter (the counter divisor is part of the day-cache
    /// signature, and the 4.0 estimate re-upserts steps_est each pass), then reload what Today shows.
    private func rescore() {
        let model = resolvedAppModel(appModelRef)
        let repo = repo
        Task {
            await model?.intelligence.analyzeRecent()
            await repo.refresh()
        }
    }

    // MARK: - Bits

    private func bigNumber(_ s: String) -> some View {
        Text(s)
            .font(StrandFont.number(28))
            .foregroundStyle(StrandPalette.textPrimary)
            .monospacedDigit()
    }

    private func pillButton(_ title: LocalizedStringKey, systemImage: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(StrandFont.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(prominent ? StrandPalette.accent : StrandPalette.surfaceInset))
                .foregroundStyle(prominent ? Color.white : StrandPalette.textPrimary)
        }
        .buttonStyle(.plain)
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Settings row to bring the tile back after it was hidden with its ×.
struct StepCalibrationTileToggleRow: View {
    @AppStorage(StepCalibrationTile.visibleKey) private var visible = true

    var body: some View {
        Toggle(isOn: $visible) {
            Text("Step calibration tile on Today")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .tint(StrandPalette.accent)
    }
}
