import SwiftUI

/// The "Show all measurements" drill-down row at the bottom of
/// `ChartDetailScreen`. Pushes `MeasurementListScreen(kind:)`.
///
/// **v0.11 W-B:** extracted out of `ChartDetailScreen.swift` so the host file
/// stays under the 1000-line SwiftLint ceiling after the inline target
/// reference panel wiring landed (same pattern as `InsufficientDataCard` and
/// `HeroDeltaChip`).
struct DrillDownRow: View {
    let kind: MetricKind
    let count: Int
    /// v0.14.4 D2 — `true` when the metric HAS recorded data, but none inside the
    /// currently-selected range (`store.dataState == .empty(.outsideRange)`). The
    /// row's count is range-bound (`recentInRange`), so without this it read "No
    /// entries" while tapping revealed the full all-time list — the operator's
    /// "shows keine Daten but tap reveals many entries". When set, the subtitle
    /// says the data lives outside the period rather than pretending there is none.
    var hasDataOutsideRange: Bool = false

    var body: some View {
        NavigationLink {
            MeasurementListScreen(kind: kind)
        } label: {
            HLCard {
                HStack(spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("Show all measurements")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        Text(subtitle)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    Spacer()
                    HLDisclosureChevron()
                }
            }
        }
        .hlPressable() // QOL-AUDIT H1: press feedback
        .accessibilityLabel(Text("Show all measurements, \(count) entries"))
        .accessibilityHint(Text("Opens a list of all measurements of this type"))
    }

    private var subtitle: LocalizedStringKey {
        if count >= 1 {
            return "\(count) entries in the period"
        }
        // No rows in this period — but if the metric has data elsewhere, route the
        // operator there honestly instead of a flat "No entries".
        return hasDataOutsideRange ? "Entries outside the period" : "No entries"
    }
}
