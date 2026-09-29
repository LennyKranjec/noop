import CoreBluetooth
import WhoopProtocol

/// Resolving WHICH WHOOP family the connected strap really is, from evidence rather than from a guess.
///
/// Why this file exists. `WhoopModel.persisted` defaults to `.whoop4`, so on a FRESH INSTALL every
/// non-scan connect path (CoreBluetooth state restoration, the targeted pin connect, a standing
/// reconnect, an adopted already-open link) opens the session believing the strap is a 4.0. Before the
/// family resolution in `BLEManager.didDiscoverServices` re-armed the pipeline, a WHOOP 5/MG reached
/// that way stayed mis-framed for the WHOLE session AND could not self-heal on a later launch, because
/// `discoverPrimaryServices` only asked for the GUESSED family's proprietary service — so the 5/MG
/// service was never discovered, and the one site that writes the `selectedWhoopModel` preference never
/// saw it. Live HR kept streaming (plain 0x2A37) while the whole historical offload produced nothing.
///
/// Two independent, GUESS-FREE sources of truth:
///
/// 1. `resolvedModel(fromDiscoveredServices:)` — what the peripheral's own GATT tree exposes. This is
///    the primary resolver and it runs before any characteristic is discovered and before any frame
///    arrives, so nothing is ever decoded with an unresolved family.
/// 2. `ProprietaryNotifySource` + `FamilyMismatchDetector` — which characteristic inbound frames
///    actually arrive on. A frame on a puffin notify characteristic can only come from a 5/MG; one on
///    the 4.0 custom notify characteristics can only come from a 4.0. This is the in-session backstop
///    for any path that somehow reaches a live proprietary stream without resolving from GATT.
///
/// Both refuse to answer when the evidence does not support an answer — a strap exposing neither
/// proprietary service, or traffic seen only on the standard HR/battery/DIS profiles (which BOTH
/// families expose), resolves to `nil`. Never guess a family the frames do not support.
///
/// Everything here is `nonisolated` and free of `BLEManager`, which is `@MainActor`: the same reason
/// `WhoopModel.scanService` keeps its UUIDs inline. The characteristic → `ProprietaryNotifySource`
/// mapping therefore lives on `BLEManager` (which owns those constants) and is handed in, so no
/// characteristic UUID is duplicated anywhere.

// MARK: - Resolution from the discovered GATT tree

/// The family the peripheral's discovered services PROVE, or nil when its GATT says nothing about it.
///
/// The 5/MG check comes first so a strap that somehow exposed BOTH proprietary services resolves to the
/// newer family rather than to whichever `services` happened to list first — a deterministic answer
/// matters more than which one wins, because the loser's characteristics are then never discovered.
///
/// Compares `WhoopModel.scanService` values, which that enum documents as mirroring
/// `BLEManager.customService` / `BLEManager.whoop5Service` (`CBUUID` compares by value), so this can
/// never disagree with the switch in `didDiscoverServices`.
func resolvedModel(fromDiscoveredServices services: [CBUUID]) -> WhoopModel? {
    if services.contains(WhoopModel.whoop5mg.scanService) { return .whoop5mg }
    if services.contains(WhoopModel.whoop4.scanService) { return .whoop4 }
    return nil
}

// MARK: - Resolution from the characteristic a frame arrived on

/// What the CHARACTERISTIC an inbound notification arrived on proves about the strap's family.
///
/// `.standardProfile` covers 0x2A37 heart rate, 0x2A19 battery, the DIS strings and anything unmapped:
/// every WHOOP exposes those, so traffic there is evidence of nothing and must move the decision in
/// neither direction. "Proves nothing" is the only honest reading of a characteristic nobody has
/// mapped, which is why it is also the default.
enum ProprietaryNotifySource: Equatable {
    case whoop4
    case whoop5
    case standardProfile

    /// The family this source attests to, or nil when it attests to nothing.
    var attestedFamily: DeviceFamily? {
        switch self {
        case .whoop4: return .whoop4
        case .whoop5: return .whoop5
        case .standardProfile: return nil
        }
    }
}

/// Detects a family the live stream contradicts, from consecutive frames on the OTHER family's
/// proprietary notify characteristics.
///
/// Why a streak rather than a single frame: one frame is already conclusive on its own (a puffin
/// characteristic exists only on a 5/MG), but acting on it re-arms the pipeline and so discards the
/// reassembler's in-progress buffer — worth two frames of certainty before paying that. Corruption can
/// never trip this: only a characteristic UUID belonging to the other family counts, and
/// `.standardProfile` traffic is ignored entirely rather than read as agreement or disagreement.
struct FamilyMismatchDetector {
    /// Contradicting frames required before re-arming. Two, for the reason above.
    static let threshold = 2

    private(set) var consecutiveContradictions = 0

    /// Feed one inbound notification. Returns the family to switch to, exactly ONCE per streak, or nil.
    ///
    /// The counter resets both on agreement (the current family's own proprietary characteristic
    /// delivered a frame, so the decision is right) and immediately after firing, so a link that
    /// somehow delivered both families' characteristics cannot re-arm on every frame.
    mutating func note(source: ProprietaryNotifySource, current: DeviceFamily) -> DeviceFamily? {
        guard let attested = source.attestedFamily else { return nil }   // proves nothing
        guard attested != current else {
            consecutiveContradictions = 0
            return nil
        }
        consecutiveContradictions += 1
        guard consecutiveContradictions >= FamilyMismatchDetector.threshold else { return nil }
        consecutiveContradictions = 0
        return attested
    }

    /// Per-connection state: a fresh link, or a freshly re-armed pipeline, starts with no evidence.
    mutating func reset() { consecutiveContradictions = 0 }
}
