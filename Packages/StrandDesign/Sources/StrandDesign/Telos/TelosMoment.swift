import SwiftUI

// MARK: - TelosMoment — full-screen moments: tokens + layout (coordinator decisions 7 and 17)
//
// The significant interactions are immersive full-screen MOMENTS rather than small cards and alerts:
// a quest issued / completed, a PR, a goal completed, a level up / the Level settling, a debt cleared,
// the daily penalty card, a broken streak, the day's gear choice, a trial's daily assignment and final
// verdict, a coach message the app pushes, the stress diagnostic, "Optimum reached", and the Telos
// Lift finish screen. Routine browsing stays in cards.
//
// THIS FILE is the design-system half: the value type (`TelosMoment`), the tokens (`TelosMomentStyle`),
// the one reusable layout (`TelosMomentView`) and the (retired, no-op) `TelosMomentBurst`. The
// PRESENTER is not here — FRAME owns a single `TelosMomentPresenter` hosted once at the app root with a
// priority queue (one at a time, never stacked, deduped per `id`, suppressed while a workout / the
// morning flow / another sheet is up). No screen attaches its own `.fullScreenCover` for a moment.
//
// Anatomy (top → bottom): overline (label voice) + a 44 pt close control · headline (`title`, or the
// Expanded `diagnostic` register) · optional detail · the EXACT figures (label + `numeralL` value +
// unit; costs in `critical`; a figure may COUNT from its old value to its new one once, on entrance) ·
// an optional accessory slot (gear chips, the Lift finish screen's exercise list) · one primary action.
// Behind it, a plain full-bleed backdrop (the register's ground) whose LIQUID FILL encodes the moment's
// number. No particles, no tone wash (only a penalty keeps the flat `criticalWash` — a state), no glow.
//
// DECISION 19 (owner, 2026-09-30 — clinical restraint, overrides decision 17's "vivid"): a moment is a
// calm, factual card — what happened, the numbers, one line of meaning, the buttons. EVERY entrance
// (`.standard`, `.celebration`, `.penalty` — the enum is kept for source compatibility and the haptic /
// strap mapping) is the same: content `screen` fade + 12 pt rise, the fill rises with `flow`. ≈ 1.2 s,
// then rest. No burst, no confetti, no embers, no flash. Reduce Motion: a cross-fade only, the fill posed
// at its value, figures shown at their final value. The moment's phone haptic plays ONCE on entrance
// (keyed on the id); the strap cue (`strapCue`) is requested by the presenter, not here.
//
// Dismissal never traps: the close control (one tap), a swipe down (the wearer's own drag followed 1:1
// with a gentle `release` snap-back), and the VoiceOver escape gesture all call `onDismiss`.
//
// Unbounded values (decision 9): a fill fraction above 1 is drawn honestly — the scale grows so the fill
// stays on screen and a hairline marks where 100 % sits, labelled "100". Nothing clamps at 100.
// Honesty: `fill == nil` draws NO liquid. Figures are strings the caller formats exactly; a counting
// figure lands on exactly that string.

// MARK: - Value

/// Which strap buzz a moment asks the strap-cue system for (decision 17).
public enum TelosStrapCue: String, Sendable {
    case reward
    case penalty
}

public struct TelosMoment: Identifiable, Equatable {

    /// What the moment is about. Drives the default priority, tone, register, entrance and haptics.
    public enum Kind: String, CaseIterable, Sendable {
        case questIssued
        case questCompleted
        case goalCompleted
        case personalRecord
        case levelUp
        case penalty
        case streakBroken
        case debtCleared
        case gearChoice
        case trialAssignment
        case trialVerdict
        case levelSettle
        case coachMessage
        case stressDiagnostic
        case optimumReached
        case liftFinished

