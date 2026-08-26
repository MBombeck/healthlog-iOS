import Foundation

/// **W-HKBACKFILL** — platform-free server→Apple-Health mirror policy.
///
/// The single source of truth for WHICH ingest sources and WHICH kinds
/// round-trip from the server into Apple Health, shared by the b198 latest-page
/// mirror (`HealthKitService.shouldMirrorFromServer`) AND the one-shot
/// historical backfill (`MeasurementsStore+HistoricalBackfill`). Lives in its
/// own file (not in `Measurement.swift`, which is already over the file-length
/// ceiling) and carries NO HealthKit import, so the policy stays testable
/// without the HealthKit framework and the two mirror paths cannot drift.
/// `HealthKitServerMirrorTests` pins the alignment with the authoritative
/// `quantitySamples` sample-builder switch.
public extension MeasurementSource {
    /// True for the sources the server-origin mirror is allowed to write into
    /// Apple Health.
    ///
    /// ONLY `.withings` / `.import_`: rows the user genuinely authored away from
    /// this device for which the server is a legitimate authoring source. We
    /// deliberately EXCLUDE `.manual` (already round-tripped at create-time),
    /// `.appleHealth` (originated in HealthKit — re-writing would duplicate /
    /// cross-source-contaminate), and `.whoop` / `.fitbit` / `.googleHealth` /
    /// `.strava` / `.oura` / `.polar` / `.nightscout` (provider-owned read-only
    /// wearable/CGM kinds we must never author into Apple Health).
    var isServerMirrorEligible: Bool {
        switch self {
        case .withings, .import_: true
        case .manual, .appleHealth, .whoop, .fitbit, .googleHealth, .computed,
             .strava, .oura, .polar, .nightscout: false
        }
    }

    /// The mirror-eligible source set, for callers that page server history per
    /// source (the historical backfill issues one source-scoped fetch each).
    static let serverMirrorEligible: [MeasurementSource] = [.withings, .import_]
}

public extension MetricKind {
    /// Kinds with an Apple-Health WRITE counterpart. The b198 mirror's
    /// `quantitySamples(for:metadata:)` switch is authoritative for the actual
    /// unit mapping; this set must stay aligned with it (pinned by
    /// `HealthKitServerMirrorTests`). Only these kinds are worth fetching in the
    /// historical backfill — every other kind has no HK write-type and the
    /// mirror would skip it anyway.
    ///
    /// Excludes sleep (system-owned category), the passive walking/mobility
    /// sensor kinds, cumulative activity aggregates, audio-exposure, and the
    /// smart-scale-only body-water/bone-mass kinds — none of which the mirror
    /// writes back.
    static let serverMirrorWritableKinds: Set<MetricKind> = [
        .weight,
        .bloodPressure,
        .glucose,
        .pulse,
        .bodyFat,
        .bodyTemperature,
        .spo2,
        .restingHeartRate,
        .hrv,
        .vo2Max,
        .bmi
    ]
}
