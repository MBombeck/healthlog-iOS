import Foundation

/// Build 3 / item 3.3 — descriptors for the 21 net-new `MetricKind` cases that
/// landed with the decoder catch-up.
///
/// Split out of `MetricKindDescriptor.swift` to keep that file under the
/// 1000-line `file_length` budget, exactly like `+IC` / `+V125`.
/// `MetricKindDescriptor.catalog` concatenates this array onto its main
/// `entries` list, so these kinds are part of the SAME single catalog dict
/// (exhaustiveness is locked by `MetricKindDescriptorRegistryTests`).
///
/// **All 21 are read/display-only.** Four are server-COMPUTED screener sums,
/// eleven are wearable-native scores (WHOOP / Oura / Polar), five are Apple
/// Health CATEGORICAL events, and one is a kilojoule energy total. None has a
/// manual-entry surface — the empty-state copy therefore never says "log one",
/// it says where the value comes from.
///
/// **Polarity is not decoration.** PHQ-9 / GAD-7 / stress measure BURDEN, so
/// lower is better; WHO-5 / SCI / recovery / resilience / the sleep sub-scores
/// measure WELL-BEING, so higher is better. Strain, sleep-need, HRV-RMSSD and
/// energy are `.neutral` — "more" is neither good nor bad without training
/// context, and the app does not have that context.
///
/// **The five categorical events carry a `1…1` server band**, so their value is
/// always `1` and only the timestamp informs. They format as `.integer` and the
/// secondary hint says so; `MetricKind.isCategoricalEvent` is the predicate a
/// surface uses to render an occurrence instead of a meaningless "1".
///
/// Monochrome doctrine: every tint is `HLSurface.secondary`.
extension MetricKindDescriptor {
    static let b3DecoderDescriptors: [MetricKindDescriptor] = screenerDescriptors
        + wearableScoreDescriptors
        + sleepSubScoreDescriptors
        + categoricalEventDescriptors

    // MARK: - Screener sum scores (server-COMPUTED, `source = COMPUTED`)

