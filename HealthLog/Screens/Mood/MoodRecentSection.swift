import SwiftUI

/// Zone-7 recent-entries preview.
///
/// The last 7 entries as rows in one card, each whole-row tappable → `EditMoodSheet`
/// (closes the swipe-only edit gap; R-Mood-1 §A). A "Show all" footer pushes
/// the full history. No swipe affordances on the preview — destructive actions
/// live in the full history.
struct MoodRecentSection: View {
    let entries: [MoodEntry]
    let totalCount: Int
    /// Tap a row → host presents `EditMoodSheet` for the entry.
    var onEdit: (MoodEntry) -> Void
    /// Tap "Show all" → host pushes the full history.
    var onShowAll: () -> Void

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionHeader("Recent entries", rank: .area)

                HLCard(layout: .rows) {
                    ForEach(entries) { entry in
                        HLRowButton {
                            onEdit(entry)
                        } label: {
                            MoodEntryRow(entry: entry)
                        }
                        .accessibilityHint(Text("Double-tap to edit"))
                    }
                }

                if totalCount > entries.count {
                    HLLinkButton("Show all") {
                        onShowAll()
                    }
                    .accessibilityHint(Text("Opens the full history"))
                }
            }
            .moodSectionGap(after: HLSpace.sm)
        }
    }
}
