import SwiftUI
import StrandDesign

// MARK: - Updates inbox
//
// The sheet behind the Today header's bell. A calm, newest-first log of what's new — release notes,
// "new data arrived" readings, strap heads-ups, and the Today info-cards the user swiped away (which
// can be restored from here). Tapping an actionable row routes via NavRouter; a dismissed-card row
// offers "Restore to Today". Everything is on-device and non-clinical — informational, never a verdict.
//
// Sheet idiom matches WhatsNewView: a FIXED macOS frame (a macOS sheet hosting a ScrollView collapses
// without one) and iOS presentationDetents via `noopSheetPresentation`.
struct UpdatesInboxView: View {
    @EnvironmentObject var updateStore: UpdateStore
    @EnvironmentObject var router: NavRouter
    let onClose: () -> Void

    /// The changelog, opened by tapping a release row (see `handleTap`). Presented from THIS sheet
    /// rather than routed, so the inbox is still behind it when it closes.
    @State private var showWhatsNew = false

    private var unread: [UpdateItem] { updateStore.sortedItems.filter { !$0.read } }
    private var read: [UpdateItem] { updateStore.sortedItems.filter { $0.read } }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(NoopChromeSurface())
            Divider().overlay(StrandPalette.hairline)
            content
            if !updateStore.items.isEmpty {
                Divider().overlay(StrandPalette.hairline)
                footer
            }
        }
        #if os(macOS)
        // A fixed frame is mandatory — a macOS sheet hosting a ScrollView collapses to nothing without
        // one (same reason WhatsNewView pins 560×640).
        .frame(width: 460, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        // AT THE ROOT OF THE CHAIN, deliberately: attached to the `if !items.isEmpty` footer branch it
        // would be torn down the moment the last item cleared, which is how a presenter ends up never
        // presenting. Nothing here depends on the list's contents.
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("INBOX").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Updates")
                    .font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle).font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var subtitle: String {
        let n = updateStore.unreadCount
        if updateStore.items.isEmpty { return String(localized: "What's new in the app and your data") }
        return n == 0 ? String(localized: "All caught up") : String(localized: "\(n) unread")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if updateStore.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if !unread.isEmpty {
                        section("NEW", items: unread)
                    }
                    if !read.isEmpty {
                        section("EARLIER", items: read)
                    }
                }
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
        }
    }

    private func section(_ label: LocalizedStringKey, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(label).font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(items) { item in
                UpdateRow(item: item, onTap: { handleTap(item) }, onRestore: { restore(item) })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: "bell.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("You're all caught up.")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("New release notes and fresh data will land here.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.clearAll() }
            } label: {
                Label("Clear all", systemImage: "trash")
                    .font(StrandFont.subhead)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textSecondary)
            .disabled(updateStore.items.isEmpty)

            Spacer()

            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.markAllRead() }
            } label: {
                Text("Mark all read").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(updateStore.unreadCount == 0)
        }
        .padding(16)
    }

    // MARK: Actions

    /// Tapping a row marks it read, then routes if it carries a known deep link (else just stays open).
    private func handleTap(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
        // THE ROW THAT SAID "TAP TO READ WHAT'S NEW" DID NOT OPEN IT. A release item is seeded with no
        // deep link (`UpdateStore.seedWhatsNewIfNeeded`) and its own copy instructs a tap, so the tap
        // fell through the guard below and only marked the row read — while the notes themselves stayed
        // clipped at two lines. Release rows now open the changelog the app already ships, which is the
        // one place those notes live; the row's words are unchanged because they are now true.
        //
        // `.whatsNew` ONLY, not `.newVersion`: that one means "a release you do NOT have", and the
        // bundled changelog describes the version you are already running — opening it there would
        // answer a different question than the row asked. Those rows carry their instructions and the
        // remote notes in their own text, so the row expands them instead (see `UpdateRow`).
        if item.kind == .whatsNew {
            showWhatsNew = true
            return
        }
        guard let key = item.deepLink, let dest = NavRouter.Destination(deepLinkKey: key) else { return }
        // Route via the shell, then close this sheet so the destination is visible.
        router.requestedDestination = dest
        onClose()
    }

    /// Restore a dismissed Today card: flip its `@AppStorage` flag back (so it reappears), drop the
    /// inbox item, and close so the card is on screen.
    private func restore(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        if let payload = item.restorePayload {
            // Clear the dismissed flag directly using the SAME key TodayView writes, so a Today that's
            // already mounted under the sheet picks the card back up immediately.
            UserDefaults.standard.set(false, forKey: TodayCardDismissal.flagKey(payload))
        }
        updateStore.requestRestore(item)
        onClose()
    }
}

