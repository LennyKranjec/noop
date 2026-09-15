import Foundation
import XCTest
@testable import StrandAnalytics

/// Parity pin for reading a quest's name back out of a model's answer. Must behave identically to the
/// Android twin `com.noop.ai.QuestTest`'s naming cases.
///
/// Everything here is about a model that did not follow instructions, because that is the normal case
/// and not the exception. The rule: a missing taunt is survivable, a missing title is not a naming.
final class QuestNamingTests: XCTestCase {

    func testTheTwoLineNamingIsRead() {
        let w = QuestNaming.parse("TITLE: The Horizontal Hours\nTAUNT: Eleven hundred steps.")
        XCTAssertEqual(w?.title, "The Horizontal Hours")
        XCTAssertEqual(w?.taunt, "Eleven hundred steps.")
    }

    func testMarkdownOnEitherSideOfTheColonIsStripped() {
        // A model told to write "TITLE:" and also told to use Markdown produces both of these about
        // equally often. A parser that only allows one silently loses half the answers.
        XCTAssertEqual(QuestNaming.parse("**TITLE:** Cold Start")?.title, "Cold Start")
        XCTAssertEqual(QuestNaming.parse("**TITLE**: Cold Start")?.title, "Cold Start")
        XCTAssertEqual(QuestNaming.parse("TITLE: **Cold Start**")?.title, "Cold Start")
    }

    func testCurlyAndStraightQuotesAreStripped() {
        XCTAssertEqual(QuestNaming.parse("TITLE: \u{201C}Cold Start\u{201D}")?.title, "Cold Start")
        XCTAssertEqual(QuestNaming.parse("TITLE: \"Cold Start\"")?.title, "Cold Start")
    }

    func testTheLabelIsCaseInsensitive() {
        XCTAssertEqual(QuestNaming.parse("Title: Cold Start")?.title, "Cold Start")
        XCTAssertEqual(QuestNaming.parse("title: Cold Start")?.title, "Cold Start")
    }

    func testAMissingTauntIsSurvivable() {
        // The caller has a written fallback for the taunt; it does not have one for a wrong title.
        let w = QuestNaming.parse("TITLE: Cold Start")
        XCTAssertEqual(w?.title, "Cold Start")
        XCTAssertEqual(w?.taunt, "")
    }

    func testAnAnswerWithNoTitleIsNotANaming() {
        XCTAssertNil(QuestNaming.parse("Sure! Here is a quest for you."))
        XCTAssertNil(QuestNaming.parse(""))
        XCTAssertNil(QuestNaming.parse("TAUNT: only a taunt"))
    }

    func testAnEmptyTitleValueIsNotATitle() {
        // "TITLE:" with nothing after it is a model that stopped mid-answer, not a quest called "".
        XCTAssertNil(QuestNaming.parse("TITLE:   \nTAUNT: x"))
    }

    func testARamblingTitleIsBounded() {
        let long = "TITLE: " + String(repeating: "word ", count: 50)
        XCTAssertEqual(QuestNaming.parse(long)?.title.count, QuestNaming.maxTitleChars)
    }

    func testARamblingTauntIsBounded() {
        let long = "TITLE: x\nTAUNT: " + String(repeating: "word ", count: 100)
        XCTAssertEqual(QuestNaming.parse(long)?.taunt.count, QuestNaming.maxTauntChars)
    }

    func testAPreambleBeforeTheLabelsIsIgnored() {
        // Small models like to say hello first.
        let w = QuestNaming.parse("Of course.\n\nTITLE: Cold Start\nTAUNT: Four days.")
        XCTAssertEqual(w?.title, "Cold Start")
        XCTAssertEqual(w?.taunt, "Four days.")
    }

    func testAWordMerelyStartingWithTheLabelIsNotAMatch() {
        // "Titles for you:" is prose, not a labelled field. Matching it would put the model's chatter
        // on the card as the quest's name.
        XCTAssertNil(QuestNaming.parse("Titles for you: something"))
    }

    // MARK: - Rewards

    func testRewardsAreReadOffTheDirectiveRatherThanAskedFor() {
        XCTAssertTrue(QuestNaming.rewards(forDirective: "Bed by 22:30").contains(.sleep))
        XCTAssertTrue(QuestNaming.rewards(forDirective: "10 minutes of breathing").contains(.brain))
        XCTAssertTrue(QuestNaming.rewards(forDirective: "8000 steps").contains(.heart))
        XCTAssertTrue(QuestNaming.rewards(forDirective: "Mobility work").contains(.muscle))
    }

    func testGermanDirectivesMatchToo() {
        // The directive is written in the wearer's own language, so the stems have to cover it.
        XCTAssertTrue(QuestNaming.rewards(forDirective: "Schlafenszeit um 22:00").contains(.sleep))
        XCTAssertTrue(QuestNaming.rewards(forDirective: "10 Minuten Atemübung").contains(.stress))
        XCTAssertTrue(QuestNaming.rewards(forDirective: "Beine dehnen").contains(.muscle))
    }

    func testTheRewardOrderIsFixedSoBothPlatformsDrawTheSameRow() {
        // The Kotlin twin builds a LinkedHashSet in this sequence; a different order here would put the
        // icons on the card in a different order on iOS.
        XCTAssertEqual(
            QuestNaming.rewards(forDirective: "Walk, then stretch, then bed early, and breathe"),
            [.sleep, .brain, .stress, .heart, .lungs, .muscle]
        )
    }

    func testADirectiveThatMatchesNothingStillImprovesSomething() {
        // An empty reward row reads as a bug rather than as modesty.
        XCTAssertEqual(QuestNaming.rewards(forDirective: "do the thing"), [.heart])
    }

    func testEveryTriggerHasItsOwnFallbackPair() {
        // A fallback that repeats across triggers would make two different quests look like the same
        // one on the card.
        let ids = ["overreach", "short-sleep", "sedentary", "idle-streak", "hrv-dip", "daily"]
        let titles = ids.map(QuestNaming.fallbackTitle(triggerId:))
        XCTAssertEqual(Set(titles).count, ids.count)
        for id in ids {
            XCTAssertFalse(QuestNaming.fallbackTaunt(triggerId: id).isEmpty)
        }
    }
}
