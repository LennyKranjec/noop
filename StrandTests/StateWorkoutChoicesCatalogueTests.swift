import XCTest
@testable import Strand

/// THE INVARIANT: the "Workouts to suggest" checklist offers every sport the app's own workout picker
/// offers. The picker enumerates `WorkoutCatalog.all` (`WorkoutSelectionScreen.filtered` →
/// `WorkoutCatalog.matching`), and the checklist is built from the SAME list — but it is built in two
/// pieces (a recovery-and-calm group, then the rest), and a filter in that split is exactly the kind of
/// edit that drops a sport silently. A sport added to the catalogue and not visible in the checklist is not
/// suggestable at all, by the coach or by the built-in rules.
///
/// DELIBERATE EXCLUSIONS ARE NAMED HERE, one per line with its reason. That is the point of the test: adding
/// one is a conscious edit to this file, and forgetting one fails loudly instead of the sport vanishing.
final class StateWorkoutChoicesCatalogueTests: XCTestCase {

    /// The only catalogue entries the checklist deliberately does not offer.
    ///
    /// - "Other": the generic bucket the live workout falls back to when nothing was picked
    ///   (`WorkoutCatalog.defaultSportName`). "Suggest something unspecified" is not a suggestion, and a
    ///   ticked box for it would let the coach answer with a sport the tile cannot name or start.
    private static let deliberatelyExcluded: Set<String> = ["Other"]

    func testEverySportThePickerOffersIsInTheChecklist() {
        let offered = Set(WorkoutCatalog.all.map(\.name))
        let checklist = Set(StateWorkoutChoices.options.map(\.key))
        let missing = offered.subtracting(checklist).subtracting(Self.deliberatelyExcluded)
        XCTAssertTrue(missing.isEmpty,
                      "the picker offers these and the checklist does not, so they can never be suggested: "
                      + missing.sorted().joined(separator: ", "))
    }

    /// And the reverse, so the exclusion list cannot rot: everything named as excluded must still BE in the
    /// catalogue and still be absent from the checklist.
    func testTheExclusionListIsStillAccurate() {
        for name in Self.deliberatelyExcluded {
            XCTAssertNotNil(WorkoutCatalog.sport(named: name),
                            "\(name) is no longer in the catalogue — drop it from the exclusion list")
            XCTAssertNil(StateWorkoutChoices.option(forKey: name),
                         "\(name) is now in the checklist — drop it from the exclusion list")
        }
    }

    /// The checklist adds exactly three keys of its own: the recovery VARIANTS the catalogue has no sport
    /// for. Anything else appearing here would be a name the parser could accept and the picker could not
    /// start.
    func testTheOnlyExtraKeysAreTheDocumentedRecoveryVariants() {
        let offered = Set(WorkoutCatalog.all.map(\.name))
        let extra = Set(StateWorkoutChoices.options.map(\.key)).subtracting(offered)
        XCTAssertEqual(extra, [StateWorkoutChoices.nsdrKey, StateWorkoutChoices.breathworkKey,
                               StateWorkoutChoices.restorativeYogaKey])
    }

    /// Each variant is RECORDED as a catalogue sport, so starting one writes a sport the rest of the app —
    /// and the Android lane, through the shared `sport` column — already understands.
    func testEveryVariantIsRecordedAsARealCatalogueSport() {
        for v in StateWorkoutChoices.variants {
            XCTAssertNotNil(WorkoutCatalog.sport(named: v.sport),
                            "\(v.key) is recorded as \(v.sport), which is not a catalogue sport")
        }
        XCTAssertEqual(StateWorkoutChoices.sport(forKey: StateWorkoutChoices.nsdrKey), "Meditation")
        XCTAssertEqual(StateWorkoutChoices.sport(forKey: StateWorkoutChoices.breathworkKey), "Meditation")
        XCTAssertEqual(StateWorkoutChoices.sport(forKey: StateWorkoutChoices.restorativeYogaKey), "Yoga")
    }

    /// The two groups partition the list: no key appears in both, and every key appears in one. A sport that
    /// fell out of the split would be in neither and simply not render.
    func testTheTwoGroupsPartitionTheWholeList() {
        let recovery = StateWorkoutChoices.recoveryOptions.map(\.key)
        let sports = StateWorkoutChoices.sportOptions.map(\.key)
        XCTAssertTrue(Set(recovery).isDisjoint(with: Set(sports)))
        XCTAssertEqual(Set(recovery + sports), Set(StateWorkoutChoices.options.map(\.key)))
        XCTAssertEqual(recovery.count + sports.count, StateWorkoutChoices.options.count,
                       "no key is listed twice")
    }

    /// The sports group keeps the CATALOGUE's own order, which is the order the picker shows (common and
    /// distance sports first). Sorting it alphabetically here would put Archery above Running.
    func testTheSportsGroupKeepsTheCataloguesOrder() {
        let expected = WorkoutCatalog.all.map(\.name)
            .filter { StateWorkoutChoices.option(forKey: $0) != nil }
            .filter { !StateWorkoutChoices.recoveryKeys.contains($0) }
        XCTAssertEqual(StateWorkoutChoices.sportOptions.map(\.key), expected)
    }

    /// THE OTHER HALF OF THE DRIFT RISK. The deterministic fallback picks from hand-written candidate lists
    /// (endurance substitutes, walk, mobility, strength, the down-regulation ladders). Every one of those
    /// names has to resolve to a real checklist key, or that substitute is dead code and the fallback
    /// silently falls through to a worse branch.
    func testEveryFallbackCandidateResolvesToARealChecklistKey() {
        let lists: [(String, [String])] = [
            ("enduranceDefaults", WorkoutSuggestionFallback.enduranceDefaults),
            ("walkKeys", WorkoutSuggestionFallback.walkKeys),
            ("mobilityKeys", WorkoutSuggestionFallback.mobilityKeys),
            ("calmMovementKeys", WorkoutSuggestionFallback.calmMovementKeys),
            ("strengthKeys", WorkoutSuggestionFallback.strengthKeys),
            ("postHardKeys", WorkoutSuggestionFallback.postHardKeys),
            ("morningKeys", WorkoutSuggestionFallback.morningKeys),
            ("calmKeys", WorkoutSuggestionFallback.calmKeys),
            ("windDownKeys", WorkoutSuggestionFallback.windDownKeys),
        ]
        for (name, keys) in lists {
            for key in keys {
                XCTAssertNotNil(StateWorkoutChoices.option(forKey: key),
                                "\(name) names \"\(key)\", which is not a selectable key — that substitute "
                                + "can never be chosen")
            }
        }
    }

    /// With nothing unticked the coach is told about every key, so "only from these" is a closed set the
    /// parser can hold the answer to — and a new catalogue sport is suggestable the day it is added.
    func testAnUnrestrictedSelectionAllowsEveryKey() {
        let all = StateWorkoutChoices.all
        XCTAssertTrue(all.isUnrestricted)
        XCTAssertEqual(all.allowedKeys.count, StateWorkoutChoices.options.count)
        for option in StateWorkoutChoices.options {
            XCTAssertTrue(all.allows(key: option.key), option.key)
        }
        XCTAssertTrue(WorkoutSuggestionWriter.allowedSection(all).contains("Padel"),
                      "the prompt's allowed list is the checklist, so a long-tail sport is named to the model")
    }
}
