import AppIntents
import SwiftUI
import WidgetKit

/// **v0.10.0 W-Mood-B — interactive mood widget.**
///
/// Home-screen (`systemSmall` / `systemMedium`) + Lock-Screen
/// (`accessoryRectangular` / `accessoryCircular`). Merges the *glance* and the
/// *quick-log* ideas into ONE widget: it shows the user's latest mood from the
/// App Group snapshot (no network in the widget process).
///
/// **v0.10.0 W10 tap-target split (HIG ≥ 44 pt):** the interactive row of five
/// tap-a-face `Button(intent:)`s — each quick-logging a mood through the
/// already-shipped ``LogMoodIntent`` (server-first, runs in the extension
/// process via the shared Keychain token, no parallel write path) — lives on
/// **`systemMedium` only**, where each face gets a `minHeight: 44` target.
/// **`systemSmall`** can't fit five 44 pt targets, so it is a single
/// whole-tile deep-link (`widgetURL` → `healthlog://mood`) that opens the
/// in-app mood quick-entry sheet; it keeps the glance display. The Lock-Screen
/// accessory variants are non-interactive glanceable per the accessory
/// contract. Monochrome throughout; mood faces are SF Symbols, not color emoji.
struct MoodWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.mood, provider: MoodProvider()) { entry in
            MoodWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.mood.title"))
        .description(Text("widget.mood.description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular
        ])
    }
}

// MARK: - Timeline entry + provider

/// One frame of the mood timeline. `Sendable` (value type of `Sendable`
/// members) so it crosses the nonisolated `TimelineProvider` boundary cleanly
/// under Swift 6 strict concurrency.
struct MoodEntryTimeline: TimelineEntry {
    let date: Date
    let recentMood: WidgetSnapshot.RecentMood?
}

/// Reads the App Group snapshot + builds a refresh timeline. The app calls
/// `WidgetCenter.reloadTimelines(ofKind: .mood)` on every mood change for
/// immediacy; the timeline also reloads at the next local midnight so the
/// "logged today" state resets honestly.
struct MoodProvider: TimelineProvider {
    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    func placeholder(in _: Context) -> MoodEntryTimeline {
        MoodEntryTimeline(date: .now, recentMood: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (MoodEntryTimeline) -> Void) {
        let snapshot = store.read() ?? .placeholder
        completion(MoodEntryTimeline(date: .now, recentMood: snapshot.recentMood))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<MoodEntryTimeline>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        let entry = MoodEntryTimeline(date: now, recentMood: snapshot.recentMood)
        // Reload at next local midnight so "logged today" flips back to the
        // quick-log prompt for the new day even if the app never opens.
        let nextMidnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60 * 60 * 6)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }
}

// MARK: - Mood glyphs (monochrome SF Symbols)

enum MoodGlyph {
    /// SF Symbol face for a 1…5 mood score. Monochrome — the symbol renders
    /// in the widget's foreground tint, never a color emoji.
    static func symbol(for score: Int) -> String {
        switch max(1, min(5, score)) {
        case 1: "face.dashed"
        case 2: "cloud.rain"
        case 3: "minus.circle"
        case 4: "face.smiling"
        default: "face.smiling.inverse"
        }
    }
}

// MARK: - Views

