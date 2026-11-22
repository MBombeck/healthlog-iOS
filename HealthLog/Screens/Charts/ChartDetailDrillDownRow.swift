import SwiftUI

/// The "Show all measurements" drill row at the end of a metric page. Pushes
/// `MeasurementListScreen(kind:)`.
///
/// The design system's ``HLDrillRow`` in a row card, the one form of this row
/// on every detail page: title, "N entries in the period" (or "entries outside
/// the period" when the period is empty but the metric has readings), the
/// chevron, nothing on the right.
struct DrillDownRow: View {
    let kind: MetricKind
    /// Entries in the chosen period.
    let count: Int
    /// `true` when the metric HAS recorded data, but none inside the selected
    /// range (`store.dataState == .empty(.outsideRange)`). The tap still opens
    /// the full list, so the row says where the entries are instead of "none".
    var hasDataOutsideRange: Bool = false

    var body: some View {
        HLCard(layout: .rows) {
            HLDrillRow("Show all measurements", count: count, hasEntriesOutsidePeriod: hasDataOutsideRange)
                .hlRowLink {
                    MeasurementListScreen(kind: kind)
                }
                .accessibilityHint(Text("Opens a list of all measurements of this type"))
        }
    }
}
