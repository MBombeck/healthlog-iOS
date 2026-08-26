import Foundation

/// v0158 — v1.25 clinical measurement-type descriptors.
///
/// Split out of `MetricKindDescriptor.swift` to keep that file under the
/// 1000-line `file_length` budget. `MetricKindDescriptor.catalog` concatenates
/// this array onto its main `entries` list, so these four kinds are part of the
/// SAME single catalog dict (exhaustiveness is locked by
/// `MetricKindDescriptorRegistryTests`).
///
/// Three are MANUAL clinical signals (`painNRS`, `gripStrength`,
/// `waistCircumference`) the user logs by hand; `waistToHeight` is render-only.
/// Favourable direction mirrors the server `signals/registry.ts`
/// (pain / waist / waist-to-height lower-is-better; grip higher-is-better).
/// Monochrome doctrine: every tint is `HLSurface.secondary`.
extension MetricKindDescriptor {
    static let v125ClinicalDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .painNRS,
            sfSymbol: "bandage.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Pain", comment: "Metric title — pain NRS (0–10)"),
            titleCompact: LocalizedStringResource("Pain", comment: "Compact title — pain NRS"),
            // NRS is dimensionless; the "/ 10" label makes the 0–10 scale explicit
            // without implying a physical unit.
            unitLabel: LocalizedStringResource("/ 10", comment: "Unit — pain on a 0–10 scale"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Rate your pain from 0 to 10",
                comment: "Empty state — pain NRS"
            )
        ),
        .init(
            kind: .gripStrength,
            sfSymbol: "hand.raised.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Grip strength", comment: "Metric title — grip strength"),
            titleCompact: LocalizedStringResource("Grip", comment: "Compact title — grip strength"),
            unitLabel: LocalizedStringResource("kg", comment: "Unit — kilograms"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Measure your grip with a dynamometer",
                comment: "Empty state — grip strength"
            )
        ),
        .init(
            kind: .waistCircumference,
            sfSymbol: "ruler.fill",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Waist circumference",
                comment: "Metric title — waist circumference"
            ),
            titleCompact: LocalizedStringResource("Waist", comment: "Compact title — waist circumference"),
            unitLabel: LocalizedStringResource("cm", comment: "Unit — centimeters"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Measure your waist with a tape",
                comment: "Empty state — waist circumference"
            )
        ),
        .init(
            kind: .waistToHeight,
            sfSymbol: "divide",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Waist-to-height ratio",
                comment: "Metric title — waist-to-height ratio"
            ),
            titleCompact: LocalizedStringResource(
                "Waist / height",
                comment: "Compact title — waist-to-height ratio"
            ),
            // Dimensionless ratio — no unit label.
            unitLabel: LocalizedStringResource("", comment: "Unit — ratio (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal2,
            emptyStateCopy: LocalizedStringResource(
                "Derived from waist and height",
                comment: "Empty state — waist-to-height ratio"
            )
        )
    ]
}
