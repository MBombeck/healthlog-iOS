import Foundation

/// **1.4 B4 — a y range that fits the readings.** Swift Charts starts a value
/// axis at zero unless told otherwise, which flattens a series that moves in a
/// narrow band far from zero (an HbA1c around 6.5 %, a weight around 80 kg):
/// the medication effect chart drew its line along the top of a 0-based axis.
/// A chart whose values never approach zero takes this range instead.
enum ChartValueDomain {
    /// `values` with a quarter of their spread above and below, at least 2 %
    /// of their size (so a flat series still gets a band), never below zero
    /// for values that are all zero or more. `nil` without a finite value.
    static func fitting(_ values: [Double]) -> ClosedRange<Double>? {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        let pad = max((high - low) * 0.25, max(abs(low), abs(high)) * 0.02, 0.1)
        let lower = low >= 0 ? max(0, low - pad) : low - pad
        return lower ... high + pad
    }
}
