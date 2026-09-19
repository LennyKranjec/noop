//  ModelReferenceEnvironment.swift
//  NOOP
//
//  NON-OBSERVING references to the app's long-lived ObservableObjects.
//
//  `@EnvironmentObject` subscribes the reading view to EVERY `objectWillChange` of the object. AppModel
//  publishes 1–3×/s while a strap streams, and the coach publishes on every streamed chunk, so a view that
//  only needs one derived value (or only calls the object from a button action) was re-evaluating its
//  whole body at that rate. These keys hand out the same instance WITHOUT the subscription; views that need
//  one value keep it in `@State` fed by `.onReceive(publisher.map { … }.removeDuplicates())`.
//
//  Injected once at the iOS root next to the matching `.environmentObject(...)`. A host that does not
//  inject them (macOS windows, previews) falls back to `AppModel.shared` via the `resolved…` helpers, so a
//  missing injection never silently disables an action. The `.environmentObject` injections stay intact —
//  child views that observe still need them.

import SwiftUI

private struct AppModelRefKey: EnvironmentKey {
    static let defaultValue: AppModel? = nil
}

private struct CoachEngineKey: EnvironmentKey {
    static let defaultValue: AICoachEngine? = nil
}

extension EnvironmentValues {
    /// The app's `AppModel`, without observing it. Prefer `resolvedAppModel(_:)` at the use site.
    var appModelRef: AppModel? {
        get { self[AppModelRefKey.self] }
        set { self[AppModelRefKey.self] = newValue }
    }

    /// The AI coach, without observing it — for views that only CALL the coach from actions.
    var coachEngine: AICoachEngine? {
        get { self[CoachEngineKey.self] }
        set { self[CoachEngineKey.self] = newValue }
    }
}

/// The injected model, or the live instance when this host did not inject one.
@MainActor
func resolvedAppModel(_ injected: AppModel?) -> AppModel? {
    injected ?? AppModel.shared
}

/// The injected coach, or the live model's coach when this host did not inject one.
@MainActor
func resolvedCoach(_ injected: AICoachEngine?) -> AICoachEngine? {
    injected ?? AppModel.shared?.coach
}

/// Like `resolvedAppModel(_:)` for a view that cannot work without the model — the same contract an
/// `@EnvironmentObject var model: AppModel` had (which traps when nothing was injected).
@MainActor
func requireAppModel(_ injected: AppModel?) -> AppModel {
    guard let model = resolvedAppModel(injected) else {
        preconditionFailure("AppModel is not available: inject appModelRef or create the AppModel first")
    }
    return model
}

/// Like `resolvedCoach(_:)` for a view that cannot work without the coach (mirrors the old
/// `@EnvironmentObject var coach: AICoachEngine` contract).
@MainActor
func requireCoach(_ injected: AICoachEngine?) -> AICoachEngine {
    guard let coach = resolvedCoach(injected) else {
        preconditionFailure("AICoachEngine is not available: inject coachEngine or create the AppModel first")
    }
    return coach
}