private struct MoodWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoodEntryTimeline

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            homeMedium
        default:
            homeSmall
        }
    }

    // MARK: Home-screen sizes (interactive)

    /// systemSmall is a single whole-tile deep-link (HIG ≥ 44 pt) — five
    /// interactive faces won't fit, so the tile shows the glance + a
    /// quick-log prompt and tapping anywhere opens the in-app mood
    /// quick-entry sheet via `widgetURL`. No inline `Button(intent:)`s here.
    private var homeSmall: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            glanceLine
            smallTapHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(Self.moodDeepLink)
    }

    /// The "Tap to log" affordance on `systemSmall`. The whole tile is the
    /// 44 pt+ tap target (via `widgetURL`), so this is presentation only.
    private var smallTapHint: some View {
        Label {
            Text("widget.mood.tap_to_log")
                .font(.caption2.weight(.semibold))
        } icon: {
            Image(systemName: "plus.circle.fill")
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(LAColor.accent)
        .lineLimit(1)
    }

    private var homeMedium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            glanceLine
            Spacer(minLength: 0)
            faceRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        Label {
            Text("widget.mood.header")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LAColor.textSecondary)
        } icon: {
            Image(systemName: "face.smiling")
                .foregroundStyle(LAColor.accent)
        }
        .labelStyle(.titleAndIcon)
    }

    /// "Good · logged 14:20" when there's a today entry, else the quick-log
    /// prompt.
    @ViewBuilder private var glanceLine: some View {
        if let mood = entry.recentMood, mood.isToday() {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(moodLevelName(mood.score))
                        .font(.headline)
                        .foregroundStyle(LAColor.text)
                } icon: {
                    Image(systemName: MoodGlyph.symbol(for: mood.score))
                        .foregroundStyle(LAColor.text)
                }
                Text(loggedLine(mood.loggedAt))
                    .font(.caption)
                    .foregroundStyle(LAColor.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("widget.mood.prompt")
                .font(.headline)
                .foregroundStyle(LAColor.text)
                .lineLimit(1)
        }
    }

    /// The five tap-a-face quick-log buttons, each an interactive
    /// `LogMoodIntent`. Monochrome SF Symbols. **systemMedium only** — each
    /// button gets a `minHeight: 44` HIG-compliant tap target (the small
    /// family can't fit five and uses the whole-tile `widgetURL` instead).
    private var faceRow: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { score in
                Button(intent: WidgetIntents.logMood(score: score)) {
                    Image(systemName: MoodGlyph.symbol(for: score))
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LAColor.text)
                .accessibilityLabel(faceA11yLabel(score))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Deep link the `systemSmall` whole-tile tap opens — the in-app mood
    /// quick-entry sheet (`AppRouter` routes `healthlog://mood` →
    /// `requestMoodQuickEntry()`).
    private static let moodDeepLink = URL(string: "healthlog://mood")

    // MARK: Lock-Screen accessories (glanceable, non-interactive)

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let mood = entry.recentMood, mood.isToday() {
                Label {
                    Text(moodLevelName(mood.score)).lineLimit(1)
                } icon: {
                    Image(systemName: MoodGlyph.symbol(for: mood.score))
                }
                .font(.headline)
                // Lock-screen accessory: the mood level (face + word) is PHI —
                // redact when the device is locked (QA-b198 Sec-L-3).
                .privacySensitive()
                Text(loggedLine(mood.loggedAt))
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Label {
                    Text("widget.mood.empty")
                } icon: {
                    Image(systemName: "face.smiling")
                }
                .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: glyphForAccessory)
                .font(.title2)
                // The face glyph encodes the mood level — redact on lock
                // (QA-b198 Sec-L-3).
                .privacySensitive()
        }
        .accessibilityElement()
        .accessibilityLabel(accessoryLabel)
    }

    private var glyphForAccessory: String {
        if let mood = entry.recentMood, mood.isToday() {
            return MoodGlyph.symbol(for: mood.score)
        }
        return "face.smiling"
    }

    private var accessoryLabel: Text {
        if let mood = entry.recentMood, mood.isToday() {
            Text("widget.mood.header") + Text(": ") + Text(moodLevelName(mood.score))
        } else {
            Text("widget.mood.empty")
        }
    }

    // MARK: Copy helpers

    /// Localized level name (Lousy…Great) reusing the intent-enum catalog
    /// keys so the widget and Siri speak the same words.
    private func moodLevelName(_ score: Int) -> String {
        switch max(1, min(5, score)) {
        case 1: String(localized: "Lousy")
        case 2: String(localized: "Bad")
        case 3: String(localized: "Okay")
        case 4: String(localized: "Good")
        default: String(localized: "Great")
        }
    }

    private func faceA11yLabel(_ score: Int) -> String {
        String(format: String(localized: "widget.mood.a11y.log"), moodLevelName(score))
    }

    private func loggedLine(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return String(format: String(localized: "widget.mood.logged_at"), time)
    }
}
