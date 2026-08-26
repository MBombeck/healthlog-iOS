import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

actor StubAPIClient: APIClientProtocol {
    /// Swift 6 strict concurrency rejects `Any` flowing across actor isolation. The
    /// handler trades in `any Sendable` instead — every concrete payload the tests
    /// shovel through (Measurements, Mood, etc.) already conforms to Sendable.
    var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        guard let handler = sendHandler else {
            throw HLError.unknown("no handler")
        }
        let result = try await handler(request)
        guard let typed = result as? T else {
            throw HLError.decoding("type mismatch — handler returned \(type(of: result)), expected \(T.self)")
        }
        return typed
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await sendHandler?(request)
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("not impl")
    }

    func setHandler(_ handler: @escaping @Sendable (any Sendable) async throws -> any Sendable) {
        sendHandler = handler
    }
}

@Suite("MeasurementsRepository")
struct MeasurementsRepositoryTests {
    @Test("Optimistic create with success replaces local entry with server-saved")
    func optimisticHappyPath() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        let m = Measurement(
            id: "local-x",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(72.4)
        )

        // The repo's create() calls `api.send(APIRequest<MeasurementWireDTO>)` — the
        // server returns a wire-shaped record, not a domain Measurement. The repo then
        // refreshes the local id from the wire response. Stub must return the wire shape.
        let savedWire = MeasurementWireDTO(
            id: "server-1",
            type: .weight,
            value: 72.4,
            measuredAt: m.recordedAt
        )

        await api.setHandler { _ in savedWire }

        let result = try await repo.create(m)
        #expect(result.id == "server-1")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty)
    }

    @Test("Optimistic create with retriable error enqueues outbox")
    func enqueueOnFailure() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        await api.setHandler { _ in throw HLError.offline }

        let m = Measurement(id: "local-y", kind: .weight, recordedAt: .now, value: .scalar(72.4))
        do {
            _ = try await repo.create(m)
            Issue.record("expected throw")
        } catch {
            // expected
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .createMeasurement)
    }
}