        /// Higher shows first when several are queued.
        public var defaultPriority: Int {
            switch self {
            case .stressDiagnostic: return 100
            case .penalty:          return 90
            case .streakBroken:     return 88
            case .gearChoice:       return 80
            case .levelUp:          return 75
            case .levelSettle:      return 70
            case .liftFinished:     return 68
            case .personalRecord:   return 66
            case .trialAssignment:  return 60
            case .trialVerdict:     return 60
            case .goalCompleted:    return 55
            case .questIssued:      return 50
            case .questCompleted:   return 45
            case .debtCleared:      return 45
            case .optimumReached:   return 40
            case .coachMessage:     return 30
            }
        }

        public var defaultTone: TelosMoment.Tone {
            switch self {
            case .penalty, .streakBroken, .stressDiagnostic: return .critical
            case .questCompleted, .debtCleared,
                 .goalCompleted, .levelUp:                   return .positive
            case .personalRecord:                            return .gold
            case .liftFinished:                              return .muscle
            case .optimumReached:                            return .effort
            case .levelSettle, .coachMessage, .trialAssignment,
                 .trialVerdict, .questIssued, .gearChoice:  return .neutral
            }
        }

        public var defaultRegister: TelosMoment.Register {
            switch self {
            case .stressDiagnostic, .optimumReached: return .diagnostic
            default:                                 return .standard
            }
        }

        public var defaultEntrance: TelosMoment.Entrance {
            switch self {
            case .questCompleted, .goalCompleted, .personalRecord, .levelUp,
                 .debtCleared, .liftFinished:
                return .celebration
            case .penalty, .streakBroken:
                return .penalty
            default:
                return .standard
            }
        }

        /// The phone pattern played once on entrance (nil = silent).
        public var defaultHaptic: TelosHaptic? {
            switch self {
            case .questIssued:      return .summon
            case .questCompleted, .goalCompleted, .personalRecord,
                 .levelUp, .debtCleared, .liftFinished:
                return .reward
            case .penalty, .streakBroken:
                return .penalty
            case .gearChoice:       return nil        // the choice itself plays `select`
            case .trialAssignment:  return .settle
            case .trialVerdict:     return .settle    // never celebratory: a verdict is a reading
            case .levelSettle:      return .levelSettle
            case .coachMessage:     return .settle
            case .stressDiagnostic: return .heartbeat // a moment about the heart
            case .optimumReached:   return .success
            }
        }

        /// The strap buzz this moment asks for (nil = none). A Lift finish only buzzes when it holds a
        /// PR — the presenter sets `strapCue = .reward` then.
        public var defaultStrapCue: TelosStrapCue? {
            switch self {
            case .questCompleted, .goalCompleted, .personalRecord, .levelUp, .debtCleared:
                return .reward
            case .penalty, .streakBroken:
                return .penalty
            default:
                return nil
            }
        }
    }

    /// The backdrop / accent family.
    public enum Tone: Sendable {
        case neutral
        case positive
        case critical
        case heart
        case charge
        case effort
        case rest
        case focus
        case muscle
        case gold

        public var color: Color {
            switch self {
            case .neutral:  return TelosColor.mint
            case .positive: return TelosColor.positive
            case .critical: return TelosColor.critical
            case .heart:    return TelosColor.heart
            case .charge:   return TelosColor.charge
            case .effort:   return TelosColor.effort
            case .rest:     return TelosColor.rest
            case .focus:    return TelosColor.focus
            case .muscle:   return TelosColor.muscle
            case .gold:     return TelosColor.bestGold
            }
        }
    }

    /// `standard` sits on the bioluminescent ground and follows the scheme; `diagnostic` is the
    /// ceremonial black field with the Expanded type (forced dark).
    public enum Register: Sendable {
        case standard
        case diagnostic
    }

    /// How the moment arrives (see the file header).
    public enum Entrance: Sendable {
        case standard
        case celebration
        case penalty
    }

    /// How a counting figure formats the numbers it passes through.
    public enum CountFormat: Equatable, Sendable {
        case integer
        case decimal(Int)
        /// With a sign and a true minus ("+24", "−3").
        case signed(Int)

