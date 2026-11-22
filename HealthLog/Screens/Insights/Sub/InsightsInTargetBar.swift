import SwiftUI

/// The rail measures the lab result page still reads under this name.
///
/// The in-range bar itself is ``RangeBandRow`` in the design system; the
/// status card of a metric page draws it as `RangeBandRow(share:window:)`.
/// These names stay only until the lab page reads ``HLRangeBandMetrics``
/// directly.
enum InsightsInTargetBar {
    static var trackTone: Color {
        HLRangeBandMetrics.trackTone
    }

    static let cornerRadius: CGFloat = HLRangeBandMetrics.cornerRadius
    static let railHeight: CGFloat = HLRangeBandMetrics.railHeight
}
