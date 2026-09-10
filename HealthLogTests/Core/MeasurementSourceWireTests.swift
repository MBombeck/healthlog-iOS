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

    /// Audit B-4 (2026-09-10) changed what "rejected" means here. A legacy or
    /// misspelled literal used to throw, and on the list path that throw cost
    /// the whole measurement row. It now lands on the ``unknown`` sentinel: the
    /// row survives with a generic provenance label, and the value is still
    /// refused everywhere it matters — it is not `.appleHealth`, it never
    /// round-trips onto the wire, and it is not a server case.
    @Test(
        "Legacy HEALTHKIT wire-value is refused, but no longer at the row's expense",
        arguments: ["HEALTHKIT", "healthKit", "AppleHealth"]
    )
    func legacyValueRejected(value: String) throws {
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: Data("\"\(value)\"".utf8))
        #expect(decoded == .unknown)
        #expect(decoded != .appleHealth, "a legacy spelling must never resolve to the real Apple-Health source")
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(decoded)
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

    // MARK: - #106 (server PR #892) — EXTERNAL ingest-token source

    @Test("An EXTERNAL row survives the tolerant list decode (no silent drop)")
    func externalRowNotDropped() throws {
        // Third time for the same failure mode (COMPUTED #42, then STRAVA/OURA/
        // POLAR/NIGHTSCOUT #46): a wire value the source enum cannot decode
        // makes `TolerantMeasurementWire` drop the whole row, so everything
        // written through an ingest Bearer token (Home Assistant bridges, scale
        // scripts) vanishes from the app and the count diverges from the server.
        let json = """
        { "measurements": [
          { "id": "e1", "type": "WEIGHT", "value": 80, "measuredAt": "2026-09-01T08:00:00Z", "source": "EXTERNAL" },
          { "id": "m1", "type": "WEIGHT", "value": 81, "measuredAt": "2026-09-01T08:00:00Z", "source": "MANUAL" }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(response.measurements.count == 2)
        #expect(response.measurements.contains { $0.id == "e1" && $0.source == .external })
    }

    @Test("EXTERNAL round-trips verbatim and maps domain ↔ wire totally")
    func externalRoundTrip() throws {
        let data = Data("\"EXTERNAL\"".utf8)
        #expect(try JSONDecoder().decode(ServerMeasurementSource.self, from: data) == .external)
        let reencoded = try String(data: JSONEncoder().encode(ServerMeasurementSource.external), encoding: .utf8)
        #expect(reencoded == "\"EXTERNAL\"")
        #expect(ServerMeasurementSource.external.toDomain() == .external)
        #expect(MeasurementSource.external.wire == .external)
    }

    @Test("EXTERNAL is server-owned read-only and never mirrored into Apple Health")
    func externalIsReadOnly() {
        // `EXTERNAL` is absent from the server's `WRITABLE_MEASUREMENT_SOURCES`
        // (`{MANUAL, APPLE_HEALTH}`) — a client-named source on the ingest path
        // is refused with `measurement.batch.source_not_permitted`. So the row
        // renders but never offers a value-edit path, and the server→Apple-
        // Health mirror must never author it.
        let row = HealthLog.Measurement(id: "x", kind: .weight, recordedAt: Date(), value: .scalar(1), source: .external)
        #expect(row.isServerDerivedReadOnly)
        #expect(!MeasurementSource.external.isServerMirrorEligible)
    }

    // MARK: - TELEGRAM / MCP — already dropped before EXTERNAL existed

    @Test("TELEGRAM and MCP rows survive the tolerant list decode (no silent drop)")
    func serverWrittenRowsNotDropped() throws {
        // `measurementSourceEnum` has carried TELEGRAM since server v1.19.2 and
        // MCP since v1.22.0 (`src/lib/validations/measurement.ts:204` + `:211`)
        // and neither had a case here — so a numeric reply to a Telegram
        // reminder, and anything logged through the MCP write surface, were
        // being dropped in the app already, before EXTERNAL was proposed. Same
        // failure mode, found while adding it.
        let json = """
        { "measurements": [
          { "id": "t1", "type": "WEIGHT", "value": 80, "measuredAt": "2026-09-01T08:00:00Z", "source": "TELEGRAM" },
          { "id": "c1", "type": "WEIGHT", "value": 81, "measuredAt": "2026-09-01T08:00:00Z", "source": "MCP" },
          { "id": "m1", "type": "WEIGHT", "value": 82, "measuredAt": "2026-09-01T08:00:00Z", "source": "MANUAL" }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(response.measurements.count == 3)
        #expect(response.measurements.contains { $0.id == "t1" && $0.source == .telegram })
        #expect(response.measurements.contains { $0.id == "c1" && $0.source == .mcp })
        #expect(response.measurements.contains { $0.id == "m1" && $0.source == .manual })
    }

    @Test("TELEGRAM and MCP round-trip verbatim and map domain ↔ wire totally", arguments: [
        ("TELEGRAM", ServerMeasurementSource.telegram, MeasurementSource.telegram),
        ("MCP", ServerMeasurementSource.mcp, MeasurementSource.mcp)
    ])
    func serverWrittenSourceRoundTrip(value: String, wire: ServerMeasurementSource, domain: MeasurementSource) throws {
        let data = Data("\"\(value)\"".utf8)
        #expect(try JSONDecoder().decode(ServerMeasurementSource.self, from: data) == wire)
        #expect(try String(data: JSONEncoder().encode(wire), encoding: .utf8) == "\"\(value)\"")
        #expect(wire.toDomain() == domain)
        #expect(domain.wire == wire)
    }

    @Test("TELEGRAM and MCP mirror the server's own edit rule", arguments: [
        MeasurementSource.telegram, .mcp
    ])
    func serverWrittenSourcesReadOnly(source: MeasurementSource) {
        // `src/app/api/measurements/[id]/route.ts:126-141` refuses a value edit
        // with 409 `measurement.update.server_owned_source` for any stored
        // source outside `WRITABLE_MEASUREMENT_SOURCES` (`{MANUAL,
        // APPLE_HEALTH}`). Neither TELEGRAM nor MCP is in that list, so the app
        // shows them read-only like COMPUTED rather than offering an edit the
        // server would reject. Neither is on the closed Apple-Health mirror
        // allowlist (`{withings, import_}`).
        let row = HealthLog.Measurement(id: "x", kind: .weight, recordedAt: Date(), value: .scalar(1), source: source)
        #expect(row.isServerDerivedReadOnly)
        #expect(!source.isServerMirrorEligible)
    }
}