        func string(_ value: Double) -> String {
            switch self {
            case .integer:           return TelosFormat.integer(value)
            case .decimal(let d):    return TelosFormat.decimal(d)(value)
            case .signed(let d):     return TelosFormat.signedDelta(value, digits: d)
            }
        }
    }

    /// One exact number on the moment. `value` is the exact final text; set `countFrom`/`countTo` to
    /// let it count once, on entrance, from the old value to the new (it lands on `value`).
    public struct Figure: Equatable {
        public var label: String
        public var value: String
        public var unit: String?
        /// Render in `critical` ink (a penalty's cost column).
        public var isCost: Bool
        public var countFrom: Double?
        public var countTo: Double?
        public var countFormat: CountFormat

        public init(label: String, value: String, unit: String? = nil, isCost: Bool = false,
                    countFrom: Double? = nil, countTo: Double? = nil, countFormat: CountFormat = .integer) {
            self.label = label
            self.value = value
            self.unit = unit
            self.isCost = isCost
            self.countFrom = countFrom
            self.countTo = countTo
            self.countFormat = countFormat
        }

        /// Whether this figure counts (both ends known and finite).
        var counts: Bool {
            guard let from = countFrom, let to = countTo else { return false }
            return from.isFinite && to.isFinite && from != to
        }
    }

    /// Dedupe key. Make it unique per occurrence and day (e.g. "quest.done.<questID>.<yyyy-MM-dd>").
    public let id: String
    public var kind: Kind
    /// Already-localised copy (the logic packages own the strings).
    public var overline: String
    public var headline: String
    public var detail: String?
    public var figures: [Figure]
    /// The backdrop fill as a fraction (1 = 100 %). nil = no liquid. Values > 1 are drawn honestly.
    public var fill: Double?
    /// The one primary action's title; nil = no primary button.
    public var primaryActionTitle: String?
    public var tone: Tone
    public var register: Register
    public var entrance: Entrance
    public var priority: Int
    public var haptic: TelosHaptic?
    public var strapCue: TelosStrapCue?

    public init(id: String,
                kind: Kind,
                overline: String,
                headline: String,
                detail: String? = nil,
                figures: [Figure] = [],
                fill: Double? = nil,
                primaryActionTitle: String? = nil) {
        self.id = id
        self.kind = kind
        self.overline = overline
        self.headline = headline
        self.detail = detail
        self.figures = figures
        self.fill = fill
        self.primaryActionTitle = primaryActionTitle
        self.tone = kind.defaultTone
        self.register = kind.defaultRegister
        self.entrance = kind.defaultEntrance
        self.priority = kind.defaultPriority
        self.haptic = kind.defaultHaptic
        self.strapCue = kind.defaultStrapCue
    }

    /// Queue order: higher priority first; equal priority keeps arrival order (the caller's index).
    public static func showsBefore(_ a: TelosMoment, _ b: TelosMoment) -> Bool {
        a.priority > b.priority
    }
}

// MARK: - Tokens

public enum TelosMomentStyle {
    /// Side padding of the moment content.
    public static let contentPadding: CGFloat = TelosSpace.xl
    /// Vertical rhythm between the moment's blocks.
    public static let blockSpacing: CGFloat = TelosSpace.l
    /// The content rises this far on entrance (not under Reduce Motion).
    public static let entranceRise: CGFloat = 12
    /// How much of the screen height a 100 % fill reaches — headroom above so an overflow reads.
    public static let fullLevel: CGFloat = 0.9
    /// Liquid opacity over the backdrop (tone colour at `fill`), and the luminous meniscus line's.
    public static let liquidOpacity: Double = TelosOpacity.fill
    public static let meniscusOpacity: Double = 0.8
    /// The whole-backdrop tone wash (`criticalWash` for the critical tone).
    public static let washOpacity: Double = TelosOpacity.whisper
    /// Swipe-down dismissal: distance, or predicted distance, past which a release dismisses.
    public static let dismissDistance: CGFloat = 120
    public static let dismissPredictedDistance: CGFloat = 220
    /// Standard entrance budget (content + fill), after which nothing moves.
    public static let settleBudget: Double = TelosMotion.settleBudget
    /// The longest a moment may animate (decision 17: ≤ 1.5 s). The burst itself is retired
    /// (decision 19); the budget stays as the ceiling for any entrance.
    public static let burstDuration: Double = 1.4
    /// RETIRED with the burst (decision 19) — nothing draws particles. Kept for source compatibility.
    public static let celebrationParticles: Int = 0
    public static let penaltyParticles: Int = 0
    /// RETIRED (decision 19): no full-screen critical flash on a penalty. Kept for source compatibility.
    public static let penaltyFlashOpacity: Double = 0
    public static let penaltyFlashDuration: Double = 0.6

