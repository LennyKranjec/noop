#if os(iOS)
import Foundation
import AppIntents
import WidgetKit

// WaterWidgetStore.swift — the water widget's + and −, without opening the app.
//
// THE WIDGET CANNOT WRITE THE LOG ITSELF. The day's water lives in the app's own SQLite database and
// its per-drink entries in the app's own defaults, and neither is in the App Group the extension can
// reach. So a tap is recorded HERE, in the shared group, as a pending change, and the widget draws the
// published total plus whatever is pending — the wearer sees the glass land at once.
//
// THE APP PICKS IT UP AS SOON AS IT CAN. The tap posts a Darwin notification; the app, which keeps
// running in the background for the strap, drains the queue into the real log the moment it hears it,
// and again whenever it comes to the front. Nothing is lost if it is not running: the queue simply waits.
//
// A CHANGE CARRIES ITS DAY. A glass tapped at 23:59 belongs to the day it was tapped on, even if the app
// only drains it after midnight.

public enum WaterWidgetStore {

    /// One tap: a signed amount in ml on a local day.
    public struct Pending: Codable, Equatable, Sendable {
        public let day: String
        public let ml: Int
        public let at: Date
    }

    /// The glass one tap adds or removes. The Today tile's own glass, so both surfaces agree.
    public static let glassMl = 250
    /// The widget's kind, for a targeted reload.
    public static let widgetKind = "TelosWaterWidget"
    /// Posted across processes when the queue grows.
    public static let darwinName = "com.telos.noop.water.pending"

    private static let key = "noop.water.pending"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Everything waiting to be written into the log.
    public static func pending() -> [Pending] {
        guard let data = defaults?.data(forKey: key),
              let items = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
        return items
    }

    /// The net pending change for `day`.
    public static func pendingMl(day: String) -> Int {
        pending().filter { $0.day == day }.reduce(0) { $0 + $1.ml }
    }

    /// Queue a change, and tell the app.
    public static func enqueue(ml: Int, day: String, at: Date = Date()) {
        guard ml != 0, let defaults else { return }
        var items = pending()
        items.append(Pending(day: day, ml: ml, at: at))
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(darwinName as CFString), nil, nil, true)
    }

    /// Take everything queued. The app calls this and writes each change into the real log.
    public static func drain() -> [Pending] {
        guard let defaults else { return [] }
        let items = pending()
        if !items.isEmpty { defaults.removeObject(forKey: key) }
        return items
    }

    /// What the widget shows for today: the published total plus anything still pending, never below 0.
    public static func shownMl(snapshot: WidgetSnapshot?, now: Date = Date()) -> Int {
        let today = WidgetSnapshot.dayKey(now)
        let published = snapshot?.waterDay == today ? (snapshot?.waterMl ?? 0) : 0
        return max(0, published + pendingMl(day: today))
    }
}

/// + one glass.
public struct AddWaterIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add a glass of water"
    public static var description = IntentDescription("Logs one glass of water without opening the app.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        WaterWidgetStore.enqueue(ml: WaterWidgetStore.glassMl, day: WidgetSnapshot.dayKey())
        WidgetCenter.shared.reloadTimelines(ofKind: WaterWidgetStore.widgetKind)
        return .result()
    }
}

/// − one glass. Never takes the shown total below zero.
public struct RemoveWaterIntent: AppIntent {
    public static var title: LocalizedStringResource = "Remove a glass of water"
    public static var description = IntentDescription("Takes back the last glass of water without opening the app.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        let shown = WaterWidgetStore.shownMl(snapshot: WidgetSnapshot.load())
        let amount = min(WaterWidgetStore.glassMl, shown)
        if amount > 0 {
            WaterWidgetStore.enqueue(ml: -amount, day: WidgetSnapshot.dayKey())
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WaterWidgetStore.widgetKind)
        return .result()
    }
}
#endif
