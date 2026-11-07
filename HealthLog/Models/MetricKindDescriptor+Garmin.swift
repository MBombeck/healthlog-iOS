import Foundation
import SwiftUI

// #162 (server v1.47.0, public #1333) — descriptors for the four Garmin
// types. All four are read/display-only, like the WHOOP-native scores: the
// server pulls `BODY_BATTERY` and `STRESS_LEVEL` from Garmin Connect, and a
// bridge the person runs writes `TRAINING_READINESS` and `ACUTE_TRAINING_LOAD`
// as `EXTERNAL`. Nothing here is a HealthKit type and nothing is uploaded.
//
// Polarity mirrors the server's `metric-status-registry.ts`: Body Battery and
// readiness higher-better, stress level lower-better, acute load a target band
// (neutral here, like cardio load). Units mirror `unit-map.ts`: the three
// scores are `score` (0–100), the load is `load` (0–3000), so none carries a
// unit label.
//
// Split out of `MetricKindDescriptor+Catalog.swift` like `+AuditB4`; the
// concatenation at the bottom of that file keeps the catalogue one dictionary.

extension MetricKindDescriptor {
    static let garminDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .bodyBattery,
            sfSymbol: "battery.75percent",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Body Battery", comment: "Metric title — Garmin Body Battery (brand term, 0–100)"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect Garmin to see your Body Battery",
                comment: "Empty state — Garmin Body Battery"
            )
        ),
        .init(
            kind: .stressLevel,
            sfSymbol: "waveform.path.ecg",
            tint: HLSurface.secondary,
            // Not "Stress": that title belongs to `stressScore`, the computed
            // HRV proxy, and both can sit in the same list.
            title: LocalizedStringResource("Stress level", comment: "Metric title — Garmin all-day stress level (0–100)"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect Garmin to see your stress level",
                comment: "Empty state — Garmin stress level"
            )
        ),
        .init(
            kind: .trainingReadiness,
            sfSymbol: "figure.run.circle",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Training readiness", comment: "Metric title — Garmin training readiness (0–100)"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No training readiness recorded yet",
                comment: "Empty state — Garmin training readiness (arrives through a bridge the person sets up)"
            )
        ),
        .init(
            kind: .acuteTrainingLoad,
            sfSymbol: "chart.bar",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Acute training load", comment: "Metric title — Garmin seven-day acute training load"),
            unitLabel: LocalizedStringResource("", comment: "Unit — training load (no label)"),
            // A target band on the server, like cardio load: more is neither
            // good nor bad without the person's own recent weeks.
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .groupedInteger,
            emptyStateCopy: LocalizedStringResource(
                "No training load recorded yet",
                comment: "Empty state — Garmin acute training load (arrives through a bridge the person sets up)"
            )
        )
    ]
}