    /// The liquid's colour for a tone: the data hue, except `neutral` and `gold`, whose liquid is a
    /// neutral grey (decision 19: no decorative green, and gold only ever as a small flat text mark).
    public static func liquidColor(_ tone: TelosMoment.Tone) -> Color {
        switch tone {
        case .neutral, .gold: return TelosColor.textTertiary
        default:              return tone.color
        }
    }
    /// A counting figure's run (the `countUp` budget).
    public static let countDuration: Double = TelosMotion.countUpMaxDuration

    /// Backdrop base colour for a register.
    public static func base(_ register: TelosMoment.Register) -> Color {
        register == .diagnostic ? TelosColor.diagField : TelosColor.canvas
    }

    /// Where the liquid's surface sits (0…`fullLevel` of the height) for `fraction`, and where the
    /// 100 % hairline sits when the value overflows (nil when it does not). Nothing clamps at 100:
    /// above 1 the scale grows so the fill stays on screen and 100 % moves down.
    public static func levels(fraction: Double) -> (level: CGFloat, hundred: CGFloat?) {
        guard fraction.isFinite, fraction > 0 else { return (0, nil) }
        let scaleMax = max(1.0, fraction)
        let level = CGFloat(fraction / scaleMax) * fullLevel
        let hundred: CGFloat? = fraction > 1 ? CGFloat(1.0 / scaleMax) * fullLevel : nil
        return (level, hundred)
    }

    /// Burst progress (0…1) at `elapsed` seconds, eased out; 1 from `burstDuration` on.
    public static func burstProgress(elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let t = min(elapsed / burstDuration, 1)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }
}

// MARK: - Backdrop

