import Foundation

// Moved out of `MeasurementDTO.swift` unchanged so that file stays
// under its baselined length while the server-v1.44 types join the type enum.

/// Patch body for `PUT /api/measurements/[id]`. All fields optional —
/// server applies only the keys that are present.
///
/// **BP-pair semantics:** `value` is the systolic component on the
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
    /// The glucose context the edit sheet holds for the row. The optimistic
    /// row is painted with it, and the outbox payload
    /// (`OutboxQueue.Payloads.UpdateMeasurement.glucoseContext`) carries it
    /// across a restart.
    ///
    /// On the wire only when ``sendsGlucoseContext`` is set: server 1.48.0
    /// takes `glucoseContext` on `PUT /api/measurements/{id}` (`null` clears
    /// it, an absent key keeps it). An older server does not, so the sheet
    /// offers no change there and the key stays off.
    public let glucoseContext: GlucoseContext?
    /// Send ``glucoseContext`` (or `null` for "no context"). Set by the edit
    /// sheet only when the context changed and the server takes it
    /// (``GlucoseContextEdit``).
    public let sendsGlucoseContext: Bool

    public init(
        value: Double? = nil,
        measuredAt: Date? = nil,
        notes: String? = nil,
        diastolic: Double? = nil,
        glucoseContext: GlucoseContext? = nil,
        sendsGlucoseContext: Bool = false
    ) {
        self.value = value
        self.measuredAt = measuredAt
        self.notes = notes
        self.diastolic = diastolic
        self.glucoseContext = glucoseContext
        self.sendsGlucoseContext = sendsGlucoseContext
    }

    private enum WireCodingKeys: String, CodingKey {
        case value
        case measuredAt
        case notes
        case glucoseContext
    }

    /// Wire encoding: value / measuredAt / notes, and `glucoseContext` only
    /// when ``sendsGlucoseContext`` (an explicit `null` clears it).
    /// `diastolic` stays off: it is the repository's fan-out signal.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireCodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try container.encodeIfPresent(notes, forKey: .notes)
        if sendsGlucoseContext {
            if let glucoseContext {
                try container.encode(glucoseContext, forKey: .glucoseContext)
            } else {
                try container.encodeNil(forKey: .glucoseContext)
            }
        }
    }

    /// Wire decoding, used for the patch persisted inside an outbox payload:
    /// a present `glucoseContext` key (a value or `null`) is a context edit
    /// that has to go out again on replay. `diastolic` is only ever populated
    /// client-side; replay re-hydrates it from the payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireCodingKeys.self)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        measuredAt = try container.decodeIfPresent(Date.self, forKey: .measuredAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        diastolic = nil
        sendsGlucoseContext = container.contains(.glucoseContext)
        glucoseContext = sendsGlucoseContext
            ? try container.decodeIfPresent(GlucoseContext.self, forKey: .glucoseContext)
            : nil
    }
}

extension MeasurementPatch {
    /// The patch of an edit: the new value (a reading carries its diastolic
    /// for the repository's second leg), time and note, and for a glucose row
    /// its context, sent only when it changed and the server takes it.
    static func edit(
        _ row: Measurement, to value: MeasurementValue, at measuredAt: Date, notes: String?, context: GlucoseContext?,
        serverTakesContext: Bool
    ) -> MeasurementPatch {
        let diastolic: Double? = if case let .bloodPressure(_, d) = value { d } else { nil }
        let glucoseContext = row.kind == .glucose ? context : nil
        return MeasurementPatch(
            value: value.primaryComponent,
            measuredAt: measuredAt,
            notes: notes,
            diastolic: diastolic,
            glucoseContext: glucoseContext,
            sendsGlucoseContext: GlucoseContextEdit.sends(
                kind: row.kind,
                initial: row.glucoseContext,
                edited: glucoseContext,
                supported: serverTakesContext
            )
        )
    }
}

/// Server 1.48.0 takes `glucoseContext` on `PUT /api/measurements/{id}`
/// (#182, part C). Before that the server dropped it, so a changed
/// context was lost without a word.
enum GlucoseContextEdit {
    static let minimumServerVersion = "1.48.0"

    /// Whether the edit sheet offers to change the context: only against a
    /// server known to take it (unknown counts as older).
    static func isSupported(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.isAtLeast(minimumServerVersion, defaults: defaults)
    }

    /// Whether a save sends the context: a glucose row, a server that takes
    /// it, and a context that differs from the one the sheet opened with.
    static func sends(kind: MetricKind, initial: GlucoseContext?, edited: GlucoseContext?, supported: Bool) -> Bool {
        kind == .glucose && supported && edited != initial
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
