import Foundation

// Moved out of `MeasurementDTO.swift` (#162) so that file, which sits on
// a baselined `file_length` ceiling, has room for the Garmin types. Pure move.

/// Server-List-Response.
///
/// **v0.6.2.1 — tolerant `measurements` decode (F3 drill-down fix).** The
/// Prisma `MeasurementType` enum on the server is a superset of
/// `ServerMeasurementType` here — it also carries `ACTIVITY_STEPS`,
/// `SLEEP_DURATION`, `ACTIVE_ENERGY_BURNED`, `FLIGHTS_CLIMBED`,
/// `WALKING_RUNNING_DISTANCE`, `AUDIO_EXPOSURE_*` and any future
/// server-only type. Whenever an
/// HK-batch upload (or Withings sync) populates one of those rows, every
/// drill-down that calls `GET /api/measurements?limit=400` saw the whole
/// `[MeasurementWireDTO]` decode reject with `dataCorrupted` on the
/// unknown enum case, leaving the user staring at "Daten konnten nicht
/// gelesen werden" with an empty list. Operator hit this on the Steps
/// chart (845 entries) on 2026-05-24.
///
/// Same tolerant pattern as `TolerantMetricKind` (v0.4.0 A4-Audit row 5)
/// — log + drop unknown rows, keep the array intact for the known
/// metrics the iOS surfaces actually render.
public struct MeasurementListWireResponse: Codable, Sendable {
    public let measurements: [MeasurementWireDTO]
    public let meta: MeasurementListResponse.ListMeta?

    public init(measurements: [MeasurementWireDTO], meta: MeasurementListResponse.ListMeta? = nil) {
        self.measurements = measurements
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case measurements
        case meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tolerant = try container.decode([TolerantMeasurementWire].self, forKey: .measurements)
        measurements = tolerant.compactMap(\.value)
        meta = try container.decodeIfPresent(MeasurementListResponse.ListMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(measurements, forKey: .measurements)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Tolerant element wrapper used inside `MeasurementListWireResponse` so a
/// single row carrying a `type` outside `ServerMeasurementType` (e.g.
/// `ACTIVITY_STEPS` until the iOS enum catches up) doesn't reject the whole
/// 400-row page. Mirrors `TolerantMetricKind`'s "log + continue" contract.
private struct TolerantMeasurementWire: Decodable {
    let value: MeasurementWireDTO?

    init(from decoder: Decoder) throws {
        do {
            value = try MeasurementWireDTO(from: decoder)
        } catch {
            // Best-effort surface the offending `type` for diagnostics —
            // every other field is uninteresting once the enum check fails.
            let container = try? decoder.container(keyedBy: DiagnosticKey.self)
            let rawType = try? container?.decodeIfPresent(String.self, forKey: .type)
            HLLog.api.warning(
                "Dropping measurement wire row with unsupported type \(rawType ?? "<unknown>", privacy: .public)"
            )
            value = nil
        }
    }

    private enum DiagnosticKey: String, CodingKey {
        case type
    }
}
