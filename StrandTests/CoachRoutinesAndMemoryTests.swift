import XCTest
@testable import Strand

/// The routines and the memory file reach the coach, and the memory commands work.
///
/// The routines are the part the wearer asked to be sure of: they must be in the context of every
/// session, with or without data access, as constraints rather than background.
@MainActor
final class CoachRoutinesAndMemoryTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CoachRoutinesTests-\(UUID().uuidString)")
    }

    func testRoutinesAreStatedAsConstraintsWithEveryFieldThatIsSet() {
        var r = CoachRoutineSet()
        r.wake = 6 * 60 + 30
        r.bed = 22 * 60 + 45
        r.workStart = 8 * 60
        r.workEnd = 17 * 60
        r.training = "Gym Mon/Wed/Fri 18:00"
        r.entries = [CoachRoutineEntry(title: "School run", detail: "07:45–08:15 weekdays")]
        CoachRoutines.write(r, defaults)

        let block = CoachRoutines.promptSection(defaults)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("hard constraints"))
        XCTAssertTrue(block!.contains("Wakes at 06:30"))
        XCTAssertTrue(block!.contains("In bed by 22:45"))
        XCTAssertTrue(block!.contains("Works 08:00–17:00"))
        XCTAssertTrue(block!.contains("Training: Gym Mon/Wed/Fri 18:00"))
        XCTAssertTrue(block!.contains("School run: 07:45–08:15 weekdays"))
    }

    func testTheRoutinesRideTheSessionContextWhetherOrNotDataIsShared() {
        var r = CoachRoutineSet()
        r.wake = 7 * 60
        CoachRoutines.write(r, defaults)
        // `sessionConstraints` is what both branches of `send` append — with consent through
        // `buildFullContext`, without it beside the no-consent note.
        XCTAssertTrue(AICoachEngine.sessionConstraints(defaults).contains("Wakes at 07:00"))
    }

    func testNoRoutinesMeansNoBlockRatherThanAPlaceholder() {
        XCTAssertNil(CoachRoutines.promptSection(defaults))
    }

    func testMemoryCommandsAreAppliedAndStrippedFromTheReply() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memory = CoachMemory(directory: dir)

        let reply = "Here is the plan.\n[[REMEMBER: Knee pain on stairs — no jumping this week.]]\nGo easy."
        let shown = memory.apply(reply: reply)
        XCTAssertEqual(shown, "Here is the plan.\nGo easy.")
        XCTAssertEqual(memory.items.map(\.text), ["Knee pain on stairs — no jumping this week."])

        let id = memory.items[0].id
        _ = memory.apply(reply: "Good news.\n**[[FORGET: \(id)]]**")
        XCTAssertTrue(memory.items.isEmpty)

        // It is a file, and it survives a relaunch.
        memory.add("Evening sessions wreck sleep")
        XCTAssertEqual(CoachMemory(directory: dir).items.map(\.text), ["Evening sessions wreck sleep"])
    }

    func testAStreamingReplyHidesItsCommandLines() {
        XCTAssertEqual(CoachMemory.hidingCommands("Plan.\n[[REMEMBER: x]]"), "Plan.")
        XCTAssertEqual(CoachMemory.hidingCommands("Plan.\n[[REMEMB"), "Plan.")
        XCTAssertEqual(CoachMemory.hidingCommands("No commands here."), "No commands here.")
    }
}
