import Foundation
import Combine
import SwiftUI
import StrandAnalytics

extension Notification.Name {
    /// Posted by `Repository` (main thread) with fresh HR-zone evidence after a refresh; `ProfileStore`
    /// observes it and re-learns its zone HRmax / resting HR. userInfo keys: `HRZoneInputsKey`.
    static let noopHRZoneInputsDidUpdate = Notification.Name("noop.hrZoneInputsDidUpdate")
}

/// userInfo keys of `noopHRZoneInputsDidUpdate`. Values: Double bpm (absent = none) / String raw source.
enum HRZoneInputsKey {
    /// `HRZones.observedZoneHRmax(...)`, absent when too few workouts.
    static let observedHRmax = "observedHRmax"
    /// `HRZones.zoneRestingHR(...).bpm`.
    static let restingHR = "restingHR"
    /// `HRZones.RestingHRSource.rawValue`.
    static let restingHRSource = "restingHRSource"
}

/// User profile (age/sex/body metrics/HR-max) persisted in UserDefaults.
/// Powers HR zones, calories and recovery baselines.
@MainActor
final class ProfileStore: ObservableObject {
    /// Canonical source of truth for age (#146): a date of birth, so age advances on its own instead
    /// of silently going stale until the user remembers to bump a number. `age` is derived from this.
    @Published var dateOfBirth: Date {
        didSet {
            // An assignment is the wearer answering (the Settings / onboarding DatePicker binds straight
            // to this), so the unknown state ends here and not before.
            dateOfBirthIsSet = true
            d.set(dateOfBirth, forKey: K.dateOfBirth)
            // Mirror the DERIVED age under the legacy `profile.age` key so the `.noopbak` backup
            // whitelist (which carries an Int age, not a Date) keeps exporting a correct value with no
            // change to the cross-platform backup contract. `BackupSettings.apply` clears
            // `profile.dateOfBirth` on restore so a restored Int age re-derives the DOB here.
            d.set(age, forKey: K.legacyAge)
        }
    }
    /// Whether ``dateOfBirth`` is the wearer's ANSWER rather than the picker's seed. False on a profile that
    /// has never been asked (a fresh install, a `.noopbak` restore that carried no age), and `age` then
    /// reports 0 — the repo-wide "unknown" for age, which `StrainScorer.effortHRmax`, the Fitness Age
    /// readiness gate and `AnalyticsEngine`'s `profile.age > 0` guard all already honour. Not persisted on
    /// its own: it IS "a stored date of birth (or legacy age) exists".
    @Published private(set) var dateOfBirthIsSet: Bool
    @Published var sex: String { didSet { d.set(sex, forKey: K.sex) } }          // "male" | "female" | "nonbinary"
    @Published var weightKg: Double { didSet { d.set(weightKg, forKey: K.weight) } }
    @Published var heightCm: Double { didSet { d.set(heightCm, forKey: K.height) } }
    /// Optional waist circumference (cm); 0 = not set. Only used to ALSO show an estimated VO₂max
    /// alongside Fitness Age — the Fitness Age itself does not need it (the body term cancels).
    @Published var waistCm: Double { didSet { d.set(waistCm, forKey: K.waist) } }
    /// 0 = auto-estimate from age.
    @Published var hrMaxOverride: Int { didSet { d.set(hrMaxOverride, forKey: K.hrMax) } }
    /// Five personalized inclusive zone starts in BPM; empty = the conventional heart-rate-RESERVE
    /// (Karvonen) zones built from `zoneHRmax` / `zoneRestingHR`.
    @Published var hrZoneThresholds: [Int] {
        didSet {
            if hrZoneThresholds.isEmpty { d.removeObject(forKey: K.hrZoneThresholds) }
            else { d.set(hrZoneThresholds.map(String.init).joined(separator: ","), forKey: K.hrZoneThresholds) }
        }
    }
    /// Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
    /// counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
    /// (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
    /// Clamped IN MEMORY, not only on the way to defaults. The `didSet` used to clamp what it wrote and
    /// leave the published property holding the raw assignment, so an out-of-range value (the calibration
    /// tile's Apply, a Settings edit, a future caller) stayed live for the whole session — and
    /// `IntelligenceEngine` reads this property, not the stored one, to build `UserProfile`. The day totals
    /// divide by it (`AnalyticsEngine`, `DayCycleIntelligenceIntegration`), so the unclamped window was the
    /// one path where a bad divisor could scale a real day toward zero before the next launch re-read and
    /// clamped it. Re-entrant-safe: the guard makes the corrective assignment a no-op second time round.
    @Published var stepTicksPerStep: Double {
        didSet {
            let bounded = Self.clampStepScale(stepTicksPerStep)
            if bounded != stepTicksPerStep { stepTicksPerStep = bounded; return }
            d.set(bounded, forKey: K.stepScale)
            // Any assignment is a CALIBRATION: it comes from the walk tile's Apply, the Settings stepper,
            // or a restore of a value one of those produced. Only the absence of a stored value means
            // "never calibrated" — see `stepTicksPerStepCalibration`.
            if stepTicksPerStepCalibration != bounded { stepTicksPerStepCalibration = bounded }
        }
    }

