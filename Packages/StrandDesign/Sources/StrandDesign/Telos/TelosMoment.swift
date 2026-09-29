import SwiftUI

// MARK: - TelosMoment — full-screen moments: tokens + layout (coordinator decision 7)
//
// The significant interactions are immersive full-screen MOMENTS rather than small cards and alerts:
// a quest issued / completed, the daily failure (penalty) card, a debt cleared, the day's gear choice,
// a trial's daily assignment and final verdict, the Level settling, a coach message the app pushes,
// the stress diagnostic and "Optimum reached". Routine browsing stays in cards.
//
// THIS FILE is the design-system half: the value type (`TelosMoment`), the tokens (`TelosMomentStyle`)
// and the one reusable layout (`TelosMomentView`). The PRESENTER is not here — FRAME owns a single
// `TelosMomentPresenter` hosted once at the app root with a priority queue (one at a time, never
// stacked, deduped per `id`, suppressed while a workout / the morning flow / another sheet is up).
// No screen attaches its own `.fullScreenCover` for a moment.
//
// Anatomy (top → bottom): overline (`scale`) + a 44 pt close control · headline (`title`, or the
// Expanded `diagnostic` register) · optional detail · the EXACT figures (label in `scale`, value in
// `numeralL` + unit; costs in `critical` ink) · an optional accessory slot (e.g. the Steady / Push /
// Relentless chips) · one primary action. Behind it, a full-bleed backdrop whose LIQUID FILL encodes
// the moment's number (e.g. a quest's completion fraction) — the living-instrument language.
//
// Motion (≈ 1.2 s, then REST — no clock keeps running):
//   • content: `TelosMotion.screen` fade + 12 pt rise; the fill rises with `TelosMotion.flow`.
//   • Reduce Motion: a cross-fade (`TelosMotion.fade`), the fill posed at its value, no rise.
//   • The moment's haptic (`kind.defaultHaptic`, overridable) fires ONCE on entrance, keyed on the id.
//
// Dismissal never traps: the close control (one tap), a swipe down (with the wearer's own drag
// followed 1:1 and a gentle `release` snap-back), and the VoiceOver escape gesture all call `onDismiss`.
//
// Unbounded values (decision 9): a fill fraction above 1 is drawn honestly — the scale grows so the fill
// stays on screen and a hairline marks where 100 % sits, labelled "100". Nothing clamps at 100.
//
// Honesty: `fill == nil` draws NO liquid (never `?? 0`). Figures are strings the caller formats
// exactly (grouped integers, units, true minus) — the view never rounds or abbreviates them.

// MARK: - Value

public struct TelosMoment: Identifiable, Equatable {

    /// What the moment is about. Drives the default priority, tone, register and haptic.
    public enum Kind: String, CaseIterable, Sendable {
        case questIssued
        case questCompleted
        case penalty
        case debtCleared
        case gearChoice
        case trialAssignment
        case trialVerdict
        case levelSettle
        case coachMessage
        case stressDiagnostic
        case optimumReached

        /// Higher shows first when several are queued.
        public var defaultPriority: Int {
            switch self {
            case .stressDiagnostic: return 100
            case .penalty:          return 90
            case .gearChoice:       return 80
            case .levelSettle:      return 70
            case .trialAssignment:  return 60
            case .trialVerdict:     return 60
            case .questIssued:      return 50
            case .questCompleted:   return 45
            case .debtCleared:      return 45
            case .optimumReached:   return 40
            case .coachMessage:     return 30
            }
        }

        public var defaultTone: TelosMoment.Tone {
            switch self {
            case .penalty, .stressDiagnostic:       return .critical
            case .questCompleted, .debtCleared:     return .positive
            case .levelSettle, .coachMessage,
                 .trialAssignment, .trialVerdict,
                 .questIssued, .gearChoice:         return .neutral
            case .optimumReached:                   return .effort
            }
        }

        public var defaultRegister: TelosMoment.Register {
            switch self {
            case .stressDiagnostic, .optimumReached: return .diagnostic
            default:                                 return .standard
            }
        }

        /// The vocabulary pattern played once on entrance (nil = silent).
        public var defaultHaptic: TelosHaptic? {
            switch self {
            case .questIssued:      return .summon
            case .questCompleted:   return .success
            case .penalty:          return .failure
            case .debtCleared:      return .success
            case .gearChoice:       return nil        // the choice itself plays `select`
            case .trialAssignment:  return .settle
            case .trialVerdict:     return .settle    // never celebratory: a verdict is a reading
            case .levelSettle:      return .levelSettle
            case .coachMessage:     return .settle
            case .stressDiagnostic: return .heartbeat // a moment about the heart
            case .optimumReached:   return .success
            }
        }
    }

