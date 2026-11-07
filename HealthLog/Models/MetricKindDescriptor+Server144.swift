import Foundation
import SwiftUI

// HK-NEW (1.5, #149) — descriptors for the six Apple Health types the
// server maps since v1.44.0. Titles follow the server's `measurements.type*`
// labels (de/en), units its `unit-map.ts`: minutes, hours, a bare valence and
// percent. Polarity: the rings and mindful minutes are achievements like steps
// and daylight (`pr-direction.ts` counts them higher-better); the State of
// Mind valence and AFib burden carry no direction on the server, so neither
// gets a trend colour here.
//
// Split out of `MetricKindDescriptor+Catalog.swift` like `+Garmin`; the
// concatenation at the bottom of that file keeps the catalogue one dictionary.

extension MetricKindDescriptor {
    static let server144Descriptors: [MetricKindDescriptor] = [
        .init(
            kind: .exerciseMinutes,
            sfSymbol: "figure.run",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Exercise minutes", comment: "Metric title — Apple exercise ring minutes per day"),
            unitLabel: LocalizedStringResource("min", comment: "Unit — minutes"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Exercise minutes arrive from Apple Health",
                comment: "Empty state — exercise minutes"
            )
        ),
        .init(
            kind: .standMinutes,
            sfSymbol: "figure.stand",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Standing minutes", comment: "Metric title — Apple stand time minutes per day"),
            unitLabel: LocalizedStringResource("min", comment: "Unit — minutes"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Standing minutes arrive from Apple Health",
                comment: "Empty state — standing minutes"
            )
        ),
        .init(
            kind: .standHours,
            sfSymbol: "figure.stand.line.dotted.figure.stand",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Stand hours", comment: "Metric title — Apple stand ring hours per day"),
            unitLabel: LocalizedStringResource("hours", comment: "Unit — stood hours per day"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Stand hours arrive from Apple Health",
                comment: "Empty state — stand hours"
            )
        ),
        .init(
            kind: .mindfulMinutes,
            sfSymbol: "wind",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Mindful minutes", comment: "Metric title — mindful session minutes per day"),
            unitLabel: LocalizedStringResource("min", comment: "Unit — minutes"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Mindful minutes arrive from Apple Health",
                comment: "Empty state — mindful minutes"
            )
        ),
        .init(
            kind: .stateOfMindValence,
            sfSymbol: "face.smiling",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("State of mind", comment: "Metric title — Apple Health State of Mind valence, −1 to 1"),
            unitLabel: LocalizedStringResource("", comment: "Unit — valence (no label)"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal2,
            emptyStateCopy: LocalizedStringResource(
                "State of mind arrives from Apple Health",
                comment: "Empty state — State of Mind valence"
            )
        ),
        .init(
            kind: .afibBurden,
            sfSymbol: "heart.text.square",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("AFib burden", comment: "Metric title — atrial fibrillation burden, share of the week"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "AFib burden arrives from Apple Health",
                comment: "Empty state — AFib burden"
            )
        )
    ]
}