    /// The step divisor AS EVIDENCE: the calibrated ticks-per-step, or **nil when it has never been
    /// calibrated on this install**.
    ///
    /// `stepTicksPerStep` above cannot express that. It defaults to 1.0, which is raw tick pass-through,
    /// and the counter day total is `ticks ÷ divisor` — so on a strap whose motion counter overcounts (a
    /// WHOOP 5/MG runs up to ~24× per this file's own note) an uncalibrated profile turned 8 000 real steps
    /// into 192 000 and Today rendered it as a MEASURED count: no "est." marker, no confidence, no
    /// calibrate affordance, and (unlike the 4.0 estimate path, which clamps at
    /// `StepsEstimateEngine.maxDailySteps`) no upper bound at all. The compute layer keeps dividing by 1.0
    /// when this is nil — behaviour unchanged, no day is rescored — but every PRESENTATION surface asks
    /// this, not the divisor, so an uncalibrated total is shown as the estimate it is.
    @Published private(set) var stepTicksPerStepCalibration: Double? {
        didSet {
            if let v = stepTicksPerStepCalibration { d.set(v, forKey: K.stepScale) }
            else { d.removeObject(forKey: K.stepScale) }
        }
    }

    /// Whether the @57 counter divisor has ever been calibrated (walk tile or Settings). False = the day
    /// total is raw ticks and must be presented as an estimate.
    var stepCounterCalibrated: Bool { stepTicksPerStepCalibration != nil }

    /// Forget the counter calibration — back to the honest "not calibrated" state (raw pass-through for
    /// compute, "est." everywhere it is shown). Used by the walk tile's Reset when there was nothing to
    /// restore.
    func clearStepTicksPerStepCalibration() {
        // Assign through the published divisor first so observers repaint (its `didSet` re-marks the
        // profile calibrated), then clear — this line is the authoritative one and removes the key.
        stepTicksPerStep = Self.uncalibratedStepDivisor
        stepTicksPerStepCalibration = nil
    }

    /// What the compute layer divides by when no calibration exists: 1.0, i.e. raw ticks straight through.
    /// Named so the "this is not a measurement" reasoning has somewhere to live.
    static let uncalibratedStepDivisor: Double = 1.0

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Written by IntelligenceEngine each analytics pass from the auto-fit against phone steps, and
    // read by the Settings/Steps screen to display + adjust the calibration. `stepsManualCoefficient`
    // is the ONLY user-settable field (0 = auto-fit; > 0 = manual override fed into calibrate()); the
    // other three are fitted outputs, surfaced read-only.
    /// Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine.
    @Published var stepsCalibrationCoefficient: Double { didSet { d.set(stepsCalibrationCoefficient, forKey: K.stepsCoeff) } }
    /// How many calibration days fed the last auto-fit (0 when purely manual / not yet fit).
    @Published var stepsCalibrationSampleDays: Int { didSet { d.set(stepsCalibrationSampleDays, forKey: K.stepsSampleDays) } }
    /// 0–1 trust in the last fit (1.0 for a manual coefficient).
    @Published var stepsCalibrationConfidence: Double { didSet { d.set(stepsCalibrationConfidence, forKey: K.stepsConfidence) } }
    /// True when the persisted coefficient came from the user's manual override, not an auto-fit.
    @Published var stepsCalibrationManual: Bool { didSet { d.set(stepsCalibrationManual, forKey: K.stepsManualFlag) } }
    /// User-set manual coefficient. 0 = auto-fit (nil to the engine); > 0 = manual override.
    @Published var stepsManualCoefficient: Double { didSet { d.set(max(0, stepsManualCoefficient), forKey: K.stepsManualCoeff) } }
    /// #1816: true when the strap has banked ANY motion (gravity samples → `dayMotionIntensity > 0`)
    /// in the calibration scan window. Written by `IntelligenceEngine` on every analytics pass so it
    /// tracks a fresh strap's first sync without a separate query. The Today tile reads this to decide
    /// whether "Need N more days where your phone also counted steps" is the honest caption or a lie:
    /// a step estimate is `motion * coefficient`, so with the motion half missing neither the estimate
    /// nor the fit moves however many phone-counted days the user collects. The caption that names only
    /// the phone half is actively misleading — it sent a field reporter to enter Apple Health steps by
    /// hand expecting calibration to start, which it cannot without strap motion. Twin of Android's
    /// `ProfileStore.stepsHasBankedMotion`.
    @Published var stepsHasBankedMotion: Bool { didSet { d.set(stepsHasBankedMotion, forKey: K.stepsHasMotion) } }

