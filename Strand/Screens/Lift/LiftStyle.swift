#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport

// LiftStyle.swift — the Telos Lift screens' shared look and copy (DESIGN_V2 "VISUAL DIRECTION" + decision 16).
//
// FAUX GLASS, NEVER LIVE BLUR (the performance rule in the visual direction): a translucent token fill, the 1 pt
// luminous gradient hairline (`TelosColor.glassEdge`, brighter top-left) and the faint top glow
// (`TelosColor.glassTopGlow`). No `.ultraThinMaterial` behind the scrolling set table, no stacked shadows — the
// only glow is one `.shadow` on the small, static check button and rest ring.
//
// Tokens only: every colour below is a `TelosColor` name, so the design-system agent's final values flow in.

struct LiftGlass: ViewModifier {
    var radius: CGFloat = TelosRadius.card
    var raised = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(raised ? TelosColor.glassRaised : TelosColor.glassFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(TelosColor.glassTopGlow)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line)
                    }
            }
    }
}

extension View {
    func liftGlass(radius: CGFloat = TelosRadius.card, raised: Bool = false) -> some View {
        modifier(LiftGlass(radius: radius, raised: raised))
    }

    /// The plan editor / exercise sheets in the Telos register: the system Form / List keeps its native editing
    /// behaviour (swipe-to-delete, reorder, steppers), drawn on the canvas ground with the glass-row look and
    /// the bioluminescent tint. Static — no material, no blur.
    func liftFormChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(TelosColor.canvas.ignoresSafeArea())
            .tint(TelosColor.mint)
    }

    /// The small-caps label style (`scale`, wide tracking, tertiary ink) used for column heads and overlines.
    func liftOverline() -> some View {
        self.font(TelosType.scale)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(TelosColor.textTertiary)
    }
}

enum LiftCopy {

    /// "77,5" / "77.5" / "75" — one decimal at most, locale-aware (the progression screen's formatter).
    static func kg(_ value: Double?) -> String {
        guard let value else { return TelosType.absent }
        return StrengthProgressionCopy.kg(value)
    }

    static func e1rm(_ value: Double?) -> String {
        guard let value else { return TelosType.absent }
        return StrengthProgressionCopy.kg(value.rounded())
    }

    static func signedKg(_ value: Double) -> String { StrengthProgressionCopy.signedKg(value) }

