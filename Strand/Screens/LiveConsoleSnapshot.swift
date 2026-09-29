import Combine
import Foundation
import WhoopStore

// MARK: - LiveConsoleSnapshot
//
// WHY THIS EXISTS. `LiveView` held `@EnvironmentObject` on BOTH `LiveState` and `AppModel` — the app's two
// highest-rate publishers. `LiveState` notifies per R-R packet and per frame-type change; `AppModel`
// notifies on the 1 Hz HR tick and again on the 1 Hz `activeWorkout` rewrite for every second of a
// workout. `@EnvironmentObject` subscribes the reading view to EVERY `objectWillChange`, so the whole
// ~700-line parent body re-evaluated at the packet rate — on the one screen a wearer sits on DURING a
// workout, which is exactly where the lag was reported. `TodayView` and `HealthView` each carry an
// explicit note saying they deliberately do NOT observe `LiveState` for this reason; Live never got that
// pass, and this is it.
//
// The fields the parent actually reads are coarse: connection/bond transitions, two guidance strings, the
// standard-HR note, whether a backfill is running, the active device's name/kind, and the workout's
// pause/clock fields. This value is exactly those, `Equatable`, fed into one `@State` by a single
// de-duplicated `.onReceive` — the parent's SOLE invalidation driver. Both objects are resolved through
// the NON-observing `\.appModelRef` (`ModelReferenceEnvironment`), so `live` / `model` still name the same
// instances every action call site already used.
//
// ⚠️ A FIELD LEFT OUT OF HERE, AND NOT READ INSIDE AN OBSERVING LEAF, IS A SILENTLY FROZEN READOUT on the
// app's most diagnostic screen. Every live-rate value — the BPM vessel, the R-R trace and RMSSD, the header
// stats, the Signal Trust tiles, the active-workout HR/avg/peak/effort, the sync chunk counter, the strap
// log — is read INSIDE a leaf that owns `LiveState` / `AppModel` itself. Nothing else in the parent may
// read either object except from an action closure, where no observation is involved.

/// The coarse `LiveState` + `AppModel` state `LiveView`'s parent body renders from. See the note above.
struct LiveConsoleSnapshot: Equatable {

    // MARK: LiveState — the link facts the layout gates on

    var connected = false
    var bonded = false
    var encryptedBond = false
    var streamingLiveHR = false
    /// Whether a history offload is running. The presence gate for the SYNCING badge only — the chunk
    /// COUNT is deliberately not here (it moves per chunk); `LiveSyncChunksBadge` reads it in a leaf.
    var backfilling = false
    // `= nil` on every optional, deliberately: without it the memberwise initialiser has no default for the
    // field, so `LiveConsoleSnapshot()` — the `@State` seed the parent starts from — would not compile.
    var reconnectGuide: String? = nil
    var pairingHint: String? = nil
    var standardHRMode: String? = nil

    // MARK: AppModel.deviceRegistry — which band the console is talking about

    /// Resolved exactly as before through `LiveConsoleReadout.activeIsWhoop`, which defaults to true for an
    /// unresolvable active row (#1303). NOT `LiveState.activeIsWhoop`: that mirror only tracks
    /// `activeDeviceId` transitions, and keeping the registry read keeps this a pure perf change.
    var activeIsWhoop = true
    var activeDeviceName = "WHOOP"

    // MARK: AppModel — the session console

    /// The active workout's PAUSE + CLOCK fields only. The live stats (`avgHr`, `peakHr`, `liveStrain`,
    /// `samples`) are deliberately absent: they are rewritten every second, so carrying them here would
    /// re-invalidate the parent at 1 Hz and undo the whole point. `ActiveWorkoutLive` reads them off the
    /// observed `AppModel` instead.
    var workout: WorkoutClock? = nil
    /// The last saved workout. Written once, when a session ends, so the whole row is coarse.
    var lastWorkout: WorkoutRow? = nil

    /// An active workout's pause state + clock inputs, carried by value.
    ///
    /// CARRIED, not consulted: this is what the card renders from, so without these three fields the
    /// parent could not say "Paused" or subtract the paused time however correct `AppModel` is — the same
    /// trap #1533 fell into. The arithmetic itself stays in `ActiveWorkoutClock`, the one place that owns it.
    struct WorkoutClock: Equatable {
        let start: Date
        var pausedAt: Date? = nil
        var pausedDuration: TimeInterval = 0

        var isPaused: Bool { pausedAt != nil }

        func elapsed(at now: Date) -> TimeInterval {
            ActiveWorkoutClock.activeElapsed(start: start, pausedAt: pausedAt,
                                             pausedDuration: pausedDuration, now: now)
        }

        /// nil when no workout is running — which is also the parent's "no active session" branch.
        static func make(from workout: AppModel.ActiveWorkout?) -> WorkoutClock? {
            guard let workout else { return nil }
            return WorkoutClock(start: workout.start, pausedAt: workout.pausedAt,
                                pausedDuration: workout.pausedDuration)
        }
    }

    // MARK: - Derived link states (the two the parent gates nearly everything on)

    /// A trusted WHOOP link, for the console readouts and the bond-only controls.
    ///
    /// Gated on the active device actually BEING a WHOOP (#2075). `LiveState` is one object that every live
    /// source writes into, so `connected && bonded` stays true for a bonded strap while an Oura ring is the
    /// device on screen — which showed the WHOOP pill, charge and WHOOP-only controls under the ring's name.
    var activeConnection: Bool { activeIsWhoop && connected && bonded }