    // ── Dynamic HR-zone inputs (WHOOP-style Karvonen zones) ──────────────────────────────────────
    // LEARNED, never user-set: written by `applyZoneInputs` whenever `Repository.refresh()` publishes new
    // evidence (`Notification.Name.noopHRZoneInputsDidUpdate`), persisted so the zones are right on the
    // next launch before any refresh has run. DISPLAY / TRAINING ZONES ONLY: Effort keeps `hrMax`.
    /// The learned zone HRmax (bpm) as last resolved by `HRZones.learnedZoneHRmax`, incl. its slow decay;
    /// nil until the first refresh. Read through `zoneHRmaxResolved`, which re-floors it at the CURRENT
    /// age formula (so a birthday or DOB edit applies at once).
    @Published private(set) var learnedZoneHRmax: Double? {
        didSet {
            if let learnedZoneHRmax { d.set(learnedZoneHRmax, forKey: K.zoneHRmaxLearned) }
            else { d.removeObject(forKey: K.zoneHRmaxLearned) }
        }
    }
    /// Unix seconds `learnedZoneHRmax` was last evaluated at: the decay clock. Not published.
    private var learnedZoneHRmaxAt: Int? {
        didSet {
            if let learnedZoneHRmaxAt { d.set(learnedZoneHRmaxAt, forKey: K.zoneHRmaxLearnedAt) }
            else { d.removeObject(forKey: K.zoneHRmaxLearnedAt) }
        }
    }
    /// The zones' resting HR (7-night sleep median, else waking RHR); nil until the first refresh, when
    /// `zoneRestingHR` reports the documented 60 bpm fallback.
    @Published private(set) var zoneRestingHRInput: HRZones.ZoneRestingHR? {
        didSet {
            if let r = zoneRestingHRInput {
                d.set(r.bpm, forKey: K.zoneRestingHR)
                d.set(r.source.rawValue, forKey: K.zoneRestingHRSource)
            } else {
                d.removeObject(forKey: K.zoneRestingHR)
                d.removeObject(forKey: K.zoneRestingHRSource)
            }
        }
    }
    /// Token for the `noopHRZoneInputsDidUpdate` observer (app-lifetime; never removed).
    private var zoneInputsObserver: NSObjectProtocol?

    // ── Profile picture (optional, on-device only) ──────────────────────────────────────────────
    /// The user's chosen profile photo as JPEG bytes, or nil for the default SF-Symbol fallback.
    /// LOCAL-ONLY — like every other field here it lives in UserDefaults on this device; NOOP is
    /// fully offline so this is never uploaded anywhere. Always set via ``setAvatar(_:)`` (which
    /// downscales) rather than written directly, so the persisted blob stays small (~256px).
    @Published var avatarImageData: Data? {
        didSet {
            if let avatarImageData { d.set(avatarImageData, forKey: K.avatar) }
            else { d.removeObject(forKey: K.avatar) }
        }
    }

