import SwiftUI
import StrandDesign

// TelosMomentPresenter.swift — the ONE presenter for full-screen moments (DESIGN_V2 decisions 7 and 17).
//
// WHY ONE, AT THE ROOT. A screen that attaches its own `.fullScreenCover` for a moment takes the moment down
// with it when the screen goes away — the torn-down-presenter bug this project has shipped three times. So
// every moment (a goal reached, the optimum, the stress diagnostic, and later quests / penalties / PRs / the
// level settling) is handed to this queue, and the shell draws whatever is `current` over every tab.
//
// THE QUEUE. Ordered by `TelosMoment.showsBefore` (priority), arrival order on a tie; one at a time, never
// stacked; deduped by `id` for the life of the process (the sources keep their own fire-once guards across
// launches). A moment is HELD — not dropped — while an active workout, the morning flow, or another sheet /
// full-screen card is up, and shown as soon as that clears. A moment the wearer asked for themselves (the
// stress tile's "open the diagnostic") is not held for a workout or the morning flow, only for a sheet: an
// overlay under a sheet would be invisible and its haptic would fire into nothing.
//
// THE STRAP. A reward / penalty moment asks the strap-cue system for its buzz ONCE per moment id, when it is
// actually put on screen (`StrapCueEngine.fire(.reward/.penalty, eventId: moment.id)`, which also dedupes by
// event and applies the budget, quiet hours and the sleep window). The phone haptic is the view's
// (`TelosMomentView` plays `moment.haptic` once on entrance) — the presenter never plays a second pattern.
//
// COST (§2.1 rule 8): no timer, no clock. Work happens only on enqueue / dismiss / a suppression change. The
// overlay view itself animates only its entrance (≤ 1.4 s, `TelosMomentView`), then rests.

/// An optional second, quieter action on a moment (the stress diagnostic's IGNORE). Drawn as a ghost
/// button under the figures; like the primary, it closes the moment.
struct TelosMomentSecondaryAction {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void = {}) {
        self.title = title
        self.action = action
    }
}

/// Where a moment's primary action asks the shell to navigate. The presenter cannot push a screen itself —
/// the shell observes `requestedRoute`, presents it, and calls `consumeRoute()`.
enum TelosMomentRoute: String, Equatable, Identifiable {
    /// The Goals screen ("Set the next goal").
    case goals

    var id: String { rawValue }
}

@MainActor
final class TelosMomentPresenter: ObservableObject {

    static let shared = TelosMomentPresenter()

    /// The moment on screen now; nil when none is.
    @Published private(set) var current: TelosMoment?
    /// A navigation the last primary action asked for (see `TelosMomentRoute`).
    @Published private(set) var requestedRoute: TelosMomentRoute?

    /// Why moments are being held right now. Set by the shell.
    struct Suppression: Equatable {
        /// A workout is running.
        var workout = false
        /// The morning flow is on screen.
        var morningFlow = false
        /// A sheet, a first-run gate, or another full-screen card (the day's penalty card, a quest pop-up)
        /// is over the tabs.
        var covered = false

        static let none = Suppression()
    }

    private struct Entry {
        let moment: TelosMoment
        /// Arrival order, the tie-break inside one priority.
        let sequence: Int
        let onPrimary: (() -> Void)?
        let onClose: (() -> Void)?
        let secondary: TelosMomentSecondaryAction?
        let requestedByWearer: Bool
    }

    private var queue: [Entry] = []
    private var active: Entry?
    private var suppression = Suppression.none
    private var sequence = 0
    /// Every id ever enqueued this process — the dedupe.
    private var seen: Set<String> = []
    /// Every id whose strap cue has been requested — never twice for one event.
    private var cued: Set<String> = []
    /// The strap hook. Injected so tests can observe it; the app uses `StrapCueEngine.shared`.
    private let strapCue: (TelosStrapCue, String) -> Void
    /// The pause between one moment closing and the next one showing. It is also what lets a primary action
    /// that opens a sheet (BREATHE, "Set the next goal") raise the suppression BEFORE the next moment would
    /// be drawn under that sheet. 0 = advance at once (tests).
    private let gap: TimeInterval
    /// A gap is running: nothing new is put on screen until it ends.
    private var inGap = false

    init(strapCue: ((TelosStrapCue, String) -> Void)? = nil, gap: TimeInterval = 0.35) {
        self.gap = gap
        self.strapCue = strapCue ?? { cue, eventId in
            switch cue {
            case .reward: StrapCueEngine.shared.fire(.reward, eventId: eventId)
            case .penalty: StrapCueEngine.shared.fire(.penalty, eventId: eventId)
            }
        }
    }

    // MARK: - Enqueue

    /// Queue a moment. A second call with an id already seen this process is ignored.
    ///
    /// - Parameters:
    ///   - onPrimary: runs when the wearer takes the primary action (the moment then closes). With no
    ///     `onPrimary` the primary button is not drawn, whatever `primaryActionTitle` says.
    ///   - onClose: runs whenever the moment leaves the screen for good — primary, secondary, the close
    ///     control, a swipe down, the VoiceOver escape, or a `withdraw`. The place for a source's
    ///     "dismissed" bookkeeping.
    ///   - secondary: an optional quieter second action (it closes the moment too).
    ///   - requestedByWearer: the wearer opened this themselves; it is not held for a workout or the
    ///     morning flow (only for a sheet).
    func enqueue(_ moment: TelosMoment,
                 onPrimary: (() -> Void)? = nil,
                 onClose: (() -> Void)? = nil,
                 secondary: TelosMomentSecondaryAction? = nil,
                 requestedByWearer: Bool = false) {
        guard !seen.contains(moment.id) else { return }
        seen.insert(moment.id)
        sequence += 1
        queue.append(Entry(moment: moment, sequence: sequence, onPrimary: onPrimary, onClose: onClose,
                           secondary: secondary, requestedByWearer: requestedByWearer))
        advance()
    }