    /// A non-WHOOP live source (the Oura ring) that is connected and actively streaming live HR. It
    /// authenticates and streams but never reaches a WHOOP encrypted bond, so `bonded` stays false and
    /// `activeConnection` never trips — which left the console reading "stream not yet trusted" for a
    /// perfectly good ring stream. (#69 twin.)
    var ringStreaming: Bool { connected && streamingLiveHR }
}

// MARK: - Reading it off the live objects

extension LiveConsoleSnapshot {

    /// Read the coarse state straight off the two objects. The `.onAppear` seed, so the parent renders the
    /// truth on its first pass instead of waiting for the next packet.
    @MainActor
    static func current(_ model: AppModel) -> LiveConsoleSnapshot {
        let live = model.live
        let registry = model.deviceRegistry
        let devices = registry?.devices ?? []
        let activeId = registry?.activeDeviceId
        return LiveConsoleSnapshot(
            connected: live.connected,
            bonded: live.bonded,
            encryptedBond: live.encryptedBond,
            streamingLiveHR: live.streamingLiveHR,
            backfilling: live.backfilling,
            reconnectGuide: live.reconnectGuide,
            pairingHint: live.pairingHint,
            standardHRMode: live.standardHRMode,
            activeIsWhoop: LiveConsoleReadout.activeIsWhoop(devices: devices, activeId: activeId),
            activeDeviceName: deviceName(devices: devices, activeId: activeId),
            workout: WorkoutClock.make(from: model.activeWorkout),
            lastWorkout: model.lastWorkout)
    }

    /// The display name of the active registry device ("WHOOP", a strap's nickname, …). Falls back to
    /// "WHOOP" before the registry opens or when the row is not resolvable, keeping the WHOOP-first tone.
    static func deviceName(devices: [PairedDevice], activeId: String?) -> String {
        guard let activeId, let active = devices.first(where: { $0.id == activeId })
        else { return "WHOOP" }
        return active.displayName
    }

    /// Every coarse change, and nothing else, as one de-duplicated stream.
    ///
    /// Built from the `@Published` PROJECTIONS rather than from `objectWillChange`, deliberately: those
    /// publishers emit in `willSet`, so a snapshot READ inside an `objectWillChange` sink would see the old
    /// value of the very field that changed, compare equal, be dropped by `removeDuplicates()` — and freeze.
    /// Mapping the emitted values has no such window. Each `@Published` also replays its current value on
    /// subscribe, so `combineLatest` emits a complete snapshot immediately.
    @MainActor
    static func publisher(_ model: AppModel) -> AnyPublisher<LiveConsoleSnapshot, Never> {
        let live = model.live

        let link: AnyPublisher<(Bool, Bool, Bool, Bool), Never> = live.$connected
            .combineLatest(live.$bonded, live.$encryptedBond, live.$streamingLiveHR)
            .eraseToAnyPublisher()

        let notes: AnyPublisher<(String?, String?, String?, Bool), Never> = live.$reconnectGuide
            .combineLatest(live.$pairingHint, live.$standardHRMode, live.$backfilling)
            .eraseToAnyPublisher()

        // `removeDuplicates()` BEFORE the join: `activeWorkout` is rewritten every second of a workout and
        // only these three fields of it are coarse, so this is what keeps the 1 Hz rewrite from reaching
        // the parent at all.
        let session: AnyPublisher<(WorkoutClock?, WorkoutRow?), Never> = model.$activeWorkout
            .map { WorkoutClock.make(from: $0) }
            .removeDuplicates()
            .combineLatest(model.$lastWorkout)
            .eraseToAnyPublisher()

        return link.combineLatest(notes, session, devicePublisher(model))
            .map { linkV, notesV, sessionV, deviceV in
                LiveConsoleSnapshot(
                    connected: linkV.0, bonded: linkV.1, encryptedBond: linkV.2, streamingLiveHR: linkV.3,
                    backfilling: notesV.3,
                    reconnectGuide: notesV.0, pairingHint: notesV.1, standardHRMode: notesV.2,
                    activeIsWhoop: deviceV.0, activeDeviceName: deviceV.1,
                    workout: sessionV.0, lastWorkout: sessionV.1)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// `(activeIsWhoop, activeDeviceName)` across the registry's whole life.
    ///
    /// `AppModel.deviceRegistry` is nil until the on-device store opens a beat after launch, and the two
    /// facts live on the registry's OWN `@Published` properties — so this switches onto them when it
    /// arrives, and emits the WHOOP-first defaults until then rather than withholding the first snapshot.
    /// Same `flatMap`-over-an-optional-object shape as `AppModel.bindOuraFeatureStatusMirror`.
    @MainActor
    private static func devicePublisher(_ model: AppModel) -> AnyPublisher<(Bool, String), Never> {
        model.$deviceRegistry
            .flatMap { registry -> AnyPublisher<(Bool, String), Never> in
                guard let registry else { return Just((true, "WHOOP")).eraseToAnyPublisher() }
                return registry.$devices.combineLatest(registry.$activeDeviceId)
                    .map { devices, activeId in
                        (LiveConsoleReadout.activeIsWhoop(devices: devices, activeId: activeId),
                         deviceName(devices: devices, activeId: activeId))
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
