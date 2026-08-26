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

    var body: some View {
        HLCard {
            actionRow(
                icon: "slider.horizontal.3",
                title: String(localized: "Customize dashboard"),
                identifier: "dashboard.quickAction.customize",
                action: onShowCustomize
            )
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: icon)
                    .font(.hlBody.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                Image(systemName: "chevron.right")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, HLSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hlPressable()
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("DashboardQuickActionsFooter") {
    DashboardQuickActionsFooter(onShowCustomize: {})
        .padding()
        .background(HLSurface.primary)
}
