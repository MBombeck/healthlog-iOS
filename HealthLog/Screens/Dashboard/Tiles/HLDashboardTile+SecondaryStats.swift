import SwiftUI

/// Build 7 / item 7.1 — the dashboard tile's web-parity secondary stats: the
/// 7-/30-day average sub-row + the spoken-label clause that folds it (and the
/// target band) into VoiceOver. Split out of `HLDashboardTile.swift` so that
/// file stays under the `file_length` budget (the previews + context-line memo
/// already live in their own `HLDashboardTile+*` extensions). The averages come
/// pre-resolved from `DashboardTileTargetResolver`; the tile formats them with
/// the SAME `formatScalar` path as its headline value so units + rounding agree.
extension HLDashboardTile {
    /// `true` when at least one average window resolved. Drives the sub-row
    /// render + the spoken-label clause.
    var hasAverages: Bool {
        avg7 != nil || avg30 != nil
    }

    /// The "7 T 72,4 · 30 T 72,8" sub-row. Values run through the SAME
    /// `formatScalar` unit-conversion the headline uses, so the sub-row agrees
    /// with the value on units + rounding. The unit suffix is intentionally
    /// omitted (it already sits on the headline) — matching the web tile, whose
    /// avg sub-rows render the bare number.
    var averagesRow: some View {
        Text(averagesText)
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .monospacedDigit()
            .accessibilityIdentifier("tile.\(metric.kind.rawValue).averages")
    }

    private var averagesText: String {
        // "7d"/"30d" are the existing trend-chip window labels (de "7 T"/"30 T").
        // Interpolated into one localized resource so the "·" separator + the
        // two windows translate as a unit (no fragment concatenation).
        String(localized: "7d \(formattedAverage(avg7)) · 30d \(formattedAverage(avg30))")
    }

    /// Formats one average through the headline's `formatScalar` (unit-aware),
    /// or the em-dash when that window is empty.
    private func formattedAverage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return formatScalar(value)
    }

    /// Spoken clause for the 7-/30-day averages + the in-range band. Empty when
    /// neither resolved, so the label reads exactly as before on plain tiles.
    var statsSpokenClause: String {
        var parts: [String] = []
        if let avg7 {
            parts.append(String(localized: "7-day avg \(formatScalar(avg7))"))
        }
        if let avg30 {
            parts.append(String(localized: "30-day avg \(formatScalar(avg30))"))
        }
        if let targetBand {
            let pct = min(100, max(0, targetBand.pctInRange))
            parts.append(String(localized: "\(pct) of 30 days in target range"))
        }
        guard !parts.isEmpty else { return "" }
        return " " + parts.joined(separator: ". ") + "."
    }
}