    private let d = UserDefaults.standard
    private enum K {
        static let dateOfBirth = "profile.dateOfBirth"
        /// Pre-#146 age key. No longer the source of truth; kept mirrored from `dateOfBirth` so the
        /// cross-platform `.noopbak` whitelist keeps round-tripping an Int age unchanged.
        static let legacyAge = "profile.age"
        static let sex = "profile.sex", weight = "profile.weightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride"
        static let hrZoneThresholds = "profile.hrZoneThresholds"
        static let stepScale = "profile.stepTicksPerStep"
        static let waist = "profile.waistCm"
        static let stepsCoeff = "profile.stepsCalibrationCoefficient"
        static let stepsSampleDays = "profile.stepsCalibrationSampleDays"
        static let stepsConfidence = "profile.stepsCalibrationConfidence"
        static let stepsManualFlag = "profile.stepsCalibrationManual"
        static let stepsManualCoeff = "profile.stepsManualCoefficient"
        static let stepsHasMotion = "profile.stepsHasBankedMotion"
        static let avatar = "profile.avatarImageData"
        // Learned zone inputs. Deliberately NOT in the `.noopbak` whitelist: they re-learn from the data.
        static let zoneHRmaxLearned = "profile.zoneHRmaxLearned"
        static let zoneHRmaxLearnedAt = "profile.zoneHRmaxLearnedAt"
        static let zoneRestingHR = "profile.zoneRestingHR"
        static let zoneRestingHRSource = "profile.zoneRestingHRSource"
    }

