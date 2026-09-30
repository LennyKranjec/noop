import SwiftUI
import StrandDesign

// MARK: - Workout selection browser
//
// Full-screen activity picker for live start (and the merge-name reuse). Catalogue, recents, GPS
// flags, and `onStart` / `RecentSportsPrefs` are unchanged — only the presentation is rebuilt into
// large destination cards with native Liquid Glass search.
//
// TELOS 2.0 (DESIGN_V2 §4.9, §6.7): the canvas ground; activity cards and recent chips are FLAT faux glass
// (translucent fill + the luminous 1 pt edge — no shadow, no material: they sit in a scroll view, where
// glass is never allowed); the only glass is the close control (role 5), whose pre-iOS-26 fallback is the
// solid `nativeLiquidGlassFallbackSurface`.

/// Public entry used by Live / Workouts. Keeps the prior `onStart` + optional title overrides so the
/// merge-name prompt can reuse the same browser.
struct StartWorkoutSheet: View {
    let onStart: (_ sport: String) -> Void
    private let heading: String
    private let explainer: String
    private let actionVerb: String

    init(title: String? = nil, subtitle: String? = nil, actionVerb: String? = nil,
         onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        self.heading = title ?? String(localized: "Choose a workout")
        self.explainer = subtitle
            ?? String(localized: "Pick an activity to begin recording heart rate, effort, peak, and average.")
        self.actionVerb = actionVerb ?? String(localized: "Start")
    }

    var body: some View {
        WorkoutSelectionScreen(heading: heading, explainer: explainer, actionVerb: actionVerb,
                               onStart: onStart)
    }
}

// MARK: - Screen

struct WorkoutSelectionScreen: View {
    let heading: String
    let explainer: String
    let actionVerb: String
    let onStart: (_ sport: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }
    private var recentSports: [WorkoutCatalog.Sport] {
        RecentSportsPrefs.recent().compactMap { WorkoutCatalog.sport(named: $0) }
    }
    private var showRecent: Bool { trimmedQuery.isEmpty && !recentSports.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    headerCopy
                    WorkoutSearchField(query: $query, isFocused: $searchFocused)
                        .padding(.top, NoopMetrics.space1)

                    if showRecent {
                        recentSection
                    }

                    if filtered.isEmpty {
                        emptyResults
                            .padding(.top, NoopMetrics.space8)
                    } else {
                        LazyVStack(spacing: TelosSpace.cardGap) {
                            ForEach(filtered) { sport in
                                WorkoutSelectionCard(sport: sport, actionVerb: actionVerb) {
                                    select(sport.name)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.space5)
                .padding(.top, NoopMetrics.space2)
                .padding(.bottom, NoopMetrics.space10)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .background {
                TelosColor.canvas.ignoresSafeArea()
            }
            .navigationBarTitleDisplayModeCompat()
            .toolbar {
                ToolbarItem(placement: .topBarTrailingCompat) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TelosType.glyphControl)
                            .foregroundStyle(TelosColor.textPrimary)
                            .frame(width: 36, height: 36)
                            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                            .contentShape(Circle())
                    }
                    .nativeLiquidGlassWorkoutSelectionControl()
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(heading)
                .font(TelosType.title)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(explainer)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Recent")
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(recentSports) { sport in
                        RecentWorkoutChip(sport: sport) { select(sport.name) }
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: NoopMetrics.space3) {
            Image(systemName: "magnifyingglass")
                .font(TelosType.glyphEmpty)
                .foregroundStyle(TelosColor.textTertiary)
            Text("No workouts found")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Try a different activity name.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space8)
        .accessibilityElement(children: .combine)
    }

    private func select(_ name: String) {
        searchFocused = false
        RecentSportsPrefs.recordSelection(name)
        onStart(name)
        dismiss()
    }
}

// MARK: - Search

struct WorkoutSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        NoopLiquidGlassSearchField(text: $query,
                                   prompt: String(localized: "Search workouts"),
                                   isFocused: isFocused)
    }
}

// MARK: - Recent chip

struct RecentWorkoutChip: View {
    let sport: WorkoutCatalog.Sport
    let onTap: () -> Void

    private var accent: Color { StrandPalette.effortColor }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NoopMetrics.space2) {
                WorkoutTypeIcon(workoutType: sport.name, size: 18, weight: .semibold, color: accent)
                Text(sport.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, TelosSpace.m)
            .padding(.vertical, TelosSpace.s)
            .frame(minHeight: TelosSpace.hitTarget)
            .background(Capsule(style: .continuous).fill(TelosColor.glassFill))
            .overlay(Capsule(style: .continuous).strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
            .contentShape(Capsule())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text("\(sport.name) workout"))
        .accessibilityHint(Text("Double tap to start"))
    }
}

