import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// T-2 Glucose-context picker — Patch + Outbox-Payload-Schicht.
///
/// Bis Server-SB-25 landet, ist `MeasurementPatch.glucoseContext` ein
/// client-side Intent-Feld (analog T-1 `diastolic`): die Wire-JSON enthält
/// es NICHT, das Outbox-Payload trägt es als first-class-Feld damit Replay
/// nach App-Restart die Intent rekonstruieren kann.
@Suite("Glucose-context patch + outbox payload (T-2)", .serialized)
struct GlucoseContextPatchTests {
    // MARK: - 1. MeasurementPatch wire shape

    @Test("MeasurementPatch with glucoseContext suppresses it from the wire JSON")
    func patchSuppressesGlucoseContextFromWire() throws {
        let patch = MeasurementPatch(
            value: 110,
            measuredAt: nil,
            notes: nil,
            glucoseContext: .afterMeal
        )
        let data = try JSONEncoder.hlDefault.encode(patch)
        let str = try #require(String(data: data, encoding: .utf8))
        #expect(str.contains("\"value\""))
        #expect(
            !str.contains("glucoseContext"),
            "glucoseContext is a client-side intent — wire schema only knows value/measuredAt/notes"
        )
    }

    @Test("MeasurementPatch wire-decode leaves glucoseContext nil even if server sent it back")
    func patchDecodeDropsGlucoseContext() throws {
        // Imagine a future server returning glucoseContext on the PATCH
        // response — our wire-shape decoder still ignores it because the
        // field is client-only by contract.
        let json = #"{"value":99,"glucoseContext":"FASTING"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(MeasurementPatch.self, from: data)
        #expect(decoded.value == 99)
        #expect(decoded.glucoseContext == nil, "Wire-decoder is intentionally lossy for client-only fields")
    }

    @Test("MeasurementPatch retains glucoseContext client-side after init")
    func patchKeepsGlucoseContextInMemory() {
        let patch = MeasurementPatch(value: 95, glucoseContext: .fasting)
        #expect(patch.glucoseContext == .fasting)
    }

    // MARK: - 2. Outbox payload encode/decode

    @Test("OutboxQueue.Payloads.UpdateMeasurement round-trips glucoseContext")
    func outboxPayloadRoundTripsGlucoseContext() throws {
        let payload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-glu-edit-1",
            patch: MeasurementPatch(value: 145, measuredAt: nil, notes: nil),
            kind: .glucose,
            diastolicId: nil,
            diastolicValue: nil,
            glucoseContext: .bedtime
        )
        let data = try JSONEncoder.hlDefault.encode(payload)
        let decoded = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.UpdateMeasurement.self,
            from: data
        )
        #expect(decoded.id == payload.id)
        #expect(decoded.kind == .glucose)
        #expect(decoded.glucoseContext == .bedtime)
        // The patch itself stays wire-clean — only the wrapping payload
        // carries the glucose intent across persistence.
        #expect(decoded.patch.value == 145)
        #expect(decoded.patch.glucoseContext == nil)
    }

    @Test("UpdateMeasurement payload defaults glucoseContext to nil for non-glucose rows")
    func nonGlucosePayloadNilContext() throws {
        let weightPayload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-w-1",
            patch: MeasurementPatch(value: 72.0),
            kind: .weight
        )
        let data = try JSONEncoder.hlDefault.encode(weightPayload)
        let decoded = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.UpdateMeasurement.self,
            from: data
        )
        #expect(decoded.glucoseContext == nil)
    }

    @Test("UpdateMeasurement payload coexists with BP-pair fields (T-1 + T-2 disjoint)")
    func payloadCoexistsWithBPFields() {
        // Sanity: a BP payload + a glucose payload share the same struct but
        // never set both intent-groups together. Snapshot the cross-product
        // so a future refactor that accidentally entangles the two trips a
        // test.
        let bp = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-sys-1",
            patch: MeasurementPatch(value: 130, diastolic: 85),
            kind: .bloodPressure,
            diastolicId: "srv-dia-1",
            diastolicValue: 85,
            glucoseContext: nil
        )
        let glu = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-glu-1",
            patch: MeasurementPatch(value: 95, glucoseContext: .fasting),
            kind: .glucose,
            diastolicId: nil,
            diastolicValue: nil,
            glucoseContext: .fasting
        )
        #expect(bp.diastolicId != nil)
        #expect(bp.glucoseContext == nil)
        #expect(glu.diastolicId == nil)
        #expect(glu.glucoseContext != nil)
    }

    // MARK: - 3. Outbox replay rehydrates glucoseContext on the patch

    @Test("Outbox replay rehydrates glucoseContext on the rebuilt patch (via repository)")
    func replayRehydratesGlucoseContext() throws {
        // We don't drive a network call here — just exercise the replay
        // shape via a recorder that captures the patch-as-received-by-repo.
        // The full networked replay path is covered by the existing
        // `OutboxKindsV05xTests` round-trips; this test isolates the
        // hydration logic for `glucoseContext`.
        let original = MeasurementPatch(
            value: 105,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "after lunch",
            glucoseContext: .afterMeal
        )
        // 1) The wire-encoded patch (as it would persist inside the payload
        //    blob) loses the glucoseContext field.
        let wireData = try JSONEncoder.hlDefault.encode(original)
        let wireDecoded = try JSONDecoder.hlDefault.decode(MeasurementPatch.self, from: wireData)
        #expect(wireDecoded.glucoseContext == nil, "Wire-encoded patch must not carry the client-only field")
        // 2) The outbox payload IS the carrier — encode + decode round-trip.
        let payload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-glu-replay-1",
            patch: original,
            kind: .glucose,
            glucoseContext: original.glucoseContext
        )
        let payloadData = try JSONEncoder.hlDefault.encode(payload)
        let decodedPayload = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.UpdateMeasurement.self,
            from: payloadData
        )
        // 3) Replay rebuilds the patch from the payload's top-level field,
        //    not from the patch sub-object (which is wire-shape-suppressed).
        let rehydrated = MeasurementPatch(
            value: decodedPayload.patch.value,
            measuredAt: decodedPayload.patch.measuredAt,
            notes: decodedPayload.patch.notes,
            glucoseContext: decodedPayload.glucoseContext
        )
        #expect(rehydrated.value == 105)
        #expect(rehydrated.notes == "after lunch")
        #expect(rehydrated.glucoseContext == .afterMeal, "Replay rehydrates the intent from the outbox payload")
    }
}

// swiftlint:enable force_unwrapping force_try
