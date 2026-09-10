import Foundation
import SwiftUI

// Audit B-4 (2026-09-10) — descriptors for the two kinds that stopped rows
// being dropped: the audio-exposure event (the 77th server `MeasurementType`,
// left without a kind when its five sibling events got one) and the generic
// `unknown` arm a type newer than this build lands on.
//
// Split out of `MetricKindDescriptor+Catalog.swift`, which carries a
// `file_length` suppression precisely because it is one indivisible data table;
// the concatenation at the bottom of that file keeps the catalogue a single
// dictionary.

extension MetricKindDescriptor {
    static let auditB4Descriptors: [MetricKindDescriptor] = [
        .init(
            kind: .audioExposureEvent,
            sfSymbol: "ear.trianglebadge.exclamationmark",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Loud audio notification",
                comment: "Metric title — Apple Health audio exposure event"
            ),
            titleCompact: LocalizedStringResource(
                "Audio alert",
                comment: "Compact title — audio exposure event"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No loud-audio notifications recorded",
                comment: "Empty state — audio exposure event"
            ),
            secondaryHint: LocalizedStringResource(
                "Recorded as an occurrence — the date is what matters",
                comment: "Secondary hint — categorical event carries no magnitude"
            )
        ),
        // The generic arm. It names no unit, no polarity and no drill-down,
        // because this build does not know what the number is — the row exists
        // so the user can see that the server holds a reading here, and that is
        // the whole claim it makes.
        .init(
            kind: .unknown,
            // NOT `questionmark.circle`: that is the registry's defensive
            // fallback glyph, and `MetricKindDescriptorRegistryTests` reads a
            // descriptor carrying it as "this kind has no catalogue entry".
            sfSymbol: "questionmark.square.dashed",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Unknown metric",
                comment: "Metric title — a measurement type this app version does not know"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — unknown metric (no label)"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: false,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Nothing recorded",
                comment: "Empty state — unknown metric"
            ),
            secondaryHint: LocalizedStringResource(
                "This app version doesn't know this measurement yet",
                comment: "Secondary hint — unknown metric explains itself"
            )
        )
    ]
}
