import XCTest
import StrandAnalytics
import StrandImport
@testable import Strand

/// The muscle-load note the wearer called "dumb". Two defects, both in the prompt: the volume table carried
/// no dates and no unit, so the note said "this week" about figures nobody could place; and with almost no
/// lifting history the model was still ordered to name the group that "most needs attention" and to say why
/// its figure made it that group — with nothing to compare against, which is a demand to bluff.
final class MuscleCoachNotePromptTests: XCTestCase {

    private func baseline(mean: Double, sd: Double) -> MuscleBaseline {
        MuscleBaseline(mean: mean, sd: sd)
    }

    /// Enough frozen normals for a real comparison.
    private var richBaselines: [MuscleGroup: MuscleBaseline] {
        var out: [MuscleGroup: MuscleBaseline] = [:]
        for g in MuscleGroup.allCases.prefix(5) { out[g] = baseline(mean: 4000, sd: 800) }
        return out
    }

    private func loads(_ groups: [MuscleGroup], kg: Double = 4000) -> [MuscleGroup: Double] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0, kg) })
    }

    // MARK: - The window, named

    func testThePromptNamesTheWindowsDatesAndTheUnit() {
        let groups = Array(MuscleGroup.allCases.prefix(5))
        let s = MuscleCoachNote.systemPrompt(loads: loads(groups), baselines: richBaselines,
                                            from: "2026-09-23", to: "2026-09-29")
        XCTAssertTrue(s.contains("2026-09-23 to 2026-09-29"), s)
        XCTAssertTrue(s.contains("TOTAL KILOGRAMS MOVED"), "the unit, so the model cannot read it as a bar weight")
        XCTAssertTrue(s.contains("VOLUME (total kg moved) FOR 2026-09-23 TO 2026-09-29"), s)
    }

    /// The previous seven days travel with each group, so the note can say a direction instead of a level.
    func testThePreviousWeekIsGivenBesideEachGroup() {
        let groups = Array(MuscleGroup.allCases.prefix(5))
        let s = MuscleCoachNote.systemPrompt(loads: loads(groups), baselines: richBaselines,
                                            from: "2026-09-23", to: "2026-09-29",
                                            priorWeek: [groups[0]: 6200])
        XCTAssertTrue(s.contains("previous 7 days 6200 kg"), s)
    }

    // MARK: - What it is asked for

    /// With real history it asks for something SPECIFIC and actionable — undertrained relative to the
    /// wearer's own weeks, and what to do in the next session — not a paragraph.
    func testWithRealHistoryItAsksForUndertrainedGroupsAndANextSession() {
        let s = MuscleCoachNote.systemPrompt(loads: loads(Array(MuscleGroup.allCases.prefix(5))),
                                             baselines: richBaselines)
        XCTAssertTrue(s.contains("most UNDERTRAINED relative to their own recent weeks"), s)
        XCTAssertTrue(s.contains("NEXT SESSION"), s)
        XCTAssertTrue(s.contains("how many working sets"), s)
        XCTAssertTrue(s.contains("one group that is genuinely fine"), s)
        XCTAssertTrue(MuscleCoachNote.question.contains("next session"))
    }

    /// THIN DATA GETS AN HONEST NOTE, NOT A VERDICT. With fewer than a few frozen normals there is nothing to
    /// be undertrained relative to, so the instruction changes shape: say so, do not rank, do not call
    /// anything low.
    func testWithAlmostNoHistoryItIsToldToSaySoRatherThanRank() {
        let two = Array(MuscleGroup.allCases.prefix(2))
        let s = MuscleCoachNote.systemPrompt(loads: loads(two), baselines: [two[0]: baseline(mean: 3000, sd: 500)],
                                             from: "2026-09-23", to: "2026-09-29")
        XCTAssertTrue(s.contains("CANNOT"), s)
        XCTAssertTrue(s.contains("not enough history"), s)
        XCTAssertTrue(s.contains("Do NOT rank groups"), s)
        XCTAssertFalse(s.contains("most UNDERTRAINED relative to their own recent weeks"),
                       "the confident ask must be absent entirely, not merely softened")
    }

    /// A group with no frozen normal is marked as not comparable, in both the table and the untrained list —
    /// so nothing can call it low. It is the repo's never-fabricate rule applied to a prompt.
    func testAGroupWithoutANormalIsNeverDescribableAsLow() {
        let groups = Array(MuscleGroup.allCases.prefix(5))
        var some = richBaselines
        some[groups[4]] = nil
        let s = MuscleCoachNote.systemPrompt(loads: loads(groups), baselines: some)
        XCTAssertTrue(s.contains("no personal normal yet — not comparable, so never call it low"), s)
        XCTAssertTrue(s.contains("NOT low and NOT weak"), s)
    }

    /// The untrained groups say whether they have a normal, because "trained nothing and has a normal" is
    /// genuinely undertrained while "trained nothing and has no normal" is simply unknown.
    func testUntrainedGroupsSayWhetherTheyAreComparable() {
        let one = Array(MuscleGroup.allCases.prefix(1))
        let s = MuscleCoachNote.systemPrompt(loads: loads(one), baselines: richBaselines)
        XCTAssertTrue(s.contains("NOT TRAINED AT ALL IN THIS WINDOW"), s)
        XCTAssertTrue(s.contains("(has a normal)"), s)
    }

    // MARK: - The fingerprint

    /// The note names its window, so the SAME kilograms read over a window that has since slid forward is a
    /// note whose first clause is wrong — and must be rewritten.
    func testTheFingerprintChangesWithTheWindowAndWithThePreviousWeek() {
        let l = loads(Array(MuscleGroup.allCases.prefix(3)))
        let a = MuscleCoachNote.fingerprint(l, priorWeek: [:], window: "2026-09-23..2026-09-29")
        let b = MuscleCoachNote.fingerprint(l, priorWeek: [:], window: "2026-09-24..2026-09-30")
        XCTAssertNotEqual(a, b, "a slid window is a new note")
        let c = MuscleCoachNote.fingerprint(l, priorWeek: l, window: "2026-09-23..2026-09-29")
        XCTAssertNotEqual(a, c, "a changed direction is a new note")
    }

    /// Still stable across process launches: FNV-1a, not Swift's per-process-seeded hasher, or the note would
    /// be rewritten on every cold start — the exact cost the whole mechanism exists to avoid.
    func testTheFingerprintIsStableForTheSameInputs() {
        let l = loads(Array(MuscleGroup.allCases.prefix(3)))
        XCTAssertEqual(MuscleCoachNote.fingerprint(l, priorWeek: [:], window: "w"),
                       MuscleCoachNote.fingerprint(l, priorWeek: [:], window: "w"))
    }
}
