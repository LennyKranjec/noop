import Foundation
import StrandAnalytics
import SwiftUI

// MorningGate.swift — the brief's last page does not let go until the night is actually in.
//
// WHAT WAS WRONG. The morning flow could be paged through and dismissed while the night was still
// draining off the strap and before anything had scored it, so the brief showed "still syncing", the
// wearer tapped START THE DAY, and the figures they had just read moved under them ten minutes later.
// The flow is the one moment in the day when the wearer is deliberately waiting for their night, and it
// was the one moment that did not wait.
//
// SO THE LAST PAGE GATES ON THREE THINGS, all of them read from the same signals the rest of the app
// reads — nothing here recomputes anything:
//
//   1. THE STRAP'S BACKLOG IS DRAINED. No offload running (`LiveState.backfilling`), no advertised
//      backlog (`LiveState.historyPendingSync`), and — while a strap is actually connected — a sync that
//      COMPLETED after the flow opened (`LiveState.lastSyncedAt`).
//   2. THE PASS THAT SCORES THE NIGHT HAS FINISHED. Nothing computing or importing, and
//      `IntelligenceEngine.lastCompletedAnalysisAt` is later than that last sync — the night's rows are
//      no use until something has scored them.
//   3. TODAY'S LEVEL IS RESOLVED. A committed `LevelLedger` entry for today, or an honest "no level for
//      today: last night wasn't recorded". Never a stand-in and never a placeholder.
//
// WHY "NO BACKLOG" IS NOT EVIDENCE OF BEING SYNCED. `historyPendingSync` is only ever set where the
// strap-reported newest record AND our own frontier are both known: it is left alone when the range
// answer is missing, and it is deliberately held false for a future-dated clock and for a phantom gap
// (see `BLEManager.maybeAutoContinueBackfill`). On a WHOOP 5/MG in particular it may never become true
// at all. So a false flag means "no evidence of a backlog", which is not the same as "caught up" — which
// is exactly why condition 1 also wants a sync that finished AFTER this flow opened, rather than
// treating the absent flag as an all-clear.
//
// AND IT NEVER BLOCKS FOREVER. After `timeoutSeconds` the gate opens with an explicit note that the
// figures may still move. A morning flow that could not be dismissed would be worse than one that
// dismisses early, and a strap that is off the wrist, flat or refusing writes is a thing that happens.
//
// The decision is pure, so every combination is a unit test rather than a thing to reproduce with a
// strap at seven in the morning.

/// Everything the gate decides from. All of it observed, none of it derived here.
struct MorningGateInputs: Equatable {
    /// A strap is connected right now, so more of the night could still arrive.
    var strapLinked = false
    /// A history offload is running.
    var offloadRunning = false
    /// The strap advertises records newer than our frontier. See the note above on why false is weak.
    var backlogPending = false
    /// When the last offload COMPLETED (even an empty one — "caught up" is a completion).
    var lastSyncedAt: Date?
    /// An analysis pass, a rescore or an import is writing to the store.
    var analysisRunning = false
    /// When the store was last known to be fully analysed.
    var analysisCompletedAt: Date?
    /// Today's level is a committed ledger entry, or a settled "no night".
    var levelResolved = false
    /// The last sync's own failure, when it had one. Named rather than hidden behind a spinner.
    var syncError: String?
    /// When the morning flow opened — the moment its forced sync started. A sync that completed BEFORE
    /// this is a sync from yesterday evening and says nothing about last night.
    ///
    /// SEPARATE FROM `waitingSince` ON PURPOSE. The wearer may have spent three minutes writing a dream
    /// before reaching the last page, and the sync that landed during it is exactly the one the gate is
    /// waiting for — anchoring the freshness test to their arrival would throw that sync away and wait
    /// for another that may never come.
    var flowOpenedAt = Date()
    /// When the last page came up — what the bounded wait is measured from, so the wearer is never held
    /// for longer than `timeoutSeconds` after they arrive, however long they spent on the pages before.
    var waitingSince = Date()
    var now = Date()

    /// Chunks acked in the current offload session — honest progress, because the total pending is
    /// unknowable from the protocol. Nil when no offload is running.
    var syncChunks: Int?
}