    init() {
        // #146 age migration. `dateOfBirth` is authoritative whenever it exists, so age advances on
        // its own. A pre-#146 install — or a `.noopbak` restore, which writes only the legacy Int age
        // and clears any stale DOB (see `BackupSettings.apply`) — has no DOB yet, so derive one from
        // the stored age. Nothing stored → UNKNOWN (see below). Deliberately NO equality heuristic: a
        // present DOB is never second-guessed against the mirrored age (doing so would re-freeze age
        // every birthday, the exact staleness #146 fixes).
        //
        // NOTHING STORED MEANS UNKNOWN, AND IS NOT WRITTEN DOWN. This used to seed the age-30 date of
        // birth AND persist it, so an install that had never been asked for an age was indistinguishable
        // from a wearer who had answered "30" — there was no "age unknown" state at all. The cost is not
        // cosmetic: a 45-year-old reinstalling was scored against Tanaka(30) = 187 instead of 176.5, so at
        // 130 bpm they sat in Edwards zone 2 instead of zone 3 for the whole day's integral, and every
        // HRmax-derived figure (Effort, VO₂max, fitness age, calories, the displayed zone table) inherited
        // it. It also made `AnalyticsEngine`'s `age: profile.age > 0 ? profile.age : nil` guard dead code
        // by construction. `dateOfBirth` keeps a non-optional seed so the Settings/onboarding DatePicker
        // still has something to show, but `dateOfBirthIsSet` says whether it means anything, `age`
        // answers 0 while it does not, and NOTHING is persisted until the wearer supplies it.
        let storedDOB = d.object(forKey: K.dateOfBirth) as? Date
        let legacyAge = d.object(forKey: K.legacyAge) as? Int
        let resolvedDOB: Date
        if let dob = storedDOB {
            resolvedDOB = dob
        } else if let legacyAge {
            resolvedDOB = Self.dateOfBirth(forAge: legacyAge)
        } else {
            resolvedDOB = Self.dateOfBirth(forAge: Self.unsetAgeSeed)
        }
        dateOfBirth = resolvedDOB
        dateOfBirthIsSet = storedDOB != nil || legacyAge != nil
        // `didSet` doesn't fire for the initial assignment inside `init`, so persist a MIGRATED DOB (an
        // install that only had the legacy Int age) explicitly — otherwise the derived DOB never reaches
        // storage until the user next edits it. A never-answered profile writes nothing at all. Written
        // from the LOCALS (not `self.dateOfBirth`, which Swift forbids reading before every stored
        // property is initialized).
        if storedDOB == nil, legacyAge != nil {
            d.set(resolvedDOB, forKey: K.dateOfBirth)
            d.set(Self.years(from: resolvedDOB, to: Date()), forKey: K.legacyAge)
        }
        sex = d.string(forKey: K.sex) ?? "male"
        weightKg = d.object(forKey: K.weight) as? Double ?? 75
        heightCm = d.object(forKey: K.height) as? Double ?? 178
        waistCm = d.object(forKey: K.waist) as? Double ?? 0
        hrMaxOverride = d.object(forKey: K.hrMax) as? Int ?? 0
        let storedThresholds = d.string(forKey: K.hrZoneThresholds)?
            .split(separator: ",").compactMap { Int($0) } ?? []
        hrZoneThresholds = Self.validZoneThresholds(storedThresholds) ? storedThresholds : []
        // ABSENT KEY = never calibrated. The divisor the compute layer uses stays 1.0 (raw pass-through,
        // no day is rescored); `stepTicksPerStepCalibration` carries the nil that every presentation
        // surface reads. `didSet` doesn't fire in `init`, so nothing is persisted here — which is the
        // point: storing 1.0 would make "never calibrated" look like "calibrated to 1.0".
        let storedStepScale = (d.object(forKey: K.stepScale) as? Double).map(Self.clampStepScale)
        stepTicksPerStep = storedStepScale ?? Self.uncalibratedStepDivisor
        stepTicksPerStepCalibration = storedStepScale
        stepsCalibrationCoefficient = d.object(forKey: K.stepsCoeff) as? Double ?? 0
        stepsCalibrationSampleDays = d.object(forKey: K.stepsSampleDays) as? Int ?? 0
        stepsCalibrationConfidence = d.object(forKey: K.stepsConfidence) as? Double ?? 0
        stepsCalibrationManual = d.object(forKey: K.stepsManualFlag) as? Bool ?? false
        stepsManualCoefficient = max(0, d.object(forKey: K.stepsManualCoeff) as? Double ?? 0)
        stepsHasBankedMotion = d.object(forKey: K.stepsHasMotion) as? Bool ?? false
        avatarImageData = d.data(forKey: K.avatar)
        learnedZoneHRmax = d.object(forKey: K.zoneHRmaxLearned) as? Double
        learnedZoneHRmaxAt = d.object(forKey: K.zoneHRmaxLearnedAt) as? Int
        if let bpm = d.object(forKey: K.zoneRestingHR) as? Double,
           let src = d.string(forKey: K.zoneRestingHRSource).flatMap(HRZones.RestingHRSource.init(rawValue:)) {
            zoneRestingHRInput = HRZones.ZoneRestingHR(bpm: bpm, source: src)
        } else {
            zoneRestingHRInput = nil
        }
        // LAST, once every stored property is initialized (the closure captures `self`). queue: .main so the
        // payload is unpacked on the main thread; the hop into the actor is the BLEManager pattern.
        zoneInputsObserver = NotificationCenter.default.addObserver(
            forName: .noopHRZoneInputsDidUpdate, object: nil, queue: .main
        ) { [weak self] note in
            let observed = note.userInfo?[HRZoneInputsKey.observedHRmax] as? Double
            let rhr = note.userInfo?[HRZoneInputsKey.restingHR] as? Double
            let src = (note.userInfo?[HRZoneInputsKey.restingHRSource] as? String)
                .flatMap(HRZones.RestingHRSource.init(rawValue:)) ?? .fallback
            let resting = HRZones.ZoneRestingHR(bpm: rhr ?? HRZones.defaultZoneRestingHR,
                                                source: rhr == nil ? .fallback : src)
            Task { @MainActor in self?.applyZoneInputs(observedHRmax: observed, restingHR: resting) }
        }
    }

    // MARK: - Profile picture

    /// The profile photo as a SwiftUI `Image`, or nil when none is set (callers fall back to the
    /// `person.crop.circle` SF Symbol). Bridges the stored JPEG bytes through the platform bitmap
    /// type (`NSImage`/`UIImage`) via the shared `Image(platformImage:)` initializer.
    var avatarImage: Image? {
        guard let data = avatarImageData, let img = PlatformImage(data: data) else { return nil }
        return Image(platformImage: img)
    }

    /// Whether a profile photo is set.
    var hasAvatar: Bool { avatarImageData != nil }

