#if os(iOS)
import Foundation

/// Hears the water widget's taps from inside the app.
///
/// The widget runs in its own process, so it cannot call into the app; it posts a Darwin notification
/// (`WaterWidgetStore.darwinName`) instead, the one signal that crosses processes. This turns that into
/// an ordinary in-app notification the shell can `onReceive`.
enum WaterWidgetBridge {

    /// Posted in the app whenever the widget queued a change.
    ///
    /// INSTALLS THE LISTENER ON FIRST USE. The shell reads this once while building its body, which is
    /// exactly when the listener is needed from, and a static initialiser runs once and only once — so
    /// there is no separate install call that could be forgotten or made twice.
    static let pendingNotification: Notification.Name = {
        let name = Notification.Name("noop.water.widgetPending")
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("noop.water.widgetPending"),
                                                    object: nil)
                }
            },
            WaterWidgetStore.darwinName as CFString, nil, .deliverImmediately)
        return name
    }()
}
#endif
