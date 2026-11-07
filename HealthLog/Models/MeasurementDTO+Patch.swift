import Foundation

// Moved out of `MeasurementDTO.swift` unchanged (HK-NEW, 1.5) so that file stays
// under its baselined length while the server-v1.44 types join the type enum.

/// Patch body for `PATCH /api/measurements/[id]`. All fields optional —
/// server applies only the keys that are present.
///
/// **BP-pair semantics (T-1):** `value` is the systolic component on the
/// systolic-row PATCH und der `diastolic`-Wert (wenn gesetzt) trägt den
/// diastolischen Wert für den paired-PATCH auf die `BLOOD_PRESSURE_DIA`-
/// Peer-Row. Das `diastolic`-Feld wird *nicht* an den Server geschickt —
/// es ist nur eine clientseitige Intent-Trag-Hilfe, die das Repository
/// in zwei einzelne wire-PATCH-Calls fanoutet. Custom `CodingKeys` filtern
/// es aus der serialisierten JSON.
public struct MeasurementPatch: Codable, Sendable {
    public let value: Double?
    public let measuredAt: Date?
    public let notes: String?
    /// Client-side intent for BP pair-update. Suppressed from JSON
    /// serialization (server does not accept it on `PATCH
    /// /api/measurements/[id]`). The repo fans out by issuing a second
    /// PATCH against the diastolic peer with `value = diastolic` instead.
    public let diastolic: Double?
    /// Client-side intent for glucose-context edits (T-2). Suppressed from
    /// JSON serialization — server-side `MeasurementPatch` Zod-schema in
    /// `src/lib/validations/measurement.ts` currently only accepts value /
    /// measuredAt / notes (server-team flagged as SB-25 to add this on
    /// PATCH post-v1.4.30). Until then the context survives via two paths:
    ///
    /// 1. **Edit-Sheet → optimistic-write:** the UI carries
    ///    `glucoseContext` through the optimistic `Measurement` injected
    ///    into the store snapshot, so the row visually reflects the new
    ///    context immediately. On the wire only value/measuredAt/notes go
    ///    out — the server-persisted context stays at its original value.
    /// 2. **Outbox-replay survives via the pair-aware payload in
    ///    `OutboxQueue.Payloads.UpdateMeasurement`** (`glucoseContext`
    ///    field). Replay re-hydrates the patch with the persisted intent.
    public let glucoseContext: GlucoseContext?

    public init(
        value: Double? = nil,
        measuredAt: Date? = nil,
        notes: String? = nil,
        diastolic: Double? = nil,
        glucoseContext: GlucoseContext? = nil
    ) {
        self.value = value
        self.measuredAt = measuredAt
        self.notes = notes
        self.diastolic = diastolic
        self.glucoseContext = glucoseContext
    }

    private enum WireCodingKeys: String, CodingKey {
        case value
        case measuredAt
        case notes
    }

    /// Wire encoding: emit value / measuredAt / notes only. `diastolic`
    /// (T-1) und `glucoseContext` (T-2) sind intentional suppressed —
    /// beide sind client-side fan-out / intent-Signale, keine server-
    /// accepted fields. Server schema:
    /// `src/lib/validations/measurement.ts` only knows the three wire keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireCodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    /// Wire decoding: read the three documented server fields. `diastolic`
    /// + `glucoseContext` are only ever populated client-side (Edit-Sheet
    /// → repo), so when decoding from persisted outbox payloads or wire
    /// responses we keep them `nil`. Outbox round-trips that need these
    /// fields use the pair-aware payload in
    /// `OutboxQueue.Payloads.UpdateMeasurement`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireCodingKeys.self)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        measuredAt = try container.decodeIfPresent(Date.self, forKey: .measuredAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        diastolic = nil
        glucoseContext = nil
    }
}

/// Request body for `DELETE /api/measurements/by-external-ids` — bulk
/// reconciliation when HK deletes propagate from the system Health app.
public struct ExternalIDBatch: Codable, Sendable {
    public let externalIds: [String]
    public init(externalIds: [String]) {
        self.externalIds = externalIds
    }
}
