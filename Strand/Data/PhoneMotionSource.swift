import Foundation
import StrandAnalytics
#if os(iOS)
import CoreMotion
#endif

/// The iPhone's own motion, reduced to the per-minute `MovementMinute`s the sitting-break detector reads.
///
/// WHY THE PHONE. The strap cannot give a live movement signal: WHOOP step / motion data only arrives with
/// the historical offload, minutes late, and on WHOOP 5/MG firmware the live raw motion stream is not
/// available at all. So live movement comes from CoreMotion — `CMMotionActivityManager` (walking / running /
/// cycling / automotive / stationary, with a confidence) and `CMPedometer` (steps). Both are HISTORY queries
/// against the motion coprocessor, which keeps ~7 days on-device, so a tick after iOS suspended the app can
/// still see every minute it missed. Nothing is subscribed to and nothing leaves the device.
///
/// HONEST GAPS. A minute the phone said nothing about carries nil, never zero: no pedometer answer is "no
/// data", not "no steps". Minutes younger than `unsettledSeconds` are re-read on every tick instead of being
/// cached, because the pedometer's history for the last few minutes can still be filling in and a cached
/// early zero would hide a walk.
///
/// iOS only. On macOS (no CoreMotion activity / pedometer) every entry point reports `.unavailable` / empty,
/// and the detector abstains with a stated reason.
@MainActor
final class PhoneMotionSource {

    /// Pedometer minutes newer than this are re-queried each time rather than cached.
    static let unsettledSeconds = 5 * 60
    /// How far before the first requested minute to read activity history, so the activity state that was
    /// already in force when the window opened (activities are CHANGE events) is known.
    static let activityLeadSeconds = 3 * 3600

    #if os(iOS)
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    #endif
    /// Settled per-minute phone steps (minute start → steps), trimmed to the lookback on every read.
    private var stepCache: [Int: Int] = [:]

    /// What the OS says about Motion & Fitness right now.
    static func access() -> MotionAccess {
        #if os(iOS)
        guard CMMotionActivityManager.isActivityAvailable() || CMPedometer.isStepCountingAvailable() else {
            return .unavailable
        }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
        #else
        return .unavailable
        #endif
    }

    /// Ask for Motion & Fitness. iOS shows its prompt on the first motion query, so this runs a one-minute
    /// history query and returns the status afterwards. When the answer is already decided the OS shows no
    /// prompt at all, which the settings screen handles by offering the Settings app instead.
    func requestAccess() async -> MotionAccess {
        #if os(iOS)
        guard Self.access() == .notDetermined else { return Self.access() }
        let now = Date()
        let manager = activityManager
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: OperationQueue.main) { _, _ in
                cont.resume()
            }
        }
        return Self.access()
        #else
        return .unavailable
        #endif
    }

    /// Every COMPLETE local minute in `[fromSec, toSec)`, oldest first, with the phone's activity and steps.
    /// Empty when access is not granted (the detector abstains on the access status, not on this emptiness).
    func minutes(fromSec: Int, toSec: Int) async -> [MovementMinute] {
        #if os(iOS)
        guard Self.access() == .authorized else { return [] }
        let first = fromSec - ((fromSec % 60) + 60) % 60
        let last = toSec - ((toSec % 60) + 60) % 60   // exclusive: the minute in progress is not complete
        guard last > first else { return [] }

        let activities = await activityHistory(fromSec: first - Self.activityLeadSeconds, toSec: last)
        await fillSteps(from: first, to: last, nowSec: toSec)
        stepCache = stepCache.filter { $0.key >= first }

        var out: [MovementMinute] = []
        var idx = 0
        var current: ActivitySample?
        var start = first
        while start < last {
            // The activity in force at the minute's midpoint: the newest change at or before it.
            let mid = Double(start + 30)
            while idx < activities.count && activities[idx].start <= mid {
                current = activities[idx]
                idx += 1
            }
            out.append(MovementMinute(start: start, activity: current?.kind, confidence: current?.confidence,
                                      steps: stepCache[start] ?? unsettled[start], heartRate: nil))
            start += 60
        }
        unsettled = [:]
        return out
        #else
        return []
        #endif
    }

    #if os(iOS)
    /// Pedometer answers for minutes too recent to cache, valid for one `minutes` call.
    private var unsettled: [Int: Int] = [:]

    /// A CMMotionActivity reduced to plain values inside the callback, so nothing CoreMotion crosses back.
    private struct ActivitySample {
        let start: TimeInterval
        let kind: PhoneActivityKind
        let confidence: PhoneActivityConfidence
    }

    /// Nonisolated: it runs inside CoreMotion's callback, which is not on the main actor.
    nonisolated private static func sample(_ a: CMMotionActivity) -> ActivitySample {
        // Several flags can be true at once (stationary + automotive at a red light): the most specific wins.
        let kind: PhoneActivityKind
        if a.automotive { kind = .automotive }
        else if a.cycling { kind = .cycling }
        else if a.running { kind = .running }
        else if a.walking { kind = .walking }
        else if a.stationary { kind = .stationary }
        else { kind = .unknown }
        let conf: PhoneActivityConfidence
        switch a.confidence {
        case .high: conf = .high
        case .medium: conf = .medium
        case .low: conf = .low
        @unknown default: conf = .low
        }
        return ActivitySample(start: a.startDate.timeIntervalSince1970, kind: kind, confidence: conf)
    }

    private func activityHistory(fromSec: Int, toSec: Int) async -> [ActivitySample] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        let manager = activityManager
        let from = Date(timeIntervalSince1970: TimeInterval(fromSec))
        let to = Date(timeIntervalSince1970: TimeInterval(toSec))
        return await withCheckedContinuation { (cont: CheckedContinuation<[ActivitySample], Never>) in
            manager.queryActivityStarting(from: from, to: to, to: OperationQueue.main) { acts, _ in
                let samples = (acts ?? []).map(PhoneMotionSource.sample).sorted { $0.start < $1.start }
                cont.resume(returning: samples)
            }
        }
    }

    /// Query every missing minute, one history query each. The first call after a launch reads the whole
    /// lookback (~3 h ≈ 180 small queries, once); after that it is one or a few per tick.
    private func fillSteps(from first: Int, to last: Int, nowSec: Int) async {
        guard CMPedometer.isStepCountingAvailable() else { return }
        var start = first
        while start < last {
            let settled = nowSec - (start + 60) >= Self.unsettledSeconds
            if !settled || stepCache[start] == nil {
                if let n = await steps(from: start, to: start + 60) {
                    if settled { stepCache[start] = n } else { unsettled[start] = n }
                }
            }
            start += 60
        }
    }

    private func steps(from: Int, to: Int) async -> Int? {
        let p = pedometer
        let a = Date(timeIntervalSince1970: TimeInterval(from))
        let b = Date(timeIntervalSince1970: TimeInterval(to))
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            p.queryPedometerData(from: a, to: b) { data, _ in
                cont.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }
    #endif
}
