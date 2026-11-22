import SwiftUI

// Extracted from `ChartDetailScreen.swift` so the host file stays
// under the 1000-line SwiftLint ceiling after the fullscreen zoom-morph
// wiring landed.

/// The chart card's place when there is nothing to draw yet.
///
/// Shown in two situations:
/// 1. Series has 0 points: "Noch keine Daten".
/// 2. Series has 1 point: one more reading and the trend appears.
///
/// **One line in the chart's card.** It used to be a card of its
/// own with a 36 pt glyph, a title and a per-metric call to action ("Verbinde
/// Apple Health, damit …"), which also showed for people whose Apple Health
/// was connected long ago. The page around it already offers capture and the
/// connection lives in Settings; the card only says what is true.
struct InsufficientDataCard: View {
    let kind: MetricKind
    /// `true` if the series has exactly one point — communicates as "we need
    /// more data" rather than "no data at all".
    let hasOnePoint: Bool

    var body: some View {
        // Missing data inside the chart's card: the design system's one
        // quiet line.
        HLCard {
            HLEmptyNote(Text(line))
        }
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        // A kind this build cannot name: nothing the user could
        // log or connect would fill it, the rows came from the server already.
        if kind == .unknown {
            return String(localized: "This app version doesn't know this measurement yet")
        }
        return hasOnePoint
            ? String(localized: "chart.insufficient.onePoint")
            : String(localized: "No data yet")
    }
}
