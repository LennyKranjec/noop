#if os(iOS)
import Foundation

extension AppModel {
    /// Write the water widget's queued taps into the real log, then republish the widget.
    ///
    /// Each tap keeps the day it was made on. An add goes in as a drink; a removal takes back from the
    /// newest drinks first, as the Today tile's minus does.
    @MainActor
    func drainPendingWater() async {
        let items = WaterWidgetStore.drain()
        guard !items.isEmpty else { return }
        for item in items {
            if item.ml > 0 {
                await repo.logHydration(amountMl: item.ml, day: item.day)
            } else {
                await repo.removeHydration(amountMl: -item.ml, day: item.day)
            }
        }
        await WidgetSnapshot.publishWater(from: self)
    }

    /// Execute any actions queued by App Intents while the app was suspended (mark moment, buzz,
    /// ask coach). Call when the app becomes active. The optional `router` lets the ask-coach
    /// intent navigate to the Coach tab after sending the question.
    func drainPendingIntents(router: NavRouter? = nil) {
        for item in PendingIntents.drain() {
            switch item.action {
            case .markMoment: markMoment(at: item.date ?? Date())
            // #921: the "Buzz Strap" Siri shortcut logged its write but a WHOOP 4.0 never vibrated.
            // The one-shot routine sends the confirmed pattern + RUN_ALARM sequence, acked, so a
            // busy just-foregrounded BLE link can't silently drop it.
            case .buzz:       buzzStrapOnce()
            // K9: "Ask Coach" via Siri — send the queued question to the Coach engine and navigate
            // to the Coach tab so the user sees the response. The question is consumed from a
            // dedicated key (one at a time).
            case .askCoach:
                if let question = PendingIntents.consumeCoachQuestion() {
                    router?.openCoach()
                    Task { @MainActor in
                        await coach.send(question)
                    }
                }
            }
        }
    }
}
#endif