    /// The backdrop / accent family. Status tones for consequences, identity tones for metrics.
    public enum Tone: Sendable {
        case neutral
        case positive
        case critical
        case heart
        case charge
        case effort
        case rest
        case focus

        public var color: Color {
            switch self {
            case .neutral:  return TelosColor.textPrimary
            case .positive: return TelosColor.positive
            case .critical: return TelosColor.critical
            case .heart:    return TelosColor.heart
            case .charge:   return TelosColor.charge
            case .effort:   return TelosColor.effort
            case .rest:     return TelosColor.rest
            case .focus:    return TelosColor.focus
            }
        }
    }

    /// `standard` sits on the canvas and follows the scheme; `diagnostic` is the ceremonial black field
    /// with the Expanded type (forced dark).
    public enum Register: Sendable {
        case standard
        case diagnostic
    }

    /// One exact number on the moment.
    public struct Figure: Equatable {
        public var label: String
        public var value: String
        public var unit: String?
        /// Render in `critical` ink (a penalty's cost column).
        public var isCost: Bool

        public init(label: String, value: String, unit: String? = nil, isCost: Bool = false) {
            self.label = label
            self.value = value
            self.unit = unit
            self.isCost = isCost
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
    public var priority: Int
    public var haptic: TelosHaptic?

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
        self.priority = kind.defaultPriority
        self.haptic = kind.defaultHaptic
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
    /// Liquid opacity over the backdrop (tone colour at `fill`), and the meniscus line's.
    public static let liquidOpacity: Double = TelosOpacity.fill
    public static let meniscusOpacity: Double = 0.6
    /// The whole-backdrop tone wash (`criticalWash` for the critical tone).
    public static let washOpacity: Double = TelosOpacity.whisper
    /// Swipe-down dismissal: distance, or predicted distance, past which a release dismisses.
    public static let dismissDistance: CGFloat = 120
    public static let dismissPredictedDistance: CGFloat = 220
    /// Entrance budget (content + fill), after which nothing moves.
    public static let settleBudget: Double = TelosMotion.settleBudget

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
}

// MARK: - Backdrop

/// Full-bleed backdrop: register base, a whisper of the tone over everything, and the liquid rising to
/// `shownFraction` (animated by the caller). `targetFraction` places the 100 % hairline.
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
                if tone == .critical {
                    TelosColor.criticalWash
                } else {
                    tone.color.opacity(TelosMomentStyle.washOpacity)
                }
                // No value → no liquid (never a fill fed from a default).
                if let fraction = shownFraction {
                    Rectangle()
                        .fill(tone.color.opacity(TelosMomentStyle.liquidOpacity))
                        .frame(height: height * TelosMomentStyle.levels(fraction: fraction).level)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(tone.color.opacity(TelosMomentStyle.meniscusOpacity))
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
/// `accessory` is an optional slot below the figures for moments that need a choice (gear chips) or a
/// small instrument; keep it to what the moment is about.
public struct TelosMomentView<Accessory: View>: View {
    private let moment: TelosMoment
    private let onPrimary: (() -> Void)?
    private let onDismiss: () -> Void
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// The standard register follows the ambient scheme; read it so `.environment` can pass it through.
    @Environment(\.colorScheme) private var colorSchemeFallback

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
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            Text(verbatim: figure.label)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(isDiagnostic ? TelosColor.diagMuted : TelosColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                Text(verbatim: figure.value)
                    .telosNumeral(.numeralL)
                    .foregroundStyle(figure.isCost ? TelosColor.critical
                                                   : (isDiagnostic ? TelosColor.diagText : TelosColor.textPrimary))
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
            shownFraction = moment.fill
            withAnimation(TelosMotion.fade) { entered = true }
        } else {
            withAnimation(TelosMotion.screen) { entered = true }
            if let target = moment.fill {
                withAnimation(TelosMotion.flow) { shownFraction = target }
            }
        }
    }
}

public extension TelosMomentView where Accessory == EmptyView {
    init(moment: TelosMoment, onPrimary: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.init(moment: moment, onPrimary: onPrimary, onDismiss: onDismiss, accessory: { EmptyView() })
    }
}
