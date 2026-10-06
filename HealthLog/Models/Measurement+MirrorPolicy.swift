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
    /// `.withings` / `.import_` / `.manual`: rows the user genuinely authored
    /// and for which the server is a legitimate authoring source.
    ///
    /// **S1 / public #11 — `.manual` joined the allowlist.** It was excluded
    /// as "already round-tripped at create-time", which holds only for a row
    /// typed in THIS app. A reading typed on the web, or on another device, is
    /// stored as `MANUAL` too, and never reached Apple Health. A manual row this
    /// app did write at create-time is recognised by the mirror's dedup, not by
    /// the source: the create-time sample carries the same server id in
    /// `HKMetadataKeyExternalUUID` (BP: the systolic row's id, which is the id
    /// the list carries; builds before S1 stamped the diastolic id, which the
    /// mirror also probes), and an own-source sample with the same type,
    /// instant and value counts as present even without that metadata.
    ///
    /// Still excluded: `.appleHealth` (originated in HealthKit — re-writing
    /// would duplicate / cross-source-contaminate), and `.whoop` / `.fitbit` /
    /// `.googleHealth` / `.strava` / `.oura` / `.polar` / `.nightscout` /
    /// `.external` / `.telegram` / `.mcp` (provider-owned, ingest-token or
    /// server-written rows — we must never author them into Apple Health).
    /// This is a closed allowlist, not a denylist: a new source joins the
    /// `false` arm unless someone decides otherwise, so nothing starts writing
    /// into Apple Health by being added to the enum.
    var isServerMirrorEligible: Bool {
        switch self {
        case .withings, .import_, .manual: true
        case .appleHealth, .whoop, .fitbit, .googleHealth, .computed,
             .strava, .oura, .polar, .nightscout, .external, .telegram, .mcp,
             // Audit B-4 — the closed allowlist doing its job: a source this
             // build cannot name never writes into Apple Health.
             .unknown: false
        }
    }

    /// The mirror-eligible source set, for callers that page server history per
    /// source (the historical backfill issues one source-scoped fetch each).
    static let serverMirrorEligible: [MeasurementSource] = [.withings, .import_, .manual]
}

public extension Measurement {
    /// Every server id an Apple-Health sample for this row may carry in
    /// `HKMetadataKeyExternalUUID`. The row id first; for a merged blood
    /// pressure also the diastolic peer id, because builds before S1 stamped
    /// the create-time BP sample with the id of the LAST POST (the diastolic
    /// row) while the list merges the pair under the systolic id. Probing both
    /// keeps the mirror from writing those readings a second time.
    var serverMirrorLinkageIDs: [String] {
        guard let diastolicID = bloodPressureDiastolicId, !diastolicID.isEmpty, diastolicID != id else {
            return [id]
        }
        return [id, diastolicID]
    }
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