/// Where the gate is. `ready` and `timedOut` both let the wearer through; nothing else does.
enum MorningGateStage: Equatable {
    /// Waiting for the strap's night to land.
    case syncing
    /// The rows are in; waiting for the pass that scores them.
    case analysing
    /// Scored; waiting for today's level to be written to the ledger.
    case scoring
    /// All three conditions hold.
    case ready
    /// The bounded wait ran out. The wearer may go on, told that the figures may still move.
    case timedOut

    /// Whether the continue control is enabled.
    var allowsContinue: Bool { self == .ready || self == .timedOut }
}

enum MorningGate {

    /// The longest the wearer is ever held. Long enough for a normal night's drain and the pass behind
    /// it, short enough that a strap which is never going to answer does not trap them in the flow.
    static let timeoutSeconds: TimeInterval = 90

    /// How far BEFORE the flow opened a completed sync still counts as this morning's.
    ///
    /// The flow asks for an offload the moment it opens, but that request is rate-limited by
    /// `BackfillPolicy`'s 90-second foreground floor — so when a sync has only just run, the flow's own
    /// request is skipped and the sync it would have started is the one that already happened. Without
    /// this grace the gate would then wait for an offload nothing is going to start, and time out on the
    /// one case where everything was already in. Wide enough to cover that floor plus the session behind
    /// it, and no wider: a sync from before this morning must never pass for the night's.
    static let syncFreshnessGrace: TimeInterval = 180

    /// Whether the strap may still have some of the night.
    ///
    /// A CONNECTED STRAP OWES US A COMPLETED SYNC. Without that clause the gate would pass the instant
    /// the flow opened on any strap whose range answer never arrives — which is the 5/MG case, and the
    /// whole reason the absent `historyPendingSync` cannot be read as an all-clear.
    static func syncOutstanding(_ i: MorningGateInputs) -> Bool {
        if i.offloadRunning || i.backlogPending { return true }
        guard i.strapLinked else { return false }
        guard let synced = i.lastSyncedAt else { return true }
        return synced < i.flowOpenedAt.addingTimeInterval(-Self.syncFreshnessGrace)
    }

    /// Whether the pass that turns rows into scores still owes us a run.
    ///
    /// Measured against the last SYNC rather than against the flow opening: the rows landed at that
    /// moment, so a pass older than it has not seen them. A phone with no strap and no sync at all needs
    /// only for some pass to have completed — otherwise a fresh install would sit here for nothing.
    static func analysisOutstanding(_ i: MorningGateInputs) -> Bool {
        if i.analysisRunning { return true }
        guard let done = i.analysisCompletedAt else { return true }
        guard let synced = i.lastSyncedAt else { return false }
        return done < synced
    }

    /// How long the gate has been waiting.
    static func waited(_ i: MorningGateInputs) -> TimeInterval {
        max(0, i.now.timeIntervalSince(i.waitingSince))
    }

    /// The gate's verdict. `ready` beats the timeout: a gate that is satisfied on the same tick it runs
    /// out must not tell the wearer their figures may still move when they may not.
    static func stage(_ i: MorningGateInputs) -> MorningGateStage {
        if i.levelResolved, !syncOutstanding(i), !analysisOutstanding(i) { return .ready }
        if waited(i) >= timeoutSeconds { return .timedOut }
        if syncOutstanding(i) { return .syncing }
        if analysisOutstanding(i) { return .analysing }
        return .scoring
    }

    /// What is happening, in a line — and, where there is one, the real failure rather than a spinner.
    static func detail(_ i: MorningGateInputs, stage: MorningGateStage) -> String {
        switch stage {
        case .syncing:
            if let error = i.syncError { return "Last sync stopped: \(error). Still trying." }
            if let chunks = i.syncChunks, chunks > 0 {
                return "Pulling last night off the strap — \(chunks) chunks so far."
            }
            if i.offloadRunning { return "Pulling last night off the strap." }
            if i.backlogPending { return "The strap still holds records we have not read." }
            return i.strapLinked
                ? "Waiting for the strap to hand over the night."
                : "Waiting for the night to land."
        case .analysing:
            return "The night is in. Scoring it now."
        case .scoring:
            return "Scored. Writing today's level."
        case .ready:
            return "Last night is in, scored, and today's level is set."
        case .timedOut:
            if let error = i.syncError { return "Gave up waiting: \(error)." }
            return "This is taking longer than it should. You can go on — the figures below may still "
                + "move once the rest of the night lands."
        }
    }

