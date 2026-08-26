import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-18 — Glukose-Kontext: nullbar UND offen.**
///
/// Zwei getrennte Server-Realitäten, beide auf demselben Feld:
///
/// 1. **Migration 0274:** `glucoseContext` darf auf einer `BLOOD_GLUCOSE`-Zeile
///    `null` sein. Kein Lesepfad darf daraus einen Kontext erfinden.
/// 2. **Offenes Enum:** `GlucoseContext` ist client-seitig ein geschlossenes
///    Vier-Fall-Enum (es speist die Picker über `CaseIterable`). Ein neues
///    Server-Literal warf früher MITTEN im `MeasurementWireDTO`-Decode: die
///    Listenroute verwarf über `TolerantMeasurementWire` die ganze Zeile, jeder
///    Einzel-Decode fiel als `HLError.decoding` hart um. Jetzt fängt der
///    Wire-Decoder das Literal ab.
///
/// Getrieben über den **echten** ``APIClient`` mit `MockURLProtocol`.
@Suite("CU-18 — glucoseContext nullbar + tolerant", .serialized)
struct GlucoseContextNullabilityWireTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    private func glucoseRow(id: String, context: String) -> String {
        #"""
        {"id":"\#(id)","type":"BLOOD_GLUCOSE","value":98,"measuredAt":"2026-07-01T08:00:00.000Z",
        "notes":null,"source":"MANUAL","glucoseContext":\#(context),"externalId":null}
        """#
    }

    private func fetchSingle(_ json: String) async throws -> MeasurementWireDTO {
        respond(json)
        let req = APIRequest<MeasurementWireDTO>.get("/api/measurements/m-1")
        return try await makeClient().send(req)
    }

    private func fetchList(_ rows: [String]) async throws -> MeasurementListWireResponse {
        respond(#"{"data":{"measurements":[\#(rows.joined(separator: ","))]}}"#)
        let req = APIRequest<MeasurementListWireResponse>.get("/api/measurements")
        return try await makeClient().send(req)
    }

    // MARK: - 1. Nullbarkeit (Migration 0274)

    @Test("BLOOD_GLUCOSE mit glucoseContext: null decodiert ohne erfundenen Kontext")
    func nullContextOnGlucoseRow() async throws {
        let wire = try await fetchSingle(#"{"data":\#(glucoseRow(id: "m-1", context: "null"))}"#)
        #expect(wire.type == .bloodGlucose)
        #expect(wire.glucoseContext == nil)

        let domain = try #require(wire.toDomain())
        #expect(domain.kind == .glucose)
        #expect(domain.glucoseContext == nil, "nil bleibt nil — kein Default auf .fasting o. ä.")
    }

    @Test("Fehlender glucoseContext-Schlüssel verhält sich wie null")
    func absentContextKey() async throws {
        let json = #"""
        {"data":{"id":"m-2","type":"BLOOD_GLUCOSE","value":112,
        "measuredAt":"2026-07-01T09:00:00.000Z","source":"MANUAL"}}
        """#
        let wire = try await fetchSingle(json)
        #expect(wire.glucoseContext == nil)
        #expect(wire.toDomain()?.glucoseContext == nil)
    }

    @Test("Gemischte Liste: Zeilen mit und ohne Kontext kommen beide durch")
    func mixedListKeepsBothShapes() async throws {
        let list = try await fetchList([
            glucoseRow(id: "m-1", context: "null"),
            glucoseRow(id: "m-2", context: "\"FASTING\"")
        ])
        #expect(list.measurements.count == 2)
        #expect(list.measurements[0].glucoseContext == nil)
        #expect(list.measurements[1].glucoseContext == .fasting)
    }

    @Test("Die vier bekannten Literale mappen unverändert", arguments: [
        ("FASTING", GlucoseContext.fasting),
        ("BEFORE_MEAL", GlucoseContext.beforeMeal),
        ("AFTER_MEAL", GlucoseContext.afterMeal),
        ("BEDTIME", GlucoseContext.bedtime)
    ])
    func knownLiteralsStillMap(literal: String, expected: GlucoseContext) async throws {
        let quoted = "\"\(literal)\""
        let wire = try await fetchSingle(#"{"data":\#(glucoseRow(id: "m-1", context: quoted))}"#)
        #expect(wire.glucoseContext == expected)
        #expect(wire.toDomain()?.glucoseContext == expected)
    }

    // MARK: - 2. Unbekanntes Literal (Gefahrenklasse #71, anderes Feld)

    @Test("Unbekanntes Kontext-Literal wirft NICHT auf dem Einzel-Decode")
    func unknownLiteralDoesNotThrowOnSingleDecode() async throws {
        // Regressionswächter: vor CU-18 warf das geschlossene Enum hier, und der
        // Aufrufer sah `HLError.decoding` statt einer Messung.
        let wire = try await fetchSingle(#"{"data":\#(glucoseRow(id: "m-1", context: "\"POST_WORKOUT\""))}"#)
        #expect(wire.id == "m-1")
        #expect(wire.value == 98)
        #expect(wire.glucoseContext == nil, "Unbenennbarer Kontext → kein Label, aber die Zeile bleibt")
        #expect(wire.toDomain()?.glucoseContext == nil)
    }

    @Test("Unbekanntes Kontext-Literal lässt die Listenzeile NICHT mehr fallen")
    func unknownLiteralKeepsListRow() async throws {
        let list = try await fetchList([
            glucoseRow(id: "m-unknown", context: "\"POST_WORKOUT\""),
            glucoseRow(id: "m-known", context: "\"BEDTIME\"")
        ])
        // Früher: 1 Zeile (die unbekannte wurde von `TolerantMeasurementWire`
        // verworfen und die Messreihe divergierte still vom Server).
        #expect(list.measurements.count == 2)
        #expect(list.measurements.map(\.id) == ["m-unknown", "m-known"])
        #expect(list.measurements[0].glucoseContext == nil)
        #expect(list.measurements[1].glucoseContext == .bedtime)
    }

    @Test("Kontext auf einer Nicht-Glukose-Zeile bleibt folgenlos")
    func contextOnNonGlucoseRowIsHarmless() async throws {
        let json = #"""
        {"data":{"id":"w-1","type":"WEIGHT","value":80.5,"measuredAt":"2026-07-01T08:00:00.000Z",
        "source":"MANUAL","glucoseContext":null}}
        """#
        let wire = try await fetchSingle(json)
        #expect(wire.type == .weight)
        #expect(wire.glucoseContext == nil)
        #expect(wire.toDomain()?.kind == .weight)
    }

    // MARK: - 3. Schreibpfad bleibt unverändert (Asymmetrie)

    @Test("POST-Body trägt den Kontext weiterhin verbatim — der Schreibpfad ist unangetastet")
    func createDTOStillEmitsContext() throws {
        let dto = MeasurementCreateDTO(
            type: .bloodGlucose,
            value: 95,
            measuredAt: Date(timeIntervalSince1970: 1_780_000_000),
            source: .manual,
            glucoseContext: .fasting
        )
        let raw = try #require(String(bytes: JSONEncoder.hlDefault.encode(dto), encoding: .utf8))
        #expect(raw.contains("\"glucoseContext\":\"FASTING\""))

        // Und ohne Kontext wird auch keiner erfunden.
        let without = MeasurementCreateDTO(
            type: .bloodGlucose,
            value: 95,
            measuredAt: Date(timeIntervalSince1970: 1_780_000_000),
            source: .manual
        )
        let rawWithout = try #require(String(bytes: JSONEncoder.hlDefault.encode(without), encoding: .utf8))
        #expect(!rawWithout.contains("FASTING"))
    }

    @Test("Der Kontext-Picker bietet weiterhin genau die vier Server-Literale an")
    func pickerHasNoInventedCase() {
        #expect(GlucoseContext.allCases.map(\.rawValue) == ["FASTING", "BEFORE_MEAL", "AFTER_MEAL", "BEDTIME"])
    }
}