/// Full-bleed backdrop: register base, the ground's depth, the flat `criticalWash` for a critical tone
/// only, and the liquid rising to `shownFraction` (animated by the caller). `targetFraction` places the
/// 100 % hairline. No particles, no decorative tone wash (decision 19).
struct TelosMomentBackdrop: View {
    let tone: TelosMoment.Tone
    let register: TelosMoment.Register
    let shownFraction: Double?
    let targetFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                TelosMomentStyle.base(register)
                if register == .standard {
                    TelosColor.groundGradient
                }
                if tone == .critical {
                    // A state (a penalty), not decoration: the flat critical wash.
                    TelosColor.criticalWash
                }
                // No value → no liquid (never a fill fed from a default).
                if let fraction = shownFraction {
                    let liquid = TelosMomentStyle.liquidColor(tone)
                    Rectangle()
                        .fill(liquid.opacity(TelosMomentStyle.liquidOpacity))
                        .frame(height: height * TelosMomentStyle.levels(fraction: fraction).level)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(liquid.opacity(TelosMomentStyle.meniscusOpacity))
                                .frame(height: TelosStroke.line)
                        }
                }
                if let target = targetFraction, let hundred = TelosMomentStyle.levels(fraction: target).hundred {
                    HStack(spacing: TelosSpace.s) {
                        Rectangle()
                            .fill(TelosColor.lineStrong)
                            .frame(height: TelosStroke.hair)
                        Text(verbatim: "100")
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                    .padding(.horizontal, TelosMomentStyle.contentPadding)
                    .padding(.bottom, height * hundred)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Entrance burst (RETIRED — decision 19)

/// RETIRED (decision 19: no particle bursts, confetti or embers). Formerly luminous particles bursting
/// out (celebration) or red embers falling (penalty). It now draws NOTHING — a clear, hit-test-transparent
/// view — and runs no clock. The type, `Style` and initialiser are kept so call sites stay
/// source-compatible; new code should simply not use it.
public struct TelosMomentBurst: View {
    public enum Style: Sendable {
        case celebration
        case penalty
    }

    /// Whether this retired effect draws anything. Always false (decision 19); pinned by a test.
    public static let drawsAnything = false

    public init(style: Style, color: Color) {}

    public var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Counting figure

/// A figure that counts from `from` to `to` ONCE, on entrance, then shows the exact `final` text.
/// Reduce Motion: the final text at once. VoiceOver always reads the final text.
struct TelosMomentCountingFigure: View {
    let from: Double
    let to: Double
    let format: TelosMoment.CountFormat
    let final: String
    @State private var number: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(from: Double, to: Double, format: TelosMoment.CountFormat, final: String) {
        self.from = from
        self.to = to
        self.format = format
        self.final = final
        self._number = State(initialValue: from)
    }

    var body: some View {
        TelosMomentAnimatedNumber(number: number, target: to, format: format, final: final)
            .onAppear {
                if reduceMotion {
                    number = to
                } else {
                    withAnimation(.easeOut(duration: TelosMomentStyle.countDuration).delay(0.15)) { number = to }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: final))
    }
}

private struct TelosMomentAnimatedNumber: View, Animatable {
    var number: Double
    let target: Double
    let format: TelosMoment.CountFormat
    let final: String

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        // Lands on the caller's exact text, never on a re-formatted approximation of it.
        Text(verbatim: number == target ? final : format.string(number))
            .lineLimit(1)
    }
}

// MARK: - Layout

/// The one moment layout. FRAME's presenter hosts it once at the root:
///
///     .overlay {
///         if let moment = presenter.current {
///             TelosMomentView(moment: moment,
///                             onPrimary: { presenter.performPrimary(moment) },
///                             onDismiss: { presenter.dismiss(moment) })
///                 .transition(.opacity)
///         }
///     }
///
/// `accessory` is an optional slot below the figures for moments that need a choice (gear chips) or
/// a small instrument / list (the Lift finish screen's exercises and muscle-group changes).
public struct TelosMomentView<Accessory: View>: View {
    private let moment: TelosMoment
    private let onPrimary: (() -> Void)?
    private let onDismiss: () -> Void
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorSchemeFallback
    @State private var entered = false
    @State private var shownFraction: Double? = nil
    @State private var dragOffset: CGFloat = 0

    public init(moment: TelosMoment,
                onPrimary: (() -> Void)? = nil,
                onDismiss: @escaping () -> Void,
                @ViewBuilder accessory: () -> Accessory) {
        self.moment = moment
        self.onPrimary = onPrimary
        self.onDismiss = onDismiss
        self.accessory = accessory()
        // The first frame already has the liquid at 0 (not absent), so the entrance GROWS it from the
        // floor instead of inserting it at full height. nil stays nil: no value, no liquid.
        self._shownFraction = State(initialValue: moment.fill == nil ? nil : 0)
    }

    public var body: some View {
        ZStack {
            TelosMomentBackdrop(tone: moment.tone,
                                register: moment.register,
                                shownFraction: shownFraction,
                                targetFraction: moment.fill)
            // No burst, no critical flash (decision 19): the card simply fades / rises in.
            content
                .opacity(entered ? 1 : 0)
                .offset(y: (entered || reduceMotion) ? 0 : TelosMomentStyle.entranceRise)
        }
        .offset(y: dragOffset)
        .gesture(dismissDrag)
        .environment(\.colorScheme, moment.register == .diagnostic ? .dark : colorSchemeFallback)
        .onAppear(perform: enter)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onDismiss() }
    }

    private var isDiagnostic: Bool { moment.register == .diagnostic }

    private var content: some View {
        VStack(alignment: .leading, spacing: TelosMomentStyle.blockSpacing) {
            HStack(alignment: .center) {
                Text(verbatim: moment.overline)
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(moment.tone == .neutral ? TelosColor.textTertiary : moment.tone.color)
                Spacer(minLength: TelosSpace.s)
                closeButton
            }

            Spacer(minLength: TelosSpace.xl)

            Text(verbatim: moment.headline)
                .font(isDiagnostic ? TelosType.diagnostic : TelosType.title)
                .tracking(isDiagnostic ? TelosType.Tracking.diagnostic : 0)
                .foregroundStyle(isDiagnostic ? TelosColor.diagText : TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let detail = moment.detail {
                Text(verbatim: detail)
                    .font(TelosType.body)
                    .foregroundStyle(isDiagnostic ? TelosColor.diagMuted : TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !moment.figures.isEmpty {
                VStack(alignment: .leading, spacing: TelosSpace.m) {
                    ForEach(Array(moment.figures.enumerated()), id: \.offset) { _, figure in
                        figureRow(figure)
                    }
                }
            }

            accessory

            Spacer(minLength: TelosSpace.xl)

            if let title = moment.primaryActionTitle, let onPrimary {
                Button(action: onPrimary) {
                    Text(verbatim: title)
                }
                .buttonStyle(NoopPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, TelosMomentStyle.contentPadding)
        .padding(.vertical, TelosSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func figureRow(_ figure: TelosMoment.Figure) -> some View {
        let ink: Color = figure.isCost ? TelosColor.critical
                                       : (isDiagnostic ? TelosColor.diagText : TelosColor.textPrimary)
        return VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            Text(verbatim: figure.label)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(isDiagnostic ? TelosColor.diagMuted : TelosColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                if figure.counts, let from = figure.countFrom, let to = figure.countTo {
                    TelosMomentCountingFigure(from: from, to: to, format: figure.countFormat, final: figure.value)
                        .telosNumeral(.numeralL)
                        .foregroundStyle(ink)
                } else {
                    Text(verbatim: figure.value)
                        .telosNumeral(.numeralL)
                        .foregroundStyle(ink)
                }
                if let unit = figure.unit {
                    Text(verbatim: unit)
                        .font(TelosType.unitFont(forNumeralSize: TelosNumeralStyle.numeralL.size))
                        .foregroundStyle(isDiagnostic ? TelosColor.diagMuted : TelosColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(TelosType.glyphControl)
                .foregroundStyle(isDiagnostic ? TelosColor.diagText : TelosColor.textPrimary)
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .contentShape(Circle())
        }
        .nativeLiquidGlassButtonChrome(controlSize: .regular) {
            // Fallback: the shared solid glass fallback, no material.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(isDiagnostic ? TelosColor.diagText : TelosColor.textPrimary)
                    .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                    .nativeLiquidGlassFallbackSurface(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(TelosPressButtonStyle())
        }
        .accessibilityLabel(Text("Done"))
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Direct manipulation: the moment follows the finger 1:1, downward only.
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let distance = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if distance > TelosMomentStyle.dismissDistance
                    || predicted > TelosMomentStyle.dismissPredictedDistance {
                    onDismiss()
                } else {
                    withAnimation(reduceMotion ? nil : TelosMotion.release) { dragOffset = 0 }
                }
            }
    }

    private func enter() {
        guard !entered else { return }
        if let haptic = moment.haptic {
            TelosHaptics.play(haptic, action: "moment." + moment.id)
        }
        if reduceMotion {
            // A cross-fade only.
            shownFraction = moment.fill
            withAnimation(TelosMotion.fade) { entered = true }
            return
        }
        withAnimation(TelosMotion.screen) { entered = true }
        if let target = moment.fill {
            withAnimation(TelosMotion.flow) { shownFraction = target }
        }
    }
}

public extension TelosMomentView where Accessory == EmptyView {
    init(moment: TelosMoment, onPrimary: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.init(moment: moment, onPrimary: onPrimary, onDismiss: onDismiss, accessory: { EmptyView() })
    }
}
