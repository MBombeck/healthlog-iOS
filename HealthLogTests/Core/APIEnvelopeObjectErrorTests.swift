import Foundation
@testable import HealthLog
import Testing

/// **CU-32 — Regressionsschloss für die eine Stelle, an der `error` kein String ist.**
///
/// Der Idempotenz-Wrapper (`src/lib/idempotency.ts`) sendet auf seinem
/// In-Flight-409 `error: { message: "…" }`. Vorher warf `APIEnvelope.init(from:)`
/// dort, jeder `try?`-Dekodierversuch in `APIClient` fiel auf `nil`, und
/// Nachricht **und** `errorCode` gingen verloren — ausgerechnet im
/// Outbox-Replay-Pfad, in dem zwei Requests denselben Idempotency-Key tragen.
///
/// Diese Suite pinnt beide Richtungen: die Objekt-Form wird gelesen, **und** die
/// String-Form verhält sich unverändert (die Toleranz darf den Normalfall nicht
/// verschieben).
@Suite("APIEnvelope — `error` als String ODER Objekt")
struct APIEnvelopeObjectErrorTests {
    private func decode(_ json: String) throws -> APIEnvelope<EmptyPayload> {
        try JSONDecoder.hlDefault.decode(APIEnvelope<EmptyPayload>.self, from: Data(json.utf8))
    }

    @Test("the object-shaped error yields its message instead of throwing")
    func objectErrorDecodes() throws {
        let envelope = try decode(
            #"{"data":null,"error":{"message":"A request with this Idempotency-Key is already in progress"}}"#
        )
        #expect(envelope.error == "A request with this Idempotency-Key is already in progress")
        #expect(envelope.errorCode == nil)
    }

    @Test("an object-shaped error does not take errorCode or meta down with it")
    func objectErrorKeepsSiblings() throws {
        let envelope = try decode(
            #"{"data":null,"error":{"message":"nope"},"errorCode":"x.y","meta":{"errorCode":"module.disabled","module":"labs"}}"#
        )
        #expect(envelope.error == "nope")
        #expect(envelope.errorCode == "x.y")
        #expect(envelope.meta?.errorCode == "module.disabled")
        #expect(envelope.meta?.module == "labs")
    }

    @Test("an object-shaped error without a message decodes to nil, not a throw")
    func objectErrorWithoutMessage() throws {
        let envelope = try decode(#"{"data":null,"error":{"code":42}}"#)
        #expect(envelope.error == nil)
    }

    // MARK: - Der Normalfall bleibt unverändert

    @Test("a plain string error still decodes exactly as before")
    func stringErrorUnchanged() throws {
        let envelope = try decode(
            #"{"data":null,"error":"Profile fact changed since it was loaded","meta":{"errorCode":"anamnesis.fact.conflict"}}"#
        )
        #expect(envelope.error == "Profile fact changed since it was loaded")
        #expect(envelope.meta?.errorCode == "anamnesis.fact.conflict")
    }

    @Test("a null error and an absent error key both stay nil")
    func nullAndAbsentErrorStayNil() throws {
        #expect(try decode(#"{"data":null,"error":null}"#).error == nil)
        #expect(try decode(#"{"data":null}"#).error == nil)
    }

    @Test("the success envelope is untouched")
    func successEnvelopeUnchanged() throws {
        struct Payload: Decodable, Sendable, Equatable { let id: String }
        let envelope = try JSONDecoder.hlDefault.decode(
            APIEnvelope<Payload>.self,
            from: Data(#"{"data":{"id":"rev-1"},"error":null}"#.utf8)
        )
        #expect(envelope.data == Payload(id: "rev-1"))
        #expect(envelope.error == nil)
    }
}
