import SwiftUI

/// Web-mirror injection **body map** — the front-of-body silhouette with eight
/// tappable site dots placed on the real anatomy, replacing the legacy
/// label-only `BodyMapGrid`. This brings the iOS picker to parity with the web
/// (`src/components/medications/injection-site-picker.tsx`), which draws a body
/// outline and overlays clickable dots.
///
/// **Asset:** `InjectionBody` (Assets.xcassets) is a clean front-body line-art
/// silhouette exported as a TEMPLATE image (alpha only), so a single asset tints
/// correctly in light AND dark mode via `foregroundStyle`. The dots are drawn by
/// SwiftUI, NOT baked into the image — exactly like the web overlays its dots —
/// so their positions, hit areas and state styling stay under our control.
///
/// **Calibration:** ``positions`` are fractional `(x, y)` coordinates of each
/// site on the asset's frame, hand-tuned against the rendered silhouette so each
/// dot sits on its zone (upper arms, the four abdomen quadrants, the thighs).
/// The fractions follow the SAME screen-side convention as the web map
/// (screen-left == "links"), so `armLeft`/`abdomenLeft*`/`thighLeft` render on
/// the viewer's left, matching `SITE_COORDS` in the web app.
///
/// **MDR boundary** is unchanged — this is hygiene/rotation guidance, never a
/// dosing recommendation; the surrounding `InjectionSitePicker` owns that copy.
struct InjectionBodyMap: View {
    let lastUsed: InjectionSite?
    let suggested: InjectionSite?
    let selected: InjectionSite?
    let onSelect: (InjectionSite) -> Void

    /// Fractional positions on the `InjectionBody` asset (front view). Tuned
    /// against the rendered silhouette — see the calibration note above.
    ///
    /// **v0.14.1 ITEM-C** — the two lowest leg markers (`thighLeft` /
    /// `thighRight`) were dropped from the map per operator feedback (the
    /// calibrated thigh points sat awkwardly low on the silhouette). The
    /// `InjectionSite` enum keeps the thigh cases (server wire-compat); they
    /// simply no longer render a body-map dot.
    private static let positions: [InjectionSite: UnitPoint] = [
        .armLeft: UnitPoint(x: 0.262, y: 0.360),
        .armRight: UnitPoint(x: 0.738, y: 0.360),
        .abdomenLeftUpper: UnitPoint(x: 0.435, y: 0.405),
        .abdomenRightUpper: UnitPoint(x: 0.565, y: 0.405),
        .abdomenLeftLower: UnitPoint(x: 0.435, y: 0.475),
        .abdomenRightLower: UnitPoint(x: 0.565, y: 0.475)
    ]

    /// The asset's intrinsic aspect (width / height) — keeps the body frame the
    /// exact shape the fractions were calibrated against, so a dot never drifts
    /// off its zone when the card width changes.
    private static let bodyAspect: CGFloat = 153.0 / 300.0

    /// Canonical body-map height inside the card. Width derives from the aspect.
    private let bodyHeight: CGFloat = 340

    private let dotSize: CGFloat = 18
    private let hitTarget: CGFloat = 44

    var body: some View {
        let bodyWidth = bodyHeight * Self.bodyAspect
        VStack(spacing: HLSpace.sm) {
            bodyGraphic(bodyWidth: bodyWidth)
            // v0.14.1 ITEM-C — legend under the body image so the dashed
            // (recommended) + orange (last-used) dot semantics read at a glance.
            legend
        }
        .frame(maxWidth: .infinity)
    }

    private func bodyGraphic(bodyWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Image("InjectionBody")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: bodyWidth, height: bodyHeight)
                // Soft outline so the dots read as the foreground signal; the
                // silhouette is quiet chrome, monochrome in both appearances.
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)

            ForEach(InjectionSite.allCases, id: \.self) { site in
                if let point = Self.positions[site] {
                    dot(for: site)
                        .position(x: point.x * bodyWidth, y: point.y * bodyHeight)
                }
            }
        }
        .frame(width: bodyWidth, height: bodyHeight)
        // Centre the body in the card without stretching the calibrated frame.
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "Body overview")))
    }

    /// **v0.14.1 ITEM-C** — dashed = recommended (rotation suggestion),
    /// orange = last-used site. Quiet, monochrome chrome bar under the map.
    private var legend: some View {
        HStack(spacing: HLSpace.md) {
            legendItem(
                label: String(localized: "med.injection.legend.recommended"),
                swatch: AnyView(
                    Circle()
                        .strokeBorder(
                            HLText.secondary,
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                        .frame(width: 14, height: 14)
                )
            )
            legendItem(
                label: String(localized: "med.injection.legend.last_used"),
                swatch: AnyView(
                    Circle()
                        .fill(HLColor.statusWarn.opacity(HLOpacity.surfaceTintWeak))
                        .overlay(Circle().strokeBorder(HLColor.statusWarn, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                )
            )
        }
        .font(.hlCaption)
        .foregroundStyle(HLText.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(label: String, swatch: AnyView) -> some View {
        HStack(spacing: HLSpace.xs) {
            swatch
            Text(label)
        }
    }

    @ViewBuilder
    private func dot(for site: InjectionSite) -> some View {
        let isSelected = selected == site
        let isSuggested = suggested == site && !isSelected
        Button {
            onSelect(site)
        } label: {
            ZStack {
                // Recommended-next ring — a dashed halo, drawn OUTSIDE the dot so
                // it reads as guidance without recolouring the dot itself (mirror
                // of the web dashed ring). Suppressed once the site is selected.
                if isSuggested {
                    Circle()
                        .strokeBorder(
                            HLText.secondary,
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                        .frame(width: dotSize + 12, height: dotSize + 12)
                }
                Circle()
                    .fill(fill(for: site))
                    .overlay(
                        Circle().strokeBorder(stroke(for: site), lineWidth: strokeWidth(for: site))
                    )
                    .frame(width: dotSize, height: dotSize)
            }
            // WCAG 2.5.5 — the visible dot is small, but the tappable wrapper is a
            // full 44pt target.
            .frame(width: hitTarget, height: hitTarget)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(site.localizedLabel))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(Text(hint(for: site)))
    }

    // MARK: - Monochrome dot styling (mirrors the prior grid semantics)

    private func fill(for site: InjectionSite) -> Color {
        if selected == site { return HLText.primary }
        if suggested == site { return HLSurface.tertiary }
        if lastUsed == site { return HLColor.statusWarn.opacity(HLOpacity.surfaceTintWeak) }
        return HLSurface.secondary
    }

    private func stroke(for site: InjectionSite) -> Color {
        if selected == site { return .clear }
        if lastUsed == site { return HLColor.statusWarn }
        return HLText.tertiary
    }

    private func strokeWidth(for site: InjectionSite) -> CGFloat {
        selected == site ? 0 : 1.5
    }

    private func hint(for site: InjectionSite) -> String {
        if suggested == site {
            return String(localized: "Empfohlene Stelle laut Rotationsplan")
        }
        if lastUsed == site {
            return String(localized: "Last used site")
        }
        return String(localized: "Double-tap to select")
    }
}