    /// Set the profile photo from raw image bytes (e.g. from a `PhotosPicker` / `NSOpenPanel`),
    /// downscaling to a small square so the persisted UserDefaults blob stays tiny. Passing nil
    /// clears it. If downscaling can't decode the bytes, the originals are stored as-is rather than
    /// dropping the user's pick. To remove a photo, pass nil or call ``clearAvatar()``.
    func setAvatar(_ data: Data?) {
        guard let data else { avatarImageData = nil; return }
        // Downscale to ~256px before persisting; fall back to the raw bytes if decoding fails so a
        // valid-but-unusual image still saves rather than silently dropping.
        avatarImageData = AvatarImage.downscaledJPEG(from: data, maxDimension: 256) ?? data
    }

    /// Remove the profile photo (reverts the header / Settings to the default icon).
    func clearAvatar() { avatarImageData = nil }

    /// The manual override to feed into `StepsEstimateEngine.calibrate(_:manualOverride:)`:
    /// nil when 0 (auto-fit), the positive value otherwise.
    var stepsManualOverride: Double? { stepsManualCoefficient > 0 ? stepsManualCoefficient : nil }

    /// Current age in whole years, derived from `dateOfBirth` (#146) rather than a number the user has
    /// to remember to update — or **0 when the wearer has never supplied one** (`dateOfBirthIsSet` false).
    /// Every existing caller (HR zones, calories, Fitness/Body Age) reads this unchanged; 0 is the value
    /// their `age > 0` guards were already written against, so they abstain instead of scoring a 45-year-old
    /// against a substituted 30.
    var age: Int { dateOfBirthIsSet ? Self.years(from: dateOfBirth, to: Date()) : 0 }

    /// Age as evidence: nil when unknown. Prefer this at any call site that can abstain.
    var ageOrNil: Int? { dateOfBirthIsSet ? age : nil }

    /// The date of birth the picker is SEEDED with before the wearer answers. A seed, never a measurement:
    /// `dateOfBirthIsSet` is what tells the two apart.
    static let unsetAgeSeed = 30