// MARK: - Activity card

struct WorkoutSelectionCard: View {
    let sport: WorkoutCatalog.Sport
    let actionVerb: String
    let onSelect: () -> Void

    private var accent: Color { StrandPalette.effortColor }
    private var meta: [WorkoutActivityMeta.Item] {
        WorkoutActivityMeta.items(for: sport)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                WorkoutTypeIcon(workoutType: sport.name, size: 30, weight: .medium, color: accent)
                    .frame(width: 52, height: 52)
                    .background(accent.opacity(TelosOpacity.wash), in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                        .strokeBorder(accent.opacity(TelosOpacity.border), lineWidth: TelosStroke.line))

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(sport.name)
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.isEmpty {
                        WorkoutActivityMetadataView(items: meta)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(TelosType.glyphControl)
                    .foregroundStyle(TelosColor.onAccent)
                    .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                    .background(Circle().fill(StrandPalette.accent))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, TelosSpace.l)
            .padding(.vertical, TelosSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Flat faux glass (the card surface honours the root card-opacity environment). NO shadow:
            // these cards scroll, and a shadow per card is exactly the stacked cost §2.1 rule 4 forbids.
            .background {
                FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card)
            }
            .contentShape(RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous))
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text("Double tap to \(actionVerb.lowercased())"))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabelText: String {
        let labels = meta.map(\.text)
        if labels.isEmpty { return "\(sport.name) workout" }
        return "\(sport.name) workout, \(labels.joined(separator: ", "))"
    }
}

// MARK: - Metadata

enum WorkoutActivityMeta {
    struct Item: Equatable {
        var symbol: String?
        var text: String
    }

    /// Labels derived only from catalogue flags / known types — no invented capabilities.
    static func items(for sport: WorkoutCatalog.Sport) -> [Item] {
        var items: [Item] = []
        if sport.isDistanceSport {
            items.append(Item(symbol: "location.fill", text: "GPS"))
        }
        if let type = KnownWorkoutType.exact(matching: sport.name) {
            switch type {
            case .treadmillRun, .treadmillWalk, .indoorCycle, .poolSwim, .rowMachine, .elliptical:
                items.append(Item(symbol: nil, text: "Indoor"))
            case .running, .walking, .hiking, .cycling, .openWaterSwim, .rowing, .skiing, .snowboarding:
                items.append(Item(symbol: nil, text: "Outdoor"))
            case .strength, .bodybuilding, .weightlifting:
                items.append(Item(symbol: nil, text: "Strength"))
            case .yoga, .pilates, .stretching:
                items.append(Item(symbol: nil, text: "Mindfulness"))
            case .hiit:
                items.append(Item(symbol: nil, text: "Cardio"))
            default:
                break
            }
        }
        return items
    }
}

struct WorkoutActivityMetadataView: View {
    let items: [WorkoutActivityMeta.Item]

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(TelosType.glyphDelta)
                    }
                    Text(item.text)
                        .font(TelosType.footnote)
                }
                .foregroundStyle(TelosColor.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Presentation helper

extension View {
    /// Full-screen workout browser on iOS; plain sheet on macOS (no fullScreenCover there).
    @ViewBuilder
    func workoutSelectionCover(isPresented: Binding<Bool>,
                               @ViewBuilder content: @escaping () -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func workoutSelectionCover<Item: Identifiable>(item: Binding<Item?>,
                                                   @ViewBuilder content: @escaping (Item) -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

// MARK: - Native Liquid Glass chrome (selection browser)

private extension View {
    /// The close control's chrome — glass role 5 (a close button on a full-screen cover). iOS 26 uses the
    /// platform glass button; macOS and older iOS the ONE solid fallback (`nativeLiquidGlassFallbackSurface`:
    /// `surfaceRaised` + 1 pt `line`) — no material, no blur.
    @ViewBuilder
    func nativeLiquidGlassWorkoutSelectionControl(capsule: Bool = false) -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .regular, capsule: capsule) {
            Group {
                if capsule {
                    self.buttonStyle(TelosPressButtonStyle())
                        .nativeLiquidGlassFallbackSurface(Capsule(style: .continuous))
                } else {
                    self.buttonStyle(TelosPressButtonStyle())
                        .nativeLiquidGlassFallbackSurface(Circle())
                }
            }
        }
    }

    /// Native Liquid Glass search field chrome. iOS 26 uses `glassEffect`; macOS / older OS use a
    /// raised solid surface (not a simulated glass stack).
    @ViewBuilder
    func nativeLiquidGlassSearchField() -> some View {
        self.nativeLiquidGlassSearchChrome()
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeCompat() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private extension ToolbarItemPlacement {
    static var topBarTrailingCompat: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

#if DEBUG
#Preview("Choose a workout") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