    /// "+12 %" / "−8 %" / "—".
    static func percentChange(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return TelosType.absent }
        let pct = Int((fraction * 100).rounded())
        if pct == 0 { return "0 %" }
        return (pct > 0 ? "+" : TelosType.minus) + "\(abs(pct)) %"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return TelosType.absent }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }

    static func setKind(_ kind: LiftSetKind) -> String {
        switch kind {
        case .working: return String(localized: "Working set")
        case .warmup: return String(localized: "Warm-up set")
        case .drop: return String(localized: "Drop set")
        case .failure: return String(localized: "To failure")
        }
    }

    /// The row index column: "1", "2" … for work, "W1" for warm-ups, with a D / F suffix for drop / failure.
    static func rowLabel(kind: LiftSetKind, index: Int) -> String {
        switch kind {
        case .warmup: return "W\(index)"
        case .drop: return "\(index)D"
        case .failure: return "\(index)F"
        case .working: return "\(index)"
        }
    }

    static func muscleName(_ raw: String) -> String {
        guard let group = MuscleGroup(rawValue: raw) else { return raw }
        switch group {
        case .chest: return String(localized: "Chest")
        case .upperBack: return String(localized: "Upper back")
        case .lats: return String(localized: "Lats")
        case .shoulders: return String(localized: "Shoulders")
        case .biceps: return String(localized: "Biceps")
        case .triceps: return String(localized: "Triceps")
        case .forearms: return String(localized: "Forearms")
        case .abs: return String(localized: "Abs")
        case .lowerBack: return String(localized: "Lower back")
        case .glutes: return String(localized: "Glutes")
        case .quadriceps: return String(localized: "Front thigh (quadriceps)")
        case .hamstrings: return String(localized: "Back thigh (hamstrings)")
        case .calves: return String(localized: "Calves")
        }
    }

    /// A glyph for the exercise strip, from the first muscle group the attribution table gives it.
    static func glyph(for exercise: String) -> String {
        switch MuscleAttribution.muscles(for: exercise).first {
        case .chest?, .triceps?, .shoulders?: return "figure.arms.open"
        case .upperBack?, .lats?: return "figure.rower"
        case .biceps?, .forearms?: return "dumbbell.fill"
        case .abs?, .lowerBack?: return "figure.core.training"
        case .quadriceps?, .hamstrings?, .glutes?, .calves?: return "figure.strengthtraining.functional"
        case nil: return "figure.strengthtraining.traditional"
        }
    }

    static func proposalLine(_ p: LiftProposal.Result) -> String? {
        switch p.kind {
        case .progress, .hold, .deload:
            guard let w = p.weightKg, let r = p.reps else {
                if p.kind == .deload { return String(localized: "Stalled — take a lighter session") }
                return nil
            }
            switch p.kind {
            case .progress: return String(localized: "Try \(StrengthProgressionCopy.kgUnit(w)) × \(r)")
            case .hold: return String(localized: "Hold \(StrengthProgressionCopy.kgUnit(w)) × \(r)")
            default: return String(localized: "Deload: \(StrengthProgressionCopy.kgUnit(w)) × \(r)")
            }
        case .none:
            return nil
        }
    }

    static func reason(_ r: LiftProposal.Reason) -> String {
        switch r {
        case .addReps: return String(localized: "one more rep at the same weight (double progression)")
        case .addWeight(let inc): return String(localized: "top of your rep range reached: +\(StrengthProgressionCopy.kgUnit(inc)), back to the bottom of the range")
        case .easyWeek: return String(localized: "easy week in your plan: hold loads")
        case .lowCharge(let c): return String(localized: "Charge \(Int(c.rounded())) today: this can wait")
        case .stalled(let sessions, let days): return String(localized: "no new best in \(sessions) sessions over \(days) days")
        case .tooFewSessions(let have, let need): return String(localized: "\(have) of \(need) sessions needed before a suggestion")
        case .noIncrement: return String(localized: "no weight step in your history to add")
        case .noHistory: return String(localized: "no history for this exercise yet")
        }
    }

    static func achievement(_ a: LiftAchievement) -> (title: String, rule: String, icon: String) {
        switch a {
        case .nightOwl(let h):
            return (String(localized: "Night owl"), String(localized: "Started at \(h):00 or later in the evening (after 21:00)"), "moon.stars.fill")
        case .earlyBird(let h):
            return (String(localized: "Early bird"), String(localized: "Started in the \(h):00 hour (before 07:00)"), "sunrise.fill")
        case .longHaul(let m):
            return (String(localized: "Long haul"), String(localized: "\(m) minutes (90 or more)"), "hourglass")
        case .everySetDone(let n):
            return (String(localized: "Every set done"), String(localized: "All \(n) planned sets checked"), "checkmark.seal.fill")
        case .newRecords(let n):
            return (String(localized: "New records"), String(localized: "\(n) personal records today"), "medal.fill")
        case .weekStreak(let w):
            return (String(localized: "Streak"), String(localized: "\(w) weeks in a row with strength training"), "flame.fill")
        case .sessionMilestone(let n):
            return (String(localized: "Milestone"), String(localized: "Strength session number \(n)"), "star.circle.fill")
        case .templateVolumeBest(let v, let prev):
            return (String(localized: "Most volume"), String(localized: "\(LiftingImporter.groupedKg(v)) kg — best for this day was \(LiftingImporter.groupedKg(prev)) kg"), "chart.bar.fill")
        }
    }
}
#endif