    /// Whole years elapsed `from`→`to` (floor — a birthday not yet reached this year doesn't count).
    nonisolated static func years(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.year], from: from, to: to).year ?? 0
    }

    /// A date of birth `age` whole years before today, anchored to today's month/day so the derived
    /// age is exactly `age`. Used to migrate a stored manual age and to seed the DOB picker.
    nonisolated static func dateOfBirth(forAge age: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -age, to: Date()) ?? Date()
    }

    /// Bounds for the DOB picker, matching the old 13...100 age `Stepper` range so a pick can't derive
    /// an out-of-range age.
    nonisolated static var dateOfBirthRange: ClosedRange<Date> {
        dateOfBirth(forAge: 100)...dateOfBirth(forAge: 13)
    }

    /// Tanaka estimate unless overridden. NOTE: with no override and no answered age this still evaluates
    /// the formula at age 0 (208 bpm) — read ``effortHRmax`` instead wherever the caller can abstain.
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded()) }

    /// The HRmax Effort is scored against AS EVIDENCE: the Settings override, else Tanaka from an ANSWERED
    /// age, else **nil**. One resolution for every path (`StrainScorer.effortHRmax`), and the one that is
    /// honest about an unknown age: `age` is 0 until the wearer supplies a date of birth, and the shared
    /// resolver returns nil for age ≤ 0 rather than scoring against a substituted default. Every stored and
    /// live Effort path already routes through that resolver, so they abstain together.
    var effortHRmax: Double? {
        StrainScorer.effortHRmax(overrideBpm: hrMaxOverride > 0 ? Double(hrMaxOverride) : nil,
                                 age: Double(age))
    }

    /// Personalized zone starts after enforcing the same five-value invariant as `HRZones`.
    var customHRZoneLowerBounds: [Double]? {
        guard Self.validZoneThresholds(hrZoneThresholds) else { return nil }
        return hrZoneThresholds.map(Double.init)
    }

    // MARK: - HR zones (display / training; WHOOP-style heart-rate reserve)

    /// The HRmax the ZONES use: the Settings override when set, else the learned value floored at the
    /// CURRENT age formula (Tanaka). NOT the Effort HRmax: `hrMax` above stays override-else-Tanaka so
    /// Effort scoring (Edwards %HRmax) is untouched by what the zones learn.
    var zoneHRmaxResolved: HRZones.ZoneHRmax {
        let formula = HRZones.tanakaMaxHR(age: Double(age))
        let learned: HRZones.ZoneHRmax
        if let l = learnedZoneHRmax, l.isFinite, l > formula {
            learned = HRZones.ZoneHRmax(bpm: l, source: .learned)
        } else {
            learned = HRZones.ZoneHRmax(bpm: formula, source: .ageFormula)
        }
        return HRZones.resolveZoneHRmax(overrideBpm: hrMaxOverride > 0 ? Double(hrMaxOverride) : nil,
                                        learned: learned)
    }

    /// Zone HRmax in whole bpm (what the Settings screen shows and the zones are built from).
    var zoneHRmax: Int { Int(zoneHRmaxResolved.bpm.rounded()) }

    /// The resting HR the zones use (whole bpm is taken in `hrZoneSet`); the 60 bpm fallback until the
    /// first refresh has measured one.
    var zoneRestingHR: HRZones.ZoneRestingHR {
        zoneRestingHRInput ?? HRZones.ZoneRestingHR(bpm: HRZones.defaultZoneRestingHR, source: .fallback)
    }

    /// The single display-zone model used by live HR, workout splits, and haptic coaching: KARVONEN
    /// (%HRR) edges from `zoneHRmax` and `zoneRestingHR`, unless the user set custom boundaries.
    var hrZoneSet: HRZoneSet {
        let source: String
        switch zoneHRmaxResolved.source {
        case .manual: source = "manual"
        case .learned: source = "learned"
        case .ageFormula: source = "tanaka"
        }
        return HRZones.zones(maxHR: Double(zoneHRmax),
                             restingHR: zoneRestingHR.bpm.rounded(),
                             source: source,
                             customLowerBounds: customHRZoneLowerBounds)
    }

    var hasCustomHRZones: Bool { customHRZoneLowerBounds != nil }

    /// Enable by seeding the editor with boundaries that classify integer BPM exactly like the current
    /// heart-rate-reserve zones; disabling removes the override and immediately restores defaults.
    func setCustomHRZonesEnabled(_ enabled: Bool) {
        hrZoneThresholds = enabled
            ? HRZones.defaultLowerBounds(maxHR: Double(zoneHRmax), restingHR: zoneRestingHR.bpm.rounded())
            : []
    }

    /// Feed fresh evidence into the learned zone inputs (called from the `noopHRZoneInputsDidUpdate`
    /// observer; directly callable for tests). `observedHRmax` is `HRZones.observedZoneHRmax(...)` over the
    /// last 180 days of workouts (nil = too few); the learned HRmax rises at once and decays slowly
    /// (`HRZones.learnedZoneHRmax`). Learning runs even while a manual override is set, so clearing the
    /// override lands on an up-to-date value. Only publishes on a real change.
    func applyZoneInputs(observedHRmax: Double?, restingHR: HRZones.ZoneRestingHR, now: Date = Date()) {
        let nowTs = Int(now.timeIntervalSince1970)
        let learned = HRZones.learnedZoneHRmax(age: Double(age), observed: observedHRmax,
                                               previous: learnedZoneHRmax, previousAt: learnedZoneHRmaxAt,
                                               now: nowTs)
        learnedZoneHRmaxAt = nowTs
        if learnedZoneHRmax != learned.bpm { learnedZoneHRmax = learned.bpm }
        // HONOUR THE `.fallback` TAG. `HRZones.zoneRestingHR` reports the documented 60 bpm SUBSTITUTE
        // tagged `.fallback` when nothing was measured. Storing that made a made-up number a learned input
        // — it rode into the persisted zone inputs and the displayed zone table, and it also overwrote a
        // genuinely measured value from an earlier refresh whenever a later one happened to read nothing.
        // A fallback is a read-time placeholder (see `zoneRestingHR`), never an input.
        guard restingHR.source != .fallback else { return }
        if zoneRestingHRInput != restingHR { zoneRestingHRInput = restingHR }
    }

    /// Move one boundary while preserving strict ordering. Neighbour-aware clamps make it impossible
    /// for the stepper to create a gap, overlap, or invalid persisted state.
    func stepHRZoneThreshold(at index: Int, up: Bool) {
        guard hrZoneThresholds.indices.contains(index) else { return }
        var next = hrZoneThresholds
        let floor = index == 0 ? HRZones.customBPMRange.lowerBound : next[index - 1] + 1
        let ceiling = index == next.count - 1 ? HRZones.customBPMRange.upperBound : next[index + 1] - 1
        guard floor <= ceiling else { return }   // no room between neighbours -> no-op (parity w/ Kotlin)
        next[index] = min(max(next[index] + (up ? 1 : -1), floor), ceiling)
        hrZoneThresholds = next
    }

    nonisolated static func validZoneThresholds(_ values: [Int]) -> Bool {
        guard values.count == 5,
              values.allSatisfy(HRZones.customBPMRange.contains) else { return false }
        return zip(values, values.dropFirst()).allSatisfy(<)
    }

    /// Whether the cycle-awareness opt-in applies to this profile (#801). Cycle phase is read from the
    /// MENSTRUAL skin-temperature shift, so the opt-in (the Health card + the Automations toggle) is only
    /// offered to profiles it can apply to and is NOT shown for male profiles. `sex` is the free String
    /// "male" | "female" | "nonbinary"; we gate by excluding "male" (case-insensitive) so any non-male
    /// value, including unrecognised ones, still sees the opt-in rather than being silently excluded.
    var cycleAwarenessApplies: Bool { Self.cycleAwarenessApplies(sex: sex) }

    /// Pure form of ``cycleAwarenessApplies`` for the given `sex` token, so the gate can be unit-tested
    /// without a live store / UserDefaults. `nonisolated` because it is a pure function over its argument
    /// (no actor state), so the gate and its tests can call it from any context.
    nonisolated static func cycleAwarenessApplies(sex: String) -> Bool {
        sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "male"
    }

    /// Whether the cycle-awareness OFFER should be VISIBLE for a profile: eligible by sex AND not hidden
    /// by the user's "not for me" opt-out. `hidden` is USER-controlled and never age-derived — a
    /// respectful hide, not an assumption about menopause. Pure, so the combined gate is unit-testable.
    nonisolated static func cycleAwarenessVisible(sex: String, hidden: Bool) -> Bool {
        cycleAwarenessApplies(sex: sex) && !hidden
    }

    /// Allowed range for the step-calibration divisor (#132). 5/MG straps overcount by
    /// up to ~24×, so the old 4.0 ceiling could never reach the truth.
    static let stepScaleRange: ClosedRange<Double> = 0.5...30.0

    /// The step divisor, forced into ``stepScaleRange``. A non-finite value (NaN from a 0/0 ratio, an
    /// infinity) is NOT clampable — every comparison against NaN is false, so a naive min/max returns NaN
    /// unchanged — and would make the day total NaN, which `Int(_:)` then traps on. It resolves to the 1.0
    /// raw-pass-through default instead, the same value a profile with no stored calibration uses.
    static func clampStepScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, stepScaleRange.lowerBound), stepScaleRange.upperBound)
    }

    /// Variable step for the calibration stepper so high values stay reachable: fine near
    /// the 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat
    /// 0.1 step from 0.5 to 30 would be ~295 taps — unusable.
    /// - `< 2.0` → 0.1   (precision around the default)
    /// - `2.0–5.0` → 0.5
    /// - `≥ 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
    static func stepScaleIncrement(for value: Double) -> Double {
        switch value {
        case ..<2.0: return 0.1
        case ..<5.0: return 0.5
        default: return 1.0
        }
    }

    /// One increment/decrement of the calibration divisor, snapped to the increment grid and
    /// clamped to ``stepScaleRange``. Decrement uses the increment for the *target* band so the
    /// up/down sequence is symmetric at the band boundaries (e.g. 5.0 −1 → 4.0, 4.0 +0.5 → 4.5).
    static func steppedStepScale(_ value: Double, up: Bool) -> Double {
        let delta = up ? stepScaleIncrement(for: value)
                       : stepScaleIncrement(for: value - 0.0001)
        let next = ((value + (up ? delta : -delta)) / delta).rounded() * delta
        return min(max(next, stepScaleRange.lowerBound), stepScaleRange.upperBound)
    }
}
