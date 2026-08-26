import Foundation
import Testing

// swiftlint:disable force_unwrapping

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-35 (3) — `correlationEnabled` on a custom metric.**
///
/// It is a **consent to an analysis**, not a display option: switching it on
/// lets the server put this metric's values next to the rest of the health
/// record looking for associations. Two things therefore have to hold on the
/// wire, and both are pinned here:
///
///  1. The default is `false` and nothing may turn it on by accident — not an
///     omitted key, not an old Outbox row, not an undo.
///  2. A `PATCH` that does not mention it leaves the stored consent alone; only
///     an explicit boolean changes it (`z.boolean().optional()` on
///     `updateCustomMetricSchema`, which has no null arm).
@Suite("CU-35 — custom-metric correlation consent")
struct CustomMetricCorrelationTests {
    private static func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - Create

    @Test("a new metric states the consent explicitly, and it defaults to OFF")
    func createDefaultsToFalse() throws {
        let json = try Self.jsonObject(CustomMetricCreate(name: "Griffkraft", unit: "kg"))
        // Always emitted, unlike the optional bounds: an explicit `false` means
        // the stored value can never disagree with the switch the user saw.
        #expect(json["correlationEnabled"] as? Bool == false)
    }

    @Test("switching the consent on sends `true`")
    func createCarriesTrue() throws {
        let json = try Self.jsonObject(
            CustomMetricCreate(name: "Griffkraft", unit: "kg", correlationEnabled: true)
        )
        #expect(json["correlationEnabled"] as? Bool == true)
    }

    @Test("an Outbox row queued before CU-35 replays as OFF instead of failing to decode")
    func createDecodesLegacyOutboxRow() throws {
        // The exact bytes a pre-CU-35 build persisted. A synthesised decode of a
        // non-optional Bool would throw here, and the queued create would never
        // drain.
        let legacy = Data(#"{"name":"Griffkraft","unit":"kg","decimals":1}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(CustomMetricCreate.self, from: legacy)
        #expect(decoded.name == "Griffkraft")
        #expect(decoded.decimals == 1)
        #expect(decoded.correlationEnabled == false, "never assume a consent that was not stated")
    }

    @Test("the create body round-trips through the Outbox codec")
    func createRoundTrips() throws {
        let original = CustomMetricCreate(
            name: "Griffkraft", unit: "kg", targetLow: 40, decimals: 1, correlationEnabled: true
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        #expect(try JSONDecoder.hlDefault.decode(CustomMetricCreate.self, from: data) == original)
    }

    // MARK: - Patch

    @Test("a patch that does not mention the consent leaves it alone")
    func patchOmitsWhenUnchanged() throws {
        let json = try Self.jsonObject(CustomMetricPatch(name: "Neuer Name"))
        #expect(
            !json.keys.contains("correlationEnabled"),
            "an omitted key is 'leave the column alone' — the consent must not be restated by accident"
        )
    }

    @Test("an explicit consent change is sent as a plain boolean, never as null")
    func patchSendsExplicitBoolean() throws {
        let on = try Self.jsonObject(CustomMetricPatch(correlationEnabled: true))
        #expect(on["correlationEnabled"] as? Bool == true)

        let off = try Self.jsonObject(CustomMetricPatch(correlationEnabled: false))
        #expect(off["correlationEnabled"] as? Bool == false)

        // `updateCustomMetricSchema` gives it no `.or(z.null())` arm, so an
        // explicit null would be a 422.
        let encoded = try JSONEncoder.hlDefault.encode(CustomMetricPatch(correlationEnabled: false))
        let raw = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!raw.contains("null"))
    }

    @Test("the editor's full-surface edit carries the switch the user is looking at")
    func fullEditCarriesConsent() throws {
        let patch = CustomMetricPatch.fullEdit(
            name: "Griffkraft", unit: "kg",
            targetLow: nil, targetHigh: nil,
            decimals: nil, description: nil,
            correlationEnabled: true
        )
        let json = try Self.jsonObject(patch)
        #expect(json["correlationEnabled"] as? Bool == true)
        // The clearable columns keep their explicit-null semantics alongside it.
        #expect(json["targetLow"] is NSNull)
    }

    @Test("a patch round-trips through the Outbox codec, three states intact")
    func patchRoundTrips() throws {
        let original = CustomMetricPatch(
            name: "A", targetLow: .clear, decimals: .set(2), correlationEnabled: true
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        #expect(try JSONDecoder.hlDefault.decode(CustomMetricPatch.self, from: data) == original)

        let untouched = CustomMetricPatch(name: "A")
        let untouchedData = try JSONEncoder.hlDefault.encode(untouched)
        let decoded = try JSONDecoder.hlDefault.decode(CustomMetricPatch.self, from: untouchedData)
        #expect(decoded.correlationEnabled == nil)
    }

    // MARK: - Read

    @Test("the read DTO decodes the server's stored consent")
    func dtoDecodesConsent() throws {
        let json = Data(#"""
        {"id":"m1","name":"Griffkraft","unit":"kg","correlationEnabled":true,
         "createdAt":"2026-07-01T00:00:00.000Z","updatedAt":"2026-07-01T00:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(dto.correlationEnabled)
    }

    @Test("a payload without the key reads as OFF, never as consented")
    func dtoDefaultsToOff() throws {
        let json = Data(#"{"id":"m1","name":"Griffkraft","unit":"kg"}"#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(!dto.correlationEnabled)
    }

    @Test("the list envelope carries the consent through to each row")
    func listCarriesConsent() throws {
        let json = Data(#"""
        {"customMetrics":[
          {"id":"m1","name":"A","unit":"kg","correlationEnabled":true},
          {"id":"m2","name":"B","unit":"reps","correlationEnabled":false}
        ]}
        """#.utf8)
        let list = try JSONDecoder.hlDefault.decode(ListCustomMetricsResponse.self, from: json)
        #expect(list.customMetrics.map(\.correlationEnabled) == [true, false])
    }
}

// swiftlint:enable force_unwrapping
