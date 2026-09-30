import Foundation

// TodayDynamicOrder.swift — which Today block goes where, right now (DESIGN_V2 coordinator decision 15).
//
// PURE. Every input is handed in (the clock as a minute of the day, the sleep anchor's wind-down, whether
// the morning flow has run, whether a workout is live, whether a penalty or a trial answer is open), so
// the whole ordering is a table the tests can read (`StrandTests/TodayDynamicOrderTests`).
//
// THE WEARER'S ORDER IS THE BASE. `base` is the Arrange sheet's order with the hidden sections already
// removed (`TodayLayoutPrefs.visibleOrder`). Promotion only LIFTS a time-relevant block above that base;
// it never shows a section the wearer hid, never drops one, and never duplicates one.
//
// THE HERO RUN STAYS ON TOP. The leading run of the base made of the hero's own sections (the quest chips,
// the REST / CHARGE / EFFORT panel and TODAY'S MISSION — the reference Home layout) keeps its place right
// under the pinned Telos hero; promoted blocks go directly under that run. A wearer who moved those
// sections down simply has an empty run, and the promotions then lead the list.
//
// THE RULES (minute of the day, local clock)
//   • Live workout (any day shown): the live workout card is FIRST, above everything.
//   • Night — from 18:00, or from tonight's wind-down start when that is earlier (and after noon), until
//     the morning flow has run, or 10:00 at the latest: the evening Sleep panel rises under the hero run.
//   • Morning — after the night ends and before 12:00: today's quests (and with them the penalty board)
//     rise.
//   • Day — 12:00 until the night starts: the STATE tile (what is left today, the workout suggestions)
//     rises.
//   • An open penalty lifts the quests at any time of day, so a penalty is never below the fold.
//   • A pending trial answer sits directly under the quest chips (or, with the quests hidden, with the
//     other promoted blocks).
//   • A past day shown: no promotions at all (they are about now), except a live workout.

/// One renderable Today block: a reorderable section, or one of the time-bound cards the dynamic order
/// lifts in.
enum TodayBlock: Hashable, Identifiable {
    case section(TodaySection)
    /// The live workout card (`ActiveWorkoutIndicatorSection`).
    case liveWorkout
    /// The evening Sleep panel (`EveningSleepPanel`, SLEEP package).
    case eveningSleep
    /// Today's trial assignment waiting for its answer (`HabitTrialTodayCard`).
    case trialAnswer

    var id: String {
        switch self {
        case .section(let s): return "section." + s.rawValue
        case .liveWorkout: return "liveWorkout"
        case .eveningSleep: return "eveningSleep"
        case .trialAnswer: return "trialAnswer"
        }
    }
}

/// Everything the order depends on. Plain values; the view resolves them.
struct TodayDynamicContext: Equatable {
    /// Minutes past local midnight, 0…1439.
    var minuteOfDay: Int
    /// Tonight's wind-down start from the sleep anchor (minutes past midnight, on TODAY's evening), or nil
    /// when the anchor has no plan / abstains.
    var windDownStartMinute: Int?
    /// Whether this morning's flow has run today (the wake + morning flow that ends the night).
    var morningFlowDone: Bool
    /// A workout is running now.
    var workoutActive: Bool
    /// The quest ledger has something the penalty board shows today.
    var penaltyOpen: Bool
    /// Today's trial assignment is waiting for its answer.
    var trialAnswerPending: Bool
    /// The day shown is today (offset 0). Promotions are about now.
    var isToday: Bool

    init(minuteOfDay: Int, windDownStartMinute: Int? = nil, morningFlowDone: Bool = false,
         workoutActive: Bool = false, penaltyOpen: Bool = false, trialAnswerPending: Bool = false,
         isToday: Bool = true) {
        self.minuteOfDay = minuteOfDay
        self.windDownStartMinute = windDownStartMinute
        self.morningFlowDone = morningFlowDone
        self.workoutActive = workoutActive
        self.penaltyOpen = penaltyOpen
        self.trialAnswerPending = trialAnswerPending
        self.isToday = isToday
    }
}

enum TodayDynamicOrder {

    enum Phase: Equatable {
        /// Evening → next morning: the Sleep panel's time.
        case night
        /// After the morning flow (or 10:00), before noon.
        case morning
        /// Noon until the evening starts.
        case day
    }

    /// The evening starts here unless the wind-down starts earlier.
    static let eveningStartMinute = 18 * 60
    /// The Sleep panel leaves by this time even when the morning flow never ran.
    static let morningLatestEndMinute = 10 * 60
    /// Morning ends / day begins.
    static let middayMinute = 12 * 60

    /// The sections that make up the reference hero below the pinned Telos header: they keep their place.
    static let heroGroup: Set<TodaySection> = [.quests, .hero, .dailyMission]

    /// When tonight's evening starts: 18:00, or an earlier wind-down start. A wind-down before noon (i.e.
    /// after midnight — a late sleeper) never starts the evening early.
    static func eveningStart(windDownStartMinute: Int?) -> Int {
        guard let w = windDownStartMinute, w >= middayMinute, w < eveningStartMinute else {
            return eveningStartMinute
        }
        return w
    }

    static func phase(_ c: TodayDynamicContext) -> Phase {
        let m = min(max(c.minuteOfDay, 0), 24 * 60 - 1)
        if m >= eveningStart(windDownStartMinute: c.windDownStartMinute) { return .night }
        if m < morningLatestEndMinute && !c.morningFlowDone { return .night }
        if m < middayMinute { return .morning }
        return .day
    }

    /// Whether the evening Sleep panel belongs on Today right now.
    static func showsEveningSleep(_ c: TodayDynamicContext) -> Bool {
        c.isToday && phase(c) == .night
    }

    /// The blocks to render, top to bottom.
    static func blocks(base: [TodaySection], context c: TodayDynamicContext) -> [TodayBlock] {
        // De-duplicate defensively: a malformed base must not render a section twice.
        var seen = Set<TodaySection>()
        let visible = base.filter { seen.insert($0).inserted }

        var out: [TodayBlock] = []
        if c.workoutActive { out.append(.liveWorkout) }
        guard c.isToday else { return out + visible.map(TodayBlock.section) }

        let run = Array(visible.prefix { heroGroup.contains($0) })
        let phase = phase(c)

        var promoted: [TodayBlock] = []
        var lifted = Set<TodaySection>()
        if phase == .night { promoted.append(.eveningSleep) }
        if phase == .morning || c.penaltyOpen, visible.contains(.quests), !run.contains(.quests) {
            promoted.append(.section(.quests))
            lifted.insert(.quests)
        }
        if phase == .day, visible.contains(.synthesis), !run.contains(.synthesis) {
            promoted.append(.section(.synthesis))
            lifted.insert(.synthesis)
        }

        let runSet = Set(run)
        let rest = visible.filter { !runSet.contains($0) && !lifted.contains($0) }

        var list: [TodayBlock] = run.map(TodayBlock.section) + promoted
        let promotedEnd = list.count
        list += rest.map(TodayBlock.section)

        if c.trialAnswerPending {
            if let q = list.firstIndex(of: .section(.quests)) {
                list.insert(.trialAnswer, at: q + 1)
            } else {
                list.insert(.trialAnswer, at: promotedEnd)
            }
        }
        return out + list
    }
}