    /// The overline over the waiting block.
    static func headline(_ stage: MorningGateStage) -> String {
        switch stage {
        case .syncing: return "SYNCING LAST NIGHT"
        case .analysing: return "SCORING THE NIGHT"
        case .scoring: return "SETTING TODAY'S LEVEL"
        case .ready: return "READY"
        case .timedOut: return "STILL NOT IN"
        }
    }
}

/// The gate's live inputs, gathered on a tick.
///
/// READS, NEVER OBSERVES. `AppModel` publishes several times a second while a strap streams, so this
/// polls the handful of values it needs on its own slow clock rather than subscribing — the same reason
/// `ModelReferenceEnvironment` exists. One `@Published` stage, so the button redraws and nothing else.
@MainActor
final class MorningGateModel: ObservableObject {

    /// How often the inputs are re-read. Slow on purpose: the flow is a page the wearer is reading.
    static let tickSeconds: UInt64 = 2

    @Published private(set) var stage: MorningGateStage = .syncing
    @Published private(set) var detail = ""
    @Published private(set) var headline = ""
    /// The inputs the published stage was decided from, for the diagnostic lines under the block.
    @Published private(set) var inputs = MorningGateInputs()

    private var flowOpenedAt = Date()
    private var waitingSince = Date()
    private var running = false

    /// Start watching. `levelResolved` is asked for on every tick rather than passed once: the brief's
    /// own poll is what resolves it, and it can resolve while this is waiting.
    func start(flowOpenedAt: Date, levelResolved: @escaping @MainActor () -> Bool) async {
        guard !running else { return }
        running = true
        // CLEARED ON EVERY WAY OUT, including cancellation. A flag set on entry and cleared only on the
        // happy path is how this app has wedged before: the view's task is cancelled whenever the page
        // goes away, and a sticky `running` would leave the gate frozen on whatever it last published
        // the next time the page came back.
        defer { running = false }
        self.flowOpenedAt = flowOpenedAt
        self.waitingSince = Date()
        while !Task.isCancelled {
            let next = read(levelResolved: levelResolved())
            publish(next)
            // Nothing can change the verdict once everything is in, so stop ticking. A timed-out gate
            // KEEPS looking: it already let the wearer through, and if the night lands while they are
            // still reading, the note about the figures moving should stop being true.
            if next.0 == .ready { return }
            try? await Task.sleep(nanoseconds: Self.tickSeconds * 1_000_000_000)
        }
    }

    private func publish(_ next: (MorningGateStage, MorningGateInputs)) {
        if inputs != next.1 { inputs = next.1 }
        let detail = MorningGate.detail(next.1, stage: next.0)
        let headline = MorningGate.headline(next.0)
        if stage != next.0 { stage = next.0 }
        if self.detail != detail { self.detail = detail }
        if self.headline != headline { self.headline = headline }
    }

    private func read(levelResolved: Bool) -> (MorningGateStage, MorningGateInputs) {
        var i = MorningGateInputs()
        i.flowOpenedAt = flowOpenedAt
        i.waitingSince = waitingSince
        i.now = Date()
        i.levelResolved = levelResolved
        i.analysisCompletedAt = IntelligenceEngine.lastCompletedAnalysisAt
        if let model = resolvedAppModel(nil) {
            let live = model.live
            i.strapLinked = live.connected
            i.offloadRunning = live.backfilling
            i.backlogPending = live.historyPendingSync
            i.lastSyncedAt = live.lastSyncedAt.map { Date(timeIntervalSince1970: $0) }
            i.syncError = live.lastSyncError
            i.syncChunks = live.backfilling ? live.syncChunksThisSession : nil
            // The same three writers the level ledger refuses to settle during — one expression of "the
            // store is being written", so the gate and the ledger cannot disagree about it.
            i.analysisRunning = model.intelligence.computing || model.hasActiveImport || live.backfilling
        }
        return (MorningGate.stage(i), i)
    }
}
