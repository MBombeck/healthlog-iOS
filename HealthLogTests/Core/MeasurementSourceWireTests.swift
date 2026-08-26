import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the wire-form for `ServerMeasurementSource`. Server (`measurementSourceEnum`)
/// is the source of truth: `MANUAL | WITHINGS | IMPORT | APPLE_HEALTH`. Any drift
/// here makes every iOS-originated HealthKit POST 422.
@Suite("ServerMeasurementSource wire-form")
struct MeasurementSourceWireTests {
    @Test("APPLE_HEALTH encodes verbatim")
    func appleHealthEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementSource.appleHealth)
        let raw = String(data: data, encoding: .utf8)
        #expect(raw == "\"APPLE_HEALTH\"")
    }

    @Test("Wire decodes APPLE_HEALTH back to the appleHealth case")
    func appleHealthRoundTrip() throws {
        let data = Data("\"APPLE_HEALTH\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
        #expect(decoded == .appleHealth)
    }

    @Test("Legacy HEALTHKIT wire-value is rejected", arguments: ["HEALTHKIT", "healthKit", "AppleHealth"])
    func legacyValueRejected(value: String) {
        let data = Data("\"\(value)\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
        }
    }

    @Test("WHOOP + FITBIT wire-values decode to their cases", arguments: [
        ("WHOOP", ServerMeasurementSource.whoop),
        ("FITBIT", ServerMeasurementSource.fitbit)
    ])
    func ingestSourceRoundTrip(value: String, expected: ServerMeasurementSource) throws {
        let data = Data("\"\(value)\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
        #expect(decoded == expected)
        let reencoded = try String(data: JSONEncoder().encode(expected), encoding: .utf8)
        #expect(reencoded == "\"\(value)\"")
    }

    @Test("All six enum cases round-trip")
    func allCasesRoundTrip() throws {
        let pairs: [(ServerMeasurementSource, String)] = [
            (.manual, "MANUAL"),
            (.appleHealth, "APPLE_HEALTH"),
            (.withings, "WITHINGS"),
            (.whoop, "WHOOP"),
            (.fitbit, "FITBIT"),
            (.import_, "IMPORT")
        ]
        for (source, wire) in pairs {
            let data = try JSONEncoder().encode(source)
            #expect(String(data: data, encoding: .utf8) == "\"\(wire)\"")
            let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
            #expect(decoded == source)
        }
    }

    @Test("Domain ↔ Wire mapping covers every case")
    func domainMapping() {
        let pairs: [(MeasurementSource, ServerMeasurementSource)] = [
            (.manual, .manual),
            (.appleHealth, .appleHealth),
            (.withings, .withings),
            (.import_, .import_)
        ]
        for (domain, wire) in pairs {
            #expect(domain.wire == wire)
            #expect(wire.toDomain() == domain)
        }
    }

    // MARK: - #42 (v1.27.6) — COMPUTED source

    @Test("COMPUTED wire-value round-trips to the computed case")
    func computedRoundTrip() throws {
        let data = Data("\"COMPUTED\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
        #expect(decoded == .computed)
        let reencoded = try String(data: JSONEncoder().encode(ServerMeasurementSource.computed), encoding: .utf8)
        #expect(reencoded == "\"COMPUTED\"")
        #expect(ServerMeasurementSource.computed.toDomain() == .computed)
        #expect(MeasurementSource.computed.wire == .computed)
    }

    @Test("A COMPUTED row survives the tolerant list decode (no silent drop)")
    func computedRowNotDropped() throws {
        // Regression guard for the #42 confirm item: before adding the COMPUTED
        // case the source enum threw on decode, so `TolerantMeasurementWire`
        // dropped every screening (COMPUTED) row — the same failure mode as
        // GOOGLE_HEALTH (#40). The row must now decode + render.
        let json = """
        { "measurements": [
          { "id": "m1", "type": "WEIGHT", "value": 12, "measuredAt": "2026-07-01T08:00:00Z", "source": "COMPUTED" },
          { "id": "m2", "type": "WEIGHT", "value": 80, "measuredAt": "2026-07-01T08:00:00Z", "source": "MANUAL" }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(response.measurements.count == 2)
        #expect(response.measurements.contains { $0.id == "m1" && $0.source == .computed })
    }

    @Test("COMPUTED measurements are read-only, others are editable")
    func computedIsReadOnly() {
        func row(_ source: MeasurementSource) -> HealthLog.Measurement {
            HealthLog.Measurement(id: "x", kind: .weight, recordedAt: Date(), value: .scalar(1), source: source)
        }
        #expect(row(.computed).isServerDerivedReadOnly)
        #expect(!row(.manual).isServerDerivedReadOnly)
        #expect(!row(.appleHealth).isServerDerivedReadOnly)
    }

    @Test("Single-measurement create payload carries APPLE_HEALTH")
    func createDTOEncodesWireValue() throws {
        let measurement = Measurement(
            id: "local-1",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_000_000),
            value: .scalar(72.0),
            source: .appleHealth,
            externalUUID: "ext-1"
        )
        let dtos = measurement.toCreateDTOs()
        #expect(dtos.count == 1)
        let json = try JSONEncoder().encode(dtos[0])
        let raw = String(data: json, encoding: .utf8) ?? ""
        #expect(raw.contains("\"APPLE_HEALTH\""))
        #expect(!raw.contains("\"HEALTHKIT\""))
    }

    // MARK: - #46 (v1.28.11) — STRAVA / OURA / POLAR / NIGHTSCOUT read-only sources

    @Test("New ingest sources round-trip verbatim on the wire", arguments: [
        ("STRAVA", ServerMeasurementSource.strava),
        ("OURA", ServerMeasurementSource.oura),
        ("POLAR", ServerMeasurementSource.polar),
        ("NIGHTSCOUT", ServerMeasurementSource.nightscout)
    ])
    func newIngestSourceRoundTrip(value: String, expected: ServerMeasurementSource) throws {
        let data = Data("\"\(value)\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: data)
        #expect(decoded == expected)
        let reencoded = try String(data: JSONEncoder().encode(expected), encoding: .utf8)
        #expect(reencoded == "\"\(value)\"")
    }

    @Test("New sources map domain ↔ wire totally", arguments: [
        (MeasurementSource.strava, ServerMeasurementSource.strava),
        (MeasurementSource.oura, ServerMeasurementSource.oura),
        (MeasurementSource.polar, ServerMeasurementSource.polar),
        (MeasurementSource.nightscout, ServerMeasurementSource.nightscout)
    ])
    func newSourcesDomainMapping(domain: MeasurementSource, wire: ServerMeasurementSource) {
        #expect(domain.wire == wire)
        #expect(wire.toDomain() == domain)
    }

    @Test("STRAVA/OURA/POLAR/NIGHTSCOUT rows survive the tolerant list decode (no silent drop)")
    func newSourceRowsNotDropped() throws {
        // Same regression guard as the #42 COMPUTED case: before adding these
        // cases the source enum threw on decode, so `TolerantMeasurementWire`
        // dropped every STRAVA/OURA/POLAR/NIGHTSCOUT row — the metric count
        // silently diverged from the server. Each row must now decode + render.
        let json = """
        { "measurements": [
          { "id": "s1", "type": "WEIGHT", "value": 80, "measuredAt": "2026-07-01T08:00:00Z", "source": "STRAVA" },
          { "id": "o1", "type": "WEIGHT", "value": 81, "measuredAt": "2026-07-01T08:00:00Z", "source": "OURA" },
          { "id": "p1", "type": "WEIGHT", "value": 82, "measuredAt": "2026-07-01T08:00:00Z", "source": "POLAR" },
          { "id": "n1", "type": "BLOOD_GLUCOSE", "value": 95, "measuredAt": "2026-07-01T08:00:00Z", "source": "NIGHTSCOUT" }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(response.measurements.count == 4)
        #expect(response.measurements.contains { $0.id == "s1" && $0.source == .strava })
        #expect(response.measurements.contains { $0.id == "o1" && $0.source == .oura })
        #expect(response.measurements.contains { $0.id == "p1" && $0.source == .polar })
        #expect(response.measurements.contains { $0.id == "n1" && $0.source == .nightscout })
    }

    @Test("New ingest sources are server-derived read-only (not writable)", arguments: [
        MeasurementSource.strava, .oura, .polar, .nightscout
    ])
    func newIngestSourcesReadOnly(source: MeasurementSource) {
        let row = HealthLog.Measurement(id: "x", kind: .weight, recordedAt: Date(), value: .scalar(1), source: source)
        #expect(row.isServerDerivedReadOnly)
    }
}
