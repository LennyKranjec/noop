import XCTest
import StrandAnalytics
@testable import Strand

/// The STATE tile's pure half: the coach's workout JSON read defensively, the deterministic fallback,
/// the refresh throttle, and what a tap on a recommendation routes to.
final class StateCoachTests: XCTestCase {

    // MARK: - Parser

    func testParsesTheDocumentedShape() throws {
        let raw = #"{"workouts":[{"sport":"Running","minutes":40,"zone":2,"effort":12,"window":"17:00-18:00","why":"Base."},{"sport":"Yoga","minutes":20,"zone":1,"effort":2,"window":"20:00-21:00","why":"Calm."}]}"#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], WorkoutSuggestion(sport: "Running", minutes: 40, zone: 2, effort: 12,
                                                 window: "17:00-18:00", why: "Base."))
        XCTAssertEqual(out[1].sport, "Yoga")
        XCTAssertEqual(out[1].zone, 1)
    }

    func testToleratesFencesProseAndABareArray() throws {
        let raw = """
        Here you go:
        ```json
        [{"sport": "cycling", "minutes": 45, "zone": 2, "why": "Easy spin."}]
        ```
        Have fun!
        """
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].sport, "Cycling", "a catalogue match takes the catalogue's spelling")
        XCTAssertEqual(out[0].minutes, 45)
        XCTAssertNil(out[0].effort)
        XCTAssertNil(out[0].window)
    }

    func testReadsNumbersAndZonesWrittenAsText() throws {
        let raw = #"{"workouts":[{"activity":"run","duration":"40 min","zone":"Z3","effort_gain":"15","time":"18:00","reason":"Tempo."}]}"#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out[0].sport, "Running", "alias")
        XCTAssertEqual(out[0].minutes, 40)
        XCTAssertEqual(out[0].zone, 3)
        XCTAssertEqual(out[0].effort, 15)
        XCTAssertEqual(out[0].window, "18:00")
        XCTAssertEqual(out[0].why, "Tempo.")
    }

    func testZoneRangeTakesTheFirstZoneNamed() {
        XCTAssertEqual(WorkoutSuggestionParser.zoneNumber("Z1-Z2"), 1)
        XCTAssertEqual(WorkoutSuggestionParser.zoneNumber("zone 4"), 4)
        XCTAssertNil(WorkoutSuggestionParser.zoneNumber("Z9"))
        XCTAssertNil(WorkoutSuggestionParser.zoneNumber(NSNumber(value: 7)))
        XCTAssertEqual(WorkoutSuggestionParser.zoneNumber(NSNumber(value: 2)), 2)
    }

    func testClampsOutOfRangeValues() throws {
        let raw = #"{"workouts":[{"sport":"Rowing","minutes":500,"zone":9,"effort":250,"why":"x"},{"sport":"Walking","minutes":1,"zone":1,"effort":-4,"why":"y"}]}"#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out[0].minutes, 180)
        XCTAssertEqual(out[0].zone, 2, "an unreadable zone falls back to 2")
        XCTAssertEqual(out[0].effort, 100)
        XCTAssertEqual(out[1].minutes, 5)
        XCTAssertEqual(out[1].effort, 0)
    }

    func testCapsAtThreeDropsDuplicatesAndSkipsItemsWithoutASport() throws {
        let raw = #"""
        {"workouts":[
          {"sport":"Running","minutes":30,"zone":2,"why":"a"},
          {"sport":"running","minutes":50,"zone":2,"why":"duplicate"},
          {"minutes":20,"zone":1,"why":"no sport"},
          {"sport":"Cycling","minutes":40,"zone":2,"why":"b"},
          {"sport":"HIIT","minutes":20,"zone":4,"why":"c"},
          {"sport":"Yoga","minutes":20,"zone":1,"why":"d"}
        ]}
        """#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out.map(\.sport), ["Running", "Cycling", "HIIT"])
    }

    func testABraceInsideAStringDoesNotEndTheObject() throws {
        let raw = #"{"workouts":[{"sport":"Walking","minutes":20,"zone":1,"why":"Easy } walk ] after dinner"}]} trailing"#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out[0].why, "Easy } walk ] after dinner")
    }

    func testTypographicQuotesAreRepairedOnlyAsASecondChance() throws {
        let raw = "{\u{201C}workouts\u{201D}:[{\u{201C}sport\u{201D}:\u{201C}Walking\u{201D},\u{201C}minutes\u{201D}:20,\u{201C}zone\u{201D}:1}]}"
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out[0].sport, "Walking")
    }

    func testUnusableRepliesReturnNil() {
        XCTAssertNil(WorkoutSuggestionParser.parse(""))
        XCTAssertNil(WorkoutSuggestionParser.parse("Sorry, I can't help with that."))
        XCTAssertNil(WorkoutSuggestionParser.parse(#"{"workouts":[]}"#))
        XCTAssertNil(WorkoutSuggestionParser.parse(#"{"workouts":[{"minutes":20}]}"#))
        XCTAssertNil(WorkoutSuggestionParser.parse(#"{"workouts":[{"sport":"Run""#), "unterminated JSON")
    }

    func testNumberReadsTheFirstNumberInAString() {
        XCTAssertEqual(WorkoutSuggestionParser.number("30-45 min"), 30)
        XCTAssertEqual(WorkoutSuggestionParser.number("about 12.5 points"), 12.5)
        XCTAssertEqual(WorkoutSuggestionParser.number("40."), 40)
        XCTAssertNil(WorkoutSuggestionParser.number("none"))
    }

    // MARK: - Fallback

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func fact(_ sport: String, hoursAgo: Double, effort: Double? = nil,
                      zones: [Double]? = nil) -> StateWorkoutFact {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        return StateWorkoutFact(sport: sport, start: start, end: start.addingTimeInterval(2400),
                                durationMin: 40, avgHr: 140, maxHr: 165, effort: effort, zoneMinutes: zones)
    }

    private func assertSane(_ out: [WorkoutSuggestion], hour: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(out.isEmpty, file: file, line: line)
        XCTAssertLessThanOrEqual(out.count, 3, file: file, line: line)
        for s in out {
            XCTAssertTrue((1...5).contains(s.zone), file: file, line: line)
            XCTAssertTrue(WorkoutSuggestionParser.minutesRange.contains(s.minutes), file: file, line: line)
            if let w = s.window, let startHour = Int(w.prefix(2)) {
                XCTAssertGreaterThan(startHour, hour, "a window must lie later today: \(w)", file: file, line: line)
            }
        }
    }

    func testLateEveningSuggestsOnlyMobility() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 90, effortNow: 10, effortTarget: 70),
            hour: 22, today: [], recent: [], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].zone, 1)
        XCTAssertEqual(out[0].sport, "Stretching")
    }

    func testTargetReachedSuggestsOnlyZoneOne() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 90, effortNow: 71, effortTarget: 70),
            hour: 15, today: [], recent: [], now: now)
        assertSane(out, hour: 15)
        XCTAssertTrue(out.allSatisfy { $0.zone == 1 })
    }

    func testLowChargeSuggestsRecoveryOnly() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 20, effortNow: 5, effortTarget: 40),
            hour: 9, today: [], recent: [], now: now)
        assertSane(out, hour: 9)
        XCTAssertTrue(out.allSatisfy { $0.zone <= 2 })
        XCTAssertTrue(out.allSatisfy { $0.lockZone == nil })
    }

    func testStrainedBodySuggestsRecoveryEvenWithHighCharge() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 5, effortTarget: 70, sleepDebtMin: 180),
            hour: 9, today: [], recent: [], now: now)
        XCTAssertTrue(out.allSatisfy { $0.zone == 1 })
    }

    func testHighChargeFarBelowTargetOffersIntervalsAndEnduranceInTheWearersSport() {
        let recent = [fact("Cycling", hoursAgo: 50, effort: 40), fact("Cycling", hoursAgo: 100, effort: 35),
                      fact("Running", hoursAgo: 150, effort: 30)]
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 10, effortTarget: 70),
            hour: 13, today: [], recent: recent, now: now)
        assertSane(out, hour: 13)
        XCTAssertTrue(out.contains { $0.zone == 4 && $0.sport == "Cycling" })
        XCTAssertTrue(out.contains { $0.zone == 2 && $0.sport == "Cycling" })
        XCTAssertEqual(out.first { $0.zone == 4 }?.lockZone, 4)
    }

    func testAHardSessionTodayRulesOutIntervals() {
        let today = [fact("Running", hoursAgo: 3, effort: 70, zones: [5, 10, 10, 12, 4])]
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 40, effortTarget: 80),
            hour: 12, today: today, recent: [], now: now)
        assertSane(out, hour: 12)
        XCTAssertFalse(out.contains { $0.zone >= 4 })
    }

    func testModerateChargeSuggestsZoneTwoSizedToTheRemainingEffort() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 8, today: [], recent: [], now: now)
        assertSane(out, hour: 8)
        let z2 = out.first { $0.zone == 2 }
        XCTAssertEqual(z2?.sport, "Running", "no history → Running")
        // 14 remaining / 0.35 per minute = 40 min.
        XCTAssertEqual(z2?.minutes, 40)
        XCTAssertEqual(z2?.effort, 14)
    }

    func testUnknownFiguresStillProduceSuggestions() {
        let out = WorkoutSuggestionFallback.suggest(figures: StateTrainingFigures(), hour: 13,
                                                    today: [], recent: [], now: now)
        assertSane(out, hour: 13)
    }

    func testMinutesRoundsToFiveAndClamps() {
        XCTAssertEqual(WorkoutSuggestionFallback.minutes(for: 14, zone: 2, range: 20...60), 40)
        XCTAssertEqual(WorkoutSuggestionFallback.minutes(for: 1, zone: 2, range: 20...60), 20)
        XCTAssertEqual(WorkoutSuggestionFallback.minutes(for: 500, zone: 2, range: 20...60), 60)
    }

    func testWindowStartsAfterNowAndStaysInTheDay() {
        XCTAssertEqual(WorkoutSuggestionFallback.window(hour: 9, preferredStart: 16), "16:00–18:00")
        XCTAssertEqual(WorkoutSuggestionFallback.window(hour: 17, preferredStart: 11), "18:00–20:00")
        XCTAssertEqual(WorkoutSuggestionFallback.window(hour: 20, preferredStart: 11), "21:00–22:00")
    }

    func testPreferredEnduranceSportIgnoresStrengthAndRecovery() {
        let recent = [fact("Strength", hoursAgo: 20), fact("Strength", hoursAgo: 40), fact("Strength", hoursAgo: 60),
                      fact("Meditation", hoursAgo: 30), fact("Rowing", hoursAgo: 70)]
        XCTAssertEqual(WorkoutSuggestionFallback.preferredEnduranceSport(recent: recent), "Rowing")
        XCTAssertEqual(WorkoutSuggestionFallback.preferredEnduranceSport(recent: []), "Running")
    }

    func testZoneOneIsNeverLocked() {
        let s = WorkoutSuggestion(sport: "Walking", minutes: 20, zone: 1, effort: nil, window: nil, why: "")
        XCTAssertNil(s.lockZone)
        XCTAssertEqual(WorkoutSuggestion(sport: "Running", minutes: 20, zone: 3, effort: nil, window: nil, why: "").lockZone, 3)
    }

    // MARK: - Recovery variants and the wearer's selection

    func testParserReadsRecoveryVariantsAsTheirActivity() throws {
        let raw = #"""
        {"workouts":[
          {"sport":"NSDR","minutes":20,"zone":1,"why":"a"},
          {"sport":"Yoga Nidra","minutes":15,"zone":1,"why":"same thing"},
          {"sport":"Restorative Yoga","minutes":20,"zone":1,"why":"b"},
          {"sport":"box breathing","minutes":10,"zone":1,"why":"c"}
        ]}
        """#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out.map(\.label), ["NSDR", "Restorative yoga", "Breathwork"], "yoga nidra is NSDR: one, not two")
        XCTAssertEqual(out.map(\.sport), ["Meditation", "Yoga", "Meditation"], "recorded as the existing activity")
        XCTAssertTrue(out.allSatisfy { $0.isRecovery && $0.lockZone == nil })
    }

    func testNSDRAndAPlainMeditationAreTwoSuggestions() throws {
        let raw = #"{"workouts":[{"sport":"Meditation","minutes":10,"zone":1},{"sport":"NSDR","minutes":20,"zone":1}]}"#
        let out = try XCTUnwrap(WorkoutSuggestionParser.parse(raw))
        XCTAssertEqual(out.count, 2)
    }

    func testSelectionFiltersSuggestions() {
        let choices = StateWorkoutChoices(excluded: ["Running", "NSDR"])
        let items = [
            WorkoutSuggestion(sport: "Running", minutes: 30, zone: 2, effort: nil, window: nil, why: ""),
            WorkoutSuggestion(sport: "Cycling", minutes: 30, zone: 2, effort: nil, window: nil, why: ""),
            WorkoutSuggestion(sport: "Meditation", minutes: 20, zone: 1, effort: nil, window: nil, why: "", label: "NSDR"),
            WorkoutSuggestion(sport: "Meditation", minutes: 10, zone: 1, effort: nil, window: nil, why: ""),
            WorkoutSuggestion(sport: "Parkour", minutes: 30, zone: 2, effort: nil, window: nil, why: ""),
        ]
        let kept = choices.filter(items)
        XCTAssertEqual(kept.map(\.choiceKey), ["Cycling", "Meditation"],
                       "disallowed dropped; NSDR is excluded on its own key; free text needs an unrestricted selection")
        XCTAssertEqual(StateWorkoutChoices.all.filter(items).count, items.count, "the default allows everything")
    }

    func testSelectionListCoversTheCatalogueAndRecoveryFirst() {
        let keys = StateWorkoutChoices.options.map(\.key)
        XCTAssertEqual(Array(keys.prefix(StateWorkoutChoices.recoveryKeys.count)), StateWorkoutChoices.recoveryKeys)
        for sport in WorkoutCatalog.all where sport.name != "Other" {
            XCTAssertTrue(keys.contains(sport.name), "\(sport.name) must be selectable")
        }
        XCTAssertEqual(Set(keys).count, keys.count, "no key twice")
        XCTAssertTrue(StateWorkoutChoices.all.isUnrestricted)
        XCTAssertEqual(StateWorkoutChoices.all.signature, "all")
        let a = StateWorkoutChoices(excluded: ["Running", "HIIT"])
        XCTAssertEqual(a.signature, StateWorkoutChoices(excluded: ["HIIT", "Running"]).signature, "order-free, stable")
        XCTAssertNotEqual(a.signature, "all")
    }

    func testSelectionPersists() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "StateCoachTests.choices"))
        d.removePersistentDomain(forName: "StateCoachTests.choices")
        XCTAssertEqual(StateWorkoutChoicesStore.read(d), StateWorkoutChoices.all, "default: everything allowed")
        StateWorkoutChoicesStore.write(StateWorkoutChoices(excluded: ["HIIT"]), d)
        XCTAssertEqual(StateWorkoutChoicesStore.read(d).excluded, ["HIIT"])
        d.removePersistentDomain(forName: "StateCoachTests.choices")
    }

    func testFingerprintChangesWithTheSelection() {
        let a = WorkoutSuggestionStore.fingerprint(today: [], choices: .all)
        let b = WorkoutSuggestionStore.fingerprint(today: [], choices: StateWorkoutChoices(excluded: ["Running"]))
        XCTAssertNotEqual(a, b)
    }

    func testFallbackOnlyPicksAllowedSportsWithSubstitutes() {
        let recent = [fact("Running", hoursAgo: 50, effort: 40), fact("Running", hoursAgo: 100, effort: 35)]
        let choices = StateWorkoutChoices(excluded: ["Running", "Walking", "NSDR"])
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 10, effortTarget: 70),
            hour: 13, today: [], recent: recent, now: now, choices: choices)
        assertSane(out, hour: 13)
        XCTAssertTrue(out.allSatisfy { choices.allows($0) }, "\(out.map(\.choiceKey))")
        XCTAssertTrue(out.contains { $0.sport == "Cycling" && $0.zone == 4 }, "the first allowed endurance sport stands in")
        XCTAssertTrue(out.contains { $0.label == "Restorative yoga" }, "the next allowed recovery stands in for NSDR")
    }

    func testFallbackWithOnlyOneOtherSportAllowed() {
        let only = StateWorkoutChoices(excluded: Set(StateWorkoutChoices.options.map(\.key)).subtracting(["Tennis"]))
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 13, today: [], recent: [], now: now, choices: only)
        XCTAssertEqual(out.map(\.sport), ["Tennis"])
        XCTAssertEqual(out.first?.zone, 2)
    }

    func testFallbackIsEmptyWhenNothingIsAllowed() {
        let none = StateWorkoutChoices(excluded: Set(StateWorkoutChoices.options.map(\.key)))
        XCTAssertTrue(none.allowedKeys.isEmpty)
        for hour in [8, 13, 22] {
            XCTAssertTrue(WorkoutSuggestionFallback.suggest(
                figures: StateTrainingFigures(charge: 70, effortNow: 10, effortTarget: 60),
                hour: hour, today: [], recent: [], now: now, choices: none).isEmpty, "hour \(hour)")
        }
    }

    // MARK: - Stress: recovery blocks and the day's order

    func testAHardSessionTodayEarnsARecoveryBlockNext() throws {
        let today = [fact("Running", hoursAgo: 2, effort: 70, zones: [5, 10, 10, 12, 4])]
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 40, effortTarget: 80),
            hour: 12, today: today, recent: [], now: now)
        assertSane(out, hour: 12)
        let rec = try XCTUnwrap(out.first { $0.label == "NSDR" })
        XCTAssertEqual(rec.sport, "Meditation", "tapping starts a Meditation session, like the meditation card's play button")
        XCTAssertEqual(rec.zone, 1)
        XCTAssertEqual(rec.window, "13:00–14:00")
        XCTAssertEqual(out.first?.label, "NSDR", "the recovery block is the next thing in the day")
    }

    func testNoRecoveryBlockWhenOneAlreadyFollowedTheHardSession() {
        let today = [fact("Running", hoursAgo: 2, effort: 70), fact("Meditation", hoursAgo: 0.5)]
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 40, effortTarget: 80),
            hour: 12, today: today, recent: [], now: now)
        XCTAssertFalse(out.contains { $0.label == "NSDR" })
    }

    func testSuggestedIntervalsAreFollowedByARecoveryBlock() throws {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 85, effortNow: 10, effortTarget: 70),
            hour: 13, today: [], recent: [], now: now)
        let intervals = try XCTUnwrap(out.first { $0.zone == 4 })
        XCTAssertEqual(intervals.window, "16:00–18:00")
        XCTAssertEqual(intervals.minutes, 40)
        let rec = try XCTUnwrap(out.first { $0.isRecovery })
        // 16:00 + 40 min of intervals + 30 min.
        XCTAssertEqual(rec.window, "17:10–17:40")
        XCTAssertEqual(rec.label, "NSDR")
    }

    func testMorningStartsWithAShortMeditation() throws {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 8, today: [], recent: [], now: now)
        assertSane(out, hour: 8)
        let first = try XCTUnwrap(out.first)
        XCTAssertEqual(first.sport, "Meditation")
        XCTAssertNil(first.label)
        XCTAssertEqual(first.window, "09:00–10:00")
        XCTAssertTrue(out.contains { $0.zone == 2 }, "the training still has its place")

        let noMeditation = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 8, today: [], recent: [], now: now, choices: StateWorkoutChoices(excluded: ["Meditation"]))
        XCTAssertEqual(noMeditation.first?.label, "Breathwork", "breathwork stands in")

        let afternoon = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 14, today: [], recent: [], now: now)
        XCTAssertFalse(afternoon.contains { $0.sport == "Meditation" }, "only in the morning")

        let alreadySat = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 55, effortNow: 30, effortTarget: 44),
            hour: 8, today: [fact("Meditation", hoursAgo: 1)], recent: [], now: now)
        XCTAssertFalse(alreadySat.contains { $0.sport == "Meditation" }, "not twice")
    }

    func testHighStressPutsDownRegulationFirst() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 60, effortNow: 10, effortTarget: 50, stress: 2.7),
            hour: 14, today: [], recent: [], now: now)
        assertSane(out, hour: 14)
        XCTAssertTrue(out.contains { $0.label == "Breathwork" })
        XCTAssertTrue(out.allSatisfy { $0.zone == 1 }, "high stress: nothing above Zone 1")

        let moderate = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 60, effortNow: 10, effortTarget: 50, stress: 2.1),
            hour: 14, today: [], recent: [], now: now)
        XCTAssertTrue(moderate.contains { $0.label == "Breathwork" }, "elevated stress still earns a downshift")
    }

    func testLateEveningRespectsTheSelection() {
        let out = WorkoutSuggestionFallback.suggest(
            figures: StateTrainingFigures(charge: 90, effortNow: 10, effortTarget: 70),
            hour: 22, today: [], recent: [], now: now, choices: StateWorkoutChoices(excluded: ["Stretching"]))
        XCTAssertEqual(out.map(\.label), ["Restorative yoga"])
    }

    func testStartMinuteReadsCommonWindowShapes() {
        XCTAssertEqual(WorkoutSuggestionFallback.startMinute(of: "17:10–17:40"), 17 * 60 + 10)
        XCTAssertEqual(WorkoutSuggestionFallback.startMinute(of: "18:00"), 18 * 60)
        XCTAssertEqual(WorkoutSuggestionFallback.startMinute(of: "7-8"), 7 * 60)
        XCTAssertNil(WorkoutSuggestionFallback.startMinute(of: "after work"))
        XCTAssertNil(WorkoutSuggestionFallback.startMinute(of: nil))
    }

    // MARK: - Prompts

    func testWorkoutPromptCarriesTheAllowedListAndTheStressObjective() {
        let choices = StateWorkoutChoices(excluded: ["Running", "HIIT"])
        let prompt = WorkoutSuggestionWriter.systemPrompt(grounding: "GROUNDING", choices: choices)
        XCTAssertTrue(prompt.contains("Only suggest from this list"))
        let allowed = WorkoutSuggestionWriter.allowedSection(choices)
        XCTAssertTrue(allowed.contains("Cycling"))
        XCTAssertTrue(allowed.contains("NSDR"))
        XCTAssertTrue(allowed.contains("Restorative yoga"))
        XCTAssertFalse(allowed.contains("Running"))
        XCTAssertFalse(allowed.contains("HIIT"))
        XCTAssertTrue(prompt.contains(allowed))
        XCTAssertTrue(prompt.contains("KEEP THE USER'S STRESS LOW"))
        XCTAssertTrue(prompt.contains("30-90 minutes after"))
        XCTAssertTrue(prompt.contains("soon after waking"))
        XCTAssertTrue(prompt.contains("never in the past"))
        XCTAssertTrue(prompt.hasSuffix("GROUNDING"))
    }

    func testPromptWithNothingAllowedAsksForAnEmptyList() {
        let none = StateWorkoutChoices(excluded: Set(StateWorkoutChoices.options.map(\.key)))
        XCTAssertTrue(WorkoutSuggestionWriter.allowedSection(none).contains(#"{"workouts":[]}"#))
    }

    func testMissionObjectiveCarriesStressAndTheSelection() {
        let open = StateDayPlanContext.missionObjective(choices: .all)
        XCTAssertTrue(open.contains("KEEP THE USER'S STRESS LOW"))
        XCTAssertTrue(open.contains("MEDITATION_MIN"))
        XCTAssertFalse(open.contains("pick it only from"))
        let restricted = StateDayPlanContext.missionObjective(choices: StateWorkoutChoices(excluded: ["Running"]))
        XCTAssertTrue(restricted.contains("pick it only from"))
    }

    func testDayPlanBlockNamesTheWindows() throws {
        let cal = Calendar.current
        let at = try XCTUnwrap(cal.date(bySettingHour: 8, minute: 15, second: 0, of: now))
        let block = StateDayPlanContext.block(now: at, schedule: .fallback, calendar: cal)
        XCTAssertTrue(block.contains("Time now: 08:15 (focus / active day)"))
        XCTAssertTrue(block.contains("Wake: 07:00. Bedtime: 22:30"))
        XCTAssertTrue(block.contains("07:00–07:30"), "morning start-up")
        XCTAssertTrue(block.contains("07:30–21:00"), "focus window up to the wind-down")
        XCTAssertTrue(block.contains("21:00–22:30"), "wind-down")

        let evening = try XCTUnwrap(cal.date(bySettingHour: 21, minute: 30, second: 0, of: now))
        XCTAssertTrue(StateDayPlanContext.block(now: evening, schedule: .fallback, calendar: cal)
            .contains("Time now: 21:30 (wind-down)"))
    }

    // MARK: - Throttle

    func testThrottleAllowsOneRefreshPerInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var throttle = RefreshThrottle(minInterval: 20)
        XCTAssertTrue(throttle.allows(at: t0))
        XCTAssertTrue(throttle.tryStart(at: t0))
        XCTAssertFalse(throttle.tryStart(at: t0.addingTimeInterval(5)))
        XCTAssertEqual(throttle.remaining(at: t0.addingTimeInterval(5)), 15, accuracy: 0.001)
        XCTAssertFalse(throttle.tryStart(at: t0.addingTimeInterval(19.9)))
        XCTAssertEqual(throttle.lastStart, t0, "a rejected attempt records nothing")
        XCTAssertTrue(throttle.tryStart(at: t0.addingTimeInterval(20)))
        XCTAssertEqual(throttle.lastStart, t0.addingTimeInterval(20))
    }

    func testThrottleDoesNotLockWhenTheClockMovesBackwards() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var throttle = RefreshThrottle(minInterval: 20)
        XCTAssertTrue(throttle.tryStart(at: t0))
        XCTAssertEqual(throttle.remaining(at: t0.addingTimeInterval(-3600)), 0)
        XCTAssertTrue(throttle.tryStart(at: t0.addingTimeInterval(-3600)))
    }

    // MARK: - Tap routing

    func testDeficitsRouteToTheirInAppActions() {
        XCTAssertEqual(StateActionMapper.action(for: .hydration), .hydration)
        XCTAssertEqual(StateActionMapper.action(for: .stress), .breathe)
        XCTAssertEqual(StateActionMapper.action(for: .sleepDebt), .sleep)
        XCTAssertEqual(StateActionMapper.action(for: .training), .pickWorkout)
        XCTAssertEqual(StateActionMapper.action(for: .steps), .startWorkout(sport: "Walking", zone: nil))
        XCTAssertEqual(StateActionMapper.action(for: .protein), .detail)
    }

    func testMissionGoalRoutes() {
        func goal(_ m: QuestMetric) -> QuestGoal { QuestGoal(metric: m, threshold: 1) }
        XCTAssertEqual(StateActionMapper.action(forGoal: goal(.waterMl)), .hydration)
        XCTAssertEqual(StateActionMapper.action(forGoal: goal(.meditationMinutes)), .breathe)
        XCTAssertEqual(StateActionMapper.action(forGoal: goal(.bedtimeBy)), .sleep)
        XCTAssertEqual(StateActionMapper.action(forGoal: goal(.journal)), .journal)
        XCTAssertEqual(StateActionMapper.action(forGoal: goal(.workoutMinutes)), .pickWorkout)
        XCTAssertEqual(StateActionMapper.action(forGoal: nil), .detail)
    }

    func testDeficitRecommendationCarriesItsTextAndAPrompt() {
        let d = DayDeficit(kind: .protein, text: "Protein: 40 of 120 g", severity: 0.6)
        let rec = StateActionMapper.recommendation(for: d)
        XCTAssertEqual(rec.title, "Protein: 40 of 120 g")
        XCTAssertEqual(rec.action, .detail)
        XCTAssertTrue(rec.askCoachPrompt.contains("Protein: 40 of 120 g"))
        XCTAssertFalse(rec.rationale.isEmpty)
    }

    // MARK: - Coach grounding

    func testTrainingBlockCarriesTargetZonesAndTodaysWorkouts() {
        let today = [fact("Running", hoursAgo: 4, effort: 41, zones: [3, 20, 15, 6, 1])]
        let recent = [fact("Cycling", hoursAgo: 30, effort: 65)]
        let block = StateTrainingContext.block(
            figures: StateTrainingFigures(charge: 71, effortNow: 34, effortTarget: 62, sleepDebtMin: 90,
                                          stress: 1.2, hrvDeltaPct: 12, rhrDeltaBpm: -2),
            zones: [HRZoneBPMRange(zone: 1, lower: 120, upper: 133), HRZoneBPMRange(zone: 2, lower: 134, upper: 147)],
            today: today, recent: recent)
        XCTAssertTrue(block.contains("remaining to target: 28"))
        XCTAssertTrue(block.contains("Z1 120-133, Z2 134-147"))
        XCTAssertTrue(block.contains("Running"))
        XCTAssertTrue(block.contains("zones Z1 3m Z2 20m Z3 15m Z4 6m Z5 1m"))
        XCTAssertTrue(block.contains("HRV last night vs 30-day median: +12%"))
        XCTAssertTrue(block.contains("Most recent hard session"))
    }

    func testLatestVsBaselineNeedsFiveValues() {
        XCTAssertNil(StateTrainingContext.latestVsBaseline([50, 52, 54, 60]))
        let r = StateTrainingContext.latestVsBaseline([50, 52, 54, 56, 60])
        XCTAssertEqual(r?.latest, 60)
        XCTAssertEqual(r?.baseline, 53)
    }

    func testFingerprintChangesWithTodaysWorkouts() {
        let a = WorkoutSuggestionStore.fingerprint(today: [])
        let b = WorkoutSuggestionStore.fingerprint(today: [fact("Running", hoursAgo: 1)])
        XCTAssertNotEqual(a, b)
    }
}
