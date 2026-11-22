import Foundation
import SwiftUI

// Descriptors for five server types the app shows but never collects: blood
// ketones typed on the web, resting energy, and the three room-climate
// readings. Titles follow the server's `measurements.type*` labels, units its
// `unit-map.ts`, decimals its `display-transform.ts` (resting energy and CO₂
// whole, temperature one decimal). The server gives all five a target band
// without a direction (`signals/registry.ts`), so none gets a trend colour.
//
// Split out of `MetricKindDescriptor+Catalog.swift` like `+Garmin`; the
// concatenation at the bottom of that file keeps the catalogue one dictionary.

extension MetricKindDescriptor {
    static let readOnlyTypeDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .bloodKetones,
            sfSymbol: "drop.halffull",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Blood ketones", comment: "Metric title — blood ketones (beta-hydroxybutyrate)"),
            unitLabel: LocalizedStringResource("mmol/L", comment: "Unit — millimoles per litre"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "No blood ketones recorded yet",
                comment: "Empty state — blood ketones (entered on the web)"
            )
        ),
        .init(
            kind: .basalEnergy,
            sfSymbol: "flame",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Resting energy", comment: "Metric title — resting (basal) energy burned per day"),
            unitLabel: LocalizedStringResource("kcal", comment: "Unit — kilocalories"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .groupedInteger,
            emptyStateCopy: LocalizedStringResource(
                "No resting energy recorded yet",
                comment: "Empty state — resting energy"
            )
        ),
        .init(
            kind: .indoorCO2,
            sfSymbol: "wind",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Indoor CO₂", comment: "Metric title — carbon dioxide in the room air"),
            unitLabel: LocalizedStringResource("ppm", comment: "Unit — parts per million"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .groupedInteger,
            emptyStateCopy: LocalizedStringResource(
                "No indoor CO₂ readings yet",
                comment: "Empty state — indoor CO₂ (from a room sensor)"
            )
        ),
        .init(
            kind: .indoorTemperature,
            sfSymbol: "thermometer.medium",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Indoor temperature", comment: "Metric title — room air temperature"),
            unitLabel: LocalizedStringResource("°C", comment: "Unit — degrees Celsius"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "No indoor temperature readings yet",
                comment: "Empty state — indoor temperature (from a room sensor)"
            )
        ),
        .init(
            kind: .indoorHumidity,
            sfSymbol: "humidity",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Indoor humidity", comment: "Metric title — relative humidity of the room air"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No indoor humidity readings yet",
                comment: "Empty state — indoor humidity (from a room sensor)"
            )
        )
    ]
}