    /// Take a moment back that no longer applies (the automatic stress alert once the reading has
    /// dropped). Queued or on screen; its `onClose` runs.
    func withdraw(id: String) {
        if let i = queue.firstIndex(where: { $0.moment.id == id }) {
            let entry = queue.remove(at: i)
            entry.onClose?()
        }
        if let entry = active, entry.moment.id == id {
            finish(entry, then: nil)
        }
    }

    /// Whether a moment with this id is queued or on screen.
    func isPending(id: String) -> Bool {
        active?.moment.id == id || queue.contains { $0.moment.id == id }
    }

    // MARK: - The shell's side

    /// The shell reports what is up. Lifting the last reason shows the next moment; raising one while a
    /// moment is on screen puts it back at the head of the queue (it comes back, it is not lost).
    func setSuppression(_ s: Suppression) {
        guard s != suppression else { return }
        suppression = s
        if let entry = active, isHeld(entry) {
            active = nil
            current = nil
            queue.append(entry)
        }
        advance()
    }

    /// The primary action of the moment on screen.
    func takePrimary() {
        guard let entry = active else { return }
        finish(entry, then: entry.onPrimary)
    }

    /// The secondary action of the moment on screen.
    func takeSecondary() {
        guard let entry = active else { return }
        finish(entry, then: entry.secondary?.action)
    }

    /// Close / swipe / escape on the moment on screen.
    func dismissCurrent() {
        guard let entry = active else { return }
        finish(entry, then: nil)
    }

    /// Ask the shell to open a route (used from a moment's `onPrimary`).
    func requestRoute(_ route: TelosMomentRoute) { requestedRoute = route }

    /// The shell has presented `requestedRoute`.
    func consumeRoute() { requestedRoute = nil }

    /// The secondary action of the moment on screen, for the overlay to draw.
    var currentSecondaryTitle: String? { active?.secondary?.title }

    /// Whether the moment on screen has a primary action to draw.
    var currentHasPrimary: Bool { active?.onPrimary != nil }

    // MARK: - Wiring (once, from the app root)

    private var wired = false

    /// Connect the logic stores that raise moments. Idempotent.
    ///
    /// Goals (HF): a reached goal's primary "Set the next goal" opens Goals.
    func wireSources() {
        guard !wired else { return }
        wired = true
        GoalStore.shared.momentSink = { [weak self] moment in
            self?.enqueue(moment, onPrimary: { [weak self] in self?.requestRoute(.goals) })
        }
    }

    // MARK: - Private

    private func isHeld(_ entry: Entry) -> Bool {
        if suppression.covered { return true }
        if entry.requestedByWearer { return false }
        return suppression.workout || suppression.morningFlow
    }

    private func finish(_ entry: Entry, then action: (() -> Void)?) {
        active = nil
        current = nil
        action?()
        entry.onClose?()
        guard gap > 0 else {
            advance()
            return
        }
        inGap = true
        let nanos = UInt64(gap * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            self.inGap = false
            self.advance()
        }
    }

    private func advance() {
        guard active == nil, !inGap else { return }
        let ordered = queue.sorted { a, b in
            if TelosMoment.showsBefore(a.moment, b.moment) { return true }
            if TelosMoment.showsBefore(b.moment, a.moment) { return false }
            return a.sequence < b.sequence
        }
        guard let next = ordered.first(where: { !isHeld($0) }),
              let index = queue.firstIndex(where: { $0.sequence == next.sequence }) else { return }
        queue.remove(at: index)
        active = next
        current = next.moment
        if let cue = next.moment.strapCue, !cued.contains(next.moment.id) {
            cued.insert(next.moment.id)
            strapCue(cue, next.moment.id)
        }
    }
}

// MARK: - The overlay

/// Draws the presenter's current moment full screen. Hosted ONCE, as the outermost overlay of the shell
/// (above the tab bar and the level strip). Observes only the presenter, which publishes on enqueue /
/// dismiss — never per frame.
struct TelosMomentOverlay: View {
    @ObservedObject var presenter: TelosMomentPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let moment = presenter.current {
                TelosMomentView(
                    moment: moment,
                    onPrimary: primaryAction,
                    onDismiss: { presenter.dismissCurrent() }
                ) {
                    if let title = presenter.currentSecondaryTitle {
                        Button {
                            presenter.takeSecondary()
                        } label: {
                            Text(verbatim: title)
                        }
                        .buttonStyle(NoopGhostButtonStyle())
                    }
                }
                // One moment replaces the next: the id keeps SwiftUI from reusing the previous moment's
                // entrance state (its `entered` / fill) for a different moment.
                .id(moment.id)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : TelosMotion.fade, value: presenter.current?.id)
    }

    /// nil when the moment on screen has no primary action, so the view draws no button.
    private var primaryAction: (() -> Void)? {
        guard presenter.currentHasPrimary else { return nil }
        let presenter = self.presenter
        return { presenter.takePrimary() }
    }
}
