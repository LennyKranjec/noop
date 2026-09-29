import XCTest
import StrandAnalytics
@testable import Strand

/// Audit item 2: `ProfileStore.init` silently seeded AND PERSISTED age 30, so there was no "age unknown"
/// state and a never-answered profile was indistinguishable from a wearer who had answered "30". A
/// 45-year-old reinstalling was therefore scored against Tanaka(30) = 187 instead of 176.5 — at 130 bpm they
/// sit in Edwards zone 2 instead of zone 3 across the whole day's integral, plus the wrong VO₂max, fitness
/// age, calories and displayed zones. It also made `AnalyticsEngine`'s `age: profile.age > 0 ? profile.age :
/// nil` guard dead code by construction.
@MainActor
final class AccuracyAuditProfileAgeTests: XCTestCase {

    private static let dobKey = "profile.dateOfBirth"
    private static let ageKey = "profile.age"

    /// THE BUG. Nothing stored → age unknown, nothing written to storage.
    func testFreshProfileHasNoAgeAndWritesNone() throws {
        try withAgeDefaults {
            let profile = ProfileStore()
            XCTAssertFalse(profile.dateOfBirthIsSet)
            XCTAssertEqual(profile.age, 0, "0 is this repo's 'unknown age'; every age > 0 guard honours it")
            XCTAssertNil(profile.ageOrNil)
            XCTAssertNil(UserDefaults.standard.object(forKey: Self.dobKey),
                         "an unanswered profile must not persist a date of birth")
            XCTAssertNil(UserDefaults.standard.object(forKey: Self.ageKey),
                         "…nor the age mirrored from it: a stored 30 IS the bug")
        }
    }

    /// With no age and no override, the HRmax every Effort path resolves through abstains instead of
    /// substituting the age formula's value at age 0 (208 bpm) or a default.
    func testEffortHRmaxAbstainsWhileAgeIsUnknown() throws {
        try withAgeDefaults {
            let profile = ProfileStore()
            XCTAssertNil(profile.effortHRmax,
                         "StrainScorer.effortHRmax returns nil for age ≤ 0 — the caller must honour it")
            XCTAssertNil(StrainScorer.effortHRmax(overrideBpm: nil, age: Double(profile.age)))
        }
    }

    /// A manual Settings override is an answer about HRmax even without an age, so it still resolves.
    func testAnOverrideStillResolvesWithoutAnAge() throws {
        try withAgeDefaults {
            let profile = ProfileStore()
            profile.hrMaxOverride = 191
            XCTAssertEqual(profile.effortHRmax, 191)
        }
    }

    /// Answering ends the unknown state, and the scored HRmax is the answer's — 176.5 for a 45-year-old,
    /// not the 187 the age-30 seed produced.
    func testAnsweringTheDateOfBirthEndsTheUnknownStateAndScoresOnIt() throws {
        try withAgeDefaults {
            let profile = ProfileStore()
            profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: 45)
            XCTAssertTrue(profile.dateOfBirthIsSet)
            XCTAssertEqual(profile.age, 45)
            XCTAssertEqual(try XCTUnwrap(profile.effortHRmax), StrainScorer.tanakaHRmax(age: 45), accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(profile.effortHRmax), 176.5, accuracy: 1e-9)
            XCTAssertNotEqual(try XCTUnwrap(profile.effortHRmax), StrainScorer.tanakaHRmax(age: 30))
            XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.dobKey), "an answer IS persisted")
        }
    }

    /// The #146 migration is untouched: a pre-DOB install carrying only the legacy Int age still derives a
    /// date of birth from it, counts as answered, and persists the derived value.
    func testLegacyStoredAgeStillMigratesAndCountsAsAnswered() throws {
        try withAgeDefaults {
            UserDefaults.standard.set(52, forKey: Self.ageKey)
            let profile = ProfileStore()
            XCTAssertTrue(profile.dateOfBirthIsSet)
            XCTAssertEqual(profile.age, 52)
            XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.dobKey))
        }
    }

    /// The fitness-age readiness gate reads `age > 0`, which was unreachable before: an unanswered profile
    /// now correctly reports not-ready instead of being scored against a substituted 30.
    func testFitnessAgeReadinessRefusesAnUnknownAge() throws {
        try withAgeDefaults {
            let profile = ProfileStore()
            let readiness = FitnessAgeEngine.assessReadiness(
                hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
                rhrDays: 7, activityDays: 7, hasHeightWeight: true, hasWaist: true)
            XCTAssertFalse(readiness.canCompute)
        }
    }

    private func withAgeDefaults(_ body: () throws -> Void) throws {
        let d = UserDefaults.standard
        let keys = [Self.dobKey, Self.ageKey, "profile.hrMaxOverride"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
        }
        for key in keys { d.removeObject(forKey: key) }
        try body()
    }
}
