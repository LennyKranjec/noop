import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// NotificationPermission.swift — the one place that asks the OS what it will actually deliver.
//
// WHY THIS EXISTS. Every notification-backed switch in this app was written the same way and got the
// same thing wrong: flip it on, fire `requestAuthorization`, persist the toggle, never look again. That
// reads correctly exactly once — the first time, on a phone where the user says yes. Every other path
// is silent:
//
//   · `requestAuthorization` only shows the system dialog while the status is `.notDetermined`. Once a
//     user has denied — or a PREVIOUS sideload of the same bundle id denied, which survives the
//     reinstall — the call returns `false` with no dialog and nothing in the UI changes.
//   · A toggle restored ON by a backup, an iCloud restore or a reinstall never runs its `onChange`, so
//     it never asks at all. It just sits there ON, against an OS that will deliver nothing.
//   · No screen showed the OS status, so the switch WAS the only evidence, and it was wrong.
//
// So: status is READ, never assumed; the dialog is raised only from an explicit user action; and a
// screen that offers one of these switches can show what the OS actually says and link to Settings.
//
// Cross-platform. macOS and iOS both have `UNUserNotificationCenter`; only the Settings deep link
// differs, and that is the whole of the `#if` below.
enum NotificationPermission {

    /// What the OS will do with our notifications RIGHT NOW. Always read — never inferred from a
    /// persisted toggle, which is the mistake this type exists to stop.
    ///
    /// `.notDetermined` on a platform without UserNotifications, so a caller's "can this fire?" logic
    /// reads the same everywhere.
    static func status() async -> UNAuthorizationStatus {
        #if canImport(UserNotifications)
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #else
        return .notDetermined
        #endif
    }

    /// Whether `status` means the OS will deliver. `.provisional` counts — it is quieter (it delivers
    /// straight to the notification centre), but it is not silence.
    ///
    /// Everything else, INCLUDING anything a future OS adds, reads as "no". An unknown status treated as
    /// delivering is a screen quietly claiming an alert will arrive; treated as not delivering it is at
    /// worst a warning the user can dismiss by looking at Settings. `.ephemeral` (App Clips, and
    /// unavailable on macOS, which is why it is not named here) falls into the same conservative bucket.
    static func delivers(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    /// ASK — and only from somewhere a user asked for something.
    ///
    /// Returns the status AFTER the attempt, so a caller can act on the real answer instead of assuming
    /// the dialog it may never have shown was accepted. Already-decided statuses are returned untouched
    /// rather than re-requested: a second `requestAuthorization` against `.denied` is a no-op that looks
    /// like an ask, which is how a denied user ends up with a switch that stays on.
    ///
    /// NEVER call this from a launch path, a `.task` on a screen that appears by itself, or behind a
    /// first-run gate. The system dialog is shown once in the lifetime of an install; spending it before
    /// the user has agreed to anything spends it for every feature at once.
    @discardableResult
    static func requestFromUserAction(options: UNAuthorizationOptions = [.alert, .sound]) async -> UNAuthorizationStatus {
        #if canImport(UserNotifications)
        let current = await status()
        guard current == .notDetermined else { return current }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
        // Re-read rather than trusting the `granted` bool: the status is what every other call site
        // checks, and the two must not be able to disagree.
        return await status()
        #else
        return .notDetermined
        #endif
    }

    /// Deep-link to the OS notification settings. The system permission dialog only ever appears once,
    /// so for a user who denied, this is the ONLY recovery path — a screen that reports "notifications
    /// are off" without it is reporting a dead end.
    @MainActor
    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
