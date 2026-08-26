import SwiftUI

/// W-FILELEN (v0153 I2/I3) — the Insights tab-strip pill view-builders, split out
/// of `InsightsMetricTabStrip.swift` to keep that file under the length ceiling.
/// These are the `pill` / `customizePill` builders the strip body calls (the
/// category pill is now an inline native `Menu`, so the v0153 accordion
/// `headerPill` / `childPill` builders are gone).
extension InsightsMetricTabStrip {
    /// v0.14.1 — the trailing "customise the strip" affordance. A quiet,
    /// circular, monochrome pencil pill that sits after the last metric pill so
    /// the operator can reorder + show/hide the strip tabs. Matches the
    /// unselected-pill treatment (recessed well + hairline) so it reads as
    /// chrome, not a metric.
    func customizePill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous).fill(HLSurface.tertiary)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Customize tab strip"))
        .accessibilityHint(String(localized: "Reorder or show and hide metrics"))
        .accessibilityIdentifier("insights.tabStrip.customize")
    }

    func pill(
        title: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.hlSubhead.weight(.semibold))
                // W-RECONCILE M1 — keep the pill single-line so a multi-word
                // category label can't wrap to two lines inside the capsule at
                // large Dynamic Type (AX5) and break the uniform pill height.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // W22-W22 (operator felt-refine #4) — on the canonical mono
                // scale every sibling surface uses. Selected: an inverted label
                // (`HLSurface.primary`) on a filled `HLText.primary` capsule;
                // unselected: `HLText.secondary` on a recessed `HLSurface
                // .tertiary` well. Replaces the off-doctrine `HLColor.background`
                // / `backgroundEleva` fills that read a hair off neighbouring
                // cards (audit P1-3).
                .foregroundStyle(isSelected ? HLSurface.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(HLSurface.tertiary))
                }
                .overlay {
                    if !isSelected {
                        Capsule(style: .continuous)
                            .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
