import Foundation
import XCTest
@testable import StrandAnalytics

/// The wearer's own tasks: what the coach's JSON is allowed to decide, and what happens when it says
/// nothing usable at all.
final class CustomTaskTests: XCTestCase {

    /// A fixed zone so "HH:MM" deadlines are deterministic wherever the suite runs.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// 2026-09-19 10:00 in Berlin.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10, minute: 0))!
    }

    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func parse(_ answer: String, _ user: String = "walk 8000 steps today") -> CustomTaskDraft? {
        CustomTaskParser.parse(answer, userText: user, now: now, calendar: calendar)
    }

    // MARK: - Reading the JSON

    func testAPlainAnswerReadsEveryField() {
        let d = parse(#"{"title":"Eight Thousand","detail":"Walk 8,000 steps before bed.","due":"21:00","metric":"STEPS","target":8000}"#)
        XCTAssertEqual(d?.title, "Eight Thousand")
        XCTAssertEqual(d?.detail, "Walk 8,000 steps before bed.")
        XCTAssertEqual(d?.goal, QuestGoal(metric: .steps, threshold: 8000))
        XCTAssertEqual(d?.fromCoach, true)
        let nine = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 21))!
        XCTAssertEqual(d?.dueAtMs, Int64(nine.timeIntervalSince1970 * 1000))
    }

    func testFencesAndProseAroundTheObjectAreIgnored() {
        let answer = """
        Sure! Here is your task:
        ```json
        {"title": "Stretch Break", "detail": "Ten minutes of stretching after lunch.", "due": "13:30", "metric": null, "target": null}
        ```
        Have a great day {and good luck}.
        """
        let d = parse(answer, "remind me to stretch 10 min after lunch")
        XCTAssertEqual(d?.title, "Stretch Break")
        XCTAssertNil(d?.goal, "stretching is not a metric: ticked off by hand")
        XCTAssertNotNil(d?.dueAtMs)
    }

    func testAReasoningBlockBeforeTheAnswerDoesNotWin() {
        let answer = """
        <think>The user wants {steps}. Maybe {"note": 1}.</think>
        {"title": "Water Up", "detail": "", "due": null, "metric": "WATER_ML", "target": 2000}
        """
        let d = parse(answer, "drink 2 litres")
        XCTAssertEqual(d?.title, "Water Up")
        XCTAssertEqual(d?.goal, QuestGoal(metric: .waterMl, threshold: 2000))
        XCTAssertNil(d?.dueAtMs)
    }

    func testBracesInsideStringsDoNotBreakTheObject() {
        let d = parse(#"{"title":"Braces } here","detail":"a { b","metric":null}"#)
        XCTAssertEqual(d?.title, "Braces } here")
        XCTAssertEqual(d?.detail, "a { b")
    }

    func testNoJSONAtAllIsNil() {
        XCTAssertNil(parse("Walk eight thousand steps, you can do it!"))
        XCTAssertNil(parse(#"{"title": "broken", "#))
        XCTAssertNil(parse(""))
    }

    func testAMissingTitleFallsBackToTheWearersWords() {
        let d = parse(#"{"metric":"STEPS","target":8000}"#, "walk 8000 steps today")
        XCTAssertEqual(d?.title, "Walk 8000 steps today")
    }

    // MARK: - What the model may not decide

    func testAnUnknownMetricMeansATickOffTask() {
        XCTAssertNil(parse(#"{"title":"x","metric":"PUSHUPS","target":50}"#)?.goal)
    }

    func testAMetricWithoutANumberMeansATickOffTask() {
        XCTAssertNil(parse(#"{"title":"x","metric":"STEPS","target":null}"#)?.goal)
        XCTAssertNil(parse(#"{"title":"x","metric":"STEPS","target":0}"#)?.goal)
    }

    func testAnImplausibleNumberIsDropped() {
        XCTAssertNil(parse(#"{"title":"x","metric":"STEPS","target":2000000}"#)?.goal)
        XCTAssertNil(parse(#"{"title":"x","metric":"STRAIN","target":35}"#)?.goal)
    }

    func testNumbersWrittenAsStringsAndLitresAreRead() {
        XCTAssertEqual(parse(#"{"title":"x","metric":"steps","target":"8,000"}"#)?.goal,
                       QuestGoal(metric: .steps, threshold: 8000))
        XCTAssertEqual(parse(#"{"title":"x","metric":"WATER_ML","target":2.5}"#)?.goal,
                       QuestGoal(metric: .waterMl, threshold: 2500))
    }

    func testABedtimeIsAClock() {
        XCTAssertEqual(parse(#"{"title":"x","metric":"BEDTIME_BY","target":"22:30"}"#)?.goal,
                       QuestGoal(metric: .bedtimeBy, threshold: 22 * 60 + 30))
        XCTAssertEqual(parse(#"{"title":"x","metric":"JOURNAL","target":null}"#)?.goal,
                       QuestGoal(metric: .journal, threshold: 1))
    }

    func testAPassedTimeMeansTomorrowAndNonsenseMeansNoDeadline() {
        // 09:00 asked at 10:00 is tomorrow's nine o'clock.
        let d = parse(#"{"title":"x","due":"09:00"}"#)
        let tomorrowNine = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!
        XCTAssertEqual(d?.dueAtMs, Int64(tomorrowNine.timeIntervalSince1970 * 1000))
        XCTAssertNil(parse(#"{"title":"x","due":"after lunch"}"#)?.dueAtMs)
        XCTAssertNil(parse(#"{"title":"x","due":"25:00"}"#)?.dueAtMs)
        // Past, and beyond a week, are both refused.
        XCTAssertNil(parse(#"{"title":"x","due":"2026-09-18T12:00"}"#)?.dueAtMs)
        XCTAssertNil(parse(#"{"title":"x","due":"2026-10-30T12:00"}"#)?.dueAtMs)
        XCTAssertNotNil(parse(#"{"title":"x","due":"2026-09-21T12:00"}"#)?.dueAtMs)
    }

    func testTitlesAndDetailsAreCapped() {
        let long = String(repeating: "word ", count: 60)
        let d = parse(#"{"title":"\#(long)","detail":"\#(long)"}"#)
        XCTAssertLessThanOrEqual(d?.title.count ?? 999, QuestNaming.maxTitleChars)
        XCTAssertLessThanOrEqual(d?.detail.count ?? 999, CustomTaskParser.maxDetailChars)
    }

    // MARK: - The fallback

    func testNoAnswerFallsBackToTheWearersOwnWords() {
        let d = CustomTaskParser.resolve(answer: nil, userText: "  call mum tonight ", now: now, calendar: calendar)
        XCTAssertEqual(d.title, "Call mum tonight")
        XCTAssertFalse(d.fromCoach)
        XCTAssertNil(d.goal)
        XCTAssertNil(d.dueAtMs)
    }

    func testAnUnreadableAnswerFallsBackToo() {
        let d = CustomTaskParser.resolve(answer: "I can't do JSON today", userText: "walk 8000 steps",
                                         now: now, calendar: calendar)
        XCTAssertFalse(d.fromCoach)
        // An unambiguous quantity in the wearer's own words still closes itself.
        XCTAssertEqual(d.goal, QuestGoal(metric: .steps, threshold: 8000))
    }

    func testTheFallbackDoesNotReadStretchingAsTraining() {
        let d = CustomTaskParser.fallback(userText: "stretch for 10 minutes after lunch")
        XCTAssertNil(d.goal)
    }

    // MARK: - The quest it becomes

    func testAConfirmedDraftIsAnActiveCustomQuestOnToday() {
        let draft = CustomTaskDraft(title: "Stretch Break", detail: "Ten minutes after lunch.")
        let q = CustomTaskParser.makeQuest(draft, now: now, calendar: calendar, id: "t1")
        XCTAssertEqual(q.kind, .custom)
        XCTAssertEqual(q.state, .active)
        XCTAssertEqual(q.dayKey, "2026-09-19")
        XCTAssertEqual(q.target, "Ten minutes after lunch.")
        XCTAssertEqual(q.xp, CustomTaskParser.xp)
        // No deadline asked for: the same window every quest gets.
        XCTAssertEqual(q.expiresAtMs, nowMs + Quest.defaultWindowMs)
        // No goal means ticked off by hand — the directive is NOT mined for one.
        XCTAssertNil(q.effectiveGoal)
    }

    func testADeadlineThatPassedWhileThePreviewSatOpenFallsBackToTheWindow() {
        let draft = CustomTaskDraft(title: "x", dueAtMs: nowMs + 60_000)
        let q = CustomTaskParser.makeQuest(draft, now: now, calendar: calendar)
        XCTAssertEqual(q.expiresAtMs, nowMs + Quest.defaultWindowMs)
        let ok = CustomTaskParser.makeQuest(CustomTaskDraft(title: "x", dueAtMs: nowMs + 3_600_000),
                                            now: now, calendar: calendar)
        XCTAssertEqual(ok.expiresAtMs, nowMs + 3_600_000)
    }

    func testACustomTaskSurvivesStorage() {
        let q = CustomTaskParser.makeQuest(
            CustomTaskDraft(title: "Eight Thousand", goal: QuestGoal(metric: .steps, threshold: 8000)),
            now: now, calendar: calendar, id: "t2")
        let back = QuestCodec.decode(QuestCodec.encode([q]), fallbackDay: "2026-09-19", now: nowMs)
        XCTAssertEqual(back, [q])
    }

    func testCustomTasksDoNotUseUpTheSideQuestBudget() {
        let mine = (0..<5).map { i in
            CustomTaskParser.makeQuest(CustomTaskDraft(title: "Mine \(i)"), now: now, calendar: calendar)
        }
        let trigger = QuestTrigger(
            id: "t", observation: "o", target: "a target nobody else has", rewards: [.heart], xp: 40)
        XCTAssertTrue(QuestTriggers.mayRaise(existingToday: mine, trigger: trigger))
    }
}
