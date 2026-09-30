import WidgetKit
import SwiftUI
import StrandDesign

/// K10: A Lock Screen / Home Screen widget showing the stored Coach morning brief.
///
/// Design contract (see PRD-K10 + D8):
/// - The widget reads **stored** brief text from the App Group — it NEVER calls the network.
///   The brief is generated on a schedule by `CoachBriefScheduler` (K5) and mirrored into the
///   App Group via `publishToWidget`. The widget just displays whatever text is there.
/// - Tap → opens the Coach tab (via the app's URL scheme / deeplink).
/// - Supported families: `accessoryRectangular` (Lock Screen), `systemSmall` (Home Screen).
///   The Lock Screen accessory shows the first line; the Home Screen widget shows more.
struct CoachBriefEntry: TimelineEntry {
    let date: Date
    let briefText: String?
    let briefDate: Date?
}

struct CoachBriefProvider: TimelineProvider {
    /// App Group keys — must match `CoachBriefScheduler.K.widgetBriefKey` / `.widgetBriefDateKey`.
    private static let briefKey = "coachBrief.widgetText"
    private static let briefDateKey = "coachBrief.widgetDate"

    func placeholder(in context: Context) -> CoachBriefEntry {
        CoachBriefEntry(
            date: Date(),
            briefText: "Recovery is strong today — consider a higher-intensity session this afternoon.",
            briefDate: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CoachBriefEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoachBriefEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes — the app pushes a reload via WidgetCenter when a new brief is
        // published, so this is just a safety net for when the app isn't running.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> CoachBriefEntry {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)
        let text = defaults?.string(forKey: CoachBriefProvider.briefKey)
        let date = defaults?.object(forKey: CoachBriefProvider.briefDateKey) as? Date
        return CoachBriefEntry(date: Date(), briefText: text, briefDate: date)
    }
}

struct CoachBriefWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoachBriefEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            small
        }
    }

    // MARK: - Lock Screen: accessoryRectangular

    /// Lock-screen colour is not colour: this family renders vibrant, so hierarchy is `.primary` /
    /// `.secondary` and the sparkle is the accentable mark (it takes the tint in `.accented`).
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .widgetAccentable()
                Text("Coach")
                    .font(TelosType.scaleFixed)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
                Spacer(minLength: 0)
                if let date = entry.briefDate {
                    Text(date, style: .time)
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                }
            }
            Text(briefDisplay)
                .font(TelosType.footnote)
                .foregroundStyle(HierarchicalShapeStyle.primary)
                .lineLimit(3)
                // 13 pt × 0.85 = 11.05: never below the 11 pt floor.
                .minimumScaleFactor(0.85)
        }
    }

    // MARK: - Lock Screen: accessoryInline

    private var inline: some View {
        Text(briefOneLine)
    }

    // MARK: - Home Screen: systemSmall

    /// Telos (§6.13): the label voice for the title, the brief in `footnote`, its time in `scaleNumber`.
    /// No extra padding: on iOS 17 `containerBackground` already applies the system content margins.
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TelosColor.mint)
                Text("Coach Brief")
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
                Spacer(minLength: 0)
            }
            if entry.briefText == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No brief yet")
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textSecondary)
                    Text("Enable Morning Brief in Coach settings to see today's readiness here.")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(briefDisplay)
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(4)
                    // 13 pt × 0.85 = 11.05: never below the 11 pt floor.
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if let date = entry.briefDate {
                Text(date, format: .dateTime.hour().minute())
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }
        }
    }

    // MARK: - Text helpers

    /// The full brief text for the widget body, or a placeholder when there's no brief.
    private var briefDisplay: String {
        entry.briefText ?? "No brief available."
    }

    /// One-line summary for the inline accessory (capped at ~100 chars).
    private var briefOneLine: String {
        guard let text = entry.briefText else { return "Coach: no brief yet" }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else { return "Coach: \(trimmed)" }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: 100)
        return "Coach: \(trimmed[..<cut].trimmingCharacters(in: .whitespaces))…"
    }
}

struct CoachBriefWidget: Widget {
    static let kind = "CoachBriefWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CoachBriefProvider()) { entry in
            if #available(iOS 17.0, *) {
                // The system strips this for the accessory families on the Lock Screen.
                CoachBriefWidgetView(entry: entry)
                    .containerBackground(for: .widget) { TelosWidgetGround() }
            } else {
                CoachBriefWidgetView(entry: entry)
                    .padding()
                    .background(TelosColor.canvas)
            }
        }
        .configurationDisplayName("Coach Brief")
        .description("Today's coaching brief at a glance. Tap to open Coach.")
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}