    private static let screenerDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .phq9Score,
            sfSymbol: "list.clipboard",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("PHQ-9 score", comment: "Metric title — PHQ-9 depression screener sum"),
            titleCompact: LocalizedStringResource("PHQ-9", comment: "Compact title — PHQ-9"),
            unitLabel: LocalizedStringResource("/ 27", comment: "Unit — PHQ-9 sum on a 0–27 scale"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Complete a PHQ-9 questionnaire to see your score here",
                comment: "Empty state — PHQ-9 score"
            ),
            secondaryHint: LocalizedStringResource(
                "Calculated from your answers",
                comment: "Secondary hint — server-computed screener sum"
            )
        ),
        .init(
            kind: .gad7Score,
            sfSymbol: "list.clipboard",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("GAD-7 score", comment: "Metric title — GAD-7 anxiety screener sum"),
            titleCompact: LocalizedStringResource("GAD-7", comment: "Compact title — GAD-7"),
            unitLabel: LocalizedStringResource("/ 21", comment: "Unit — GAD-7 sum on a 0–21 scale"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Complete a GAD-7 questionnaire to see your score here",
                comment: "Empty state — GAD-7 score"
            ),
            secondaryHint: LocalizedStringResource(
                "Calculated from your answers",
                comment: "Secondary hint — server-computed screener sum"
            )
        ),
        .init(
            kind: .who5Score,
            sfSymbol: "face.smiling",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("WHO-5 well-being", comment: "Metric title — WHO-5 well-being index"),
            titleCompact: LocalizedStringResource("WHO-5", comment: "Compact title — WHO-5"),
            unitLabel: LocalizedStringResource("/ 25", comment: "Unit — WHO-5 raw sum on a 0–25 scale"),
            // The only screener of the four where a HIGHER value is the good one.
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Complete a WHO-5 questionnaire to see your score here",
                comment: "Empty state — WHO-5 score"
            ),
            secondaryHint: LocalizedStringResource(
                "Calculated from your answers",
                comment: "Secondary hint — server-computed screener sum"
            )
        ),
        .init(
            kind: .sciScore,
            sfSymbol: "bed.double",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Sleep Condition Indicator",
                comment: "Metric title — SCI sleep screener sum"
            ),
            titleCompact: LocalizedStringResource("SCI", comment: "Compact title — Sleep Condition Indicator"),
            unitLabel: LocalizedStringResource("/ 32", comment: "Unit — SCI sum on a 0–32 scale"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Complete a sleep questionnaire to see your score here",
                comment: "Empty state — SCI score"
            ),
            secondaryHint: LocalizedStringResource(
                "Calculated from your answers",
                comment: "Secondary hint — server-computed screener sum"
            )
        )
    ]

    // MARK: - Wearable score classes (WHOOP / Oura / Polar ingest)

    private static let wearableScoreDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .recoveryScore,
            sfSymbol: "arrow.clockwise.heart",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Recovery", comment: "Metric title — recovery score"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your recovery score",
                comment: "Empty state — recovery score"
            )
        ),
        .init(
            kind: .stressScore,
            sfSymbol: "waveform.path.ecg",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Stress", comment: "Metric title — stress score"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your stress score",
                comment: "Empty state — stress score"
            )
        ),
        .init(
            kind: .strainScore,
            sfSymbol: "flame",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Strain", comment: "Metric title — normalised 0–100 strain score"),
            unitLabel: LocalizedStringResource("", comment: "Unit — score (no label)"),
            // More strain is neither good nor bad without training context.
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your strain score",
                comment: "Empty state — strain score"
            )
        ),
        .init(
            kind: .hrvRMSSD,
            sfSymbol: "waveform.path",
            tint: HLSurface.secondary,
            // Named for the STATISTIC, not just "HRV" — the app already shows an
            // SDNN-based `hrv` tile and the two numbers differ by tens of ms.
            title: LocalizedStringResource("HRV (RMSSD)", comment: "Metric title — heart-rate variability, RMSSD"),
            titleCompact: LocalizedStringResource("RMSSD", comment: "Compact title — HRV RMSSD"),
            unitLabel: LocalizedStringResource("ms", comment: "Unit — milliseconds"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your RMSSD",
                comment: "Empty state — HRV RMSSD"
            ),
            secondaryHint: LocalizedStringResource(
                "Measured differently than Apple Health's HRV",
                comment: "Secondary hint — RMSSD is a different statistic than SDNN"
            )
        ),
        .init(
            kind: .dayStrain,
            sfSymbol: "flame",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Day strain", comment: "Metric title — WHOOP day strain (0–21)"),
            unitLabel: LocalizedStringResource("/ 21", comment: "Unit — strain on a 0–21 scale"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your day strain",
                comment: "Empty state — day strain"
            )
        ),
        .init(
            kind: .workoutStrain,
            sfSymbol: "figure.run",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Workout strain", comment: "Metric title — WHOOP per-workout strain"),
            unitLabel: LocalizedStringResource("/ 21", comment: "Unit — strain on a 0–21 scale"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .decimal1,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your workout strain",
                comment: "Empty state — workout strain"
            )
        ),
        .init(
            kind: .energyExpenditureKJ,
            sfSymbol: "bolt",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Energy expenditure", comment: "Metric title — energy expenditure in kJ"),
            titleCompact: LocalizedStringResource("Energy (kJ)", comment: "Compact title — energy expenditure kJ"),
            unitLabel: LocalizedStringResource("kJ", comment: "Unit — kilojoules"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .groupedInteger,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your energy expenditure",
                comment: "Empty state — energy expenditure kJ"
            ),
            secondaryHint: LocalizedStringResource(
                "In kilojoules, not calories",
                comment: "Secondary hint — kJ is a different unit than the kcal active-energy tile"
            )
        ),
        .init(
            kind: .resilience,
            sfSymbol: "shield.lefthalf.filled",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Resilience", comment: "Metric title — Oura resilience level"),
            // A 1–5 ORDINAL level, not a continuous score — no unit label.
            unitLabel: LocalizedStringResource("", comment: "Unit — ordinal level (no label)"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your resilience",
                comment: "Empty state — resilience"
            )
        )
    ]

    // MARK: - Sleep sub-scores

    private static let sleepSubScoreDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .sleepPerformance,
            sfSymbol: "moon.zzz",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep performance", comment: "Metric title — sleep performance %"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your sleep performance",
                comment: "Empty state — sleep performance"
            )
        ),
        .init(
            kind: .sleepEfficiency,
            sfSymbol: "moon.zzz",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep efficiency", comment: "Metric title — sleep efficiency %"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your sleep efficiency",
                comment: "Empty state — sleep efficiency"
            )
        ),
        .init(
            kind: .sleepConsistency,
            sfSymbol: "calendar.badge.clock",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep consistency", comment: "Metric title — sleep consistency %"),
            unitLabel: LocalizedStringResource("%", comment: "Unit — percent"),
            trendPolarity: .higherIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your sleep consistency",
                comment: "Empty state — sleep consistency"
            )
        ),
        .init(
            kind: .sleepNeed,
            sfSymbol: "hourglass",
            tint: HLSurface.secondary,
            title: LocalizedStringResource("Sleep need", comment: "Metric title — sleep need in minutes"),
            unitLabel: LocalizedStringResource("min", comment: "Unit — minutes"),
            trendPolarity: .neutral,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .groupedInteger,
            emptyStateCopy: LocalizedStringResource(
                "Connect a wearable to see your sleep need",
                comment: "Empty state — sleep need"
            )
        )
    ]

    // MARK: - Categorical Apple Health events (server band `1…1`)

    //
    // These five carry NO magnitude: the server clamps the value to exactly 1,
    // so the reading is the OCCURRENCE and its timestamp. Their secondary hint
    // says as much so a tile showing "1" is never read as a measurement.

    private static let categoricalEventDescriptors: [MetricKindDescriptor] = [
        .init(
            kind: .irregularRhythmNotification,
            sfSymbol: "waveform.path.ecg.rectangle",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Irregular rhythm notification",
                comment: "Metric title — Apple Health irregular rhythm notification event"
            ),
            titleCompact: LocalizedStringResource(
                "Irregular rhythm",
                comment: "Compact title — irregular rhythm notification"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No notifications recorded",
                comment: "Empty state — irregular rhythm notification"
            ),
            secondaryHint: eventOccurrenceHint
        ),
        .init(
            kind: .highHeartRateEvent,
            sfSymbol: "arrow.up.heart",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "High heart rate event",
                comment: "Metric title — Apple Health high heart rate notification"
            ),
            titleCompact: LocalizedStringResource("High heart rate", comment: "Compact title — high heart rate event"),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No events recorded",
                comment: "Empty state — categorical health event"
            ),
            secondaryHint: eventOccurrenceHint
        ),
        .init(
            kind: .lowHeartRateEvent,
            sfSymbol: "arrow.down.heart",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Low heart rate event",
                comment: "Metric title — Apple Health low heart rate notification"
            ),
            titleCompact: LocalizedStringResource("Low heart rate", comment: "Compact title — low heart rate event"),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No events recorded",
                comment: "Empty state — categorical health event"
            ),
            secondaryHint: eventOccurrenceHint
        ),
        .init(
            kind: .walkingSteadinessEvent,
            sfSymbol: "figure.walk.motion",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Walking steadiness notification",
                comment: "Metric title — Apple Health walking steadiness event"
            ),
            titleCompact: LocalizedStringResource(
                "Steadiness alert",
                comment: "Compact title — walking steadiness event"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No notifications recorded",
                comment: "Empty state — irregular rhythm notification"
            ),
            secondaryHint: eventOccurrenceHint
        ),
        .init(
            kind: .breathingDisturbanceEvent,
            sfSymbol: "lungs",
            tint: HLSurface.secondary,
            title: LocalizedStringResource(
                "Breathing disturbance event",
                comment: "Metric title — breathing disturbance event"
            ),
            titleCompact: LocalizedStringResource(
                "Breathing event",
                comment: "Compact title — breathing disturbance event"
            ),
            unitLabel: LocalizedStringResource("", comment: "Unit — event occurrence (no label)"),
            trendPolarity: .lowerIsBetter,
            renderHint: .scalar,
            supportsDrillDown: true,
            formatStyle: .integer,
            emptyStateCopy: LocalizedStringResource(
                "No events recorded",
                comment: "Empty state — categorical health event"
            ),
            secondaryHint: eventOccurrenceHint
        )
    ]

    /// Shared secondary hint for the five categorical events — the value is
    /// always `1`, so the line has to say that the DATE is the information.
    private static let eventOccurrenceHint = LocalizedStringResource(
        "Recorded as an occurrence — the date is what matters",
        comment: "Secondary hint — categorical event carries no magnitude"
    )
}
