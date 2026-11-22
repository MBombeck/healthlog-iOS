import SwiftUI

/// Dashboard footer entry point for layout customization.
///
/// The **web** dashboard header carries two persistent actions (a `+` quick-add
/// dropdown and a wrench "customize" shortcut). iOS deliberately keeps the
/// dashboard *top* clean — the operator flagged the old always-on
/// `slider.horizontal.3` toolbar button as "fürchterlich" (v0.10 R5), so it was
/// removed. This footer keeps customization as a calm, monochrome row
/// at the BOTTOM of the metrics area instead of the top chrome:
///
/// - **Dashboard anpassen** → pushes `DashboardCustomizationScreen` (the tile
///   visibility + order editor), previously only reachable via Settings or the
///   all-tiles-hidden empty-state escape hatch.
///
/// Rendered only when the dashboard actually has tiles — the empty states carry
/// their own (contextual) capture/customize CTAs, so this footer would be
/// redundant there.
struct DashboardQuickActionsFooter: View {
    /// Pushes the dashboard-customization screen.
    let onShowCustomize: () -> Void
    /// #186 — pushes the symptom quick entry; `nil` hides the row (illness
    /// module off, or a server that predates linked occurrences).
    var onLogSymptom: (() -> Void)?

    var body: some View {
        // A menu row: it opens a settings page and shows no value, so it
        // keeps the chevron (Z2).
        HLCard(layout: .rows) {
            if let onLogSymptom {
                // The same row as its neighbour: it opens a page to log on.
                HLRowButton(action: onLogSymptom) {
                    HLRow("symptoms.add", accessory: .chevron) {
                        HLRowGlyph(symbol: "heart.text.square")
                    }
                }
                .accessibilityIdentifier("dashboard.quickAction.symptom")
            }
            HLRowButton(action: onShowCustomize) {
                HLRow("Customize dashboard", accessory: .chevron) {
                    HLRowGlyph(symbol: "slider.horizontal.3")
                }
            }
            .accessibilityIdentifier("dashboard.quickAction.customize")
        }
    }
}

#Preview("DashboardQuickActionsFooter") {
    DashboardQuickActionsFooter(onShowCustomize: {}, onLogSymptom: {})
        .padding()
        .background(HLSurface.primary)
}
