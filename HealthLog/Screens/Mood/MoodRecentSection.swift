import SwiftUI

/// v0.10.0 W-Mood-A — zone-7 recent-entries preview (DESIGN-A §4).
///
/// The last 7 entries as a calm list (flat rows on canvas, hairline dividers —
/// NOT an inset-grouped table), each whole-row tappable → `EditMoodSheet`
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
                HLSectionLabel("Recent entries")

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            onEdit(entry)
                        } label: {
                            MoodEntryRow(entry: entry)
                                .padding(.vertical, HLSpace.sm)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Double-tap to edit"))
                        if index < entries.count - 1 {
                            Divider().overlay(HLColor.separator)
                        }
                    }
                }

                if totalCount > entries.count {
                    HLButton(String(localized: "Show all"), icon: "chevron.right", variant: .ghost, size: .regular) {
                        onShowAll()
                    }
                    .accessibilityHint(Text("Opens the full history"))
                }
            }
        }
    }
}
