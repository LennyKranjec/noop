import Foundation

// HealthAbsence.swift — why a number is not there, in one place.
//
// HEALTH_V2 §S1-A.5. Absent is always nil plus a typed reason, rendered as "—" plus one short line. The
// app has ~270 literal dashes with ad-hoc reasons; every NEW 2.0 surface uses this enum instead, so the
// same absence reads the same everywhere. Existing screens are not migrated in 2.0.

/// A typed reason a value is not shown.
public enum HealthAbsence: Equatable, Codable, Sendable {
    /// Nothing was logged for this night or day.
    case notLogged
    /// Fewer nights than the analysis needs.
    case tooFewNights(have: Int, need: Int)
    /// The sensor this needs has never been paired.
    case sensorNotPaired
    /// Steps are a raw pass-through until the wearer calibrates them.
    case stepsUncalibrated
    /// Sleep staging too sparse to use.
    case stagingSparse
    /// No motion evidence for the window.
    case noMotionEvidence
    /// A running trial's results stay sealed until this day.
    case sealedUntil(day: String)
    /// Still calibrating: `days` of `need` collected.
    case calibrating(days: Int, need: Int)
    /// An illness heads-up was raised for this period.
    case illnessFlagged
    /// The habit cannot be separated from the adjustment factors (for example it only ever happens on
    /// weekends), so no estimate is possible.
    case cannotSeparate

    /// The placeholder shown where the value would be.
    public static let dash = "—"

    /// One fixed short line.
    public var text: String {
        switch self {
        case .notLogged:
            return "Not logged"
        case .tooFewNights(let have, let need):
            return "\(have) of \(need) nights so far"
        case .sensorNotPaired:
            return "No sensor paired"
        case .stepsUncalibrated:
            return "Steps not calibrated yet"
        case .stagingSparse:
            return "Too little sleep-stage data"
        case .noMotionEvidence:
            return "No movement data for this window"
        case .sealedUntil(let day):
            return "Sealed until \(day)"
        case .calibrating(let days, let need):
            return "Calibrating (\(days) of \(need) days)"
        case .illnessFlagged:
            return "Possible illness in this period"
        case .cannotSeparate:
            return "Can't be separated from training load, weekends or drift"
        }
    }

    /// The dash and the reason, as one line.
    public var line: String { "\(HealthAbsence.dash) \(text)" }
}