// MARK: - Row

private struct UpdateRow: View {
    let item: UpdateItem
    let onTap: () -> Void
    let onRestore: () -> Void

    /// Whether this row's clipped message is showing in full. See `hasDestination`.
    @State private var expanded = false

    /// Whether a tap on this row has somewhere to go — a release row opens the changelog, a `.reading`
    /// row routes by its deep link. Rows with neither used to SWALLOW the tap: the whole card is a tap
    /// target with a press state and a VoiceOver button trait, and tapping it only marked it read while
    /// its message stayed clipped at two lines. A `.newVersion` row composes the remote release notes
    /// into that message, so the text the tap could not reach was the point of the row. Those rows now
    /// expand instead, which is a real answer to the finger.
    private var hasDestination: Bool {
        item.kind == .whatsNew || item.deepLink != nil
    }

    /// Spelled out as a typed property rather than inlined as `expanded ? nil : 2`: `lineLimit` has
    /// several overloads and a bare ternary against `nil` is exactly the expression that resolves in an
    /// editor and not in a build.
    private var messageLineLimit: Int? { expanded ? nil : 2 }

    var body: some View {
        NoopCard(tint: item.read ? nil : tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(StrandFont.headline)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(StrandFont.headline.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(messageLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(relativeDate)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 1)
                    }
                    Spacer(minLength: 0)
                    if !item.read {
                        Circle().fill(StrandPalette.statusCritical)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                    }
                }
                if item.kind == .dismissedCard {
                    Button(action: onRestore) {
                        Label("Restore to Today", systemImage: "arrow.uturn.up")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
            // Animated so the card grows into its full height instead of snapping the rows below it.
            if !hasDestination { withAnimation(StrandMotion.fade) { expanded.toggle() } }
        }
        .strandPressable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.read ? "\(item.title). \(item.message)"
                                       : "Unread. \(item.title). \(item.message)")
    }

    private var symbol: String {
        switch item.kind {
        case .dismissedCard: return "rectangle.on.rectangle"
        case .whatsNew:      return "sparkles"
        case .reading:       return "waveform.path.ecg"
        case .strapAlert:    return "exclamationmark.triangle"
        // Distinct from `.whatsNew`'s sparkles on purpose: this is something you have NOT got yet.
        case .newVersion:    return "arrow.down.circle"
        }
    }

    /// A per-kind tint drawn from the domain palette so each row reads in its own colour world.
    private var tint: Color {
        switch item.kind {
        case .dismissedCard: return StrandPalette.textSecondary
        case .whatsNew:      return StrandPalette.accent
        case .reading:       return StrandPalette.restColor
        case .strapAlert:    return StrandPalette.statusWarning
        case .newVersion:    return StrandPalette.accent
        }
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: item.date, relativeTo: Date())
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state in `@AppStorage` under a stable per-card key. The
// inbox restores a card by clearing that same key, so the key shape lives in ONE place both sides use.
enum TodayCardDismissal {
    /// The `@AppStorage` bool key for a Today info-card's dismissed flag, by stable card id.
    static func flagKey(_ cardID: String) -> String { "noop.todayCard.\(cardID).dismissed" }
}
